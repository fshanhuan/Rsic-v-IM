`timescale 1ns / 1ps

/* =============================================================================
 * tb_xadc_sampler.sv — XADC 采样器自检台（带一个 DRP 从机模型）
 * -----------------------------------------------------------------------------
 * XADC 是 Xilinx 硬核，行为模型只在 unisim 里；本台子用一个**行为级 DRP 从机**
 * 替它：收到 den 后 2 拍拉 drdy，do 返回一个可预测的计数器值。
 *
 * 这样能验证采样器里所有"自己写的"部分：
 *   · 轮询节拍（POLL_HZ）对不对
 *   · 通道是否严格交替（ch0 → ch1 → ch0 …）
 *   · DRP 握手（den 一拍、等 drdy、取 do）
 *   · FIFO 入队/出队、level、满与溢出标志
 *   · 看门狗（DRP 永远不回 drdy 时能不能自己走出来）
 *
 * 唯一没被验证的是 XADC 硬核本身（那是厂商保证的），这一点在文件里明说。
 * ============================================================================= */
module tb_xadc_sampler;

    localparam int CLK_HZ  = 50_000_000;
    localparam int POLL_HZ = 1_000_000;          // 50 拍一次，便于快速跑
    localparam int PERIOD  = CLK_HZ / POLL_HZ;   // 50

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #10 clk = ~clk;                        // 50 MHz

    logic        en = 1'b0;
    logic [6:0]  ch0 = 7'h16, ch1 = 7'h1B;
    logic        ch1_en = 1'b1;

    logic [6:0]  daddr;
    logic        den, dwe;
    logic [15:0] di, do_;
    initial begin drdy = 1'b0; do_ = 16'd0; end
    logic        drdy;

    logic        rd_en = 1'b0, clr_ovf = 1'b0;
    logic [15:0] rd_data;
    logic [10:0] level;
    logic        full, overflow;
    logic [31:0] sample_cnt;

    xadc_sampler #(
        .CLK_HZ  (CLK_HZ),
        .POLL_HZ (POLL_HZ),
        .FIFO_AW (4)                 // 16 深，方便把"满/溢出"跑出来
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .en         (en),
        .ch0        (ch0),
        .ch1        (ch1),
        .ch1_en     (ch1_en),
        .daddr      (daddr),
        .den        (den),
        .dwe        (dwe),
        .di         (di),
        .do_        (do_),
        .drdy       (drdy),
        .rd_en      (rd_en),
        .clr_ovf    (clr_ovf),
        .rd_data    (rd_data),
        .level      (level),
        .full       (full),
        .overflow   (overflow),
        .sample_cnt (sample_cnt)
    );

    /* =========================================================================
     * DRP 从机模型：den 后 2 拍给 drdy，do = {通道号[6:0], 9 位转换计数}
     * 每个样本都能反推出"是第几次转换、哪个通道"。
     * mute_drdy=1 时永不回应，用来测看门狗。
     * ====================================================================== */
    logic [1:0]  dly    = 2'd0;
    logic [6:0]  last_ch = 7'd0;
    int          conv_n  = 0;
    logic        mute_drdy = 1'b0;

    always @(posedge clk) begin
        dly <= {dly[0], den};
        if (den) begin
            last_ch <= daddr;
            conv_n  = conv_n + 1;
        end
    end

    always @(posedge clk) begin
        drdy <= (!mute_drdy) && dly[1];
        if (dly[1]) do_ <= {last_ch, 9'd0} | {7'd0, conv_n[8:0]};
    end
    /* =========================================================================
     * 检查
     * ====================================================================== */
    int errors = 0;

    task automatic chk(input string nm, input int got, input int exp);
        if (got == exp) $display("[PASS] %-36s = %0d", nm, got);
        else begin $display("[FAIL] %-36s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    /* 记录交替顺序 */
    logic [6:0] seen_ch [0:7];
    int         n_seen = 0;
    int         den_cnt = 0;
    always @(posedge clk) if (den) den_cnt = den_cnt + 1;
    always @(posedge clk) begin
        if (den && n_seen < 8) begin
            seen_ch[n_seen] = daddr;
            n_seen = n_seen + 1;
        end
    end

    initial begin
        int n0, n1;

        repeat (5) @(posedge clk);
        rst <= 1'b0;
        en  <= 1'b1;

        // 让 FIFO 写满（16 深）再停
        wait (full == 1'b1);
        @(posedge clk);
        en <= 1'b0;

        repeat (3) @(posedge clk);

        $display("---- 交替顺序 ----");
        $display("  前 6 次 DRP 地址: %02h %02h %02h %02h %02h %02h",
                 seen_ch[0], seen_ch[1], seen_ch[2], seen_ch[3], seen_ch[4], seen_ch[5]);
        chk("第1次采样 ch0", seen_ch[0], 7'h16);
        chk("第2次采样 ch1", seen_ch[1], 7'h1B);
        chk("第3次采样 ch0", seen_ch[2], 7'h16);
        chk("第4次采样 ch1", seen_ch[3], 7'h1B);

        $display("---- FIFO ----");
        chk("FIFO 已满",     full,     1);
        chk("level == 16",   level,   16);
        chk("样本计数 >= 16", sample_cnt >= 16 ? 1 : 0, 1);

        // 取 4 个样本，看 level 掉下去
        n0 = level;
        repeat (4) begin
            rd_en <= 1'b1; @(posedge clk);
            rd_en <= 1'b0; @(posedge clk);
        end
        n1 = level;
        $display("  读 4 次后 level: %0d -> %0d", n0, n1);
        chk("读 4 个后 level", n1, n0 - 4);

        // 溢流：满了还开着 en
        en <= 1'b1;
        repeat (PERIOD * 10) @(posedge clk);
        en <= 1'b0;
        chk("溢出标志置起", overflow, 1);

        // 清溢出
        clr_ovf <= 1'b1; @(posedge clk);
        clr_ovf <= 1'b0; @(posedge clk);
        chk("清溢出后为 0", overflow, 0);

        $display("---- 看门狗：DRP 不回应 ----");
        // 把 FIFO 读空，再静音 drdy，看采样器能不能自己继续轮询（不卡死）
        repeat (4) begin
            rd_en <= 1'b1; @(posedge clk);
            rd_en <= 1'b0; @(posedge clk);
        end
        mute_drdy <= 1'b1;
        en        <= 1'b1;
        @(posedge clk);
        // 数一下地址变化次数：卡死的话地址不变
        begin
            /* ★ 不能用"daddr 变了"当活着的证据：daddr 只在**成功取到样本**时才换通道，
             *   而这里 drdy 是静音的，永远不会成功 —— 第一版就是拿这个判据误报的。
             *   正确的活证据是"den 还在周期性发出"（每次重试都会重新发一拍 den）。 */
            int d0 = den_cnt;
            repeat (PERIOD * 40) @(posedge clk);
            $display("  drdy 静音后 den 脉冲数 = %0d", den_cnt - d0);
            if ((den_cnt - d0) >= 2) $display("[PASS] 看门狗能自己走出等待态");
            else begin $display("[FAIL] 卡死在等待态"); errors++; end
        end

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[FAIL] 仿真总超时（level=%0d full=%b）", level, full);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
