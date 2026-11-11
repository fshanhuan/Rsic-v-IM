/* =============================================================================
 * sw/ps/start_ps.S -- Cortex-A9 裸机入口（PS 侧）
 * -----------------------------------------------------------------------------
 * 只用三件事：设栈、清 .bss、调 main。ARM 不需要像 RISC-V 那样保存调用者的 gp，
 * 但这个程序是"被 JTAG 调试器 dow 之后直接 con"跑的，所以：
 *   · 栈顶用一个确定地址（_stack_top，来自链接脚本，OCM 顶端）；
 *   · 不清 .bss 之外的任何东西（PS 的 PLL/MIO 由 ps7_init 负责，不在这里做）。
 * ============================================================================= */
    .section .text.start, "ax"
    .global _start
    .type   _start, %function
_start:
    /* ARM 模式、禁止未对齐访问（Cortex-A9 默认允许，这里显式关掉，行为可预测） */
    mrc     p15, 0, r0, c1, c0, 0
    bic     r0, r0, #(1 << 1)        /* A bit = 0 : 未对齐访问 → 异常 */
    mcr     p15, 0, r0, c1, c0, 0

    ldr     sp, =_stack_top

    /* 清 .bss */
    ldr     r0, =__bss_start
    ldr     r1, =__bss_end
    mov     r2, #0
1:  cmp     r0, r1
    strlo   r2, [r0], #4
    blo     1b

    bl      main

2:  b       2b                        /* main 返回：停在这里（不返回 BootROM） */
    .size _start, . - _start
