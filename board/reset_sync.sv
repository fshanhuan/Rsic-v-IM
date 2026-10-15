`timescale 1ns / 1ps

/* =============================================================================
 * reset_sync.sv — 「异步置位、同步释放」的复位同步器
 * -----------------------------------------------------------------------------
 * 为什么需要它：板卡按键复位是**异步**的（按下时刻与时钟无关）。直接把它当同步
 *   复位喂给 CPU 里成百上千个 `always_ff @(posedge clock) if (reset)`，置位时刻就
 *   与时钟无关，不同寄存器可能在不同拍被清掉；而且触发器的复位恢复/移除时间
 *   （recovery/removal）会被违反，属于典型的亚稳态风险。
 *
 * ★ 不变量：
 *   - 置位（assert）走**异步**通路：rst_n_async 一低，两个同步触发器立刻清零 →
 *     输出立刻有效，不用等时钟。这就是敏感表里 `or negedge rst_n_async` 的作用，
 *     删掉它只剩同步置位（要等一拍，按键窄脉冲还可能被整个漏掉）。
 *   - 释放（deassert）走**同步**通路：按键松开后先经两级触发器同步进 clk 域，
 *     两个触发器一起释放，保证全芯片寄存器的复位释放落在同一个时钟沿，
 *     不会出现"部分先释放、部分后释放"。
 *   - 输入 rst_n_async 是**低有效**（板卡按键上拉、按下接地），
 *     输出 rst_sync 是**高有效**：rst_sync = ~sync_ff2，正好对上 v9 全工程
 *     `if (reset)` 的同步高有效约定。极性不能反 —— 反了整个 CPU 会常驻复位。
 *
 * 上板连线：.clk(sys_clk，与 CPU 同源) / .rst_n_async(btn_rst_n，低有效) /
 *   .rst_sync(cpu_rst → myCPU.cpu_rst)。
 * =========================================================================== */
module reset_sync (
    input  logic clk,
    input  logic rst_n_async,
    output logic rst_sync
);

    // 两级同步寄存器：异步置位、同步释放。（(* async_reg *) 提示工具把这两级放近、
    //   别合并/优化掉 —— 它们是抗亚稳态链，不是普通打拍。）
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

    // ★ 不变量：输出取反 —— 内部 0 表示"复位有效"，对外的高有效 rst_sync=1 才是在复位。
    assign rst_sync = ~sync_ff2;

endmodule
