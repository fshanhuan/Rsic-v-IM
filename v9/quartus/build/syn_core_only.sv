// =============================================================================
// quartus/build/syn_core_only.sv — 只综合「CPU 核心」的测量用外壳
// -----------------------------------------------------------------------------
// 为什么需要它：
//   board/board_top.sv 里带 IROM(16KB) + DRAM(64KB) 两块同步 BRAM，共 80KB。
//   Cyclone IV E 的 EP4CE6 只有 30 个 M9K（=270Kb = 33.75KB），光存储器就装不下，
//   用它测「CPU 逻辑占多少 LE」会被存储器噪声盖住。
//   所以这里放一个**只把 myCPU 的端口引出来**的外壳，
//   用 quartus_map 单独跑 Analysis & Synthesis，得到纯逻辑资源。
//
// 用法：
//   quartus_map v9_core --read_settings_files=on
//   （工程文件 v9_core.qsf 的 TOP_LEVEL_ENTITY 指向本模块）
//
// 注意：本模块只用于资源测量，不是一个可上板的顶层
//   （irom_*/perip_* 在这里是悬空输入，综合会被优化掉一部分）。
//   真正上板请用 board/board_top.sv。
// =============================================================================
`include "para.sv"

module syn_core_only (
    input  logic        sys_clk,
    input  logic        sys_rst,

    output logic [31:0] irom_addr,
    input  logic [31:0] irom_data,
    output logic        irom_en,

    output logic [31:0] perip_addr,
    output logic        perip_wen,
    output logic        perip_ren,
    output logic [ 1:0] perip_mask,
    output logic [31:0] perip_wdata,
    input  logic [31:0] perip_rdata,

    output logic        debug_wb_have_inst,
    output logic [31:0] debug_wb_pc,
    output logic        debug_wb_ena,
    output logic [ 4:0] debug_wb_reg,
    output logic [31:0] debug_wb_value,

    output logic [31:0] debug_icache_hit_cnt,
    output logic [31:0] debug_icache_miss_cnt,
    output logic [31:0] debug_dcache_hit_cnt,
    output logic [31:0] debug_dcache_miss_cnt
);

    myCPU u_cpu (
        .cpu_clk            (sys_clk),
        .cpu_rst            (sys_rst),
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

        .debug_icache_hit_cnt  (debug_icache_hit_cnt),
        .debug_icache_miss_cnt (debug_icache_miss_cnt),
        .debug_dcache_hit_cnt  (debug_dcache_hit_cnt),
        .debug_dcache_miss_cnt (debug_dcache_miss_cnt)
    );

endmodule
