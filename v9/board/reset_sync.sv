`timescale 1ns / 1ps

/* =============================================================================
 * reset_sync.sv — 「异步置位、同步释放」的复位同步器
 * -----------------------------------------------------------------------------
 * 为什么需要它：
 *   板卡按键复位是**异步**的（按下时刻与时钟无关）。如果把它直接当同步复位
 *   喂给 CPU 里成百上千个 `always_ff @(posedge clock) if (reset)`，
 *   复位的**置位时刻**就与时钟无关，不同寄存器可能在不同拍被清掉，
 *   而且触发器的复位恢复时间（recovery/removal）会被违反，属于典型的
 *   亚稳态风险。
 *
 * 做法（标准两级同步器）：
 *   - 置位（assert）走**异步**通路：rst_n_async 一低，输出立刻为低，
 *     保证按键一按下就进复位，不需要等时钟；
 *   - 释放（deassert）走**同步**通路：按键松开后，先经两级触发器同步到
 *     clk 域，再一起释放。这样所有寄存器的复位释放都发生在同一个时钟沿，
 *     不会出现“部分先释放、部分后释放”。
 *
 * 复位极性：
 *   输入 rst_n_async 是**低有效**（板卡按键一般接成按下拉低），
 *   输出 rst_sync 是**高有效**，正好对上 v9 全工程
 *   `always_ff @(posedge clock) if (reset) ...` 的同步高有效复位约定。
 *
 * 上板连线建议：
 *   .clk        (sys_clk)        // 与 CPU 同一时钟
 *   .rst_n_async(btn_rst_n)      // 按键，低有效
 *   .rst_sync   (cpu_rst)        // 送 myCPU.cpu_rst
 * =========================================================================== */
module reset_sync (
    input  logic clk,
    input  logic rst_n_async,
    output logic rst_sync
);

    // 两级同步寄存器：异步置位、同步释放
    (* async_reg = "true" *) logic sync_ff1;
    (* async_reg = "true" *) logic sync_ff2;

    always_ff @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) begin
            sync_ff1 <= 1'b0;
            sync_ff2 <= 1'b0;
        end else begin
            sync_ff1 <= 1'b1;
            sync_ff2 <= sync_ff1;
        end
    end

    assign rst_sync = ~sync_ff2;

endmodule
