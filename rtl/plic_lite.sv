`include "para.sv"
`include "soc_map.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * plic_lite.sv — A2：平台级中断控制器（PLIC 的教学简化版）
 * -----------------------------------------------------------------------------
 * 改造前：`CSR.sv:191` 把 `meip` **硬连 0**，全核只有 mtime 一个中断源，
 * 所有外设都靠软件轮询（UART 收字节、按键、LED…）。这就是"按方向键会丢键"
 * 这类问题的根：RX FIFO 只有 8 深，CPU 一旦在别的循环里待久了就溢出。
 *
 * 本模块提供 SPARC/PLIC 风格的最小集合：
 *   · 每个源一个 pending 位：源为**电平**，置位后一直挂着，直到软件 claim；
 *   · 每个源一个 enable 位（可读可写，WARL）；
 *   · 输出 `irq = |(pending & enabled)`，直接接 CSR 的 meip；
 *   · `best_id` 是"当前最高优先级的待处理源号"，配合 claim 写 1 清位使用。
 *
 * ★ 为什么用**电平**而不是边沿：
 *   UART RX FIFO 非空是电平信号。若用边沿置位、claim 清位，在两个字节之间
 *   会有"数据还在 FIFO 里但 pending 已被清"的窗口 —— 那一个字节就永远不会
 *   再触发中断了。电平语义保证"只要还有数据 pending 就重新冒出来"。
 *
 * ★ 优先级：源号越小优先级越高（固定优先级，不做可编程门限）。教学够用；
 *   标准 PLIC 的 priority/threshold 寄存器刻意不做，避免"读了 spec 却只实现
 *   一半"的尴尬 —— 文档里明确写清这是 plic_**lite**。
 *
 * ★ 不变量：
 *   · `clr` 与 `src` 同拍时 **clear 优先**。电平源若仍为高，下一拍会重新置位，
 *     所以不会丢事件；反之若 clear 不优先，claim 就变成了空操作。
 *   · `irq` 是组合输出，不许打拍 —— 它要直接进 CSR 的 mip，晚一拍就是晚一拍。
 * ============================================================================= */
module plic_lite #(
    parameter integer NSRC = 8
) (
    input  logic              clk,
    input  logic              reset,

    /* ---- 中断源（电平，1 = 该源有效请求）---- */
    input  logic [NSRC-1:0]   src,

    /* ---- 软件接口 ---- */
    input  logic [NSRC-1:0]   en_wdata,   // 使能寄存器写入值
    input  logic              en_we,      // 写使能
    input  logic [NSRC-1:0]   clr_we,     // 写 1 清 pending（= claim）
    output logic [NSRC-1:0]   pending,
    output logic [NSRC-1:0]   enabled,

    /* ---- 输出 ---- */
    output logic              irq,        // = |(pending & enabled) → meip
    output logic [3:0]        best_id     // 最高优先级待处理源号（无则 0）
);

    /* ------------------------------ pending ------------------------------- */
    always_ff @(posedge clk) begin
        if (reset) pending <= '0;
        else       pending <= (pending | src) & ~clr_we;   // clear 优先
    end

    /* ------------------------------ enable -------------------------------- */
    always_ff @(posedge clk) begin
        if (reset)     enabled <= '0;
        else if (en_we) enabled <= en_wdata;
    end

    /* ------------------------------ 汇总 ---------------------------------- */
    logic [NSRC-1:0] active;
    assign active = pending & enabled;
    assign irq    = |active;

    /* --------------------------- 优先级编码 -------------------------------
     * 源号小 = 优先级高。用 for 循环"从大到小覆盖"，最后留下的就是最小号。
     * ------------------------------------------------------------------- */
    integer i;
    always_comb begin
        best_id = 4'd0;
        for (i = NSRC - 1; i >= 0; i = i - 1)
            if (active[i]) best_id = i[3:0];
    end

endmodule
