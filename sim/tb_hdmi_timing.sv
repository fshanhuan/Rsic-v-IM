`timescale 1ns / 1ps

/* =============================================================================
 * tb_hdmi_timing.sv — 800×600@60 时序发生器的自检台
 * -----------------------------------------------------------------------------
 * 这个台子回答四个问题，全部用**数出来的**数字而不是"看着像"：
 *   1. 一行到底多少像素？  期望 H_TOTAL = 1056
 *   2. 一帧到底多少行？    期望 V_TOTAL = 628
 *   3. DE 有效区多大？     期望 800 × 600 = 480000 像素
 *   4. 同步脉宽对不对？    期望 HSYNC 低 128 像素/行、VSYNC 低 4 行/帧
 *
 * 外加彩条的**内容**检查：抽样 8 条竖条的 Y 值，以及第 2 条里 Cb/Cr 的先后
 * 顺序（BT.656 惯例第一像素 Cb、第二像素 Cr）。
 *
 * 为什么这些必须仿真验：时序参数错一个数，显示器多半是"黑屏"或者"图像偏一边"，
 * 这两种现象在板子上都看不出是哪一位错了。仿真里 1056/628 是硬数字，一目了然。
 *
 * 期望值推导：
 *   H = 800 + 40 + 128 + 88 = 1056
 *   V = 600 +  1 +   4 + 23 =  628
 *   每帧总拍数 = 1056 × 628 = 663168
 *   DE 像素/帧 = 800 × 600 = 480000
 *   HSYNC 低电平/帧 = 128 × 628 = 80384
 *   帧率 = 40 MHz / 663168 = 60.30 Hz
 * ============================================================================= */
module tb_hdmi_timing;

    localparam int H_TOTAL    = 1056;
    localparam int V_TOTAL    = 628;
    localparam int FRAME_CYC  = H_TOTAL * V_TOTAL;   // 663168
    localparam int DE_PER_FR  = 800 * 600;           // 480000
    localparam int HSLOW_FR   = 128 * V_TOTAL;       // 80384

    logic clk = 1'b0;
    logic rst = 1'b1;

    always #12.5 clk = ~clk;     // 40 MHz（800×600@60 的像素时钟）

    logic        hsync, vsync, de, frame_tick;
    logic [15:0] vdata;

    hdmi_timing dut (
        .pix_clk    (clk),
        .rst        (rst),
        .hsync      (hsync),
        .vsync      (vsync),
        .de         (de),
        .vdata      (vdata),
        .frame_tick (frame_tick)
    );

    int errors = 0;

    task automatic chk(input string nm, input int got, input int exp);
        if (got == exp) $display("[PASS] %-34s = %0d", nm, got);
        else begin $display("[FAIL] %-34s = %0d  (期望 %0d)", nm, got, exp); errors++; end
    endtask

    /* ------------------------------ 逐帧统计 ------------------------------
     * ★ 不要在 frame_tick 那一拍清零再数：tick 那一拍本身属于上一帧，
     *   清掉它就每帧少算 1 拍（第一版就是这么错的：663167 / 479999）。
     *   这里改成"全程累加 + 在第 1 和第 3 个 tick 各拍一张快照"，
     *   两帧相减再除以 2 —— 与边界怎么定义无关，数字是硬的。
     * ------------------------------------------------------------------- */
    int frame_no = 0;
    int cyc = 0, de_cyc = 0, hsl_cyc = 0, hs_fall = 0;

    int cyc_f = -1, de_f = -1, hsl_f = -1, hsf_f = -1;
    logic hsync_d = 1'b1;

    int snap_cyc0 = 0, snap_de0 = 0, snap_hsl0 = 0, snap_hsf0 = 0;
    int snap_t0   = 0;
    int frames_measured = 0;

    always @(posedge clk) begin
        hsync_d <= hsync;
        cyc    <= cyc + 1;
        if (de)                de_cyc  <= de_cyc + 1;
        if (!hsync)            hsl_cyc <= hsl_cyc + 1;
        if (hsync_d && !hsync) hs_fall <= hs_fall + 1;

        if (frame_tick) begin
            if (frame_no == 0) begin
                snap_cyc0 = cyc;    snap_de0  = de_cyc;
                snap_hsl0 = hsl_cyc; snap_hsf0 = hs_fall;
                snap_t0   = $time;
            end else if (frame_no == 2) begin
                frames_measured = 2;
                cyc_f  = (cyc    - snap_cyc0) / 2;
                de_f   = (de_cyc - snap_de0 ) / 2;
                hsl_f  = (hsl_cyc- snap_hsl0) / 2;
                hsf_f  = (hs_fall- snap_hsf0) / 2;
                $display("  （两帧实测拍数 = %0d，$time 差 = %0d ns）",
                         cyc - snap_cyc0, $time - snap_t0);
            end
            frame_no <= frame_no + 1;
        end
    end

    /* ------------------------------ 彩条抽样 ------------------------------
     * 在 DE 有效行上按 x 坐标取 Y；再取第 2 条里相邻两像素的色度值。
     * ---------------------------------------------------------------- */
    logic [7:0] y0, y1, y2, y3, y4, y5, y6, y7;
    logic [7:0] c_at150, c_at151;

    always @(posedge clk) begin
        if (!rst && de && frame_no == 1) begin
            case (dut.hcnt)
                11'd50:  y0 <= vdata[15:8];
                11'd150: begin y1 <= vdata[15:8]; c_at150 <= vdata[7:0]; end
                11'd151: c_at151 <= vdata[7:0];
                11'd250: y2 <= vdata[15:8];
                11'd350: y3 <= vdata[15:8];
                11'd450: y4 <= vdata[15:8];
                11'd550: y5 <= vdata[15:8];
                11'd650: y6 <= vdata[15:8];
                11'd750: y7 <= vdata[15:8];
                default: ;
            endcase
        end
    end

    /* ------------------------------ 激励 ------------------------------ */
    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("wave/tb_hdmi_timing.vcd");
            $dumpvars(0, tb_hdmi_timing);
        end

        repeat (8) @(posedge clk);
        rst <= 1'b0;

        // 跑 3 帧，第 2 帧的统计与抽样有效
        wait (frame_no >= 3);
        @(posedge clk);

        $display("---- 时序统计（以第 1 整帧为准）----");
        $display("  每帧拍数   = %0d  (帧率 %.2f Hz @40MHz)", cyc_f, 40.0e6 / cyc_f);
        chk("每帧总拍数 H*V", cyc_f, FRAME_CYC);
        chk("每帧 DE 像素数", de_f, DE_PER_FR);
        chk("每帧 HSYNC 低电平拍数", hsl_f, HSLOW_FR);
        chk("每帧 HSYNC 下降沿（行数）", hsf_f, V_TOTAL);

        $display("---- 彩条 Y 值（BT.601 8 位）----");
        $display("  y0..y7 = %0d %0d %0d %0d %0d %0d %0d %0d",
                 y0, y1, y2, y3, y4, y5, y6, y7);
        chk("bar0 white  Y", y0, 235);
        chk("bar1 yellow Y", y1, 210);
        chk("bar2 cyan   Y", y2, 170);
        chk("bar3 green  Y", y3, 145);
        chk("bar4 magenta Y", y4, 106);
        chk("bar5 red    Y", y5, 81);
        chk("bar6 blue   Y", y6, 41);
        chk("bar7 black  Y", y7, 16);

        $display("---- 4:2:2 色度顺序（bar1 = yellow，Cb=16 Cr=146）----");
        $display("  x=150 C=0x%02h  x=151 C=0x%02h", c_at150, c_at151);
        chk("偶像素送 Cb(16)",  c_at150, 16);
        chk("奇像素送 Cr(146)", c_at151, 146);

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #200_000_000;                // 200 ms 仿真上限（约 3.6 帧）
        $display("[FAIL] 仿真总超时（frame_no=%0d）", frame_no);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
