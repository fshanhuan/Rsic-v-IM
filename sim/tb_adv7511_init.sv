`timescale 1ns / 1ps

/* =============================================================================
 * tb_adv7511_init.sv — 验证 ADV7511 自动配置状态机
 * -----------------------------------------------------------------------------
 * 从机模型：一个"只会被写"的 ADV7511
 *   · 7 位地址 0x39 应答，其它字节一律 ACK
 *   · 把每次 (reg, val) 记进 writes[]，按顺序对比
 *
 * 判据：
 *   A1 表里 14 项全部写完，顺序与 reg/val 完全一致
 *   A2 最后一项是 0x41=0x10（退出掉电，必须在最后）
 *   A3 done=1、busy=0、no_dev=0
 *   A4 器件不在（+noslave）时不误判：no_dev=1、done=0、ack_err>0
 * ============================================================================= */
module tb_adv7511_init;

    localparam int CLK_HZ = 4_000_000;      // 仿真加速，SCL 仍 100 kHz
    localparam int SCL_HZ = 100_000;

    logic clk = 1'b0;
    always #125 clk = ~clk;                  // 4 MHz

    logic rst = 1'b1;
    logic start = 1'b0;

    logic scl_oe, sda_oe, sda_i;

    logic        busy, done, no_dev;
    logic [4:0]  cur_idx;
    logic [7:0]  last_reg, last_val;
    logic [15:0] ack_err;

    /* ---------------- 开漏线与 ---------------- */
    logic slave_low;
    initial slave_low = 1'b0;

    wire scl_w = scl_oe ? 1'b0 : 1'b1;
    wire sda_w = (sda_oe | slave_low) ? 1'b0 : 1'b1;
    assign sda_i = sda_w;

    /* ---------------- 从机模型 ---------------- */
    localparam logic [6:0] ADDR = 7'h39;

    logic slave_en;
    initial begin
        slave_en = 1'b1;
        if ($test$plusargs("noslave")) slave_en = 1'b0;
    end

    logic [7:0] sh;
    logic [3:0] bitcnt;         // 0..8
    logic       ack_phase;
    logic [1:0] ast;            // 0=idle 1=reg 2=val
    logic [7:0] regptr;
    logic [7:0] mem [0:255];

    logic [15:0] writes [0:63];
    int          nwr = 0;

    logic scl_d, sda_d;

    /* ★ 必须显式初始化：iverilog 对"声明处赋初值"的模块级 logic 有时按线网处理，
     *   而状态变量若从 X 起步，itcnt < 8 恒为假 —— 从机永远走不到 ACK 决策，
     *   现象就是"一条 [SLV] 都不打印、主控收到 NACK"。 */
    initial begin
        scl_d     = 1'b1;
        sda_d     = 1'b1;
        bitcnt    = 4'd0;
        ack_phase = 1'b0;
        ast       = 2'd0;
        sh        = 8'd0;
        regptr    = 8'd0;
    end
    wire startc = ~scl_w & scl_d;            // 占位（下面用 SDA 判 START）
    wire sda_fall = ~sda_w & sda_d;
    wire sda_rise = sda_w & ~sda_d;

    int n_rise = 0, n_fall = 0, n_start = 0;
    always @(posedge clk) begin
        scl_d <= scl_w;
        sda_d <= sda_w;
        if (scl_w & ~scl_d) n_rise <= n_rise + 1;
        if (~scl_w & scl_d) n_fall <= n_fall + 1;
        if (~sda_w & sda_d & scl_w) n_start <= n_start + 1;

        if (sda_fall && scl_w) begin
            $display("[SLV] START t=%0t", $time);
            /* START */
            ast       <= 2'd0;
            bitcnt    <= 4'd0;
            ack_phase <= 1'b0;
            slave_low <= 1'b0;
            sh        <= 8'd0;
        end else if (sda_rise && scl_w) begin
            /* STOP */
            ast       <= 2'd0;
            slave_low <= 1'b0;
        end else if (scl_w & ~scl_d) begin
            /* rising：采样一位 */
            if (bitcnt < 4'd8) begin
                sh[7 - bitcnt[2:0]] <= sda_w;
                bitcnt <= bitcnt + 4'd1;
            end
        end else if (~scl_w & scl_d) begin
            /* falling */
            if (bitcnt == 4'd8 && !ack_phase) begin
                /* 第 8 位之后的下降沿：准备 ACK */
                ack_phase <= 1'b1;
                $display("[SLV] t=%0t ack? ast=%0d byte=%02h match=%b en=%b",
                         $time, ast, sh, (sh[7:1]==ADDR), slave_en);
                case (ast)
                    2'd0: slave_low <= (slave_en && (sh[7:1] == ADDR));
                    2'd1: slave_low <= slave_en;
                    2'd2: slave_low <= slave_en;
                    default: slave_low <= 1'b0;
                endcase
            end else if (ack_phase) begin
                /* ACK 位结束：处理刚收到的字节 */
                ack_phase <= 1'b0;
                slave_low <= 1'b0;
                if (bitcnt == 4'd8 && slave_en) begin
                    case (ast)
                        2'd0: ast <= (sh[0] == 1'b0) ? 2'd1 : 2'd0;   // 写：下一步收 reg
                        2'd1: begin
                            regptr <= sh;
                            ast    <= 2'd2;
                        end
                        2'd2: begin
                            mem[regptr] = sh;
                            if (nwr < 64) writes[nwr] = {regptr, sh};
                            nwr    <= nwr + 1;
                            ast    <= 2'd1;
                        end
                        default: ;
                    endcase
                end
                bitcnt <= 4'd0;
                sh     <= 8'd0;
            end
        end
    end

    int errors = 0;
    task automatic chk(input string nm, input longint got, input longint exp);
        if (got == exp) $display("[PASS] %-32s = %0d", nm, got);
        else begin $display("[FAIL] %-32s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    /* 与 DUT 表一致的期望序列 */
    function automatic logic [15:0] exp_tbl(input int i);
        case (i)
            0: exp_tbl = 16'h9803;
            1: exp_tbl = 16'h9AE0;
            2: exp_tbl = 16'h9C30;
            3: exp_tbl = 16'h9D61;
            4: exp_tbl = 16'hA2A4;
            5: exp_tbl = 16'hA3A4;
            6: exp_tbl = 16'hAF04;
            7: exp_tbl = 16'h1501;
            8: exp_tbl = 16'h1630;
            9: exp_tbl = 16'h1700;
            10: exp_tbl = 16'h1846;
            11: exp_tbl = 16'h3B00;
            12: exp_tbl = 16'h4C00;
            13: exp_tbl = 16'h4110;
            default: exp_tbl = 16'h0000;
        endcase
    endfunction

    adv7511_init #(
        .CLK_HZ   (CLK_HZ),
        .SCL_HZ   (SCL_HZ),
        .RETRY_CY (200_000)          // 仿真里缩短重试间隔
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .start    (start),
        .scl_oe   (scl_oe),
        .sda_oe   (sda_oe),
        .sda_i    (sda_i),
        .busy     (busy),
        .done     (done),
        .no_dev   (no_dev),
        .cur_idx  (cur_idx),
        .last_reg (last_reg),
        .last_val (last_val),
        .ack_err  (ack_err)
    );

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;


        if ($test$plusargs("noslave")) begin
            /* 器件不在：应当 no_dev=1、done=0、ack_err 增长 */
            repeat (60) @(posedge clk);
            wait (ack_err > 0);
            @(posedge clk);
            chk("无器件 no_dev", no_dev, 1);
            chk("无器件 done",   done,   0);
            chk("无器件 ack_err>0", ack_err > 0 ? 1 : 0, 1);
        end else begin
            wait (done == 1'b1);
            repeat (4) @(posedge clk);

            $display("---- 写入序列（共 %0d 次）----", nwr);
            for (int i = 0; i < nwr && i < 20; i++)
                $display("  [%0d] reg=%02h val=%02h", i, writes[i][15:8], writes[i][7:0]);

            chk("写入次数", nwr, 14);
            for (int i = 0; i < 14; i++)
                if (i < nwr) chk($sformatf("第%0d项", i), writes[i], exp_tbl(i));
            chk("最后一项是 0x41=0x10", writes[13], 16'h4110);
            chk("done",   done,   1);
            chk("busy",   busy,   0);
            chk("no_dev", no_dev, 0);
        end

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[FAIL] 仿真超时（done=%b busy=%b ack_err=%0d nwr=%0d rise=%0d fall=%0d start=%0d）", done, busy, ack_err, nwr, n_rise, n_fall, n_start);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
