`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_boot_scan.sv -- boot_loader 的"中途插入"行为测试
 * -----------------------------------------------------------------------------
 * 复现什么：板上的引导流是**连续**的，而 FPGA 配置完成的瞬间，宿主正发到流的
 *   任意位置。于是 boot_loader 上电后看到的第一个字节几乎不可能是会话起点，它必须
 *   在 S_IDLE 里"扫描"到下一个 magic。本测试台就从**任意字节偏移**开始喂字节流，
 *   看它最终能不能把镜像灌进去。
 *
 * 输入：sw/gen_boot_stream.py 生成的逐字节 hex（每行一个字节）。
 *
 * 判据（每次运行打印一行 SCAN）：
 *   off      起始字节偏移
 *   fed      喂进去多少字节（到 S_FIN 为止 / 总共）
 *   w_irom   写进 IROM 的字数（应为 16384）
 *   w_dram   写进 DRAM 的字数（应为 583 或镜像实际长度）
 *   ok/err   最终标志（1/0）
 *   busy     最终 busy（必须 0，否则 CPU 会被永久按住）
 *   w0       IROM 第 0 个字（用来确认写的确实是镜像的第一条指令）
 *
 * ★ 不变量：这里不放 CPU、不放 DCache，只测 loader 的协议健壮性 —— 要能把"扫描
 *   阶段被 magic-like 字节误导"这件事与 CPU 行为完全隔离开。
 * ============================================================================= */
module tb_boot_scan;

    localparam integer MAX_WORDS  = 16384;
    localparam integer MAX_DWORDS = 32768;

    localparam integer CLK_HALF = 10;      // 10ns 半周期 -> 50MHz
    logic clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    logic rst    = 1'b1;
    logic [7:0]  rx_data  = 8'd0;
    logic        rx_valid = 1'b0;

    logic        mem_sel, mem_we;
    logic [31:0] mem_addr, mem_wdata;
    logic        busy, ok, err;
    logic [15:0] dbg_words;

    boot_loader #(
        .CLK_FREQ    (50_000_000),
        // 为了跑得快：IDLE 超时 1ms、字节间超时 1ms（真实值是 5ms/20us 量级，
        // 但只要"字节间隔 << 超时"这个关系不变，扫描逻辑的行为就一样）。
        .IDLE_TMO_MS (1),
        .GAP_TMO_MS  (1),
        // ★ v13.3（P1）起生产配置是 SOF_SILENCE_MS=1（帧首静默）。本测试台**故意关掉**
        //   它，因为它测的是"没有帧同步时的裸扫描行为"（历史缺陷的复现手段）。
        //   真实协议行为见 sim/tb_boot_sync.sv（那是进回归的那一个）。
        //   注意：关掉之后，从会话起点喂流能成功、从载荷中间喂会被假 'G' 打死 ——
        //   这正是 v13.1 之前上板三次只成功一次的原因。
        .SOF_SILENCE_MS (0),
        .MAX_WORDS   (MAX_WORDS),
        .MAX_DWORDS  (MAX_DWORDS)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .rx_data   (rx_data),
        .rx_valid  (rx_valid),
        .busy      (busy),
        .ok        (ok),
        .err       (err),
        .mem_sel   (mem_sel),
        .mem_we    (mem_we),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .dbg_words (dbg_words)
    );

    // ------------------------------------------------------------ 统计
    integer w_irom = 0;
    integer w_dram = 0;
    logic [31:0] w0 = 32'hx;
    always @(posedge clk) begin
        if (mem_we) begin
            if (mem_sel) w_dram = w_dram + 1;
            else begin
                if (w_irom == 0) w0 = mem_wdata;
                w_irom = w_irom + 1;
            end
        end
    end

    // ------------------------------------------------------------ 状态轨迹
    // 看清楚"扫描阶段到底被哪个 magic-like 字节带偏了"：每次 st 变化打一行。
    logic [2:0] st_prev = 3'd0;
    always @(posedge clk) begin
        if (dut.st != st_prev) begin
            if ($test$plusargs("trace"))
                $display("  ST fed=%0d st=%0d rx=%02x we=%0d sel=%0d addr=%0d len=%0d sum=%08x have=%0d",
                         fed, dut.st, (rx_valid ? rx_data : 8'hxx),
                         mem_we, mem_sel, mem_addr, dut.len, dut.sum, dut.have_r);
            st_prev = dut.st;
        end
    end

    // ------------------------------------------------------------ 字节流
    localparam integer STREAM_MAX = 400000;
    logic [7:0] stream [0:STREAM_MAX-1];
    integer stream_len = 0;

    reg [8*260-1:0] stream_path = "sim/cm_stream.hex";
    integer off = 0;
    integer max_feed = 0;      // 0 = 全部喂完

    integer i;
    integer fed;
    integer k;
    integer seen_fin_at;
    integer expect_irom = -1;      // -1 = 只打印，不做判据
    integer expect_ok   = -1;

    // 把 32 位十六进制（$readmemh 读进来时是 32 位）压成 8 位
    logic [31:0] tmp [0:STREAM_MAX-1];

    initial begin
        if ($value$plusargs("stream=%s", stream_path)) ;
        if ($value$plusargs("off=%d", off)) ;
        if ($value$plusargs("max=%d", max_feed)) ;
        if ($value$plusargs("expect_irom=%d", expect_irom)) ;
        if ($value$plusargs("expect_ok=%d", expect_ok)) ;

        $readmemh(stream_path, tmp);
        // 统计有效字节数（$readmemh 之后尾部是 x）
        stream_len = 0;
        for (i = 0; i < STREAM_MAX; i = i + 1) begin
            if (tmp[i] === 32'hx) ;
            else begin
                stream[i] = tmp[i][7:0];
                stream_len  = i + 1;
            end
        end
        if ($test$plusargs("quiet") == 0)
            $display("[tb] stream=%0s  len=%0d  off=%0d", stream_path, stream_len, off);

        rst = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        fed = 0;
        seen_fin_at = -1;
        for (i = off; ((i < stream_len) && ((max_feed == 0) || (fed < max_feed))); i = i + 1) begin
            // 已经被 'G' 打进 S_FIN 就记下位置，然后继续喂到上限
            if (seen_fin_at < 0 && dut.st == 3'd4) seen_fin_at = fed;
            @(negedge clk);
            rx_data  = stream[i];
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
            fed = fed + 1;
            for (k = 0; k < 8; k = k + 1) @(posedge clk);
        end

        // 停止喂字节，等超时把所有失败路径走完（IDLE_TMO = 50000 拍）
        repeat (4 * 50000) @(posedge clk);

        $display("SCAN off=%0d fed=%0d len=%0d w_irom=%0d w_dram=%0d ok=%0d err=%0d busy=%0d fin_at=%0d w0=%08x",
                 off, fed, stream_len, w_irom, w_dram, ok, err, busy, seen_fin_at, w0);

        // 可选判据：给了 +expect_irom= / +expect_ok= 就打自检标签（给 regress.ps1 用）
        if (expect_irom >= 0 || expect_ok >= 0) begin
            if (((expect_irom < 0) || (w_irom == expect_irom)) &&
                ((expect_ok   < 0) || (ok == expect_ok[0])) &&
                (busy == 1'b0)) begin
                $display("[BOOTSCAN-SELFCHECK] status=PASS");
            end else begin
                $display("[BOOTSCAN-SELFCHECK] status=FAIL (want w_irom=%0d ok=%0d, got w_irom=%0d ok=%0d busy=%0d)",
                         expect_irom, expect_ok, w_irom, ok, busy);
            end
        end
        $finish;
    end

endmodule
