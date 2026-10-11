// =============================================================================
// quartus/build/board_top_small.sv — 「减存储」变体（只用于量化 EP4CE30 的可达性）
// -----------------------------------------------------------------------------
// 目的：确认「逻辑够、只有 M9K 不够」这个判断。
//   EP4CE30F23C6 上板级原版的实测是：逻辑 19,251/28,848 = 67%、
//   寄存器 9,268/30,421 = 30%、引脚 201/329 = 61%，
//   而 M9K 68/66 = 103% —— **唯一超标的只有片上 RAM**。
//   所以在不改任何 CPU 逻辑的前提下，把 DRAM 从 16384 字(64KB) 降到 4096 字(16KB)、
//   IROM 从 4096 字(16KB) 降到 2048 字(8KB)，再 fit 一次：
//   如果这次 fit 通过，就说明瓶颈确实只在存储器容量，而不是逻辑。
//
// 用法：
//   quartus_map v9_small --read_settings_files=on
//   quartus_fit v9_small --read_settings_files=on
//
// 注意：这不是一个交付用的顶层，只是测量件。
//   要在真板上跑，请按 syn/quartus_modelsim_实测.md §4.3 的方案 A/B 正式改造。
// =============================================================================
`include "para.sv"

module board_top_small (
    input  logic        sys_clk,
    input  logic        btn_rst_n,
    output logic        debug_wb_have_inst,
    output logic [31:0] debug_wb_pc,
    output logic        debug_wb_ena,
    output logic [ 4:0] debug_wb_reg,
    output logic [31:0] debug_wb_value,
    // 4 个 32 位计数器在真板上会把引脚吃满（实测 201/92 脚），
    // 这个测量变体只各引出 1 位「是否发生过 miss」的锁存，代表「窄接口」写法。
    output logic        debug_icache_miss_seen,
    output logic        debug_dcache_miss_seen
);

    logic cpu_rst;
    reset_sync reset_sync_inst (
        .clk         (sys_clk),
        .rst_n_async (btn_rst_n),
        .rst_sync    (cpu_rst)
    );

    logic [31:0] irom_addr;
    logic [31:0] irom_data;
    logic        irom_en;

    logic [31:0] perip_addr;
    logic        perip_wen;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;
    logic        perip_ren;
    logic [ 1:0] perip_mask;

    logic [31:0] ic_hit, ic_miss, dc_hit, dc_miss;

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
        .debug_icache_hit_cnt  (ic_hit),
        .debug_icache_miss_cnt (ic_miss),
        .debug_dcache_hit_cnt  (dc_hit),
        .debug_dcache_miss_cnt (dc_miss)
    );

    // 窄接口：只把「发生过 miss」这一位寄存后送出去（2 个脚，而不是 128 个脚）
    always_ff @(posedge sys_clk) begin
        if (cpu_rst) begin
            debug_icache_miss_seen <= 1'b0;
            debug_dcache_miss_seen <= 1'b0;
        end else begin
            if (ic_miss != 32'b0) debug_icache_miss_seen <= 1'b1;
            if (dc_miss != 32'b0) debug_dcache_miss_seen <= 1'b1;
        end
    end

    // IROM 减半：2048 字 = 8KB
    sync_mem #(
        .WORDS     (2048),
        .READ_ONLY (1),
        .INIT_FILE ("prog.hex")
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

    // DRAM 降到 1/4：4096 字 = 16KB（原 16384 字 = 64KB）
    sync_mem #(
        .WORDS     (4096),
        .READ_ONLY (0),
        .INIT_FILE ("")
    ) dram_inst (
        .clk   (sys_clk),
        .reset (1'b0),
        .addr  (perip_addr),
        .ren   (perip_ren),
        .rdata (perip_rdata),
        .wen   (perip_wen),
        .wdata (perip_wdata),
        .mask  (perip_mask)
    );

endmodule
