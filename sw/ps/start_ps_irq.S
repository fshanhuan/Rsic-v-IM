/* =============================================================================
 * sw/ps/start_ps_irq.S -- Cortex-A9 裸机入口（**带中断向量表**，第 3 步专用）
 * -----------------------------------------------------------------------------
 * 与 start_ps.S 的区别只有一条：这个版本在 0x0 放了一张 ARM 异常向量表，
 * 因为要用 FPGA 送来的 IRQ_F2P 中断（RISC-V → PS）。
 *
 * Cortex-A9 复位后 VBAR = 0x0，而我们的裸机程序正好链接在 OCM 0x0 ——
 * 所以向量表放在最前面就能被硬件取到，不需要写 VBAR。
 *
 * 布局（每个向量 4 字节）：
 *   0x00 复位    b _start
 *   0x04 未定义  b .            （死循环：真出了就是 bug，停下来比乱跑好排查）
 *   0x08 SVC     b .
 *   0x0c 预取异常 b .
 *   0x10 数据异常 b .
 *   0x14 保留    b .
 *   0x18 IRQ     b irq_handler  ★ 只有这个是有用的
 *   0x1c FIQ     b .
 *
 * IRQ 处理约定：
 *   · IRQ 模式有自己的栈（_irq_stack_top，在 _start 里切过去设好）；
 *   · 保存 r0-r3/r12/lr，调 C 的 gic_irq_handler()，回来 movs pc,lr；
 *   · 进 IRQ 时 lr = 被中断指令 + 4，所以要先减 4（ARMv7 标准做法）。
 * ============================================================================= */

    .section .vectors, "ax"
    .global _vectors
_vectors:
    b       _start                  /* 0x00 reset            */
    b       .                       /* 0x04 undefined        */
    b       .                       /* 0x08 SVC              */
    b       .                       /* 0x0c prefetch abort   */
    b       .                       /* 0x10 data abort       */
    b       .                       /* 0x14 reserved         */
    b       irq_handler             /* 0x18 IRQ   <-- 我们用的 */
    b       .                       /* 0x1c FIQ              */

    .section .text.start, "ax"
    .global _start
    .type   _start, %function
_start:
    /* 关未对齐访问（A=0） */
    mrc     p15, 0, r0, c1, c0, 0
    bic     r0, r0, #(1 << 1)
    mcr     p15, 0, r0, c1, c0, 0

    /* 给 IRQ 模式准备一个栈：切到 IRQ(0x12) 设 sp，再切回 SVC(0x13) */
    mrs     r0, cpsr
    bic     r1, r0, #0x1F
    orr     r1, r1, #0x12
    msr     cpsr_c, r1
    ldr     sp, =_irq_stack_top
    msr     cpsr_c, r0

    ldr     sp, =_stack_top

    ldr     r0, =__bss_start
    ldr     r1, =__bss_end
    mov     r2, #0
1:  cmp     r0, r1
    strlo   r2, [r0], #4
    blo     1b

    bl      main

2:  b       2b
    .size _start, . - _start

    .section .text, "ax"
    .global irq_handler
    .type   irq_handler, %function
irq_handler:
    sub     lr, lr, #4              /* 回到被中断的那条指令 */
    push    {r0-r3, r12, lr}
    bl      gic_irq_handler
    pop     {r0-r3, r12, lr}
    movs    pc, lr                  /* 恢复 CPSR 并返回 */
    .size irq_handler, . - irq_handler
