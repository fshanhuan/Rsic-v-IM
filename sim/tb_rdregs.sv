`timescale 1ns / 1ps

/* =============================================================================
 * tb_rdregs.sv —— 验证 adv7511_rdregs 的读时序（不重建位流就能查）
 * -----------------------------------------------------------------------------
 * 从机模型：ADV7511 的"写寄存器号 → 重复 START → 读一字节"协议
 *   · 地址 0x39 应答
 *   · 写阶段：收到 reg 号就记住
 *   · 读阶段：把 regmem[reg] 逐位送到 SDA
 * 判据：
 *   A1 向 0x50（不存在）发地址时 ack_bogus=0
 *   A2 4 个寄存器读回的值 = 模型里预置的值
 *   A3 ok=1、busy 归 0
 * ============================================================================= */
module tb_rdregs;

    localparam int CLK_HZ = 4_000_000;
    localparam int SCL_HZ = 100_000;
    localparam logic [6:0] ADDR = 7'h39;

    logic clk = 1'b0;
    always #125 clk = ~clk;

    logic rst = 1'b1;
    logic go = 1'b0;

    logic scl_oe, sda_oe, sda_i;
    logic [7:0] d0, d1, d2, d3;
    logic busy, ok, ack_bogus;

    /* ---------- 开漏线与 ---------- */
    logic slave_low;
    initial slave_low = 1'b0;
    wire scl_w = scl_oe ? 1'b0 : 1'b1;
    wire sda_w = (sda_oe | slave_low) ? 1'b0 : 1'b1;
    assign sda_i = sda_w;

    /* ---------- 寄存器内容 ---------- */
    logic [7:0] regmem [0:255];
    initial begin
        for (int i = 0; i < 256; i++) regmem[i] = 8'h00;
        regmem[8'h00] = 8'h75;   // ID
        regmem[8'h41] = 8'h10;
        regmem[8'h42] = 8'h40;   // HPD 位为 1
        regmem[8'h16] = 8'h34;
    end

    /* ---------- 从机 ---------- */
    logic scl_d, sda_d;
    logic [7:0] sh;
    logic [3:0] biti;          // 0..8
    logic [1:0] ast;           // 0=等地址 1=收reg 2=收数据 3=发送中
    logic       rw;            // 当前地址字节的 R/W
    logic [7:0] regptr;
    logic       ack_ph;
    logic [7:0] txbyte;
    int         n_read = 0;

    initial begin
        scl_d = 1'b1; sda_d = 1'b1; biti = 4'd0; ast = 2'd0; rw = 1'b0;
        regptr = 8'd0; ack_ph = 1'b0; sh = 8'd0; txbyte = 8'd0;
    end

    wire sda_fall = ~sda_w & sda_d;
    wire sda_rise = sda_w & ~sda_d;

    always @(posedge clk) begin
        scl_d <= scl_w;
        sda_d <= sda_w;

        if (sda_fall && scl_w) begin
            /* START */
            ast   <= 2'd0;
            biti  <= 4'd0;
            ack_ph<= 1'b0;
            slave_low <= 1'b0;
            sh    <= 8'd0;
        end else if (sda_rise && scl_w) begin
            /* STOP */
            ast <= 2'd0;
            slave_low <= 1'b0;
        end else if (scl_w & ~scl_d) begin
            /* SCL 上升：采样（仅接收阶段） */
            if (ast != 2'd3) begin
                if (biti < 4'd8) begin
                    sh[7 - biti[2:0]] <= sda_w;
                    biti <= biti + 4'd1;
                end
            end
        end else if (~scl_w & scl_d) begin
            /* SCL 下降 */
            if (ast == 2'd3) begin
                /* 发送阶段：先摆下一位 */
                if (biti < 4'd8) begin
                    slave_low <= ~txbyte[7 - biti[2:0]];
                    biti <= biti + 4'd1;
                    ack_ph <= 1'b0;
                end else if (!ack_ph) begin
                    slave_low <= 1'b0;      // 释放，等主机 ACK
                    ack_ph <= 1'b1;
                end else begin
                    /* 主机已回 ACK/NACK：如果它是 NACK（SDA 高）就结束 */
                    ast <= 2'd0;
                    slave_low <= 1'b0;
                end
            end else if (biti == 4'd8 && !ack_ph) begin
                ack_ph <= 1'b1;
                case (ast)
                    2'd0: begin
                        slave_low <= (sh[7:1] == ADDR);
                        rw <= sh[0];
                    end
                    2'd1: slave_low <= 1'b1;
                    default: slave_low <= 1'b1;
                endcase
            end else if (ack_ph) begin
                ack_ph <= 1'b0;
                slave_low <= 1'b0;
                if (biti == 4'd8) begin
                    case (ast)
                        2'd0: ast <= (sh[7:1] == ADDR) ? (rw ? 2'd3 : 2'd1) : 2'd0;
                        2'd1: begin regptr <= sh; ast <= 2'd2; end
                        2'd2: ast <= 2'd1;
                        default: ;
                    endcase
                end
                biti <= 4'd0;
                sh   <= 8'd0;
                if (rw && (ast == 2'd0)) begin
                    /* 读地址：直接把 regmem 装进 txbyte */
                    txbyte <= regmem[regptr];
                    slave_low <= ~regmem[regptr][7];
                end
                if (ast == 2'd3) n_read <= n_read + 1;
            end
        end
    end

    /* ---------- DUT ---------- */
    adv7511_rdregs #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ), .I2C_ADDR(ADDR)) dut (
        .clk(clk), .rst(rst), .go(go),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_i(sda_i),
        .d0(d0), .d1(d1), .d2(d2), .d3(d3),
        .busy(busy), .ok(ok), .ack_bogus(ack_bogus)
    );

    int errors = 0;
    task automatic chk(input string nm, input longint got, input longint exp);
        if (got == exp) $display("[PASS] %-28s = %0h", nm, got);
        else begin $display("[FAIL] %-28s = %0h (期望 %0h)", nm, got, exp); errors++; end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);
        go <= 1'b1;
        @(posedge clk);
        go <= 1'b0;

        /* 等 4 个寄存器读完（每个约 5 字节 = 500 µs） */
        repeat (400_000) @(posedge clk);      // 100 ms @4MHz
        $display("n_read=%0d busy=%b ok=%b ack_bogus=%b", n_read, busy, ok, ack_bogus);
        chk("ack_bogus(不存在的0x50)", ack_bogus, 0);
        chk("0x00 ID",   d0, 8'h75);
        chk("0x41 电源", d1, 8'h10);
        chk("0x42 HPD",  d2, 8'h40);
        chk("0x16 格式", d3, 8'h34);
        chk("ok",        ok, 1);
        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("[FAIL] 超时：busy=%b ok=%b n_read=%0d d=%0h %0h %0h %0h", busy, ok, n_read, d0, d1, d2, d3);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
