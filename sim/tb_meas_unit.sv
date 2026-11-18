`timescale 1ns / 1ps

/* =============================================================================
 * tb_meas_unit.sv — 验证窗内 min/max/Vpp/均值
 * -----------------------------------------------------------------------------
 * 用一段**完全手算得出**的波形：
 *   1024 个样本，前 512 个 = 0x1000，后 512 个 = 0x3000
 *   → min = 0x1000, max = 0x3000, Vpp = 0x2000
 *   → 均值 = (512*0x1000 + 512*0x3000) / 1024 = 0x2000
 *
 * 再跑第二个窗口：全部 0x0800
 *   → min = max = 0x0800, Vpp = 0, 均值 = 0x0800
 *
 * 这两个窗口的四个数全部可以手算核对，所以判定是硬的。
 * ============================================================================= */
module tb_meas_unit;

    logic clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    logic rst = 1'b1;
    logic [15:0] sample = 16'd0;
    logic        stb = 1'b0;
    logic        clr = 1'b0;

    logic [15:0] min_v, max_v, vpp, mean_v;
    logic [31:0] win_cnt;

    meas_unit #(.WIN_LOG2(10)) dut (
        .clk        (clk),
        .rst        (rst),
        .sample     (sample),
        .sample_stb (stb),
        .clr        (clr),
        .min_v      (min_v),
        .max_v      (max_v),
        .vpp        (vpp),
        .mean_v     (mean_v),
        .win_cnt    (win_cnt)
    );

    int errors = 0;
    task automatic chk(input string nm, input longint got, input longint exp);
        if (got == exp) $display("[PASS] %-22s = 0x%04h", nm, got);
        else begin $display("[FAIL] %-22s = 0x%04h (期望 0x%04h)", nm, got, exp); errors++; end
    endtask

    task automatic push(input logic [15:0] s);
        begin
            @(negedge clk);
            sample <= s;
            stb    <= 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            stb    <= 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(negedge clk); clr <= 1'b1;
        @(posedge clk); #1;
        @(negedge clk); clr <= 1'b0;

        /* ---- 窗口 1：512 x 0x1000 + 512 x 0x3000 ---- */
        for (int i = 0; i < 512; i++) push(16'h1000);
        for (int i = 0; i < 512; i++) push(16'h3000);
        repeat (2) @(posedge clk); #1;

        chk("窗口1 win_cnt", win_cnt, 1);
        chk("窗口1 min",     min_v,   16'h1000);
        chk("窗口1 max",     max_v,   16'h3000);
        chk("窗口1 Vpp",     vpp,     16'h2000);
        chk("窗口1 mean",    mean_v,  16'h2000);

        /* ---- 窗口 2：1024 x 0x0800（直流）---- */
        for (int i = 0; i < 1024; i++) push(16'h0800);
        repeat (2) @(posedge clk); #1;

        chk("窗口2 win_cnt", win_cnt, 2);
        chk("窗口2 min",     min_v,   16'h0800);
        chk("窗口2 max",     max_v,   16'h0800);
        chk("窗口2 Vpp",     vpp,     16'h0000);
        chk("窗口2 mean",    mean_v,  16'h0800);

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[FAIL] 仿真超时（win_cnt=%0d）", win_cnt);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
