`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * boot_loader.sv — 串口程序引导器（IROM + DRAM 双镜像）
 * -----------------------------------------------------------------------------
 * 解决什么问题：IROM 的初值原来靠 IROM_INIT($readmemh) 在**综合时**固化进 BRAM，
 *   于是"改一行程序 = 重综合 + 重实现 + 重布线"（实测 33 min）。本模块让宿主机
 *   通过串口把镜像直接写进 IROM/DRAM，改程序从 33 min 降到 ~1 s。
 *
 * ★ v13：加了 **DRAM 帧**。原因：本核是哈佛双口（取指走 IROM、load/store 走 DRAM），
 *   C 程序的 .rodata/.data 必须落在能被 lw 读到的 DRAM 里，而原来只能灌 IROM。
 *   没有 DRAM 帧，跑 C 程序（CoreMark/FreeRTOS）就只能改 bitstream。
 *
 * ★★ 宿主 → 板的帧格式（8N1，115200，全大端）。三种命令，都是"magic 开头"：
 *
 *      'B' (0x42)  IROM 帧
 *      'C' (0x43)  DRAM 帧
 *      'G' (0x47)  GO：释放 CPU（无负载）
 *
 *   帧体（'B' / 'C' 相同）：
 *      字节 0        : magic
 *      字节 1..4     : len[31:24] .. len[7:0]   字数
 *      字节 5..(4+4*len) : 每个字 4 字节，MSB first
 *      最后 4 字节   : cks = 全部字按 32 位无符号累加和
 *
 *   典型会话：'B' 帧 → 'C' 帧（可选）→ 'G'。
 *   ★ 不变量：大端顺序、无 ACK（只有 RX 方向）、校验和是**按字累加**而不是按字节。
 *     宿主机脚本 _diag/load_uart.ps1 必须与此严格一致。
 *
 * ★ 引导期间的行为：
 *   - busy=1 → 上层把 CPU 按在复位里，IROM/DRAM 口被本模块独占（不需要仲裁）；
 *   - 每收完一帧（校验通过）→ **继续留在引导态**等下一帧或 'G'；
 *   - 收到 'G' → busy=0、ok=1，CPU 从 0x0 开始跑新程序；
 *   - 收完帧后 IDLE_TMO_MS 内没等到下一帧/'G' → 也自动释放（ok=1），
 *     这样宿主机忘了发 'G' 也不会把板子永久按在复位里；
 *   - 复位后 IDLE_TMO_MS 内连 magic 都没等到 → busy=0、ok=0、err=1，
 *     CPU 照常跑 IROM 里原有的程序（板子离了主机也能独立启动）；
 *   - 帧内断流 → 回到等 magic（允许宿主重发），再超时一次才释放。
 *
 * ★★ 不变量（第一版就写错过，务必看住）：
 *   **任何**失败路径最终都必须让 busy 回到 0。第一版把"IDLE 超时"也写成回到
 *   S_IDLE，于是没有 magic 时会在 IDLE 里无限循环、CPU 被永久按在复位里 ——
 *   表现是"上电后板子毫无动静"，而且极易被误判成时钟/复位问题。
 *   现在的规则：S_IDLE 超时 → S_FIN（释放）；收帧中途超时 → S_IDLE（允许重发），
 *   而这一次 S_IDLE 若再超时也会走 S_FIN，所以最多多等一个 IDLE_TMO_MS。
 * ============================================================================= */
module boot_loader #(
    parameter integer CLK_FREQ    = 50_000_000,
    // 复位后/帧间等待 magic 的超时（ms）：超时则放弃等待、释放 CPU
    parameter integer IDLE_TMO_MS = 500,
    // 帧内字节间超时（ms）：断流即放弃这一帧
    parameter integer GAP_TMO_MS  = 20,
    // ★★ v13.3（P1）帧首静默：magic 之前线路必须**静默**这么久才认（0 = 关闭该特性）。
    //   为什么必须有：S_IDLE 是在一条连续字节流里逐字节扫描 magic 的，而载荷里天然
    //   出现 0x42/0x43/0x47（一份 67 KB 的 CoreMark 会话里有 'B'×10 / 'C'×27 / 'G'×79）。
    //   没有静默要求时，"FPGA 配置完成的瞬间宿主发到流的哪个字节"就决定了引导成败：
    //   撞上假 'G' 直接报废、撞上假 'B'/'C' 会按垃圾长度写垃圾（实测写掉 28 652 个 DRAM 字）。
    //   帧内相邻字节只隔 87 us（115200），而宿主在帧/会话之间留的空隙是 50 ms 量级，
    //   所以"静默 >= 1 ms"就能把两者彻底分开 —— 这就是 Modbus-RTU 的做法。
    //   ★ 不变量：宿主的帧间空隙必须 > SOF_SILENCE_MS（load_uart.ps1 的 -FrameGapMs，
    //     默认 50 ms）；改这里就要同步改宿主。
    parameter integer SOF_SILENCE_MS = 1,
    // IROM 帧允许的最大字数（与 IROM_WORDS 一致）
    parameter integer MAX_WORDS   = 16384,
    // DRAM 帧允许的最大字数（与 DRAM_WORDS 一致）
    parameter integer MAX_DWORDS  = 32768,
    // ★ DRAM 帧的写入**基址（字）**：软件约定 .rodata/.data 从 0x1_0000 开始
    //   （sw/coremark_port/link.ld 的 ORIGIN(dram)），也就是一个字偏移 0x4000。
    //   镜像文件本身不带地址前缀，所以引导时必须把它放到基址上，
    //   否则数据会落在 DRAM 的低 64KB 空洞里，CPU 一条都读不到。
    parameter integer DRAM_BASE_WORD = 32'h1_0000 >> 2
) (
    input  logic        clk,
    input  logic        rst,        // 同步高有效

    // 来自 uart_rx
    input  logic [7:0]  rx_data,
    input  logic        rx_valid,   // 单拍脉冲

    // 状态
    output logic        busy,       // 1 = 正在引导，CPU 必须保持复位
    output logic        ok,         // 1 = 至少一帧写入成功
    output logic        err,        // 1 = 校验失败/长度非法/超时（诊断用）

    // 写口：mem_sel 选择目标（0 = IROM，1 = DRAM），与 mem_we 同拍有效
    output logic        mem_sel,
    output logic        mem_we,
    output logic [31:0] mem_addr,   // 字地址
    output logic [31:0] mem_wdata,

    // 诊断
    output logic [15:0] dbg_words   // 已写入的总字数（两个镜像合计）
);

    // ---- 超时门限（拍） ----
    localparam integer IDLE_TMO = (CLK_FREQ / 1000) * IDLE_TMO_MS;
    localparam integer GAP_TMO  = (CLK_FREQ / 1000) * GAP_TMO_MS;
    localparam integer SOF_SIL  = (CLK_FREQ / 1000) * SOF_SILENCE_MS;

    localparam logic [7:0] MAGIC_IROM = 8'h42;   // 'B'
    localparam logic [7:0] MAGIC_DRAM = 8'h43;   // 'C'
    localparam logic [7:0] MAGIC_GO   = 8'h47;   // 'G'

    typedef enum logic [2:0] {
        S_IDLE = 3'd0,   // 等 magic
        S_LEN  = 3'd1,   // 收 4 字节长度
        S_DATA = 3'd2,   // 收 len 个字
        S_CK   = 3'd3,   // 收 4 字节校验和
        S_FIN  = 3'd4    // 释放 CPU
    } st_t;

    st_t         st;
    logic [31:0] tmo_cnt;
    logic [31:0] len;          // 目标字数
    logic [31:0] word_cnt;     // 已收字数
    logic [ 1:0] byte_i;       // 字内字节序号（0 = MSB）
    logic [31:0] sh_len;
    logic [31:0] sh_word;
    logic [31:0] sh_cks;
    logic [31:0] sum;          // 累加和（按字）
    logic        busy_r, ok_r, err_r;
    logic [15:0] words_r;
    logic        sel_r;        // 当前帧的目标：0 = IROM，1 = DRAM
    logic        have_r;       // 本会话是否已经成功收过至少一帧

    // 长度上限按当前目标选
    logic [31:0] len_max;
    assign len_max = sel_r ? MAX_DWORDS : MAX_WORDS;

    // 当前字节拼进 32 位移位寄存器（大端：先来的进高位）
    logic [31:0] word_next;
    assign word_next = {sh_word[23:0], rx_data};

    // 长度/校验和也是同样的大端拼接
    logic [31:0] len_next, cks_next;
    assign len_next = {sh_len[23:0], rx_data};
    assign cks_next = {sh_cks[23:0], rx_data};

    // 超时门限按状态选：IDLE 用长超时，收帧过程中用字节间短超时
    logic [31:0] tmo_limit;
    assign tmo_limit = (st == S_IDLE) ? IDLE_TMO : GAP_TMO;

    logic tmo_hit;
    assign tmo_hit = (tmo_cnt >= tmo_limit);

    /* ---- ★★ v13.3（P1）：帧首静默计数器 ----------------------------------------
     * 语义：距离上一个收到的字节过了多少拍（饱和在 SOF_SIL 上）。
     *   帧内字节间隔 ~87 us（4340 拍）→ sil_ok 永远为 0；
     *   宿主在帧/会话之间的 50 ms 空隙 → sil_ok 为 1。
     * S_IDLE 只在这时候认 magic，于是"载荷里的假 magic"再也不可能被当成命令。
     * 为什么它比"双字节 magic"更好：双字节只是把误判概率从 1/256 降到 1/65536，
     *   而静默是**语义上**不可能误判 —— 载荷内部的字节流不允许出现静默。
     */
    localparam logic [31:0] SOF_SIL_C = SOF_SIL;
    logic [31:0] sil_cnt;
    logic        sil_ok;
    assign sil_ok = (sil_cnt >= SOF_SIL_C);

    always_ff @(posedge clk) begin
        if (rst)              sil_cnt <= 32'd0;
        else if (rx_valid)    sil_cnt <= 32'd0;
        else if (!sil_ok)     sil_cnt <= sil_cnt + 32'd1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            st        <= S_IDLE;
            tmo_cnt   <= 32'd0;
            len       <= 32'd0;
            word_cnt  <= 32'd0;
            byte_i    <= 2'd0;
            sh_len    <= 32'd0;
            sh_word   <= 32'd0;
            sh_cks    <= 32'd0;
            sum       <= 32'd0;
            busy_r    <= 1'b1;        // 复位后立刻按住 CPU，等宿主来灌镜像
            ok_r      <= 1'b0;
            err_r     <= 1'b0;
            words_r   <= 16'd0;
            sel_r     <= 1'b0;
            have_r    <= 1'b0;
            mem_we    <= 1'b0;
            mem_sel   <= 1'b0;
            mem_addr  <= 32'd0;
            mem_wdata <= 32'd0;
        end else begin
            mem_we <= 1'b0;                       // 写脉冲默认只有一拍

            // ---- 超时计数（收到任何字节都清零） ----
            if (rx_valid)          tmo_cnt <= 32'd0;
            else if (!tmo_hit)     tmo_cnt <= tmo_cnt + 32'd1;

            if (!rx_valid && tmo_hit && (st != S_FIN)) begin
                // ★ 超时的处置**按状态区分**（第一版这里写错，见头部不变量）：
                //   S_IDLE 超时 = 宿主不来（再来）引导 → 直接释放 CPU；
                //     已经收过一帧 → ok=1（正常完成），一帧都没收 → err=1，跑原有程序；
                //   收帧中途超时 = 这一帧废了 → 退回 S_IDLE 允许宿主重发，
                //     而 S_IDLE 下一次超时必然走 S_FIN，所以不会永久按住 CPU。
                if (st == S_IDLE) begin
                    st    <= S_FIN;
                    ok_r  <= have_r;
                    err_r <= ~have_r;
                end else begin
                    st     <= S_IDLE;
                    byte_i <= 2'd0;
                    err_r  <= 1'b1;
                end
            end else begin
                case (st)
                    // ---------------- 等 magic / GO ----------------
                    S_IDLE: begin
                        // ★ v13.3：只有"线路静默够久"之后的那个字节才可能是帧首命令。
                        //   载荷内部的假 magic 一律忽略（不认 magic = 不会误动作）。
                        if (rx_valid && sil_ok) begin
                            if (rx_data == MAGIC_IROM) begin
                                sel_r  <= 1'b0;
                                st     <= S_LEN;
                                byte_i <= 2'd0;
                                err_r  <= 1'b0;
                            end else if (rx_data == MAGIC_DRAM) begin
                                sel_r  <= 1'b1;
                                st     <= S_LEN;
                                byte_i <= 2'd0;
                                err_r  <= 1'b0;
                            // ★★ v13.1 曾经这里要求 `&& have_r`（"没收过帧就不认 GO"），
                            //   v13.3 起**撤掉**：那时它是"没有帧同步"的补丁，用来防
                            //   载荷里的假 'G' 把会话当场打死。现在帧首静默（SOF_SILENCE_MS）
                            //   已经从语义上排除了这种可能（载荷内部不可能有 1 ms 静默），
                            //   而保留 have_r 反而制造新问题：**校验失败的会话无法用 'G'
                            //   显式释放**，只能干等 5 s 空闲超时（tb_boot 的 u_bad 就是这么
                            //   抓到的）。所以这里恢复无条件响应，ok 仍只在真收过帧时为 1。
                            end else if (rx_data == MAGIC_GO) begin
                                // ok 只在真收过帧时为 1。
                                st   <= S_FIN;
                                ok_r <= have_r;
                            end
                        end
                    end

                    // ---------------- 4 字节长度 ----------------
                    S_LEN: begin
                        if (rx_valid) begin
                            sh_len <= len_next;
                            if (byte_i == 2'd3) begin
                                byte_i <= 2'd0;
                                // ★ 长度必须在 1..上限 之间，否则判失败并退回等 magic
                                if ((len_next > len_max) || (len_next == 32'd0)) begin
                                    err_r <= 1'b1;
                                    st    <= S_IDLE;
                                end else begin
                                    len      <= len_next;
                                    word_cnt <= 32'd0;
                                    sum      <= 32'd0;
                                    st       <= S_DATA;
                                end
                            end else begin
                                byte_i <= byte_i + 2'd1;
                            end
                        end
                    end

                    // ---------------- len 个字 ----------------
                    S_DATA: begin
                        if (rx_valid) begin
                            sh_word <= word_next;
                            if (byte_i == 2'd3) begin
                                byte_i <= 2'd0;
                                // 收满一个字：当拍发写脉冲（mem_we 只高这一拍）
                                // ★ addr/data/sel 与 we 同拍寄存，所以写发生在下一拍，
                                //   期间 addr/data/sel 保持不变 —— 不需要额外握手。
                                mem_we    <= 1'b1;
                                mem_sel   <= sel_r;
                                // ★ DRAM 帧要加基址；IROM 帧从 0 开始
                                mem_addr  <= sel_r ? (word_cnt + DRAM_BASE_WORD[31:0])
                                                   : word_cnt;
                                mem_wdata <= word_next;
                                sum       <= sum + word_next;
                                word_cnt  <= word_cnt + 32'd1;
                                words_r   <= words_r + 16'd1;
                                if ((word_cnt + 32'd1) == len) begin
                                    st <= S_CK;
                                end
                            end else begin
                                byte_i <= byte_i + 2'd1;
                            end
                        end
                    end

                    // ---------------- 4 字节校验和 ----------------
                    S_CK: begin
                        if (rx_valid) begin
                            sh_cks <= cks_next;
                            if (byte_i == 2'd3) begin
                                byte_i <= 2'd0;
                                // sum 此时已含全部字（最后一个字在 S_DATA 里加的）
                                if (cks_next == sum) begin
                                    ok_r   <= 1'b1;
                                    err_r  <= 1'b0;
                                    have_r <= 1'b1;
                                end else begin
                                    ok_r   <= 1'b0;
                                    err_r  <= 1'b1;
                                end
                                // ★ v13：不再直接 S_FIN，而是回等 magic 等 'G'
                                //   （多个镜像要分几帧发，CPU 必须等到最后一帧才放）
                                st <= S_IDLE;
                            end else begin
                                byte_i <= byte_i + 2'd1;
                            end
                        end
                    end

                    // ---------------- 释放 CPU ----------------
                    S_FIN: begin
                        busy_r <= 1'b0;
                    end

                    default: st <= S_IDLE;
                endcase
            end
        end
    end

    assign busy      = busy_r;
    assign ok        = ok_r;
    assign err       = err_r;
    assign dbg_words = words_r;

endmodule
