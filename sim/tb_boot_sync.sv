`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_boot_sync.sv -- 帧首静默（v13.3 / P1）的专项单测
 * -----------------------------------------------------------------------------
 * 测什么（三条，正好对应"没有静默时到底是什么行为"）：
 *
 *   S1  静默之后的合法帧            -> 必须收下（写 4 个字）
 *   S2  没有静默的"完整合法帧"      -> 必须**完全忽略**（一个字节都不许写）
 *       这是本特性存在的理由：载荷里出现 0x42/0x43/0x47 时，如果长度和校验和
 *       恰好都成立（实测载荷里真的能拼出来），靠"扫描 magic"是分不开的。
 *       ---- 停掉上层脚本的手工测试 ----
 *       用 iverilog 跑本文件：
 *         iverilog -g2012 -I rtl -I board -o _diag/tb_boot_sync.vvp \
 *             sim/tb_boot_sync.sv board/boot_loader.sv
 *         vvp -n _diag/tb_boot_sync.vvp
 *   S3  再静默之后的第二个合法帧    -> 必须收下（累计写 8 个字）
 *   S4  不发 GO，等空闲超时         -> busy 必须回 0 且 err=0（已经收过帧）
 *
 * ★ 判据只认"写进去几个字 + 关键字值"，不看内部状态机 —— 改实现也不用改测试。
 * ★ 参数口径：SOF_SILENCE_MS=1 -> 50000 拍；帧内字节间隔 40 拍（远小于它）。
 * ============================================================================= */
module tb_boot_sync;

    localparam integer CLK_HALF   = 10;        // 10ns 半周期 -> 50MHz
    localparam integer SOF_SIL    = 50_000;    // = 1 ms @50MHz
    localparam integer BYTE_GAP   = 40;        // 帧内字节间隔（约 0.8 us）

    logic clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    logic rst = 1'b1;
    logic [7:0] rx_data  = 8'd0;
    logic       rx_valid = 1'b0;

    logic        mem_sel, mem_we;
    logic [31:0] mem_addr, mem_wdata;
    logic        busy, ok, err;
    logic [15:0] dbg_words;

    boot_loader #(
        .CLK_FREQ       (50_000_000),
        .IDLE_TMO_MS    (20),
        .GAP_TMO_MS     (5),
        .SOF_SILENCE_MS (1),
        .MAX_WORDS      (1024),
        .MAX_DWORDS     (1024)
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

    /* ------------------------------------------------------------ 观测 */
    integer      nwr   = 0;
    logic [31:0] w0    = 32'hx;
    logic [31:0] wlast = 32'hx;
    always_ff @(posedge clk) begin
        if (mem_we && !mem_sel) begin
            if (nwr == 0) w0 = mem_wdata;
            wlast = mem_wdata;
            nwr   = nwr + 1;
        end
    end

    /* ------------------------------------------------------------ 发送器 */
    task automatic put(input logic [7:0] b, input integer gap);
        integer k;
        begin
            for (k = 0; k < gap; k = k + 1) @(posedge clk);
            @(negedge clk);
            rx_data  = b;
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
        end
    endtask

    task automatic put_word(input logic [31:0] w);
        begin
            put(w[31:24], BYTE_GAP);
            put(w[23:16], BYTE_GAP);
            put(w[15: 8], BYTE_GAP);
            put(w[ 7: 0], BYTE_GAP);
        end
    endtask

    // 一帧 'B'：magic + 字数 + 数据 + 校验和（全大端，与 load_uart.ps1 一致）
    //   first_gap = 第一个字节之前的空闲拍数（静默门控就吃这个）
    task automatic send_irom_frame(input logic [31:0] a, b, c, d,
                                   input integer first_gap);
        logic [31:0] cks;
        begin
            cks = a + b + c + d;
            put(8'h42, first_gap);
            put_word(32'd4);
            put_word(a); put_word(b); put_word(c); put_word(d);
            put_word(cks);
        end
    endtask

    /* ------------------------------------------------------------ 主流程 */
    integer n_after_s1 = 0, n_after_s2 = 0, n_after_s3 = 0;
    logic   busy_at_s2;
    integer npass = 0, nfail = 0;

    task automatic chk(input [8*70-1:0] name, input cond);
        begin
            if (cond) begin
                npass = npass + 1;
                $display("  [PASS] %0s", name);
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    initial begin
        $display("================================================================");
        $display(" tb_boot_sync : SOF_SILENCE_MS=1 (%0d cycles), idle timeout 20 ms", SOF_SIL);
        $display("================================================================");

        rst = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);

        // ---------------- S1：静默之后的合法帧 ----------------
        send_irom_frame(32'h1111_1111, 32'h2222_2222, 32'h3333_3333, 32'h4444_4444,
                        SOF_SIL + 1000);
        repeat (200) @(posedge clk);
        n_after_s1 = nwr;
        $display("[S1] 静默后合法帧：写入 %0d 个字，w0=%08x", n_after_s1, w0);

        // ---------------- S2：**没有静默**的完整合法帧（必须被忽略） ----------------
        //   注意：帧内容本身完全合法（长度与校验和都对），唯一的区别是前面没有静默。
        //   这正是"载荷里恰好拼出一个合法帧"的情形。
        send_irom_frame(32'hAAAA_AAAA, 32'hBBBB_BBBB, 32'hCCCC_CCCC, 32'hDDDD_DDDD,
                        BYTE_GAP);
        repeat (600) @(posedge clk);
        n_after_s2 = nwr;
        busy_at_s2 = busy;             // ★ 必须当场快照：S4 之后 busy 会释放
        $display("[S2] 无静默的合法帧：累计写入 %0d 个字（应仍为 %0d），busy=%0b err=%0b",
                 n_after_s2, n_after_s1, busy, err);

        // ---------------- S3：再次静默后的合法帧 ----------------
        send_irom_frame(32'h5555_5555, 32'h6666_6666, 32'h7777_7777, 32'h8888_8888,
                        SOF_SIL + 1000);
        repeat (200) @(posedge clk);
        n_after_s3 = nwr;
        $display("[S3] 再静默后合法帧：累计写入 %0d 个字，w0=%08x wlast=%08x",
                 n_after_s3, w0, wlast);

        // ---------------- S4：不发 GO，等空闲超时 ----------------
        repeat (25 * 50_000) @(posedge clk);     // 25 ms > IDLE_TMO_MS(20)
        $display("[S4] 超时后：busy=%0b ok=%0b err=%0b", busy, ok, err);

        $display("----------------------------------------------------------");
        // ★ 判据名必须纯 ASCII：chk() 的参数是 8*70 位 packed vector，
        //   塞 UTF-8 中文会按字节截断成乱码（本轮第一次跑就是这样）。
        chk("S1 frame after silence accepted (4 words)", n_after_s1 == 4);
        chk("S1 first word correct",                     w0 == 32'h1111_1111);
        chk("S2 complete frame WITHOUT silence ignored", n_after_s2 == n_after_s1);
        chk("S2 busy still 1 (no fake GO took it to S_FIN)", busy_at_s2 === 1'b1);
        chk("S3 second gapped frame accepted (8 words)", n_after_s3 == n_after_s1 + 4);
        chk("S3 last word correct",                      wlast == 32'h8888_8888);
        chk("S4 idle timeout released busy",             busy === 1'b0);
        chk("S4 got a frame -> ok=1 err=0",              ok === 1'b1 && err === 1'b0);
        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[BOOTSYNC-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[BOOTSYNC-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $display("================================================================");
        $finish;
    end

endmodule
