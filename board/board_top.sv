`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * board_top.sv — v9 的板级顶层（CPU + 同步存储器 + 复位同步器）
 * -----------------------------------------------------------------------------
 * 这一层只做三件事，逻辑一律不写在这里：
 *   1. 复位：板卡按键 → reset_sync（异步置位、同步释放）→ myCPU.cpu_rst；
 *   2. 存储：IROM / DRAM 全部换成 board/sync_mem.sv 的**同步 BRAM**
 *      （固定 1 拍读延迟 + 读使能，正好对上 ICache/DCache 的同步化改造）；
 *   3. 可观测性：把 debug_* 引出来（数码管 / LED / UART / ILA 都在上层接）。
 *
 * ★ 接口契约（存储译码口径，改之前必读）：
 *   - v13：容量翻 4 倍。IROM **16384 字 = 64KB**（irom_addr[15:2] 索引）；
 *     DRAM **32768 字 = 128KB**（perip_addr[16:2] 索引，按 mask 字节写）。
 *     容量由 sync_mem 的 $clog2(WORDS) 自己算，这里只改参数，不需要改任何索引位。
 *     ★ 为什么要扩：CoreMark 的 .text 就有 23KB、C 程序还要 .rodata/.data，
 *       16KB IROM 连一个 benchmark 都装不下（docs/COREMARK.md）。
 *   - 两套地址空间**各自独立译码、不做统一 memory map**（与 cdp-tests/mySoC 以及
 *     sim/tb_iverilog.sv 一致）；别在这里擅自加地址优先级的仲裁。
 *   - ★ 软件侧的约定（sw/link.ld 一致）：.text 放 IROM[0..)，.rodata/.data/.bss/栈
 *     放 DRAM 的 **0x10000 以上**。DRAM 的 0x0000~0xFFFF 是同地址空洞，故意不用
 *     （否则同一地址在取指口和数据口指到不同物理存储，调试时极易看错）。
 *   - 读：DCache 给 mem_en=1 的**那一拍**给出 mem_addr，sync_mem 在下一个时钟沿
 *     输出 rdata，正好被 DCache 的 cpu_valid_r 那一拍采走。
 *   - 写：DCache 的 mem_wen 是**单拍脉冲**，sync_mem 在同一沿按 mem_mask 合并写入；
 *     所以这里直接透传，不需要额外握手。
 *   - 数据侧读使能 perip_en = perip_ren（用 myCPU 的顶层端口，不做层次化引用）；
 *     取指侧同理，读使能直连 irom_en。
 *
 * ★ 不许改回去的地方：见下面各处的 `★ 不变量：`（原编号 B8）
 *   上板待补（数码管 / UART / 消抖的具体建议）：见 syn/修复史_全量.md §BOARDTOP-2
 * =========================================================================== */
module board_top #(
    // IROM 字数（16384 字 = 64KB）★ v13 从 4096 扩上来（CoreMark .text 就 23KB）
    parameter IROM_WORDS = 16384,
    // DRAM 字数（32768 字 = 128KB）★ v13 从 16384 扩上来
    parameter DRAM_WORDS = 32768,
    // 程序镜像（hex 文本，$readmemh 载入 IROM；Vivado 会把它变成 BRAM 初值）
    parameter IROM_INIT  = "prog.hex",
    // ★ v12（A）：串口引导开关。
    //   0 = 保持 v11 的行为：IROM 是**只读** BRAM，程序在综合时固化（改程序要重跑 33min）；
    //   1 = IROM 变**可写**，由 boot_loader 经 uart_rx 灌入镜像（改程序 ~1 s）。
    //   ★ 不动这条默认值，已冻结的 v11 ILA 构建的网表就完全不变。
    parameter IROM_BOOT  = 0,
    // 引导超时（ms）：复位后等 magic 的窗口 / 帧内字节间隔。
    //   暴露成参数纯为**可测性**：仿真里把 IDLE 超时改成 1 ms，
    //   否则要跑 25,000,000 拍才能验"没镜像时也能启动"这条路。
    // ★ 板上默认给 5 s 而不是 0.5 s：宿主机脚本（PowerShell 起 .NET 串口、枚举 COM）
    //   从按复位到发出第一个字节经常要 1~2 s，0.5 s 会踩线。
    //   代价是"不接主机时上电要等 5 s 才开始跑 IROM 里的程序"。
    parameter BOOT_TMO_MS = 5000,
    parameter BOOT_GAP_MS = 20,
    // ★ v13.3（P1）：帧首静默门限（ms）—— 线路必须静默这么久，magic 才被当命令。
    //   宿主的帧间空隙（load_uart.ps1 -FrameGapMs，默认 50 ms）必须明显大于它。
    //   0 = 关闭（老协议行为）。
    parameter BOOT_SILENCE_MS = 1
) (
    input  logic        sys_clk,
    input  logic        btn_rst_n,     // 板卡按键复位，低有效（建议先消抖）

    /* ---- P4 可观测性：写回信息引出（数码管 / LED / ILA 都用它） ---- */
    // ★ 不变量：这些端口上的 (* keep = "true" *) 不能删 —— 顶层悬空时全靠它阻止
    //   综合把调试网整条优化掉（ILA 的 mark_debug 标记打在 myCPU 侧，网没了就没得抓）。
    (* keep = "true" *) output logic        debug_wb_have_inst,
    (* keep = "true" *) output logic [31:0] debug_wb_pc,
    (* keep = "true" *) output logic        debug_wb_ena,
    (* keep = "true" *) output logic [ 4:0] debug_wb_reg,
    (* keep = "true" *) output logic [31:0] debug_wb_value,

    /* ---- 便于观察的额外计数器输出 ---- */
    (* keep = "true" *) output logic [31:0] debug_icache_hit_cnt,
    (* keep = "true" *) output logic [31:0] debug_icache_miss_cnt,
    (* keep = "true" *) output logic [31:0] debug_dcache_hit_cnt,
    (* keep = "true" *) output logic [31:0] debug_dcache_miss_cnt,

    /* ---- 异常现场观察口（v9 + ILA 新增引出） ---- */
    // 这 4 个口在 myCPU 上一直存在（v9 修复 C4 加的），但 board_top 原来**没有引出**，
    //   于是 myCPU 例化时它们悬空，板上/ILA 都看不到异常现场，现在一并引出（不占引脚）。
    //   注：debug_mtval 这一路历史上因为 CSR.mtval_out 漏了 assign 而恒 0，
    //   现已在 CSR.sv 补上驱动，probe11 抓到的是真实值。
    (* keep = "true" *) output logic [31:0] debug_mcause,
    (* keep = "true" *) output logic [31:0] debug_mepc,
    (* keep = "true" *) output logic [31:0] debug_mtval,
    (* keep = "true" *) output logic        debug_trap_take,

    /* ---- v9 新增（B9）：重定向诊断三根线（请求 / 背压 / 结果） ----
     * 只给 ILA 抓，不占引脚。要区分"重定向请求没发"与"请求被 IFU 的 ready 门控
     * 吃掉"，必须在同一拍看到这三根：
     *   debug_dnpc_flag : dnpc_flag  —— 控制面已确认的重定向请求（1 bit）
     *   debug_ready     : IFU.ready  —— 下游结构性背压（1 bit，就是 IDU_ready）
     *   debug_ifu_pc    : IFU 的 PC  —— 重定向有没有落到 PC 上（32 bit）
     * 定位过程见 IFU.sv 的 B9 注释与 syn/修复史_全量.md §BOARDTOP-3。 */
    (* keep = "true" *) output logic        debug_dnpc_flag,
    (* keep = "true" *) output logic        debug_ready,
    (* keep = "true" *) output logic [31:0] debug_ifu_pc,

    /* ---- v12（B）新增：停顿状态字 + 拍计数器 ---- */
    // debug_status：低 8 位由 myCPU 驱动（见 rtl/myCPU.sv 的位分配注释），
    //   8~10 位由本层补上串口引导状态 —— 二者**不同位**，是或关系不是选择关系。
    // debug_mcycle：mcycle 低 32 位，板上量拍数的唯一来源。
    (* keep = "true" *) output logic [31:0] debug_status,
    (* keep = "true" *) output logic [31:0] debug_mcycle,

    /* ---- v12（A）串口引导 ---- */
    // uart_rx 只在 IROM_BOOT=1 时被使用；IROM_BOOT=0 时整个引导逻辑不会综合出来。
    input  logic        uart_rx,
    /* ---- v12（B）串口发送：接板上 J8-2 (PL_RS232_TX, 引脚 A17) ---- */
    // ★ 不变量：这根线**不能**只在 IROM_BOOT=1 时存在 —— console 是 CPU 程序的
    //   通用能力（打印调试字符串），与"用串口灌镜像"是两件事。所以它恒被驱动。
    (* keep = "true" *) output logic        uart_tx,
    /* ---- v12（C）GPIO：LED1~LED7（软件写 0x1000_0010 的低 7 位） ---- */
    (* keep = "true" *) output logic [6:0]  led,
    (* keep = "true" *) output logic        debug_boot_busy,  // 1 = 正在灌镜像，CPU 被复位按住
    (* keep = "true" *) output logic        debug_boot_ok,    // 1 = 镜像完整且校验通过
    (* keep = "true" *) output logic        debug_boot_err    // 1 = 校验失败/长度非法/超时
);

    /* ---------------- 1) 复位：异步置位、同步释放 ---------------- */
    logic cpu_rst;

    reset_sync reset_sync_inst (
        .clk         (sys_clk),
        .rst_n_async (btn_rst_n),
        .rst_sync    (cpu_rst)
    );

    /* ---------------- 2) CPU 与存储总线 ---------------- */
    // 两组互不相干的存储口：irom_*（取指，只读）与 perip_*（数据，读写）。
    //   全部是 myCPU 的**顶层端口**，不许改成 u_cpu.xxx 的层次化引用（见下面 B8）。
    logic [31:0] irom_addr;
    logic [31:0] irom_data;
    logic        irom_en;

    /* ---------------- 2a) v14：IROM 的**数据窗口**（解"哈佛 lw 读不到 IROM"） -----
     * 取指永远走 irom_*（哈佛不变），但给 IROM 加的**第二个读口**映射到数据地址空间：
     *   0x0002_0000 .. 0x0002_FFFF  ⇒ IROM 字 [perip_addr[15:2]]（64KB 全量可见）
     * ★ v16：这个窗口**也可写**（只写不缓存到 DRAM）—— 端口 B 本来就是读/写复用的
     *   （引导器用它写代码区），让 CPU 的 store 也走这一路之后，软件就能**直接写代码区**：
     *   写完 `fence.i` 再 `jalr` 到对应的取指地址，程序就跑起来了（shell 的 load/run）。
     *   不需要把 IROM/DRAM 合成统一地址空间，也不需要改 link.ld。
     * 为什么放在 0x2_0000：
     *   · DRAM 占 0..0x1_FFFF（128KB），这里紧接着，不重叠；
     *   · MMIO 在 0x1000_0000 以上（DCache 的 UNCACHE_MASK 分界），也不冲突；
     *   · 地址 < 0x1000_0000 ⇒ DCache 会把它当**可缓存**地址。写走写直达（store 合并进
     *     缓存行 + 同一份数据写进 IROM 端口 B），读走端口 B —— 两侧始终一致。
     * ★ 不变量：DRAM 的写使能必须继续被这个窗口挡掉（下面 dram_inst 的 .wen），
     *   否则一次 `sw 0x2_0040` 会同时改掉 DRAM 第 0x40 个字。
     * 代价：BRAM 数量不变（BRAM36 本来就是双口），只多一级译码 + 一条读数据 mux。 */
    logic [31:0] irom_d_rdata;      // IROM 第二读口（数据侧）返回
    logic        irom_win_sel;      // 本次数据访问落在 IROM 窗口
    assign irom_win_sel = (perip_addr[31:16] == 16'h0002);

    logic [31:0] perip_addr;
    logic        perip_wen;
    logic [ 1:0] perip_mask;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;
    logic        perip_en;
    logic        perip_ren;

    // v12（B）：myCPU 侧的状态字（只驱动低 8 位）+ 拍计数器
    logic [31:0] debug_status_cpu;

    myCPU u_cpu (
        .cpu_clk            (sys_clk),
        // ★ v12：用 cpu_rst_eff（= cpu_rst | boot_busy）。IROM_BOOT=0 时它就是 cpu_rst，
        //   与 v11 完全等价；IROM_BOOT=1 时引导期间 CPU 被按住，IROM 口由 loader 独占。
        .cpu_rst            (cpu_rst_eff),

        .irom_addr          (irom_addr),
        .irom_data          (irom_data),
        .irom_en            (irom_en),

        .perip_addr         (perip_addr),
        .perip_wen          (perip_wen),
        .perip_ren          (perip_ren),
        .perip_mask         (perip_mask),
        .perip_wdata        (perip_wdata),
        .perip_rdata        (perip_rdata),

        .debug_wb_have_inst (debug_wb_have_inst),
        .debug_wb_pc        (debug_wb_pc),
        .debug_wb_ena       (debug_wb_ena),
        .debug_wb_reg       (debug_wb_reg),
        .debug_wb_value     (debug_wb_value),

        // v9 修复（B8）：四条缓存计数器走 myCPU 的**顶层端口**。
        //   原来这里是 `assign debug_icache_hit_cnt = u_cpu.icache_hit_cnt;` 这类层次化
        //   引用：iverilog/ModelSim 容忍，Quartus 报 Error (10207) 直接综合失败。
        //   细节：syn/修复史_全量.md §BOARDTOP-1
        .debug_icache_hit_cnt  (debug_icache_hit_cnt),
        .debug_icache_miss_cnt (debug_icache_miss_cnt),
        .debug_dcache_hit_cnt  (debug_dcache_hit_cnt),
        .debug_dcache_miss_cnt (debug_dcache_miss_cnt),

        // v9 + ILA：异常现场观察口（原来这 4 个口悬空，现在引到顶层给 ILA 抓）
        .debug_mcause          (debug_mcause),
        .debug_mepc            (debug_mepc),
        .debug_mtval           (debug_mtval),
        .debug_trap_take       (debug_trap_take),

        // v9 + ILA（B9）：重定向诊断三根线
        .debug_dnpc_flag       (debug_dnpc_flag),
        .debug_ready           (debug_ready),
        .debug_ifu_pc          (debug_ifu_pc),

        // v12（B）：停顿状态字（低 8 位）+ mcycle
        .debug_status          (debug_status_cpu),
        .debug_mcycle          (debug_mcycle)
    );

    // I-Cache 的读使能 / D-Cache 的读使能：直接接同步存储器的读口。
    // ★ 不变量：perip_en = perip_ren，两侧读使能都必须取自 myCPU 的**顶层端口**。
    //   原因（v9 修复 B8）：取指侧原来写的是 `assign irom_en = u_cpu.icache_mem_en;`，
    //   而 myCPU 根本没有 icache_mem_en 这个端口 —— 它是 myCPU 的**内部信号**。
    //   iverilog / ModelSim 容忍层次化引用，Quartus 不行，会报
    //     Error (10207): can't resolve reference to object "icache_mem_en"
    //     Error (12153): Can't elaborate top-level user hierarchy
    //   → Analysis & Synthesis 失败，fit/时序/上板全部跑不起来。
    //   细节：syn/修复史_全量.md §BOARDTOP-1
    assign perip_en = perip_ren;

    /* ---------------- 3) 同步 BRAM：IROM ----------------
     * IROM_BOOT=0：只读，程序在综合时由 $readmemh 固化（v11 行为，网表不变）；
     * IROM_BOOT=1：可写，引导期间由 boot_loader 独占写口（见 board/boot_loader.sv）。
     * ★ 不变量：引导期间 boot_busy=1 → CPU 被 cpu_rst_eff 按住 → IROM 口**不存在竞争**，
     *   所以这里用简单的 2:1 mux 就够，不需要任何仲裁器。
     * ★ 不变量：cpu_rst_eff 必须 = cpu_rst | boot_busy，且 boot_busy 在**所有**失败路径
     *   上都能回到 0（细节见 boot_loader.sv 头部的失败不变量）。
     * ------------------------------------------------------------------- */
    logic cpu_rst_eff;

    /* 引导总线：★ v13 起提升到**模块作用域**声明 —— 因为 DRAM 的端口在引导期间
     * 也要被 loader 独占（原来只有 IROM 需要，声明在 generate 块里就够）。
     * IROM_BOOT=0 时下面 g_irom_rom 把它们全钉成 0 → 所有 mux 都选 CPU 侧。 */
    logic        boot_busy, boot_ok, boot_err;
    logic        boot_we, boot_mem_sel;
    logic [31:0] boot_addr, boot_wdata;
    logic [15:0] boot_words;

    generate
        if (IROM_BOOT) begin : g_irom_boot
            logic [ 7:0] boot_rx_data;
            logic        boot_rx_valid;

            /* ★★ v13.4（P3）软件触发重新引导（"用软件按一下复位键"）
             * ------------------------------------------------------------------
             * 动机：改一个程序原来有两条路，都不便宜 ——
             *   ① 重烧 bitstream：冷启动 53~57 s，而且 ILA 要重新 arm；
             *   ② 按 S1 复位键：人不在板子边上就做不到。
             * 现在：任何程序只要往 0x1000_0014 写 bit0=1，就能把 boot_loader 重新
             *   武装（FSM 复位回 S_IDLE、busy=1 按住 CPU），然后宿主照常灌镜像即可。
             *   典型用途：串口 monitor 的 `boot` 命令。
             *
             * 实现要点（都是踩过的坑）：
             *   • 复位必须是**有限宽度的脉冲**（这里 7 拍）：如果一直按住，loader 永远
             *     停在复位里、busy 恒 1，CPU 永久停机。
             *   • 复位同时给 boot_loader 和它的 uart_rx：否则 receiver 里残留的半帧
             *     状态会让第一个字节错位。
             *   • boot_rx_cnt 也一起清，这样"重新武装后收到了几个字节"才是干净的诊断口径。
             *   • 脉冲结束后 loader 自己 busy=1 就把 CPU 按住了（cpu_rst_eff = cpu_rst |
             *     boot_busy），所以不需要额外的保持寄存器。
             *   • 这个功能只在 IROM_BOOT=1（有引导器）时存在；否则写进去没有作用。
             */
            logic        sw_boot_req;
            logic [ 2:0] sw_boot_rst_cnt;
            logic        boot_ldr_rst;

            assign sw_boot_req = perip_wen & (perip_addr == 32'h1000_0014)
                               & perip_wdata[0];

            always_ff @(posedge sys_clk) begin
                if (cpu_rst)                   sw_boot_rst_cnt <= 3'd0;
                else if (sw_boot_req)          sw_boot_rst_cnt <= 3'd7;
                else if (sw_boot_rst_cnt != 3'd0) sw_boot_rst_cnt <= sw_boot_rst_cnt - 3'd1;
            end
            assign boot_ldr_rst = cpu_rst | (sw_boot_rst_cnt != 3'd0);

            /* ★ v13 诊断：串口收到的**字节总数**（10 位饱和）。
             * 为什么需要：引导失败时"到底是没收到字节，还是收到了但协议没过"完全
             * 看不出来（串口 TX 也可能不通）。这个计数器接进 debug_status[20:11]，
             * ILA 一看就知道 RX 有没有通 —— 收到的字节数为 0 就说明物理链路/引脚有问题。
             * 只在 IROM_BOOT=1 时存在；饱和到 0x3FF，够判断"有没有"。
             * ★ 不变量：清零点跟 boot_loader 一样（配置/按键复位/软件重新武装才清）。 */
            logic [9:0] boot_rx_cnt;
            always_ff @(posedge sys_clk) begin
                if (boot_ldr_rst)                  boot_rx_cnt <= 10'd0;
                else if (boot_rx_valid && !(&boot_rx_cnt)) boot_rx_cnt <= boot_rx_cnt + 10'd1;
            end

            uart_rx #(
                .CLK_FREQ (50_000_000),
                .BAUD     (115_200)
            ) uart_rx_inst (
                .clk   (sys_clk),
                .rst   (boot_ldr_rst),
                .rx    (uart_rx),
                .data  (boot_rx_data),
                .valid (boot_rx_valid)
            );

            boot_loader #(
                .CLK_FREQ    (50_000_000),
                .IDLE_TMO_MS (BOOT_TMO_MS),
                .GAP_TMO_MS  (BOOT_GAP_MS),
                .SOF_SILENCE_MS (BOOT_SILENCE_MS),
                .MAX_WORDS   (IROM_WORDS),
                .MAX_DWORDS  (DRAM_WORDS)
            ) boot_loader_inst (
                .clk       (sys_clk),
                .rst       (boot_ldr_rst),
                .rx_data   (boot_rx_data),
                .rx_valid  (boot_rx_valid),
                .busy      (boot_busy),
                .ok        (boot_ok),
                .err       (boot_err),
                .mem_sel   (boot_mem_sel),
                .mem_we    (boot_we),
                .mem_addr  (boot_addr),
                .mem_wdata (boot_wdata),
                .dbg_words (boot_words)
            );

            assign cpu_rst_eff = cpu_rst | boot_busy;

            // 可写版 IROM：mask=2'b11 表示整字写（loader 只发对齐的 32 位写）
            // ★★ 不变量：这里的 reset **必须只接 cpu_rst，不能接 cpu_rst_eff**！
            //   sync_mem 的写逻辑在 `if (reset) ... else begin ... if (wen) ...` 的
            //   else 分支里 —— 复位期间写会被整段丢掉。而 cpu_rst_eff 在引导全程为 1
            //   （= cpu_rst | boot_busy），接了它就会"校验和通过、但一个字都没写进去"，
            //   表现为 CPU 起来后执行全 0 的 IROM（非法指令）。这个坑是仿真抓出来的。
            //   引导期间 CPU 本来就被 cpu_rst_eff 按住，读口 ren 被 mux 成 0，
            //   所以 IROM 不跟着复位是安全的。
            sync_mem_dp #(
                .WORDS     (IROM_WORDS),
                .INIT_FILE (IROM_INIT)
            ) irom_inst (
                .clk     (sys_clk),
                .reset   (cpu_rst),
                // ---- 端口 A：取指（只读，引导期间 CPU 被按住 → ren=0）----
                .a_addr  (irom_addr),
                .a_ren   (boot_busy ? 1'b0 : irom_en),
                .a_rdata (irom_data),
                // ---- 端口 B：CPU 数据读/写（窗口 0x2_0000）/ 引导器写（'B' 帧）----
                //   ★ 二者互斥：boot_busy=1 时 CPU 在复位，不可能来读/写。
                //   ★ v16：CPU 的 store 也走这一路（写代码区），见上面 2a 段。
                .b_addr  (boot_busy ? (boot_addr << 2) : perip_addr),
                .b_ren   (boot_busy ? 1'b0 : (perip_en & irom_win_sel)),
                .b_rdata (irom_d_rdata),
                .b_wen   (boot_busy ? (boot_we & ~boot_mem_sel)
                                    : (perip_wen & irom_win_sel)),
                .b_wdata (boot_busy ? boot_wdata : perip_wdata),
                .b_mask  (boot_busy ? 2'b11 : perip_mask)
            );

            assign debug_boot_busy = boot_busy;
            assign debug_boot_ok   = boot_ok;
            assign debug_boot_err  = boot_err;
            // v12（B）：状态字 8~10 位补上引导状态（低 8 位来自 myCPU，**位不重叠**）
            //   用 {31'b0,x} 拼接而不用 SV 的 32'(x) 强转：板级件也要能被 iverilog
            //   -g2012 之外的流程吃下，拼接是最保险的写法。
            assign debug_status    = debug_status_cpu
                                   | ({31'b0, boot_busy} << 8)
                                   | ({31'b0, boot_ok}   << 9)
                                   | ({31'b0, boot_err}  << 10)
                                   | ({22'b0, boot_rx_cnt} << 11);
            // 注：boot_words 目前不引出（避免多占 ILA probe）；需要时再加。
        end else begin : g_irom_rom
            // v11 原样：只读、$readmemh 固化
            sync_mem_dp #(
                .WORDS     (IROM_WORDS),
                .INIT_FILE (IROM_INIT)
            ) irom_inst (
                .clk     (sys_clk),
                .reset   (cpu_rst),
                .a_addr  (irom_addr),
                .a_ren   (irom_en),
                .a_rdata (irom_data),
                // 无引导器时写口钉死；数据窗口照常可用（这就是"lw 能读 IROM"）
                .b_addr  (perip_addr),
                .b_ren   (perip_en & irom_win_sel),
                .b_rdata (irom_d_rdata),
                // ★ v16：这个分支（IROM_BOOT=0，纯 ROM 固化）也让窗口可写，好让
                //   shell 的 load/run 在**仿真**里也能测（与 IROM_BOOT=1 行为一致）。
                //   只有 CPU 能写到这里；没有引导器。
                .b_wen   (perip_wen & irom_win_sel),
                .b_wdata (perip_wdata),
                .b_mask  (perip_mask)
            );

            assign cpu_rst_eff     = cpu_rst;
            assign debug_boot_busy = 1'b0;
            assign debug_boot_ok   = 1'b0;
            assign debug_boot_err  = 1'b0;
            assign debug_status    = debug_status_cpu;   // 无引导时 8~10 位恒 0
            // 引导总线钉死 → 下面的 IROM/DRAM mux 全部选 CPU 侧（网表与 v11 等价）
            assign boot_busy       = 1'b0;
            assign boot_we         = 1'b0;
            assign boot_mem_sel    = 1'b0;
            assign boot_addr       = 32'd0;
            assign boot_wdata      = 32'd0;
            assign boot_ok         = 1'b0;
            assign boot_err        = 1'b0;
            assign boot_words      = 16'd0;
        end
    endgenerate

    /* ---------------- 4) v12（B/C）MMIO：串口收发 + GPIO @ 0x1000_00xx -----
     * 为什么放在 0x1000_0000：DCache 的 UNCACHE_MASK 默认 0x0FFF_FFFF，地址 ≥ 0x1000_0000
     *   的物品**自动**走 MMIO 通路（不分配缓存行、读直通外设）。DRAM 只有 64KB
     *   （perip_addr[15:2] 索引），两者地址空间天然不重叠，所以这里只加一个窗口译码。
     * ★ 不变量：窗口按 perip_addr[31:16] 译码、寄存器号用 [4:2]。不能用 perip_addr[31:28]
     *   —— 那是 256MB 的大窗口，会把以后的定时器/GPIO 一起吞掉。
     * ★ 不变量：MMIO 写必须**门掉 DRAM 的写使能**（下面 dram_inst 的 .wen），否则一次
     *   `sw 0x10000000` 会同时改掉 DRAM 第 0 个字（perip_addr[15:2]=0）—— 那个字是
     *   栈/全局变量区，症状是"打印一个字符，某个变量莫名其妙变了"。
     *
     * 寄存器映射（字地址，下标 = perip_addr[4:2]）：
     *   +0x00  idx0  WO  TXDATA  ：写 → 低 8 位入发送器（忙时丢弃，见 uart_tx.sv）
     *   +0x04  idx1  RO  TXSTAT  ：bit0 = busy（1 = 上一帧还没发完）
     *   +0x08  idx2  RO  RXDATA  ：读 → **只看队头，不弹**（v13.5 起；读是幂等的）
     *   +0x0c  idx3  RO  RXSTAT  ：bit0 = FIFO 非空；bit1 = 溢出过（读一次即清）
     *   +0x10  idx4  RW  LED    ：低 7 位驱动板上 LED1~LED7（复位值 0）
     *   +0x14  idx5  WO  BOOTREQ：写 bit0=1 → 重新武装 boot_loader（v13.4 / P3）
     *   +0x18  idx6  WO  RXPOP  ：写 1 → 从 RX FIFO 弹一个字节（v13.5；配合 RXDATA 的 peek）
     *
     * ★ 为什么 RX 要 8 深 FIFO 而不是 1 个字节寄存器：115200 下一个字节 87us，
     *   而 CPU 一次打印/一次循环可能几十 us 不看串口 —— 单字节寄存器在"多打几个字符"
     *   时必然丢字节。8 深度成本 ~36 FF，几乎白送。
     * ★ 为什么 console 用**第二个** uart_rx 实例：引导器（boot_loader）和 console 是
     *   两个独立消费者，uart_rx 的 valid 是**单拍脉冲**、二者之间没有握手。共用一份
     *   就变成"谁先看到谁拿走"，引导期间 console FIFO 会吞掉镜像帧的字节（反之亦然）。
     *   两个接收器各自监听同一根线（~15 FF/个）比加仲裁便宜得多，也不会互相干扰。
     * ------------------------------------------------------------------- */
    logic        mmio_sel;
    logic [ 2:0] mmio_idx;
    logic        uart_busy;
    logic [31:0] dram_rdata;

    assign mmio_sel = (perip_addr[31:16] == 16'h1000) & (perip_addr[15] == 1'b0);
    assign mmio_idx = perip_addr[4:2];

    // 只对 TXDATA 的有效写产生 send 脉冲（顺带挡掉字节/半字写：UART 只认整字写，
    //   免得 sb 的低位数据落到别的字节通道上，行为取决于 mask 反而更难看）
    uart_tx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115_200)
    ) uart_tx_inst (
        .clk   (sys_clk),
        .rst   (cpu_rst),
        .data  (perip_wdata[7:0]),
        .send  (perip_wen & mmio_sel & (mmio_idx == 3'd0)),
        .tx    (uart_tx),
        .busy  (uart_busy)
    );

    /* ---- console 接收：独立接收器 + 8 深 FIFO ---- */
    logic [7:0] con_rx_data;
    logic       con_rx_valid;

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115_200)
    ) uart_rx_con_inst (
        .clk   (sys_clk),
        .rst   (cpu_rst_eff),      // 引导期间整体保持复位 → 镜像帧不会灌进 console FIFO
        .rx    (uart_rx),
        .data  (con_rx_data),
        .valid (con_rx_valid)
    );

    logic [7:0] rx_fifo [0:7];
    logic [2:0] rx_wp, rx_rp;
    logic [3:0] rx_cnt;
    logic       rx_ovf;
    logic       rx_avail;

    assign rx_avail = (rx_cnt != 4'd0);

    /* ★★ v13.5（P3）修复：把"看"和"弹"分开 —— 读 RXDATA 变成**幂等**的 peek。
     *
     * 为什么必须这么改（实测，不是猜）：sim/tb_monitor.sv 的 [RD] 轨迹显示，
     *   一次 `lw 0x1000_0008` 会让 `perip_ren` 出现**两个**脉冲（相隔约 20 拍）：
     *       [RD] rp=0 cnt=5 rd=6c   → 读出 'l'，rp→1
     *       [RD] rp=1 cnt=4 rd=20   → 401 ns 后又读一次，读出 ' '，rp→2
     *   于是"读即弹"每读一个字节就多吃掉一个（命令 `l 3f` 变成 `l3`、LED 写成 3）。
     *   根因在 DCache 的 uncacheable 读会被重发一次（CPU 数据通路问题，见
     *   docs/CHECKPOINT_v13.md §9 的 P4 条），改它风险大、要单独一轮 +
     *   全量回归；外设侧能做的正确防御就是"读没有副作用"：
     *       0x1000_0008 RXDATA : 只**看**队头，不弹（读几次都一样）
     *       0x1000_0018 RXPOP  : 写 1 -> 弹一个字节（写是单拍的，实测不会重复）
     *   软件用法：`while (RXSTAT&1); c = RXDATA; RXPOP = 1;`
     * ★ 不变量：RXDATA **永远不许**再带弹出副作用 —— 一旦带回来，这个 bug 立刻复发。
     * ★ 旧语义（读即弹）在 v13.4 及以前有效；只有 sw/monitor.c 用过，已同步改。
     */
    logic rx_pop;
    assign rx_pop = perip_wen & mmio_sel & (mmio_idx == 3'd6) & rx_avail;

    always_ff @(posedge sys_clk) begin
        if (cpu_rst_eff) begin
            rx_wp  <= 3'd0;
            rx_rp  <= 3'd0;
            rx_cnt <= 4'd0;
            rx_ovf <= 1'b0;
        end else begin
            case ({con_rx_valid & (rx_cnt != 4'd8), rx_pop})
                2'b10: begin                        // 只进不出
                    rx_fifo[rx_wp] <= con_rx_data;
                    rx_wp          <= rx_wp + 3'd1;
                    rx_cnt         <= rx_cnt + 4'd1;
                end
                2'b01: begin                        // 只出
                    rx_rp  <= rx_rp + 3'd1;
                    rx_cnt <= rx_cnt - 4'd1;
                end
                2'b11: begin                        // 同时进出（写在弹之前的位置，见下）
                    rx_fifo[rx_wp] <= con_rx_data;
                    rx_wp          <= rx_wp + 3'd1;
                    rx_rp          <= rx_rp + 3'd1;
                    // cnt 不变
                end
                default: ;                          // 空转
            endcase
            // FIFO 满还来字节 → 丢弃并置溢出位（★ 不覆盖已有数据：覆盖会让软件读到
            //   "看起来正常、其实是后来那个字节"的错误序列，比丢字节更难查）
            if (con_rx_valid && (rx_cnt == 4'd8)) rx_ovf <= 1'b1;
            // RXSTAT 被读 → 清溢出位（读清语义，与常见 UART 一致）
            if (perip_ren & mmio_sel & (mmio_idx == 3'd3)) rx_ovf <= 1'b0;
        end
    end

    /* ---- GPIO：7 个 LED（LED1~LED7） ---- */
    logic [6:0] led_reg;
    always_ff @(posedge sys_clk) begin
        if (cpu_rst_eff)                                          led_reg <= 7'd0;
        else if (perip_wen & mmio_sel & (mmio_idx == 3'd4))       led_reg <= perip_wdata[6:0];
    end
    assign led = led_reg;

    // 读：按寄存器号选，其余地址返回 DRAM
    // ★ 不变量：这个 mux 是**地址译码**，不是数据通路 —— 别把它塞进 DCache。
    // ★ RXDATA 的读值是"当前队头"，**不弹**；弹出由写 0x1000_0018 完成（v13.5）。
    // ★ v14：0x2_0000~0x2_FFFF 是 IROM 的数据窗口（第二读口），优先级在 MMIO 之后、
    //   DRAM 之前 —— 三者地址区间互不重叠，这里只是把三路拼起来。
    always_comb begin
        if (mmio_sel) begin
            case (mmio_idx)
                3'd1:    perip_rdata = {31'b0, uart_busy};
                3'd2:    perip_rdata = {24'b0, rx_fifo[rx_rp]};
                3'd3:    perip_rdata = {30'b0, rx_ovf, rx_avail};
                default: perip_rdata = 32'b0;          // idx0(TXDATA)/idx4(LED) 读回 0
            endcase
        end else if (irom_win_sel) begin
            perip_rdata = irom_d_rdata;                // IROM 第二读口（只读）
        end else begin
            perip_rdata = dram_rdata;
        end
    end

    /* ---------------- 5) 同步 BRAM：DRAM（读写，按 mask 字节写） ----------------
     * reset 接 1'b0：真实 BRAM 的存储阵列不会因复位被清空（见 sync_mem 头部契约）。
     * ★ v13：引导期间（boot_busy=1，CPU 被复位按住）这个口由 loader 独占，
     *   用来灌 .rodata/.data 镜像（'C' 帧）。IROM_BOOT=0 时 boot_busy 恒 0，
     *   所有 mux 都选 CPU 侧，网表与 v11/v12 完全等价。
     *   ★ 不变量：cpu_rst_eff = cpu_rst | boot_busy 保证"引导期间 CPU 不会来抢"，
     *     所以这里仍然不需要仲裁器。 */
    sync_mem #(
        .WORDS     (DRAM_WORDS),
        .READ_ONLY (0),
        .INIT_FILE ("")
    ) dram_inst (
        .clk   (sys_clk),
        .reset (1'b0),
        .addr  (boot_busy ? (boot_addr << 2) : perip_addr),
        .ren   (boot_busy ? 1'b0 : perip_en),
        .rdata (dram_rdata),
        // ★ 不变量：MMIO 写必须挡住 DRAM 写（见上面第 4) 段的说明）
        // ★ v13：引导写（boot_mem_sel=1 的 DRAM 帧）单独走这一路，与 MMIO 无关
        // ★ v14：IROM 数据窗口（0x2_xxxx）也**只读** —— 写它既不改 IROM 也不改 DRAM，
        //   静默丢弃。软件不该往代码区写；真要改镜像请走 boot_loader。
        .wen   (boot_busy ? (boot_we & boot_mem_sel)
                          : (perip_wen & ~mmio_sel & ~irom_win_sel)),
        .wdata (boot_busy ? boot_wdata : perip_wdata),
        .mask  (boot_busy ? 2'b11 : perip_mask)
    );

    /* ---------------- 6) 观测计数器引出 ---------------- */
    // v9 修复（B8）：四条计数器已经在 myCPU 的端口上接好了（见上面的例化），
    //   这里不再需要层次化引用。

endmodule
