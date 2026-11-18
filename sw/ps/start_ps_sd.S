/* =============================================================================
 * sw/ps/start_ps_sd.S -- Cortex-A9 裸机入口（带异常向量表）
 * -----------------------------------------------------------------------------
 * 与 start_ps.S 的区别只有一处，但很关键：**0x0 处放真正的向量表**。
 *
 * 为什么需要：
 *   裸机程序链接在 0x0000_0000，异常向量表也在 0x0。之前没有向量表，
 *   所以一旦发生数据/预取异常（例如某个外设访问回了 AXI SLVERR），
 *   CPU 会跳到 0x10 执行"恰好排在那里的普通指令"，表现为程序在某些位置
 *   **莫名其妙地断掉** —— 2026-11-18 排查 SD 控制器时就是这样丢了两小时。
 *   现在把异常接住：记下异常类型 / DFSR / DFAR 到内存日志，然后原地停住。
 *   一看日志就知道是"哪条访问、什么错误"。
 * ============================================================================= */
    .section .text.start, "ax"
    .global _start
    .type   _start, %function
_start:
    b       reset                 /* 0x00 复位                      */
    b       fault_undef           /* 0x04 未定义指令                */
    b       fault_undef           /* 0x08 软件中断（不用）          */
    b       fault_pabt            /* 0x0C 预取中止                  */
    b       fault_dabt            /* 0x10 数据中止                  */
    b       fault_undef           /* 0x14 保留                      */
    b       fault_undef           /* 0x18 IRQ（不用，MIO 里没开）   */
    b       fault_undef           /* 0x1C FIQ（不用）               */

reset:
    /* ARM 模式、禁止未对齐访问 */
    mrc     p15, 0, r0, c1, c0, 0
    bic     r0, r0, #(1 << 1)
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

2:  b       2b

/* ---- 异常处理 ---- */
fault_undef:
    mov     r0, #1
    b       fault_common
fault_pabt:
    mov     r0, #2
    b       fault_common
fault_dabt:
    mov     r0, #3
fault_common:
    ldr     sp, =_stack_top        /* 防止异常发生在栈没建好之前 */
    mov     r3, lr                 /* 异常返回地址 = 出错的那条指令附近 */
    mrc     p15, 0, r1, c5, c0, 0  /* DFSR */
    mrc     p15, 0, r2, c6, c0, 0  /* DFAR */
    bl      port_fault
3:  b       3b

    .size _start, . - _start
