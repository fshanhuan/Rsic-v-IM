`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * clint.sv — A3：标准定时器（CLINT 的精简版：mtime / mtimecmp）
 * -----------------------------------------------------------------------------
 * 改造前：`mtime/mtimecmp` 是**非标准 CSR**（0x7C0/0x7C1，见 rtl/CSR.sv:9），
 * 而 RISC-V 标准把它们放在**内存映射的 CLINT**（machine timer）。
 *
 * A3 的做法不是"再加一个计数器"，而是**把计数器搬出来，成为唯一计数源**：
 *   · 本模块拥有 mtime（分频递增）与 mtimecmp 两个寄存器；
 *   · CSR 侧 0x7C0/0x7C1 退化成**门面**：读=转发、写=发一条 we 脉冲；
 *   · 总线上 0x1000_0030 / 0x38 直接读写本模块。
 *   ⇒ `csrr mtime` 与 `lw 0x1000_0030` 读出的一定是同一个数（这就是 A3 的判据）。
 *
 * ★ 为什么必须单一计数源：两套计数器哪怕分频完全一样，也会因为复位相位/写入
 *   时刻不同而漂移。软件一旦混用两条路径（比如 shell 用 CSR 算 uptime、驱动用
 *   MMIO 设超时），时间就会对不上，而且极难查。
 *
 * 写优先级（同拍只可能有一个来源）：
 *     ① CSR 写（csrw mtime / csrw mtimecmp）   ← 软件兼容路径，优先级最高
 *     ② 总线写（sw 0x1000_0030 / 0x38）        ← SoC 标准路径
 *     ③ 自增（仅 mtime，按 `MTIME_DIV_DEFAULT 分频）
 *
 * ★ 不变量：mtimecmp 复位为全 1 —— 上电后 mtime 追不上它，不会凭空冒出 MTIP。
 * ★ 不变量：写 mtime 时**顺带清零分频计数器**，否则刚写完 0 又立刻 +1，
 *   读回来比写入值大 1，软件没法拿它当精确基准（这是 v10.3 踩过的坑）。
 * ============================================================================= */
module clint #(
    // 分频值：mtime 每 DIV 拍 +1。50 MHz / 100 = 500 kHz（2 us 每 tick）
    parameter integer DIV = `MTIME_DIV_DEFAULT
) (
    input  logic        clk,
    input  logic        reset,

    /* ---- 写口①：CSR 路径（csrw mtime / mtimecmp）---- */
    input  logic        csr_mtime_we,
    input  logic        csr_mtimecmp_we,
    input  logic [31:0] csr_wdata,

    /* ---- 写口②：总线路径（0x1000_0030 / 0x38）---- */
    input  logic        bus_mtime_we,
    input  logic        bus_mtimecmp_we,
    input  logic [31:0] bus_wdata,

    /* ---- 读出（同时供 CSR 的 mtip 比较与总线读）---- */
    output logic [31:0] mtime,
    output logic [31:0] mtimecmp
);

    /* ------------------------------ 分频 -------------------------------- */
    logic [31:0] divcnt;
    logic        tick;

    assign tick = (DIV <= 1) ? 1'b1 : (divcnt >= (DIV - 1));

    /* ------------------------------ mtime -------------------------------- */
    always_ff @(posedge clk) begin
        if (reset) begin
            divcnt <= 32'd0;
            mtime  <= 32'd0;
        end else if (csr_mtime_we) begin
            divcnt <= 32'd0;
            mtime  <= csr_wdata;
        end else if (bus_mtime_we) begin
            divcnt <= 32'd0;
            mtime  <= bus_wdata;
        end else if (tick) begin
            divcnt <= 32'd0;
            mtime  <= mtime + 32'd1;
        end else begin
            divcnt <= divcnt + 32'd1;
        end
    end

    /* ---------------------------- mtimecmp ------------------------------- */
    always_ff @(posedge clk) begin
        if (reset)                      mtimecmp <= 32'hFFFF_FFFF;
        else if (csr_mtimecmp_we)       mtimecmp <= csr_wdata;
        else if (bus_mtimecmp_we)       mtimecmp <= bus_wdata;
    end

endmodule
