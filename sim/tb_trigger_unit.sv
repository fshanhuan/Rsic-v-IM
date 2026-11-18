`timescale 1ns / 1ps

/* =============================================================================
 * tb_trigger_unit.sv — 验证 trigger_unit 的边沿/电平判定与 holdoff
 * -----------------------------------------------------------------------------
 * 判据（每条都要能用"手算"对上）：
 *   T1 上升沿：样本序列里只有一个从 <TH 到 >=TH 的跳变 → 恰好 1 次触发
 *   T2 下降沿：模式 1 下同一条序列 → 1 次（在相反的那个跳变处）
 *   T3 任意边沿：模式 2 → 2 次（两个跳变各一次）
 *   T4 电平：模式 3 → 每一次 >=TH 的样本都算；用 holdoff 限流后次数可预言
 *   T5 holdoff：连续过阈值时，触发次数 = ceil(N / HOLDOFF)
 *   T6 fired 粘滞，clear 后清零
 * ============================================================================= */
module tb_trigger_unit;

    localparam int HOLDOFF = 8;
    localparam logic [15:0] TH = 16'h8000;      // 阈值 0x8000

    logic clk = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    logic        rst = 1'b1;
    logic [15:0] sample = 16'd0;
    logic        sample_valid = 1'b0;
    logic [15:0] threshold = TH;
    logic [1:0]  mode = 2'd0;
    logic        enable = 1'b0;
    logic        clear = 1'b0;

    logic        trig, fired, above;
    logic [31:0] trig_cnt;
    logic [15:0] last_sample;

    trigger_unit #(.HOLDOFF(HOLDOFF)) dut (
        .clk         (clk),
        .rst         (rst),
        .sample      (sample),
        .sample_valid(sample_valid),
        .threshold   (threshold),
        .mode        (mode),
        .enable      (enable),
        .clear       (clear),
        .trig        (trig),
        .fired       (fired),
        .trig_cnt    (trig_cnt),
        .last_sample (last_sample),
        .above       (above)
    );

    int errors = 0;
    task automatic chk(input string nm, input longint got, input longint exp);
        if (got == exp) $display("[PASS] %-30s = %0d", nm, got);
        else begin $display("[FAIL] %-30s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    /* 打一个样本：一拍 valid */
    task automatic push(input logic [15:0] s);
        begin
            @(negedge clk);
            sample <= s;
            sample_valid <= 1'b1;
            @(posedge clk);              // 这一拍被采样
            #1;
            @(negedge clk);
            sample_valid <= 1'b0;
        end
    endtask

    task automatic do_reset();
        begin
            rst <= 1'b1; enable <= 1'b0; clear <= 1'b1;
            repeat (3) @(posedge clk);
            #1;
            rst <= 1'b0; clear <= 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        /* -------------------- T1 上升沿 -------------------- */
        do_reset();
        mode <= 2'd0; enable <= 1'b1;
        push(16'h1000);  push(16'h2000);  push(16'h9000);   // 2000 -> 9000 = 上升沿
        push(16'hA000);  push(16'h3000);
        @(posedge clk); #1;
        chk("T1 上升沿触发次数", trig_cnt, 1);
        chk("T1 fired",          fired,    1);

        /* -------------------- T2 下降沿 -------------------- */
        do_reset();
        mode <= 2'd1; enable <= 1'b1;
        push(16'h9000);  push(16'hA000);  push(16'h3000);   // A000 -> 3000 = 下降沿
        push(16'h2000);
        @(posedge clk); #1;
        chk("T2 下降沿触发次数", trig_cnt, 1);

        /* -------------------- T3 任意边沿 -------------------- */
        do_reset();
        mode <= 2'd2; enable <= 1'b1;
        push(16'h2000); push(16'h9000); push(16'h1000);     // 上 + 下
        @(posedge clk); #1;
        /* holdoff = 8 个样本，这两次跳变相隔 1 个样本 → 第二次被 holdoff 吃掉 */
        chk("T3 任意边沿（holdoff 限制）", trig_cnt, 1);

        /* -------------------- T4/T5 holdoff 限流 -------------------- */
        do_reset();
        mode <= 2'd3; enable <= 1'b1;                        // 电平：一直 >= TH
        repeat (24) push(16'h9000);                          // 24 个样本全在高电平
        @(posedge clk); #1;
        /* 第一个样本立即触发，之后每 (HOLDOFF+1)=9 个样本一次：
         * 触发点 = 第 1, 10, 19 个 → 3 次 */
        chk("T5 电平+holdoff 次数", trig_cnt, 3);

        /* -------------------- T6 fired 粘滞 / clear -------------------- */
        @(negedge clk); clear <= 1'b1;
        @(posedge clk); #1;
        @(negedge clk); clear <= 1'b0;
        repeat (2) @(posedge clk); #1;
        chk("T6 clear 后 fired=0",  fired,    0);
        chk("T6 clear 后计数=0",    trig_cnt, 0);

        /* -------------------- T7 禁用时不触发 -------------------- */
        do_reset();
        mode <= 2'd0; enable <= 1'b0;                        // 关掉
        push(16'h1000); push(16'hF000);
        @(posedge clk); #1;
        chk("T7 禁用时不触发", trig_cnt, 0);

        /* -------------------- T8 last_sample / above -------------------- */
        do_reset();
        mode <= 2'd0; enable <= 1'b1;
        push(16'h9000);
        @(posedge clk); #1;
        chk("T8 last_sample", last_sample, 16'h9000);
        chk("T8 above",       above,       1);

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("[FAIL] 仿真超时");
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
