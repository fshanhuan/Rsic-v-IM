`timescale 1ns / 1ps

/* =============================================================================
 * tb_hdmi_i2c_swapped.sv — 证明「SCL/SDA 互换 ⇒ 永远 NACK」这个机制
 * -----------------------------------------------------------------------------
 * 背景（2026-11-20 13:0x）：
 *   project_src/board_top_rec.sv 里原来是 `wire swap = sw[0];`，而 XDC 给
 *   sw[*] 配了 PULLTYPE PULLUP —— 拨码不动就读 1，于是"互换 SCL/SDA 的实验"
 *   默认是开着的。互换**不改变空闲电平**（两根都是开漏），所以
 *   `hdmi_scl=hdmi_sda=1`、占空比 65%、line_health=0x55 全部照旧好看，
 *   但 ADV7511 的时钟脚上收到的是我们的数据脚 → 永远构不出合法时序。
 *
 * 这个 TB 把顶层的那个 mux **原样搬过来**，用同一个只会被写的 ADV7511 从机
 * 模型证明两件事：
 *
 *   B1  swap=0（正确接线）：整表 14 项写完，done=1        ← 对照组
 *   B2  swap=1（互换）    ：ack_err 增长、done=0、no_dev=1 ← 就是板上现象
 *   B3  swap=1 时**从机一次都没有 ACK**（`n_ack_drive=0`）—— 这一步很关键：
 *       从机是活的、地址也对，它 ACK 不了是因为**它认的时钟来自我们的数据脚**，
 *       那条线上根本没有 8 个连续时钟沿，所以它连地址都没解出来。
 *       也就是说"芯片不响应"这个说法本身是错的：**我们从来没给它一个合法的
 *       时钟序列**，它连拒绝的机会都没有。
 *
 * 用法（iverilog，和回归里其它 run 一样）：
 *   vvp tb_hdmi_i2c_swapped.vvp            → swap=0
 *   vvp tb_hdmi_i2c_swapped.vvp +swap      → swap=1
 * ============================================================================= */
module tb_hdmi_i2c_swapped;

    localparam int CLK_HZ = 4_000_000;      // 仿真加速，SCL 仍 100 kHz
    localparam int SCL_HZ = 100_000;

    logic clk = 1'b0;
    always #125 clk = ~clk;                  // 4 MHz

    logic rst = 1'b1;
    logic start = 1'b0;

    logic scl_oe, sda_oe, sda_i;
    logic busy, done, no_dev;
    logic [4:0]  cur_idx;
    logic [7:0]  last_reg, last_val;
    logic [15:0] ack_err;

    /* ---------------- 顶层那个 mux（原样搬过来） ---------------- */
    logic swap = 1'b0;
    initial if ($test$plusargs("swap")) swap = 1'b1;

    logic slave_low;
    initial slave_low = 1'b0;

    /* 注意极性：oe=1 表示**驱动低**（开漏），与 IOBUF 的 .T(~oe) 一致 */
    wire h_scl = swap ? sda_oe : scl_oe;    // 顶层：h_scl = ... (swap ? h_sda_oe : h_scl_oe)
    wire h_sda = swap ? scl_oe : sda_oe;    // 顶层：h_sda = ... (swap ? h_scl_oe : h_sda_oe)

    wire scl_w = h_scl ? 1'b0 : 1'b1;                    // 物理 SCL（上拉）
    wire sda_w = (h_sda | slave_low) ? 1'b0 : 1'b1;      // 物理 SDA（上拉 + 从机开漏）
    assign sda_i = swap ? scl_w : sda_w;                 // 顶层：h_sdai = swap ? hdmi_scl_rd : hdmi_sda_rd

    /* ---------------- 从机模型（与 tb_adv7511_init 相同） ---------------- */
    localparam logic [6:0] ADDR = 7'h39;

    logic [7:0] sh;
    logic [3:0] bitcnt;         // 0..8
    logic       ack_phase;
    logic [1:0] ast;            // 0=idle 1=reg 2=val
    logic [7:0] regptr;
    logic [7:0] mem [0:255];

    logic [15:0] writes [0:63];
    int          nwr = 0;
    int          n_ack_drive = 0;   // 从机真正把 SDA 拉低的次数（= 它 ACK 了几次）

    logic scl_d, sda_d;
    initial begin
        scl_d     = 1'b1;
        sda_d     = 1'b1;
        bitcnt    = 4'd0;
        ack_phase = 1'b0;
        ast       = 2'd0;
        sh        = 8'd0;
        regptr    = 8'd0;
    end

    wire sda_fall = ~sda_w & sda_d;
    wire sda_rise = sda_w & ~sda_d;

    int n_start = 0;
    always @(posedge clk) begin
        scl_d <= scl_w;
        sda_d <= sda_w;
        if (~sda_w & sda_d & scl_w) n_start <= n_start + 1;

        if (sda_fall && scl_w) begin
            ast       <= 2'd0;
            bitcnt    <= 4'd0;
            ack_phase <= 1'b0;
            slave_low <= 1'b0;
            sh        <= 8'd0;
        end else if (sda_rise && scl_w) begin
            ast       <= 2'd0;
            slave_low <= 1'b0;
        end else if (scl_w & ~scl_d) begin
            if (bitcnt < 4'd8) begin
                sh[7 - bitcnt[2:0]] <= sda_w;
                bitcnt <= bitcnt + 4'd1;
            end
        end else if (~scl_w & scl_d) begin
            if (bitcnt == 4'd8 && !ack_phase) begin
                ack_phase <= 1'b1;
                case (ast)
                    2'd0: slave_low <= (sh[7:1] == ADDR);
                    2'd1: slave_low <= 1'b1;
                    2'd2: slave_low <= 1'b1;
                    default: slave_low <= 1'b0;
                endcase
            end else if (ack_phase) begin
                ack_phase <= 1'b0;
                slave_low <= 1'b0;
                if (bitcnt == 4'd8) begin
                    case (ast)
                        2'd0: ast <= (sh[0] == 1'b0) ? 2'd1 : 2'd0;
                        2'd1: begin regptr <= sh; ast <= 2'd2; end
                        2'd2: begin
                            mem[regptr] = sh;
                            if (nwr < 64) writes[nwr] = {regptr, sh};
                            nwr <= nwr + 1;
                            ast <= 2'd1;
                        end
                        default: ;
                    endcase
                end
                bitcnt <= 4'd0;
                sh     <= 8'd0;
            end
        end
    end

    /* 从机把 SDA 拉低的拍数 —— 用来证明"它确实 ACK 过" */
    always @(posedge clk) if (slave_low) n_ack_drive <= n_ack_drive + 1;

    adv7511_init #(
        .CLK_HZ   (CLK_HZ),
        .SCL_HZ   (SCL_HZ),
        .RETRY_CY (200_000)
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

    int errors = 0;
    task automatic chk(input string nm, input longint got, input longint exp);
        if (got == exp) $display("[PASS] %-34s = %0d", nm, got);
        else begin $display("[FAIL] %-34s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        if (!swap) begin
            /* ---------- B1 对照组：正确接线 ---------- */
            wait (done == 1'b1);
            repeat (4) @(posedge clk);
            chk("swap=0 写入次数",      nwr, 14);
            chk("swap=0 首项 0x9803",   writes[0], 16'h9803);
            chk("swap=0 末项 0x4110",   writes[13], 16'h4110);
            chk("swap=0 done",          done, 1);
            chk("swap=0 no_dev",        no_dev, 0);
            chk("swap=0 从机 ACK 过",   n_ack_drive > 0 ? 1 : 0, 1);
        end else begin
            /* ---------- B2/B3 互换：等第一个 NACK ---------- */
            wait (ack_err > 0);
            repeat (8) @(posedge clk);
            $display("---- swap=1：从机 ACK 拉低拍数=%0d，主控 ack_err=%0d ----", n_ack_drive, ack_err);
            chk("swap=1 从机一次都没 ACK（认不到时钟）", n_ack_drive, 0);
            chk("swap=1 主控读不到 ACK（done）", done, 0);
            chk("swap=1 ack_err>0",     ack_err > 0 ? 1 : 0, 1);
            chk("swap=1 no_dev",        no_dev, 1);
        end

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[FAIL] 仿真超时（swap=%b done=%b busy=%b ack_err=%0d nwr=%0d ack_drive=%0d）",
                 swap, done, busy, ack_err, nwr, n_ack_drive);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
