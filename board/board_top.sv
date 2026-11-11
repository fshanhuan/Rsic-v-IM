`include "para.sv"
`include "soc_map.sv"
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
    //   2 = （双核协同第 1 步）**不要引导器**：IROM 固化一个几百字节的 stage-0 stub，
    //       主镜像由 AXI 主机（PS）灌进 DRAM，CPU 被 ps_hold 按住直到 PS 放行，
    //       然后 stub 把 DRAM → 代码窗口搬完再跳过去。见 board/ps_ctrl.sv。
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
    parameter BOOT_SILENCE_MS = 1,
    /* #6: AXI4-Lite host port switch.
     *   0 (default) = byte-identical to v18: single-port DRAM, no AXI logic.
     *   1 = DRAM becomes board/dram_shared.sv (CPU keeps its own read/write port;
     *       the AXI host *borrows* the port in cycles when the CPU is idle), plus
     *       board/axil_slave.sv. PS / any AXI master can then read and write the
     *       128 KB, without ever stalling the CPU.
     * NOTE: this uses a plain 32-bit array (NOT a true-dual-port byte-lane array),
     *       because Vivado cannot infer BRAM for the latter (Synth 8-3391) and
     *       xvlog needs >400 s to compile it. See docs/AXI_总线化_6_7.md. */
    parameter AXIL_EN = 0
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
    (* keep = "true" *) output logic        debug_boot_err,   // 1 = 校验失败/长度非法/超时

    /* ---- 双核协同（第 3 步）：CPU → PS 中断 ----
     * 电平语义，由 MMIO 0x1000_001C bit1 驱动；PS 设计里接到 Zynq 的 IRQ_F2P。
     * ★ 为什么是电平不是脉冲：GIC 的 SPI 是电平敏感，脉冲要在 PS 侧自己锁存，
     *   反而多一层状态。CPU 侧"置 1 → 等 PS 处理 → 清 0"，就是标准的生产者语义。
     * AXIL_EN=0 时照样被驱动（悬空无害），这样 TB 也能观察它。 */
    (* keep = "true" *) output logic        irq_ps,

    /* ---- #6: AXI4-Lite slave port (only functional when AXIL_EN=1) ----
     * Standard s_axil_* naming so it can be connected to an Xilinx Interconnect / PS
     * directly. When AXIL_EN=0 all outputs are tied off and the inputs are ignored.
     * The bridge and the memory run on the SAME clock (no CDC): in the PS design
     * both sys_clk and axil_aclk are driven by FCLK_CLK0. */
    input  logic        axil_aclk,
    input  logic        axil_aresetn,
    input  logic [31:0] s_axil_awaddr,
    input  logic [2:0]  s_axil_awprot,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [31:0] s_axil_araddr,
    input  logic [2:0]  s_axil_arprot,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready
);

    /* ---------------- 1) 复位：异步置位、同步释放 ---------------- */
    logic cpu_rst;
    /* ★ P0-4（lint）：cpu_rst_eff 在 232 行（CPU 例化）就用到了，原来声明在 305 行 ——
     *   靠隐式网络规则"先造一根 1 bit 隐式线"，xvlog 报 VRFC 10-2938。提到这里。 */
    logic cpu_rst_eff;

    /* ---------------- 1b) 双核协同的控制面（第 1/2/3 步） ----------------
     * ps_hold       ：AXI 主机（PS）把 CPU 按在复位里，等镜像灌完
     * ps_irq_to_cpu ：PS → CPU 的电平中断（PLIC 源 4）
     * irq_ps_r      ：CPU → PS 的电平中断（MMIO 0x1000_001C bit1）
     * cpu_alive_r   ：stage-0 stub 报过到（写 MMIO 0x1000_001C bit2）
     * dcache_inval  ：MMIO 0x1000_001C bit0 的一拍脉冲 → DCache 整表无效
     * ★ AXIL_EN=0 时 ps_hold / ps_irq_to_cpu 由 generate 的 else 支钉成 0，
     *   行为与 v18 逐位相同（网表里这几个信号被常量折叠掉）。 */
    logic ps_hold;
    logic ps_irq_to_cpu;
    logic irq_ps_r;
    logic cpu_alive_r;
    logic dcache_inval;
    logic alive_clr;
    logic irq_ps_clr;

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
    logic [31:0] dram_rdata;        // DRAM 读值（原来的声明在 MMIO 段，A1 提前）
    logic [31:0] mmio_rdata;        // 外设寄存器读值（下面那个小 case）

    /* ---- A1：系统总线的片选/使能（全部来自 board/soc_bus.sv）----
     * 改造前 `irom_win_sel` 与 `mmio_sel` 是两处手写比较，DRAM 的写使能还要
     * 再"减掉"它们（`perip_wen & ~mmio_sel & ~irom_win_sel`）。现在这三件事
     * 全在 soc_bus 里，加外设不用再改这里。 */
    logic        bus_hit_dram, bus_hit_code, bus_hit_mmio;
    logic [ 3:0] bus_mmio_idx;
    logic        bus_re_dram, bus_re_code;
    logic        bus_we_dram, bus_we_code, bus_we_mmio;
    logic        bus_unmapped;

    logic [31:0] perip_addr;
    logic        perip_wen;
    logic [ 1:0] perip_mask;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;
    logic        perip_ren;

    /* ---------------- 2b) A1：系统总线实例 ----------------
     * 译码口径见 rtl/soc_map.sv（地址表的单一来源）与 board/soc_bus.sv（契约）。
     * ★ 时序不变量：这里**没有**加任何一级寄存器，也没有引入等待态 ——
     *   请求拍给地址、下一拍数据有效，与改造前逐位相同（WNS 已只剩 0.048 ns）。
     * ------------------------------------------------------------------- */
    soc_bus #(
        .STRICT_DECODE (1'b0)          // 0 = 与改造前逐位兼容（DRAM 为默认从设备）
    ) soc_bus_inst (
        .ren        (perip_ren),
        .wen        (perip_wen),
        .addr       (perip_addr),
        .wdata      (perip_wdata),
        .mask       (perip_mask),
        .dram_rdata (dram_rdata),
        .code_rdata (irom_d_rdata),
        .mmio_rdata (mmio_rdata),
        .rdata      (perip_rdata),
        .hit_dram   (bus_hit_dram),
        .hit_code   (bus_hit_code),
        .hit_mmio   (bus_hit_mmio),
        .mmio_idx   (bus_mmio_idx),
        .re_dram    (bus_re_dram),
        .re_code    (bus_re_code),
        .we_dram    (bus_we_dram),
        .we_code    (bus_we_code),
        .we_mmio    (bus_we_mmio),
        .unmapped   (bus_unmapped)
    );

    // v12（B）：myCPU 侧的状态字（只驱动低 8 位）+ 拍计数器
    logic [31:0] debug_status_cpu;

    /* ---------------- 2c) A2：PLIC-lite（外部中断） ----------------
     * 改造前 CSR 把 meip 硬连 0，全核只有 mtime 一个中断源。现在把"谁在请求中断"
     * 交给一个 8 源的小控制器，CPU 的 mip.MEIP 直接吃它的汇总输出。
     *
     * 源分配（编号见 rtl/soc_map.sv）：
     *   [0] UART RX FIFO 非空（电平）—— 这条是"按方向键丢键"的根治
     *   [1] UART RX 溢出（电平）
     *   [2] 定时器（A3 接 CLINT，现在先接 0）
     *   [3] 软件自触发（写 0x1000_002C，一次脉冲）
     * ★ 为什么是电平不是边沿：FIFO 非空是电平。用边沿置位 + claim 清位，会在两个
     *   字节之间出现"数据还在但 pending 已被清"的窗口，那个字节再也不会触发中断。
     * ------------------------------------------------------------------- */
    logic [7:0] plic_src;
    logic [7:0] plic_pend, plic_en, plic_clr;
    logic        plic_irq;
    logic [3:0] plic_best;
    logic       irq_sw_pulse;
    // A3：CLINT 读值（计数器在 myCPU 内，这里只拿来回 MMIO 读 mux）
    logic [31:0] clint_mtime, clint_mtimecmp;

    /* 说明：plc_lite 的例化放在下面"console RX FIFO"之后 —— 它的两个中断源
     * （rx_avail / rx_ovf）在那里才声明。这里只声明信号。 */

    myCPU u_cpu (
        .cpu_clk            (sys_clk),
        // ★ v12：用 cpu_rst_eff（= cpu_rst | boot_busy）。IROM_BOOT=0 时它就是 cpu_rst，
        //   与 v11 完全等价；IROM_BOOT=1 时引导期间 CPU 被按住，IROM 口由 loader 独占。
        .cpu_rst            (cpu_rst_eff),
        .ext_irq            (plic_irq),          // A2
        .dcache_inval       (dcache_inval),      // 双核协同第 2 步：MMIO 0x1000_001C bit0

        // ---- A3：CLINT 总线侧（计数器在核内，这里只做 MMIO 译码）----
        .mm_mtime_we        (bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_MTIME)),
        .mm_mtimecmp_we     (bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_MTIMECMP)),
        .mm_wdata           (perip_wdata),
        .clint_mtime        (clint_mtime),
        .clint_mtimecmp     (clint_mtimecmp),

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
    // ★ A1：原来的 `assign perip_en = perip_ren;` 已删除 —— 总线上不再有"合并后的
    //   访问使能"这个概念，读（perip_ren）和写（perip_wen）在 soc_bus 里分别处理。
    //   上面那条 B8 不变量的精神不变：两侧读使能仍然取自 myCPU 的**顶层端口**。

    /* ---------------- 3) 同步 BRAM：IROM ----------------
     * IROM_BOOT=0：只读，程序在综合时由 $readmemh 固化（v11 行为，网表不变）；
     * IROM_BOOT=1：可写，引导期间由 boot_loader 独占写口（见 board/boot_loader.sv）。
     * ★ 不变量：引导期间 boot_busy=1 → CPU 被 cpu_rst_eff 按住 → IROM 口**不存在竞争**，
     *   所以这里用简单的 2:1 mux 就够，不需要任何仲裁器。
     * ★ 不变量：cpu_rst_eff 必须 = cpu_rst | boot_busy，且 boot_busy 在**所有**失败路径
     *   上都能回到 0（细节见 boot_loader.sv 头部的失败不变量）。
     * ------------------------------------------------------------------- */

    /* 引导总线：★ v13 起提升到**模块作用域**声明 —— 因为 DRAM 的端口在引导期间
     * 也要被 loader 独占（原来只有 IROM 需要，声明在 generate 块里就够）。
     * IROM_BOOT=0 时下面 g_irom_rom 把它们全钉成 0 → 所有 mux 都选 CPU 侧。 */
    logic        boot_busy, boot_ok, boot_err;
    logic        boot_we, boot_mem_sel;
    logic [31:0] boot_addr, boot_wdata;
    logic [15:0] boot_words;

    generate
        if (IROM_BOOT == 1) begin : g_irom_boot
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
            /* 无引导器分支（IROM_BOOT=0 纯 ROM 固化 / IROM_BOOT=2 AXI 主机装载）。
             * ★ IROM 本体已经**提到 generate 外面**（见下面 3b 段），两支共用一份 ——
             *   boot_busy 在这里被钉成 0，于是共享实例里所有 `boot_busy ? ... : ...`
             *   的 mux 都被常量折叠成 CPU 侧，IROM_BOOT=0 的网表与 v18 逐位相同。 */
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

    /* ---------------- 3b) 同步 BRAM：IROM（两支共用，提到 generate 外） --------
     * ★ 为什么要提出来：第 1 步新增了 IROM_BOOT=2（AXI 主机装载）这一支，如果照抄
     *   一份 sync_mem_dp 就有三份拷贝、三个实例名，容易改漏。
     *   IROM_BOOT=0/2 时 boot_busy 恒 0 ⇒ 下面每个 mux 都选 CPU 侧，
     *   综合结果与 v18 的只读分支**逐位等价**（已用重建比特流核对 WNS/资源）。
     *
     * ★★ 不变量：这里的 reset **必须只接 cpu_rst，不能接 cpu_rst_eff**！
     *   sync_mem 的写逻辑在 `if (reset) ... else begin ... if (wen) ...` 的 else 分支里
     *   —— 复位期间写会被整段丢掉。而 cpu_rst_eff 在引导全程为 1
     *   （= cpu_rst | boot_busy | ps_hold），接了它就会"校验和通过、但一个字都没写进去"，
     *   表现为 CPU 起来后执行全 0 的 IROM（非法指令）。这个坑是仿真抓出来的。
     *   引导/装载期间 CPU 本来就被按住，读口 ren 被 mux 成 0，所以 IROM 不跟复位是安全的。 */
    sync_mem_dp #(
        .WORDS     (IROM_WORDS),
        .INIT_FILE (IROM_INIT)
    ) irom_inst (
        .clk     (sys_clk),
        .reset   (cpu_rst),
        // ---- 端口 A：取指（只读，引导/装载期间 CPU 被按住 → ren=0）----
        .a_addr  (irom_addr),
        .a_ren   (boot_busy ? 1'b0 : irom_en),
        .a_rdata (irom_data),
        // ---- 端口 B：CPU 数据读/写（窗口 0x2_0000）/ 引导器写（'B' 帧）----
        //   ★ 二者互斥：boot_busy=1 时 CPU 在复位，不可能来读/写。
        //   ★ v16：CPU 的 store 也走这一路（写代码区），见上面 2a 段。
        .b_addr  (boot_busy ? (boot_addr << 2) : perip_addr),
        .b_ren   (boot_busy ? 1'b0 : bus_re_code),
        .b_rdata (irom_d_rdata),
        .b_wen   (boot_busy ? (boot_we & ~boot_mem_sel) : bus_we_code),
        .b_wdata (boot_busy ? boot_wdata : perip_wdata),
        .b_mask  (boot_busy ? 2'b11 : perip_mask)
    );

    /* ---------------- 3c) 唯一的 cpu_rst_eff 定义点 ----------------
     * 双核协同（第 1 步）：再加一个 ps_hold（AXI 主机的"等我把镜像灌完"）。
     * AXIL_EN=0 时 ps_hold 被钉成 0 → 与 v18 等价的 cpu_rst | boot_busy。 */
    assign cpu_rst_eff = cpu_rst | boot_busy | ps_hold;

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
    logic        uart_busy;

    /* A1：`mmio_sel` / `mmio_idx` / `dram_rdata` 的声明与赋值都搬走了 ——
     *   片选与寄存器号由 soc_bus 给（bus_hit_mmio / bus_mmio_idx），
     *   dram_rdata 在 2a 段声明。这里只剩外设自己的状态。 */

    // 只对 TXDATA 的有效写产生 send 脉冲（顺带挡掉字节/半字写：UART 只认整字写，
    //   免得 sb 的低位数据落到别的字节通道上，行为取决于 mask 反而更难看）
    uart_tx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115_200)
    ) uart_tx_inst (
        .clk   (sys_clk),
        .rst   (cpu_rst),
        .data  (perip_wdata[7:0]),
        // ★ A1：send 用总线门过的写使能 we_mmio（已经保证命中 MMIO），
        //   寄存器号用 soc_map 的宏，不再出现裸的 3'd0。
        .send  (bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_TXDATA)),
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
    assign rx_pop = bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_RXPOP) & rx_avail;

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
            if (perip_ren & bus_hit_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_RXSTAT)) rx_ovf <= 1'b0;
        end
    end

    /* ---- GPIO：7 个 LED（LED1~LED7） ---- */
    logic [6:0] led_reg;
    always_ff @(posedge sys_clk) begin
        if (cpu_rst_eff)                                          led_reg <= 7'd0;
        else if (bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_LED)) led_reg <= perip_wdata[6:0];
    end
    assign led = led_reg;

    /* ---- 双核协同（第 1/2/3 步）：CTL @ 0x1000_001C --------------------------
     * 三个动作合成一个寄存器，因为 4 位索引下 0x1C 是最后一个空位（见 soc_map.sv）：
     *   bit0 写 1 → dcache_inval 一拍脉冲（PS 改完 DRAM，CPU 读之前先清）
     *   bit1 RW   → irq_ps 电平（CPU 敲 ARM）
     *   bit2 写 1 → cpu_alive 置位（stub 报平安；PS 可用 CTRL.bit2 清）
     * ★ 顺序敏感：dcache_inval 必须**先**于"读 PS 的数据"，中间不能有别的访存。
     * ------------------------------------------------------------------------- */
    always_ff @(posedge sys_clk) begin
        if (cpu_rst_eff) begin
            irq_ps_r   <= 1'b0;
            cpu_alive_r <= 1'b0;
        end else begin
            if (bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_CTL)) begin
                irq_ps_r <= perip_wdata[1];
                if (perip_wdata[2]) cpu_alive_r <= 1'b1;
            end
            if (alive_clr)   cpu_alive_r <= 1'b0;
            if (irq_ps_clr)  irq_ps_r    <= 1'b0;   // PS 收下中断后由它清（见 ps_ctrl）
        end
    end
    assign irq_ps = irq_ps_r;

    // 一拍脉冲：只在写 CTL 且 bit0=1 的那一拍有效
    assign dcache_inval = bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_CTL)
                        & perip_wdata[0];

    // 读：按寄存器号选，其余地址返回 DRAM
    // ★ 不变量：这个 mux 是**地址译码**，不是数据通路 —— 别把它塞进 DCache。
    // ★ RXDATA 的读值是"当前队头"，**不弹**；弹出由写 0x1000_0018 完成（v13.5）。
    // ★ v14：0x2_0000~0x2_FFFF 是 IROM 的数据窗口（第二读口），优先级在 MMIO 之后、
    //   DRAM 之前 —— 三者地址区间互不重叠，这里只是把三路拼起来。
    /* ---------------- 4b) A2：PLIC-lite 接线（源信号到这里才齐） ---------------- */
    assign plic_src[`SOC_IRQ_UART_RX]  = rx_avail;
    assign plic_src[`SOC_IRQ_UART_OVF] = rx_ovf;
    assign plic_src[`SOC_IRQ_TIMER]    = 1'b0;          // A3 接入 CLINT
    assign plic_src[`SOC_IRQ_SW]       = irq_sw_pulse;
    assign plic_src[7:5]               = 3'b000;
    // 双核协同（第 3 步）：PS 经 AXI 控制寄存器 bit1 拉高的电平中断
    assign plic_src[`SOC_IRQ_PS]       = ps_irq_to_cpu;

    // 写 IRQ_PEND 的 1 表示"这个我处理完了"（claim 清位）；写 IRQ_SW 触发软件源
    assign plic_clr     = {8{bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_IRQPEND)}} & perip_wdata[7:0];
    assign irq_sw_pulse = bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_IRQSW);

    plic_lite #(.NSRC(8)) plic_inst (
        .clk      (sys_clk),
        .reset    (cpu_rst),
        .src      (plic_src),
        .en_wdata (perip_wdata[7:0]),
        .en_we    (bus_we_mmio & (bus_mmio_idx == `SOC_MMIO_IDX_IRQEN)),
        .clr_we   (plic_clr),
        .pending  (plic_pend),
        .enabled  (plic_en),
        .irq      (plic_irq),
        .best_id  (plic_best)
    );

    /* ★ A1：这里**只剩外设自己的寄存器堆**。
     *   原来"MMIO > 代码窗口 > DRAM"的三路优先级 mux 已经搬进 soc_bus ——
     *   本模块不再需要知道代码窗口和 DRAM 的存在。 */
    always_comb begin
        case (bus_mmio_idx)
            `SOC_MMIO_IDX_TXSTAT: mmio_rdata = {31'b0, uart_busy};
            `SOC_MMIO_IDX_RXDATA: mmio_rdata = {24'b0, rx_fifo[rx_rp]};
            `SOC_MMIO_IDX_RXSTAT: mmio_rdata = {30'b0, rx_ovf, rx_avail};
            // ---- A2：PLIC-lite ----
            `SOC_MMIO_IDX_IRQPEND: mmio_rdata = {24'b0, plic_pend};
            `SOC_MMIO_IDX_IRQEN:   mmio_rdata = {24'b0, plic_en};
            `SOC_MMIO_IDX_IRQID:   mmio_rdata = {28'b0, plic_best};
            // ---- A3：CLINT ----
            `SOC_MMIO_IDX_MTIME:     mmio_rdata = clint_mtime;
            `SOC_MMIO_IDX_MTIMEH:    mmio_rdata = 32'b0;
            `SOC_MMIO_IDX_MTIMECMP:  mmio_rdata = clint_mtimecmp;
            `SOC_MMIO_IDX_MTIMECMPH: mmio_rdata = 32'b0;
            // ---- 双核协同：控制寄存器回读（bit1 = irq_ps 当前电平）----
            `SOC_MMIO_IDX_CTL:       mmio_rdata = {30'b0, irq_ps_r, 1'b0};
            default:              mmio_rdata = 32'b0;   // TXDATA/LED/BOOTREQ/RXPOP/IRQSW 读回 0
        endcase
    end

    /* ---------------- 5) 同步 BRAM：DRAM（读写，按 mask 字节写） ----------------
     * reset 接 1'b0：真实 BRAM 的存储阵列不会因复位被清空（见 sync_mem 头部契约）。
     * ★ v13：引导期间（boot_busy=1，CPU 被复位按住）这个口由 loader 独占，
     *   用来灌 .rodata/.data 镜像（'C' 帧）。IROM_BOOT=0 时 boot_busy 恒 0，
     *   所有 mux 都选 CPU 侧，网表与 v11/v12 完全等价。
     *   ★ 不变量：cpu_rst_eff = cpu_rst | boot_busy 保证"引导期间 CPU 不会来抢"，
     *     所以这里仍然不需要仲裁器。 */
    /* ============ DRAM: single port (default) or shared with an AXI host (#6) ============
     * Both forms present the CPU with the SAME timing contract (sync BRAM: ren cycle
     * gives the address, rdata valid the next cycle; wen cycle writes per mask), so
     * CPU behaviour does not change.
     *
     * AXIL_EN=1 uses board/dram_shared.sv: the CPU keeps its own read and write port;
     * the AXI host *borrows* them in cycles where the CPU is idle (CPU always wins).
     * A plain 32-bit array is used on purpose -- a true-dual-port byte-lane array is
     * not inferable by Vivado (Synth 8-3391) and takes >400 s in xvlog. */
    generate
        if (AXIL_EN == 0) begin : g_dram_single
            sync_mem #(
                .WORDS     (DRAM_WORDS),
                .READ_ONLY (0),
                .INIT_FILE ("")
            ) dram_inst (
                .clk   (sys_clk),
                .reset (1'b0),
                .addr  (boot_busy ? (boot_addr << 2) : perip_addr),
                .ren   (boot_busy ? 1'b0 : bus_re_dram),
                .rdata (dram_rdata),
                // ★ 不变量：MMIO 写必须挡住 DRAM 写（见上面第 4) 段的说明）
                // ★ v13：引导写（boot_mem_sel=1 的 DRAM 帧）单独走这一路，与 MMIO 无关
                // ★ v14：IROM 数据窗口（0x2_xxxx）也**只读** —— 写它既不改 IROM 也不改 DRAM，
                //   静默丢弃。软件不该往代码区写；真要改镜像请走 boot_loader。
                // ★ A1：`bus_we_dram` 已经在 soc_bus 里排除了 MMIO 与代码窗口，
                //   所以这里**不再**重复写 `& ~mmio_sel & ~irom_win_sel` —— 一份判断只许有一处。
                .wen   (boot_busy ? (boot_we & boot_mem_sel)
                                  : bus_we_dram),
                .wdata (boot_busy ? boot_wdata : perip_wdata),
                .mask  (boot_busy ? 2'b11 : perip_mask)
            );

            assign s_axil_awready = 1'b0;
            assign s_axil_wready  = 1'b0;
            assign s_axil_bresp   = 2'b00;
            assign s_axil_bvalid  = 1'b0;
            assign s_axil_arready = 1'b0;
            assign s_axil_rdata   = 32'h0;
            assign s_axil_rresp   = 2'b00;
            assign s_axil_rvalid  = 1'b0;

            /* 双核协同的控制面在没有 AXI 主机时钉死 → 与 v18 逐位等价：
             *   ps_hold      = 0 → cpu_rst_eff 回到 cpu_rst | boot_busy
             *   ps_irq_to_cpu= 0 → PLIC 源 4 恒 0（行为同改造前）
             *   alive_clr    = 0 → 没有主机来清"已到岗"标志 */
            assign ps_hold      = 1'b0;
            assign ps_irq_to_cpu = 1'b0;
            assign alive_clr    = 1'b0;
            assign irq_ps_clr   = 1'b0;
        end else begin : g_dram_axil
            logic [31:0] ax_addr, ax_wdata, ax_rdata;
            logic        ax_req, ax_we, ax_gnt, ax_rvalid;
            logic [ 3:0] ax_wstrb;

            axil_slave u_axil (
                .aclk          (axil_aclk),
                .aresetn       (axil_aresetn),
                .s_axil_awaddr (s_axil_awaddr), .s_axil_awprot (s_axil_awprot),
                .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
                .s_axil_wdata  (s_axil_wdata),  .s_axil_wstrb (s_axil_wstrb),
                .s_axil_wvalid (s_axil_wvalid), .s_axil_wready (s_axil_wready),
                .s_axil_bresp  (s_axil_bresp),  .s_axil_bvalid(s_axil_bvalid),
                .s_axil_bready (s_axil_bready),
                .s_axil_araddr (s_axil_araddr), .s_axil_arprot (s_axil_arprot),
                .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
                .s_axil_rdata  (s_axil_rdata),  .s_axil_rresp (s_axil_rresp),
                .s_axil_rvalid (s_axil_rvalid), .s_axil_rready (s_axil_rready),
                .m_addr (ax_addr), .m_req (ax_req), .m_we (ax_we),
                .m_wdata (ax_wdata), .m_wstrb (ax_wstrb),
                .m_gnt (ax_gnt), .m_rvalid (ax_rvalid), .m_rdata (ax_rdata)
            );

            /* ---- 双核协同：AXI 本地地址 0x2_0000 以上是**控制平面**，不是 DRAM。
             *   BD 窗口 256 KB，DRAM 只占低 128 KB（0x0_0000..0x1_FFFF），
             *   `addr[17]` 一位就能把"控制寄存器"和"DRAM"完全分开 —— 不动内存译码。
             *   ★ 必须门掉通往 DRAM 的请求：否则 PS 写 0x2_0000 会顺带写 DRAM 第 0 个字
             *     （addr[16:2]=0），把 shell 的 .rodata 开头改掉。 */
            logic ax_is_ctrl, ax_gnt_dram, ax_gnt_ctrl;
            logic ax_rv_dram, ax_rv_ctrl;
            logic [31:0] ax_rd_dram, ax_rd_ctrl;

            assign ax_is_ctrl = ax_addr[17];

            ps_ctrl u_ps_ctrl (
                .clk        (sys_clk),
                .aresetn    (axil_aresetn),
                .s_addr     (ax_addr),
                .s_req      (ax_req),
                .s_we       (ax_we),
                .s_wdata    (ax_wdata),
                .s_gnt      (ax_gnt_ctrl),
                .s_rvalid   (ax_rv_ctrl),
                .s_rdata    (ax_rd_ctrl),
                .cpu_rst_eff(cpu_rst_eff),
                .boot_busy  (boot_busy),
                .plic_irq   (plic_irq),
                .irq_ps     (irq_ps_r),
                .cpu_alive  (cpu_alive_r),
                .hold       (ps_hold),
                .ps_irq     (ps_irq_to_cpu),
                .alive_clr  (alive_clr),
                .irq_ps_clr (irq_ps_clr)
            );

            dram_shared #(
                .WORDS     (DRAM_WORDS),
                .INIT_FILE ("")
            ) dram_inst (
                .clk   (sys_clk),
                .reset (1'b0),
                .cpu_addr  (boot_busy ? (boot_addr << 2) : perip_addr),
                .cpu_ren   (boot_busy ? 1'b0 : bus_re_dram),
                .cpu_rdata (dram_rdata),
                .cpu_wen   (boot_busy ? (boot_we & boot_mem_sel) : bus_we_dram),
                .cpu_wdata (boot_busy ? boot_wdata : perip_wdata),
                .cpu_mask  (boot_busy ? 2'b11 : perip_mask),
                .b_addr (ax_addr),
                .b_req  (ax_req & ~ax_is_ctrl),   // ★ 控制窗口**不进** DRAM
                .b_we   (ax_we),
                .b_wdata (ax_wdata), .b_be (ax_wstrb),
                .b_gnt (ax_gnt_dram), .b_rvalid (ax_rv_dram), .b_rdata (ax_rd_dram)
            );

            // 两条路的授权/响应互斥（由 ax_is_ctrl 选择），合成一路回桥
            assign ax_gnt    = ax_is_ctrl ? ax_gnt_ctrl : ax_gnt_dram;
            assign ax_rvalid = ax_is_ctrl ? ax_rv_ctrl  : ax_rv_dram;
            assign ax_rdata  = ax_is_ctrl ? ax_rd_ctrl  : ax_rd_dram;
        end
    endgenerate


    /* ---------------- 6) 观测计数器引出 ---------------- */
    // v9 修复（B8）：四条计数器已经在 myCPU 的端口上接好了（见上面的例化），
    //   这里不再需要层次化引用。

endmodule
