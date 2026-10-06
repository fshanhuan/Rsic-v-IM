`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * board_top.sv — v9 的板级顶层（CPU + 同步存储器 + 复位同步器）
 * -----------------------------------------------------------------------------
 * 这一层只做三件事，逻辑一律不写在这里：
 *   1. 复位：板卡按键 → reset_sync（异步置位、同步释放）→ myCPU.cpu_rst；
 *   2. 存储：IROM / DRAM 全部换成 board/sync_mem.sv 的**同步 BRAM**
 *      （固定 1 拍读延迟 + 读使能，正好对上 ICache/DCache 的同步化改造）；
 *   3. 可观测性：把 debug_wb_* 引出来，供数码管 / LED / UART 使用。
 *
 * 存储映射（与 sim/tb_iverilog.sv 一致）：
 *   IROM：0x0000_0000 ~ 0x0000_3FFF（4096 字 = 16KB），只读，
 *         initial + $readmemh 固化程序（Vivado 可综合到 BRAM 初值）；
 *   DRAM：0x0000_0000 ~ 0x0000_FFFF（16384 字 = 64KB），读写，按 mask 字节写。
 *   注意：这个教学 SoC 用 **perip_addr[15:2]** 索引 DRAM、用
 *         **irom_addr[13:2]** 索引 IROM，两套地址空间各自独立译码
 *         （和 cdp-tests/mySoC 的做法一致），不做统一 memory map。
 *
 * 读写时序契约（与 DCache 对齐，改这里之前先读 DCache.sv 头部）：
 *   - 读：DCache 给 mem_en=1 的**那一拍**给出 mem_addr，sync_mem 在
 *         下一个时钟沿输出 rdata，正好被 DCache 的 cpu_valid_r 那一拍采走；
 *   - 写：DCache 的 mem_wen 是**单拍脉冲**，sync_mem 在同一沿按 mem_mask
 *         合并写入。所以这里直接透传，不需要额外握手。
 *
 * 上板需要补的（本文件只留接口注释，不实现）：
 *   ── 7 段数码管（P4 可观测性）────────────────────────────────────────────
 *     建议用一个 1kHz 左右的扫描计数器轮流点亮 8 位数码管，段选译码：
 *       数码管 0-1：debug_wb_pc[15:0]        （写回 PC 低 16 位）
 *       数码管 2-3：debug_wb_value[15:0]     （写回数据低 16 位）
 *       数码管 4-5：{9'b0, icache_hit_cnt, icache_miss_cnt} 之类的计数器
 *       数码管 6  ：debug_wb_reg（写回目标寄存器号）
 *       数码管 7  ：{debug_wb_ena, debug_wb_have_inst}（写回使能/有效）
 *     例如：
 *       seg_data <= (scan_sel == 3'd0) ? {16'b0, debug_wb_pc[15:0]} : ...
 *       seg_sel  <= 8'b0000_0001 << scan_sel;
 *   ── UART（最接近 printf 的观察方式）─────────────────────────────────────
 *     建议 115200-8-N-1，在 debug_wb_have_inst 的上升沿把
 *       "PC=xxxx REG=xx VAL=xxxxxxxx\n"
 *     格式化后丢进一个 FIFO，再用波特率计数器移位输出到 uart_txd。
 *   ── 复位按键：btn_rst_n 需要额外做一次按键消抖（~10ms 计数），
 *     本模块只负责“异步置位、同步释放”，消抖属于板级输入调理。
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

    /* ---- P4 可观测性：写回信息引出（数码管 / LED / UART 都用它） ---- */
    output logic        debug_wb_have_inst,
    output logic [31:0] debug_wb_pc,
    output logic        debug_wb_ena,
    output logic [ 4:0] debug_wb_reg,
    output logic [31:0] debug_wb_value,

    /* ---- 便于上板观察的额外计数器输出 ---- */
    output logic [31:0] debug_icache_hit_cnt,
    output logic [31:0] debug_icache_miss_cnt,
    output logic [31:0] debug_dcache_hit_cnt,
    output logic [31:0] debug_dcache_miss_cnt
);

    /* ---------------- 1) 复位：异步置位、同步释放 ---------------- */
    logic cpu_rst;

    reset_sync reset_sync_inst (
        .clk         (sys_clk),
        .rst_n_async (btn_rst_n),
        .rst_sync    (cpu_rst)
    );

    /* ---------------- 2) CPU 与存储总线 ---------------- */
    logic [31:0] irom_addr;
    logic [31:0] irom_data;
    logic        irom_en;

    logic [31:0] perip_addr;
    logic        perip_wen;
    logic [ 1:0] perip_mask;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;
    logic        perip_en;

    myCPU u_cpu (
        .cpu_clk            (sys_clk),
        .cpu_rst            (cpu_rst),

        .irom_addr          (irom_addr),
        .irom_data          (irom_data),

        .perip_addr         (perip_addr),
        .perip_wen          (perip_wen),
        .perip_mask         (perip_mask),
        .perip_wdata        (perip_wdata),
        .perip_rdata        (perip_rdata),

        .debug_wb_have_inst (debug_wb_have_inst),
        .debug_wb_pc        (debug_wb_pc),
        .debug_wb_ena       (debug_wb_ena),
        .debug_wb_reg       (debug_wb_reg),
        .debug_wb_value     (debug_wb_value)
    );

    // I-Cache 的读使能 / D-Cache 的读使能：myCPU 内部已经算好，这里取出来
    // 直接接同步存储器的读口（不接也能工作，接上更贴近真实 BRAM 用法）。
    assign irom_en  = u_cpu.icache_mem_en;
    assign perip_en = u_cpu.dcache_mem_en;

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
    // reset 接 1'b0：真实 BRAM 的存储阵列不会因复位被清空（见 sync_mem 头部）。
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
    assign debug_icache_hit_cnt  = u_cpu.icache_hit_cnt;
    assign debug_icache_miss_cnt = u_cpu.icache_miss_cnt;
    assign debug_dcache_hit_cnt  = u_cpu.dcache_hit_cnt;
    assign debug_dcache_miss_cnt = u_cpu.dcache_miss_cnt;

endmodule
