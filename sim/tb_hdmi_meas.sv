`timescale 1ns / 1ps

/* =============================================================================
 * tb_hdmi_meas.sv — 验证 hdmi_meas 数出来的帧参数与"理论值"一致
 * -----------------------------------------------------------------------------
 * 这是 S1b 上板测量的**预言来源**：先把 TB 里的理论值算清楚，上板后 VIO 读
 * 回来的数必须一模一样，否则就是生成器/测量模块有问题。
 *
 *   800x600@60，H total = 800+40+128+88 = 1056
 *                V total = 600+1+4+23   =  628
 *   一帧像素时钟 = 1056 x 628 = 663 168
 *   DE 像素      =  800 x 600 = 480 000
 *   hsync 低     =  128 x 628 = 80 384
 *   vsync 低     =    4 x 1056 =  4 224
 * ============================================================================= */
module tb_hdmi_meas;

    localparam int CLK_PIX_HZ = 40_000_000;   // 25 ns

    logic pix_clk = 1'b0;
    logic cpu_clk = 1'b0;
    logic rst_pix = 1'b1;
    logic rst_cpu = 1'b1;

    always #12.5 pix_clk = ~pix_clk;
    always #10   cpu_clk = ~cpu_clk;

    logic hsync, vsync, de;
    logic [15:0] vdata;
    logic frame_tick, rd_bank;

    /* iverilog 不允许把常量直接接到 DUT 的 output 端口上（必须给一个变量） */
    wire        wr_en;
    wire        wr_col_unused_ok;
    wire [9:0]  wr_col, wr_min, wr_max;
    /* ★ wr_bank 是 scope_display 的 **输出**（告诉 CPU 该写哪块），
     *   不能由 TB 驱动 —— 之前在这里 assign 了一次，iverilog 报
     *   "uwire wr_bank must have a single driver, found (2)"。 */
    wire        wr_bank;
    assign wr_en   = 1'b0;
    assign wr_col  = 10'd0;
    assign wr_min  = 10'd0;
    assign wr_max  = 10'd0;

    scope_display #(
        .H_ACTIVE (800), .H_FP (40), .H_SYNC (128), .H_BP (88),
        .V_ACTIVE (600), .V_FP ( 1), .V_SYNC (  4), .V_BP (23),
        .GRID_X   (80),  .GRID_Y (50)
    ) dut (
        .pix_clk    (pix_clk),
        .cpu_clk    (cpu_clk),
        .rst_pix    (rst_pix),
        .rst_cpu    (rst_cpu),
        .wr_en      (wr_en),
        .wr_col     (wr_col),
        .wr_min     (wr_min),
        .wr_max     (wr_max),
        .wr_bank    (wr_bank),
        .hsync      (hsync),
        .vsync      (vsync),
        .de         (de),
        .vdata      (vdata),
        .frame_tick (frame_tick),
        .rd_bank    (rd_bank)
    );

    logic [31:0] m_frame_clk, m_de_pix, m_hs_low, m_vs_low, m_frame_cnt;
    logic [15:0] m_frame_lines;

    hdmi_meas u_meas (
        .pix_clk     (pix_clk),
        .rst_pix     (rst_pix),
        .hsync       (hsync),
        .vsync       (vsync),
        .de          (de),
        .frame_clk   (m_frame_clk),
        .frame_lines (m_frame_lines),
        .de_pix      (m_de_pix),
        .hs_low      (m_hs_low),
        .vs_low      (m_vs_low),
        .frame_cnt   (m_frame_cnt)
    );

    int errors = 0;
    task automatic chk(input string nm, input longint got, input longint exp);
        if (got == exp) $display("[PASS] %-26s = %0d", nm, got);
        else begin $display("[FAIL] %-26s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    initial begin
        repeat (8) @(posedge cpu_clk);
        rst_cpu <= 1'b0;
        rst_pix <= 1'b0;

        /* 等 3 帧，确保 frame_cnt >= 2（第一次锁存可能是半帧） */
        wait (m_frame_cnt >= 3);
        @(posedge pix_clk);

        $display("---- hdmi_meas 实测（第 %0d 帧之后）----", m_frame_cnt);
        chk("一帧像素时钟",   m_frame_clk,   663168);
        chk("一帧行数",       m_frame_lines, 628);
        chk("DE 像素数",      m_de_pix,      480000);
        chk("hsync 低时钟数", m_hs_low,      80384);
        chk("vsync 低时钟数", m_vs_low,      4224);

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #120_000_000;  // 120 ms 硬超时（一帧 16.7 ms，要 3 帧才稳定）
        $display("[FAIL] 仿真超时（frame_cnt=%0d）", m_frame_cnt);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
