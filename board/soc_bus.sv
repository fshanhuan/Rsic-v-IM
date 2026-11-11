`include "para.sv"
`include "soc_map.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * soc_bus.sv — 系统总线（A1）：地址译码 + 片选 + 读数据回选
 * -----------------------------------------------------------------------------
 * 它做三件事，且**只**做这三件事：
 *   1. 把 CPU 数据口的一次访问（ren/wen/addr）译到唯一一个从设备；
 *   2. 给每个从设备发片选 + 已门过的读/写使能（外设不用再自己判地址）；
 *   3. 把各从设备的读数据回选成一路 rdata。
 *
 * ★ 为什么先做"组合译码总线"而不是完整 Wishbone/AXI：
 *   现在的 CPU 是**固定 1 拍延迟**访存（请求拍给地址，下一拍数据有效，见
 *   board_top 头部契约）。Wishbone 的 `ack` 握手会迫使 LSU 增加一个等待态，
 *   而 LSU/DCache 这条路径正是 P4（MMIO 重复读）的现场，WNS 又只剩 0.048 ns。
 *   所以 A1 先把"四处散落的译码"收成**一处**，**逐位保持时序不变**；
 *   等真的出现需要等待态的外设（SD 卡 / 慢速 Flash），再给总线加 ack 引脚。
 *   这条取舍写在 docs/ 里，别当没发生过。
 *
 * ★ 两个"读"和"写"必须分开，别合用一个 req：
 *   `perip_ren`（= dcache_mem_en）只在**读**的那一拍为 1；
 *   `perip_wen` 只在**写**的那一拍为 1。两者可能都不为 1（流水线空转）。
 *   合成 `req = ren | wen` 再分发，是唯一不会漏掉 store 的写法。
 *
 * ★ 片选优先级（与改造前逐位一致）：
 *     MMIO  >  代码窗口  >  DRAM（默认从设备）
 *   默认从设备 = 既不是 MMIO 也不是代码窗口的地址一律落到 DRAM。这是改造前的
 *   真实行为（DRAM 只用 addr[16:2] 索引，天然按 128 KB 回卷），刻意保留以免打断
 *   隐藏依赖。需要严格译码时把 STRICT_DECODE 置 1（未命中回 0 + unmapped=1）。
 *
 * ★ 不变量（板级契约）：
 *   · 写使能**必须**由本模块门过：`we_dram` 已排除 MMIO 与代码窗口，下游
 *     （sync_mem 的 .wen）不许再做第二次地址判断 —— 双份判断迟早对不上。
 *   · 片选互斥：一次访问最多一个 hit_* 为 1，由掩码比较天然保证。
 *   · rdata 的 mux 由 **hit_\***（纯译码）决定，**不能**用 sel_*（含 ren/wen）——
 *     数据在请求的下一拍才有效，那时 ren/wen 已经撤了，用 sel_* 会让读回变成 0。
 *   · 回选是**地址译码**不是数据通路：不许塞进 DCache。
 *
 * ★ 顺带修掉的旧缺陷：改造前 `dram .ren` 接的是 `perip_en`（不做地址判断），
 *   于是读 MMIO / 读代码窗口时 DRAM 也在读（纯功耗浪费）。现在 `re_dram` 只在
 *   命中 DRAM 时为 1 —— 功能不变，少一路无意义的读。
 * ============================================================================= */
module soc_bus #(
    // 0 = 默认从设备（改造前行为，逐位兼容）；1 = 严格译码
    parameter bit STRICT_DECODE = 1'b0
) (
    /* ---- CPU 数据侧请求（对应 myCPU 的 perip_* 顶层端口）---- */
    input  logic        ren,          // 本拍发一次读（= perip_ren = dcache_mem_en）
    input  logic        wen,          // 本拍发一次写（= perip_wen）
    input  logic [31:0] addr,         // 字节地址
    input  logic [31:0] wdata,        // 写数据（仅透传）
    input  logic [ 1:0] mask,         // 字节掩码（仅透传）

    /* ---- 各从设备的读数据（同步 BRAM/外设在 T+1 给出）---- */
    input  logic [31:0] dram_rdata,
    input  logic [31:0] code_rdata,   // IMEM 第二口
    input  logic [31:0] mmio_rdata,   // 外设寄存器（board_top 里的小 case）

    /* ---- 回选结果 ---- */
    output logic [31:0] rdata,

    /* ---- 纯译码结果（不含 ren/wen）：给读 mux 与调试用 ---- */
    output logic        hit_dram,
    output logic        hit_code,
    output logic        hit_mmio,
    output logic [ 3:0] mmio_idx,

    /* ---- 已按片选门过的读使能 ---- */
    output logic        re_dram,
    output logic        re_code,

    /* ---- 已按片选门过的写使能（下游直接用）---- */
    output logic        we_dram,
    output logic        we_code,
    output logic        we_mmio,

    /* ---- 严格模式下才会为 1：访问没有落到任何从设备 ---- */
    output logic        unmapped
);

    /* ------------------------------ 译码 ---------------------------------- */
    logic hit_default;
    logic [31:0] unused_ok;

    assign hit_mmio = `SOC_SEL_MMIO(addr);
    assign hit_code = `SOC_SEL_CODE(addr);

    generate
        if (STRICT_DECODE) begin : g_strict
            // 严格：DRAM 只认 0x0000_0000 – 0x0001_FFFF
            assign hit_dram = (addr < `SOC_DRAM_BYTES);
            assign unmapped = !(hit_dram | hit_code | hit_mmio);
        end else begin : g_default
            // 默认从设备：与改造前一致（任何未命中 MMIO/代码窗口的地址都落到 DRAM）
            assign hit_dram = !(hit_code | hit_mmio);
            assign unmapped = 1'b0;
        end
    endgenerate

    assign hit_default = 1'b0;
    // ★ A2：4 位（addr[5:2]）—— 3 位时 0x20 会和 0x00 别名（magic 0xF0 撞 LED 就是这么来的）
    assign mmio_idx = addr[5:2];

    /* --------------------------- 使能分发 ---------------------------------
     * 写：`we & hit` —— 这就是老不变量的新家。
     *   改造前 `dram .wen(perip_wen & ~mmio_sel & ~irom_win_sel)` 与之逐位相同，
     *   但"写 DRAM 的可能性"从此**只在这一个地方**存在。
     * 读：`ren & hit` —— 顺带挡掉读 MMIO 时对 DRAM 的无意义读。
     * ------------------------------------------------------------------- */
    assign re_dram = ren & hit_dram;
    assign re_code = ren & hit_code;

    assign we_dram = wen & hit_dram;
    assign we_code = wen & hit_code;
    assign we_mmio = wen & hit_mmio;

    /* --------------------------- 读数据回选 ---------------------------------
     * ★ 用 hit_*（纯译码），不能用 ren/wen 门过的结果：数据在请求的下一拍才有效。
     * 优先级 MMIO > 代码窗口 > DRAM，与改造前一致；未映射回 0。
     * ------------------------------------------------------------------- */
    always_comb begin
        if (hit_mmio)      rdata = mmio_rdata;
        else if (hit_code) rdata = code_rdata;
        else if (hit_dram) rdata = dram_rdata;
        else               rdata = 32'b0;
    end

    /* wdata / mask 目前不参与译码；保留端口是为了将来加等待态从设备时由总线统一
     * 寄存一份，免得每个外设各存一份。这里用一个哑负载防止 lint 报 unused。 */
    assign unused_ok = ^{wdata, mask, hit_default};

endmodule
