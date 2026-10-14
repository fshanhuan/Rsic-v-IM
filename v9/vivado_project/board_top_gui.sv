`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * board_top_gui.sv — v9 在 EES-331 上的**工程模式**顶层（ILA 标准 IP 例化版）
 * -----------------------------------------------------------------------------
 * 【为什么又有一个顶层】
 *   前一版 board_top_ila.sv 把 ILA 交给 (* mark_debug *) + create_debug_core
 *   在**内存里**插入。这条链路本身是通的（bit 已经出来、时序也过了），但它
 *   绕开了工程的 run：磁盘上没有 .runs/.srcs，GUI 里 Design Runs 全灰、
 *   双击网表 / Open Implemented Design 都点不动 —— 正是你说的「打开工程
 *   还是灰的 / 黑的」的根因。
 *
 *   本文件改用 Vivado 最标准的做法：**把 ILA 当成一个普通 IP 例化在 RTL 里**。
 *   好处：
 *     1) 综合 / 实现 / bitstream 全部由 synth_1、impl_1 两个真实 run 完成，
 *        GUI 里全流程可见、可右键 Re-run；
 *     2) ILA 出现在 Sources 窗口的 IP 源里，双击就能改深度 / 位宽重新生成；
 *     3) 上板时 Hardware Manager 能自动匹配同目录的 .ltx 探针文件；
 *     4) 不再需要"骗综合别删我"的绕法 —— ILA 的 probe 端口就是这些信号的
 *        **真实负载**，综合自然不会删。
 *
 * 【层次】
 *   board_top_gui (本文件)
 *     ├─ u_ila_0         : xilinx.com:ip:ila:6.2，13 个 probe，深度 2048
 *     └─ u_board_top_ila : board_top_ila.sv（MMCM 100→50MHz + CPU + 存储器）
 *
 * 【时钟】
 *   采样时钟用 MMCM 出来的 **50MHz**（`u_board_top_ila.sys_clk_50m`），
 *   和 CPU 同源同频。ILA IP 自己配置里的 C_CLK_FREQ 只是算时间戳的默认值，
 *   真正决定采样率的是接进来的 .clk。
 *   若以后想按 100MHz 采样，把 .clk 换成 sys_clk 即可，但采样时钟必须和
 *   被观测信号同源，否则抓到的数据没有意义。
 *
 * 【probe 分配表】（与 syn/ila_使用说明.md §3 一致，顺序不可乱改）
 *   probe0  debug_wb_have_inst      1   bit  写回是否有有效指令
 *   probe1  debug_wb_pc            32   bit  写回级 PC
 *   probe2  debug_wb_ena            1   bit  写回使能
 *   probe3  debug_wb_reg            5   bit  写回目的寄存器号
 *   probe4  debug_wb_value         32   bit  写回数据
 *   probe5  debug_icache_hit_cnt   32   bit  I-Cache 命中计数
 *   probe6  debug_icache_miss_cnt  32   bit  I-Cache 缺失计数
 *   probe7  debug_dcache_hit_cnt   32   bit  D-Cache 命中计数
 *   probe8  debug_dcache_miss_cnt  32   bit  D-Cache 缺失计数
 *   probe9  debug_mcause           32   bit  异常原因
 *   probe10 debug_mepc             32   bit  异常返回 PC
 *   probe11 debug_mtval            32   bit  异常附加信息
 *           ▲ 已知 RTL 待修：v9 的 CSR.mtval 从未被写，这一路综合后是常量。
 *             详见 syn/上板改造说明.md。
 *   probe12 debug_trap_take         1   bit  是否正在进入异常
 *
 * 【引脚】（EES-331 用户手册管脚约束表，别用原理图位号）
 *   sys_clk    ← M19  PL 时钟 FPGA_CLK0，100MHz（有源晶振）
 *   btn_rst_n  ← L18  PL 按键 S1（标号 FPGA_RESET），4.7K 上拉、按下为低
 *   debug_dead → 不接，或接一个 LED 当"CPU 在跑"的心跳灯（XDC 里接的是 V4=LED0）
 * ============================================================================= */
module board_top_gui #(
    parameter IROM_WORDS = 4096,
    parameter DRAM_WORDS = 16384,
    parameter IROM_INIT  = "prog.hex"
) (
    input  logic sys_clk,      // M19，100MHz
    input  logic btn_rst_n,    // L18，低有效
    output logic debug_dead    // 心跳，可不接
);

    /* ---------------- 1) 被观测设计的全部调试量 ---------------- */
    // 这些线同时接到 ILA 的 probe 上，所以有真实负载，综合不会删。
    logic        debug_wb_have_inst;
    logic [31:0] debug_wb_pc;
    logic        debug_wb_ena;
    logic [ 4:0] debug_wb_reg;
    logic [31:0] debug_wb_value;
    logic [31:0] debug_icache_hit_cnt,  debug_icache_miss_cnt;
    logic [31:0] debug_dcache_hit_cnt,  debug_dcache_miss_cnt;
    logic [31:0] debug_mcause, debug_mepc, debug_mtval;
    logic        debug_trap_take;

    /* ---------------- 2) 被测设计（含 MMCM 100→50MHz，并把 50MHz 引出来） ---- */
    logic sys_clk_50m;

    board_top_ila #(
        .IROM_WORDS (IROM_WORDS),
        .DRAM_WORDS (DRAM_WORDS),
        .IROM_INIT  (IROM_INIT)
    ) u_board_top_ila (
        .sys_clk               (sys_clk),
        .btn_rst_n             (btn_rst_n),
        .sys_clk_50m           (sys_clk_50m),

        .debug_wb_have_inst    (debug_wb_have_inst),
        .debug_wb_pc           (debug_wb_pc),
        .debug_wb_ena          (debug_wb_ena),
        .debug_wb_reg          (debug_wb_reg),
        .debug_wb_value        (debug_wb_value),

        .debug_icache_hit_cnt  (debug_icache_hit_cnt),
        .debug_icache_miss_cnt (debug_icache_miss_cnt),
        .debug_dcache_hit_cnt  (debug_dcache_hit_cnt),
        .debug_dcache_miss_cnt (debug_dcache_miss_cnt),

        .debug_mcause          (debug_mcause),
        .debug_mepc            (debug_mepc),
        .debug_mtval           (debug_mtval),
        .debug_trap_take       (debug_trap_take),

        .debug_dead            (debug_dead)
    );

    /* ---------------- 3) 片内逻辑分析仪（标准 IP 例化） ---------------- */
    // ★ 这一句就是"GUI 里能看到 ILA、流程不灰"的关键：它是普通 RTL 例化，
    //   综合时是个真实 IP，Hardware Manager 也能自动匹配探针文件。
    //   probe 位宽必须与 build_project_ila.tcl 里的 ILA_PROBES 列表一致。
    u_ila_0 u_ila_0 (
        .clk     (sys_clk_50m),          // 采样时钟 = CPU 时钟 = 50MHz

        .probe0  (debug_wb_have_inst),   // 1
        .probe1  (debug_wb_pc),          // 32
        .probe2  (debug_wb_ena),         // 1
        .probe3  (debug_wb_reg),         // 5
        .probe4  (debug_wb_value),       // 32
        .probe5  (debug_icache_hit_cnt), // 32
        .probe6  (debug_icache_miss_cnt),// 32
        .probe7  (debug_dcache_hit_cnt), // 32
        .probe8  (debug_dcache_miss_cnt),// 32
        .probe9  (debug_mcause),         // 32
        .probe10 (debug_mepc),           // 32
        .probe11 (debug_mtval),          // 32（RTL 待修，见文件头）
        .probe12 (debug_trap_take)       // 1
    );

endmodule
