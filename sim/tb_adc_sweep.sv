`timescale 1ns / 1ps

/* =============================================================================
 * tb_adc_sweep.sv — DAC↔ADC 传输曲线扫描器自检台（含一个"模拟前端"行为模型）
 * -----------------------------------------------------------------------------
 * adc_sweep 只做数字部分：打码 → 等稳定 → 数新样本 → 求平均 → 存表。
 * 真正难验的是"它到底在什么时刻采样"，所以本台子造一个**确定性前端模型**：
 *
 *     收到 wr 就更新 dac_reg（= DAC 锁存器）
 *     adc_last = (dac_reg << 4) + OFFSET     （12 位左对齐，和 XADC 结果寄存器一致）
 *     adc_stb  每 8 拍一个           （= 采样率，和真板的 200 kSa/s 同一个含义）
 *
 * 这样每条记录的正确值都是**可解析算出来的**：avg(i) = (i<<4) + OFFSET。
 * 只要有一条不对，就说明状态机在"码值/稳定/累加"三者之间有错位。
 *
 * 覆盖：
 *   T1 补零前端（OFFSET=0）   256 条全对 + n_done=256 + done=1
 *   T2 加常数偏置（OFFSET=16）再扫一遍 —— 顺带验证"扫完之后再 start 能重启"
 *   T3 abort：中途叫停后 busy 落、done 保持 0
 *   T4 start 一直拉高不会再触发（边沿检测），done 不会被清掉
 *   T5 drain 必须在 busy 期间为 1（扫描期间要把 FIFO 腾空，否则 1024 深必满）
 *
 * 不验的：DAC0832 与 XADC 的模拟特性（那只能上板量，见 docs §48.15~48.17）。
 * ============================================================================= */
module tb_adc_sweep;

    localparam int CLK_HZ  = 50_000_000;
    localparam int TICK_HZ = 100_000;                 // 时基 10 µs = 500 拍
    localparam int STB_PER = 8;                       // 采样节拍 8 拍一个

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #10 clk = ~clk;                            // 50 MHz

    /* ---------------- DUT 端口 ---------------- */
    logic        start_level = 1'b0, abort_level = 1'b0;
    logic [15:0] settle = 16'd1;                      // 1 个 tick，跑得快
    logic [ 3:0] avg_log2 = 4'd4;                     // 16 次
    logic [ 7:0] rd_ptr = 8'd0;
    logic [15:0] rd_avg;
    logic        rd_ok;
    logic        busy, wr, done, drain;
    logic [ 7:0] code;
    logic [ 8:0] n_done;
    logic [15:0] adc_last;
    logic        adc_stb;

    adc_sweep #(
        .CLK_HZ  (CLK_HZ),
        .TICK_HZ (TICK_HZ)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .start_level (start_level),
        .abort_level (abort_level),
        .settle      (settle),
        .avg_log2    (avg_log2),
        .rd_ptr      (rd_ptr),
        .rd_avg      (rd_avg),
        .rd_ok       (rd_ok),
        .busy        (busy),
        .code        (code),
        .wr          (wr),
        .done        (done),
        .n_done      (n_done),
        .adc_last    (adc_last),
        .adc_stb     (adc_stb),
        .drain       (drain)
    );

    /* ---------------- 行为级"模拟前端" ---------------- */
    logic [ 7:0] dac_reg = 8'd0;
    logic [15:0] offset  = 16'd0;
    logic [ 2:0] stb_div = 3'd0;

    always_ff @(posedge clk) begin
        if (rst) begin
            dac_reg <= 8'd0;
            stb_div <= 3'd0;
            adc_stb <= 1'b0;
        end else begin
            if (wr) dac_reg <= code;                 // DAC 输入锁存器
            stb_div <= stb_div + 3'd1;
            adc_stb <= (stb_div == 3'd7);            // 每 8 拍一个样本节拍
        end
    end
    assign adc_last = {dac_reg, 4'b0000} + offset;   // 12 位左对齐 + 可编程偏置

    /* ---------------- 判据 ---------------- */
    int pass_cnt = 0;
    int fail_cnt = 0;
    string fails = "";

    task automatic chk(input bit cond, input string msg);
        if (cond) pass_cnt++;
        else begin
            fail_cnt++;
            if (fails.len() < 900) fails = {fails, "  FAIL: ", msg, "\n"};
            $display("[SWEEP] FAIL %s", msg);
        end
    endtask

    task automatic wait_done(input int max_cyc);
        int n;
        n = 0;
        while (!done && n < max_cyc) begin
            @(posedge clk);
            n++;
        end
    endtask

    /* 读所有 256 条并逐条比对，返回错误条数 */
    task automatic verify_ram(input int off);
        int bad, bad_ok;
        int i;
        logic [15:0] exp_v, got;
        bad = 0;
        bad_ok = 0;
        for (i = 0; i < 256; i++) begin
            rd_ptr = i[7:0];
            #1;
            exp_v = (i[15:0] << 4) + off;
            got   = rd_avg;
            if (rd_ok !== 1'b1) bad_ok++;
            if (got !== exp_v) begin
                bad++;
                if (bad <= 5)
                    $display("[SWEEP]   i=%0d exp=0x%04X got=0x%04X", i, exp_v, got);
            end
        end
        rd_ptr = 8'd0;
        #1;
        chk(bad == 0, $sformatf("256 条全对 (off=%0d)，错 %0d 条", off, bad));
        chk(bad_ok == 0, $sformatf("256 条 rd_ok 全为 1，例外 %0d 条", bad_ok));
    endtask

    task automatic pulse_start();
        start_level = 1'b0;
        @(posedge clk);
        @(posedge clk);
        start_level = 1'b1;                          // 上升沿 → 触发一次
        @(posedge clk);
    endtask

    initial begin
        $display("==== tb_adc_sweep start ====");

        /* ---------- 复位 ---------- */
        rst         = 1'b1;
        start_level = 1'b0;
        abort_level = 1'b0;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);

        chk(busy == 1'b0 && done == 1'b0 && n_done == 9'd0, "复位后 idle/done=0/n_done=0");
        chk(drain == 1'b0, "idle 时 drain=0（不干扰正常运行时的 FIFO）");
        chk(rd_ok == 1'b0, "复位后 rd_ok=0（还没扫到任何条目，不能当真值读）");

        /* ---------- T1：OFFSET=0，一次完整扫描 ---------- */
        offset = 16'd0;
        pulse_start();
        @(posedge clk);
        chk(busy == 1'b1, "T1 start 后 busy=1");
        chk(drain == 1'b1, "T1 扫描期间 drain=1（腾空 FIFO）");
        wait_done(600_000);
        chk(done == 1'b1, "T1 扫描完成 done=1");
        chk(n_done == 9'd256, $sformatf("T1 n_done=256 (实际 %0d)", n_done));
        chk(code == 8'hFF, $sformatf("T1 结束时停在码 0xFF (实际 0x%02X)", code));
        chk(busy == 1'b0, "T1 结束后 busy=0（DAC 交还 MMIO）");
        verify_ram(0);

        /* ---------- T2：加 16 LSB 偏置，扫完再重启 ---------- */
        offset = 16'd16;
        pulse_start();
        @(posedge clk);
        @(posedge clk);
        chk(busy == 1'b1 && done == 1'b0, "T2 重启：busy=1 且 done 被清");
        wait_done(600_000);
        chk(done == 1'b1, "T2 第二次扫描完成");
        verify_ram(16);

        /* ---------- T4：start 保持高电平不应再触发 ---------- */
        start_level = 1'b1;
        repeat (20_000) @(posedge clk);
        chk(done == 1'b1 && busy == 1'b0, "T4 start 恒高不重触发（边沿检测生效）");
        chk(n_done == 9'd256, "T4 done 状态被保持");

        /* ---------- T3：中途 abort ---------- */
        offset = 16'd0;
        pulse_start();
        repeat (2000) @(posedge clk);                // 停在中途
        chk(busy == 1'b1, "T3 abort 前仍在扫");
        abort_level = 1'b1;
        @(posedge clk);
        @(posedge clk);
        chk(busy == 1'b0, "T3 abort 后 busy=0");
        abort_level = 1'b0;
        start_level = 1'b0;
        repeat (5) @(posedge clk);

        /* ---------- 汇总 ---------- */
        if (fail_cnt != 0) $write("%s", fails);
        if (fail_cnt == 0)
            $display("\n[SWEEP-SELFCHECK] status=PASS  (%0d 条判据)", pass_cnt);
        else
            $display("\n[SWEEP-SELFCHECK] status=FAIL  (pass=%0d fail=%0d)", pass_cnt, fail_cnt);
        $finish;
    end

    /* 看门狗：防止某个 wait 永远不返回 */
    initial begin
        #50_000_000;                                  // 50 ms 仿真时间
        $display("[SWEEP] TIMEOUT");
        $display("\n[SWEEP-SELFCHECK] status=FAIL  (timeout)");
        $finish;
    end

endmodule
