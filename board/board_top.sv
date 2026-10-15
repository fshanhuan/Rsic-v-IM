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
 *   - IROM 用 **irom_addr[13:2]** 索引（4096 字 = 16KB，只读，0x0000_0000~0x3FFF）；
 *     DRAM 用 **perip_addr[15:2]** 索引（16384 字 = 64KB，读写，按 mask 字节写）。
 *     两套地址空间**各自独立译码、不做统一 memory map**（与 cdp-tests/mySoC 以及
 *     sim/tb_iverilog.sv 一致）；别在这里擅自加地址优先级的仲裁。
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
    // IROM 字数（4096 字 = 16KB）
    parameter IROM_WORDS = 4096,
    // DRAM 字数（16384 字 = 64KB）
    parameter DRAM_WORDS = 16384,
    // 程序镜像（hex 文本，$readmemh 载入 IROM；Vivado 会把它变成 BRAM 初值）
    parameter IROM_INIT  = "prog.hex"
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
    (* keep = "true" *) output logic [31:0] debug_ifu_pc
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

    logic [31:0] perip_addr;
    logic        perip_wen;
    logic [ 1:0] perip_mask;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;
    logic        perip_en;
    logic        perip_ren;

    myCPU u_cpu (
        .cpu_clk            (sys_clk),
        .cpu_rst            (cpu_rst),

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
        .debug_ifu_pc          (debug_ifu_pc)
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

    /* ---------------- 3) 同步 BRAM：IROM（只读，$readmemh 固化） ---------------- */
    sync_mem #(
        .WORDS     (IROM_WORDS),
        .READ_ONLY (1),
        .INIT_FILE (IROM_INIT)
    ) irom_inst (
        .clk   (sys_clk),
        .reset (cpu_rst),
        .addr  (irom_addr),
        .ren   (irom_en),
        .rdata (irom_data),
        .wen   (1'b0),
        .wdata (32'b0),
        .mask  (2'b0)
    );

    /* ---------------- 4) 同步 BRAM：DRAM（读写，按 mask 字节写） ---------------- */
    // reset 接 1'b0：真实 BRAM 的存储阵列不会因复位被清空（见 sync_mem 头部契约）。
    sync_mem #(
        .WORDS     (DRAM_WORDS),
        .READ_ONLY (0),
        .INIT_FILE ("")
    ) dram_inst (
        .clk   (sys_clk),
        .reset (1'b0),
        .addr  (perip_addr),
        .ren   (perip_en),
        .rdata (perip_rdata),
        .wen   (perip_wen),
        .wdata (perip_wdata),
        .mask  (perip_mask)
    );

    /* ---------------- 5) 观测计数器引出 ---------------- */
    // v9 修复（B8）：四条计数器已经在 myCPU 的端口上接好了（见上面的例化），
    //   这里不再需要层次化引用。

endmodule
