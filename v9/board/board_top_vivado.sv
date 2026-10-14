`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * board_top_vivado.sv — board_top 的 Vivado 工程外壳（唯一目的是省引脚）
 * -----------------------------------------------------------------------------
 * 为什么需要它：Vivado 实现阶段报了
 *     ERROR: [Place 30-58] IO placement is infeasible.
 *     Number of unplaced IO Ports (201) is greater than number of available pins (200).
 * 根因不是逻辑，而是**顶层端口位宽**：
 *     board_top 的 4 个缓存计数器 debug_icache_hit_cnt / debug_icache_miss_cnt /
 *     debug_dcache_hit_cnt / debug_dcache_miss_cnt 每个都是 32 位 → 4×32 = 128 位，
 *     再加 debug_wb_pc(32) + debug_wb_value(32) + debug_wb_reg(5) + have_inst(1)
 *     + ena(1) + sys_clk(1) + btn_rst_n(1) = **201**，
 *     而 xc7z020clg484 封装的 I/O bank 一共只引出 **200** 个可用引脚。
 * 注意 200 是「器件封装上限」，真实 ZedBoard 上 200 个 PL 引脚里还有一大批被
 * DDR3 / QSPI Flash / 以太网 / USB 等板载器件占掉，**实际留给扩展口的只有几十个**。
 * 所以 32 位性能计数器在 clg484 上根本引不出来，必须收窄。
 *
 * 本文件的处理：
 *   - debug_wb_have_inst / debug_wb_pc / debug_wb_ena / debug_wb_reg /
 *     debug_wb_value —— **保持全宽**，这 5 个是判断 CPU「跑没跑对」的关键信号；
 *   - 4 个性能计数器 —— 只引出低 CNT_W 位（默认 8 位），引脚占用从 128 降到 4×8=32，
 *     顶层总端口从 201 降到 **105**。
 *   - board_top.sv 本身**不做任何修改**，sim/ 的回归与 board/tb_board_top.sv 全部不受影响。
 *
 * 代价与影响（说清楚，别踩坑）：
 *   8 位计数器在 256 次事件后回绕，只适合粗看「有没有动、动得快不快」，
 *   不能拿来算精确命中率。要全 32 位就得上更大封装
 *   （clg400/clg484 之外，例如 xc7z020clg484 换 xc7z045ffg900），
 *   或者把计数器改成 UART / ILA 输出，而不是引到引脚。
 *
 * 上板前仍需补（与 board_top.sv 头部注释一致）：
 *   ① v9_board.xdc 里的 PACKAGE_PIN / IOSTANDARD（现在是 TODO 占位）；
 *   ② 7 段数码管扫描 + 段选译码；③ 按键 ~10ms 消抖；
 *   ④ ZedBoard 的 BTNC 是**高有效**，本模块 btn_rst_n 是**低有效**，
 *      直连会「上电即复位、按下才跑」，必须反相或改端口极性。
 * ============================================================================= */
module board_top_vivado #(
    // IROM 字数（4096 字 = 16KB）
    parameter IROM_WORDS = 4096,
    // DRAM 字数（16384 字 = 64KB）
    parameter DRAM_WORDS = 16384,
    // 程序镜像（hex 文本，$readmemh 载入 IROM；Vivado 会把它变成 BRAM 初值）
    parameter IROM_INIT  = "prog.hex",
    // 性能计数器引出位宽。8 = 省引脚（顶层共 105 个端口）；
    //   改成 32 就回到 201 个端口 → clg484 上 place_design 会直接报 30-58 失败。
    parameter CNT_W      = 8
) (
    input  logic        sys_clk,
    input  logic        btn_rst_n,     // 板卡按键复位，低有效（ZedBoard BTNC 是高有效，注意反相）

    /* ---- P4 可观测性：写回信息全宽引出（数码管 / LED / UART 都用它） ---- */
    output logic        debug_wb_have_inst,
    output logic [31:0] debug_wb_pc,
    output logic        debug_wb_ena,
    output logic [ 4:0] debug_wb_reg,
    output logic [31:0] debug_wb_value,

    /* ---- 性能计数器：只引出低 CNT_W 位（省引脚，见文件头） ---- */
    output logic [CNT_W-1:0] debug_icache_hit_cnt,
    output logic [CNT_W-1:0] debug_icache_miss_cnt,
    output logic [CNT_W-1:0] debug_dcache_hit_cnt,
    output logic [CNT_W-1:0] debug_dcache_miss_cnt
);

    // board_top 的 4 个 32 位计数器输出先接到内部线上，再截低位出去。
    logic [31:0] icache_hit_cnt_f, icache_miss_cnt_f;
    logic [31:0] dcache_hit_cnt_f, dcache_miss_cnt_f;

    board_top #(
        .IROM_WORDS (IROM_WORDS),
        .DRAM_WORDS (DRAM_WORDS),
        .IROM_INIT  (IROM_INIT)
    ) u_board_top (
        .sys_clk               (sys_clk),
        .btn_rst_n             (btn_rst_n),

        .debug_wb_have_inst    (debug_wb_have_inst),
        .debug_wb_pc           (debug_wb_pc),
        .debug_wb_ena          (debug_wb_ena),
        .debug_wb_reg          (debug_wb_reg),
        .debug_wb_value        (debug_wb_value),

        .debug_icache_hit_cnt  (icache_hit_cnt_f),
        .debug_icache_miss_cnt (icache_miss_cnt_f),
        .debug_dcache_hit_cnt  (dcache_hit_cnt_f),
        .debug_dcache_miss_cnt (dcache_miss_cnt_f)
    );

    assign debug_icache_hit_cnt  = icache_hit_cnt_f[CNT_W-1:0];
    assign debug_icache_miss_cnt = icache_miss_cnt_f[CNT_W-1:0];
    assign debug_dcache_hit_cnt  = dcache_hit_cnt_f[CNT_W-1:0];
    assign debug_dcache_miss_cnt = dcache_miss_cnt_f[CNT_W-1:0];

endmodule
