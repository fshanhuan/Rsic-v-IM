`timescale 1ns / 1ps

/* =============================================================================
 * tb_scope_display.sv — 列缓冲 + 扫描渲染的自检台（S3 核心）
 * -----------------------------------------------------------------------------
 * 验四件事：
 *   1. 列缓冲写入 → 扫描出来的波形位置**对得上**（写 min=max=100，屏幕上第 100 行亮）
 *   2. 渲染优先级：波形 > 网格 > 背景
 *   3. 网格落在 x=0/80/160… 和 y=0/50/100…
 *   4. 乒乓换页：写 bank 与读 bank 相反，换页后新数据上屏
 *
 * 测试图案：
 *   全部 800 列写 min=max=100 → 一整条水平亮线（y=100）
 *
 * ★ 台子里必须"按 DE 计数"而不是按拍计数：输出级把 de 也延迟了一拍，
 *   用原始 px/py 抽样会错一个像素 —— 这正是被测模块要保证的那条不变量。
 * ============================================================================= */
module tb_scope_display;

    logic pix_clk = 1'b0;
    logic cpu_clk = 1'b0;
    logic rst_pix = 1'b1, rst_cpu = 1'b1;

    always #12.5 pix_clk = ~pix_clk;   // 40 MHz
    always #10.0 cpu_clk = ~cpu_clk;   // 50 MHz

    logic        hsync, vsync, de, frame_tick;
    logic [15:0] vdata;
    logic        wr_bank, rd_bank;

    logic        wr_en = 1'b0;
    logic        commit;
    initial commit = 1'b0;
    logic [9:0]  wr_col = 10'd0, wr_min = 10'd0, wr_max = 10'd0;

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
        .commit     (commit),
        .wr_bank    (wr_bank),
        .hsync      (hsync),
        .vsync      (vsync),
        .de         (de),
        .vdata      (vdata),
        .frame_tick (frame_tick),
        .rd_bank    (rd_bank)
    );

    int errors = 0;
    task automatic chk(input string nm, input int got, input int exp);
        if (got == exp) $display("[PASS] %-34s = %0d", nm, got);
        else begin $display("[FAIL] %-34s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    /* ------------------------------ 按 DE 计数 ------------------------------ */
    int xc = 0, yc = 0;
    int frame_no = 0;
    int y_at_100_400 = -1, y_at_200_401 = -1, y_at_200_400 = -1;
    int y_at_250_401 = -1, y_at_100_400_g = -1;

    always @(posedge pix_clk) begin
        if (frame_tick) begin
            frame_no <= frame_no + 1;
            xc <= 0;
            yc <= 0;
        end else if (de) begin
            if (frame_no == 1) begin      // 第 2 帧（第 1 个 tick 之后）开始抽样
                if (yc == 100 && xc == 400) y_at_100_400   = vdata[15:8];
                if (yc == 100 && xc == 400) y_at_100_400_g = vdata[15:8];
                if (yc == 201 && xc == 401) y_at_200_401   = vdata[15:8];
                if (yc == 200 && xc == 400) y_at_200_400   = vdata[15:8];
                if (yc == 250 && xc == 401) y_at_250_401   = vdata[15:8];
            end
            if (xc == 799) begin
                xc <= 0;
                yc <= yc + 1;
            end else begin
                xc <= xc + 1;
            end
        end
    end

    /* ------------------------------ 激励 ------------------------------ */
    initial begin
        repeat (6) @(posedge cpu_clk);
        rst_cpu <= 1'b0;
        rst_pix <= 1'b0;
        repeat (4) @(posedge cpu_clk);

        $display("---- 写列缓冲（800 列，min=max=100）----");
        $display("  当前 wr_bank=%b rd_bank=%b", wr_bank, rd_bank);
        chk("写 bank 与读 bank 相反", wr_bank != rd_bank ? 1 : 0, 1);

        for (int i = 0; i < 800; i++) begin
            @(posedge cpu_clk);
            wr_en  <= 1'b1;
            wr_col <= i[9:0];
            wr_min <= 10'd100;
            wr_max <= 10'd100;
        end
        @(posedge cpu_clk);
        wr_en <= 1'b0;

        /* ★ 新语义（2026-11-17）：bank 只在 CPU **提交**之后的帧同步才翻。
         *   不提交的话画面会一直冻结在写好的那一块上（这是有意为之的"冻结"）。 */
        commit <= 1'b1;
        @(posedge cpu_clk);
        commit <= 1'b0;

        // 等换页（第 1 个 frame_tick），再跑满一帧抽样
        wait (frame_no >= 2);
        @(posedge cpu_clk);

        $display("---- 渲染结果 ----");
        $display("  (y=100,x=400) Y = %0d  期望 235(波形)", y_at_100_400);
        $display("  (y=201,x=401) Y = %0d  期望  16(背景)", y_at_200_401);
        $display("  (y=200,x=400) Y = %0d  期望  70(网格 x)", y_at_200_400);
        $display("  (y=250,x=401) Y = %0d  期望  70(网格 y)", y_at_250_401);

        chk("波形行 y=100 亮",   y_at_100_400, 235);
        chk("相邻行是背景",       y_at_200_401, 16);
        chk("x=400 是网格线",     y_at_200_400, 70);
        chk("y=250 是网格线",     y_at_250_401, 70);
        chk("波形压过网格",       y_at_100_400_g, 235);

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #300_000_000;
        $display("[FAIL] 仿真总超时（frame_no=%0d yc=%0d）", frame_no, yc);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
