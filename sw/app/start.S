/* =============================================================================
 * sw/app/start.S -- 从 shell 启动的 C 应用的入口桩（P1-1 的最后一块）
 * -----------------------------------------------------------------------------
 * 为什么需要它（这是 "run <name> 打不出 HELLO-APP、反而重打 shell 横幅" 的根因）：
 *   应用是被 shell 用 `jalr` **直接跳进 main** 的，此时：
 *     · gp = shell 的 __global_pointer$（指向 shell 的 .data），应用的全局变量
 *       一访问就是 shell 的数据；
 *     · sp = shell 的栈，应用的深层调用/局部数组会和 shell 的栈帧叠在一起；
 *     · .bss 没人清（shell 不知道应用多大）。
 *   任何一条踩中都会让应用跑飞 -> 异常 -> mtvec=0 -> 从 0 重启 -> 又见到横幅。
 *
 * 本桩只做四件事（并且全部在**应用自己的**数据区里完成）：
 *   1. 把 shell 的 gp/ra/sp 存进应用 .data 里的 app_shell_ctx；
 *   2. gp = 应用的 __global_pointer$，sp = 应用自己的栈顶 __app_stack_top；
 *   3. 清应用的 .bss；
 *   4. call main，返回后把 shell 的 gp/ra/sp 原样还回去，ret 回 shell。
 *
 * ★ 三条硬约束（改这个文件前先读）：
 *   · app_shell_ctx 必须放 **.data** 而不是 .bss：上面第 3 步清 .bss 会把它擦掉，
 *     函数返回时就会带着 gp=0 回 shell（shell 立刻崩）。
 *   · 本文件的代码必须排在 .text 最前面（链接脚本 KEEP(*(.text.start))），
 *     因为容器头里记录的入口就是镜像基址 0x0000_5000 本身。
 *   · 保存/恢复用 t0 做基址：t0 是 caller-saved，main 可以随便改。
 * ============================================================================= */
    .section .text.start, "ax", @progbits
    .globl _start
    .type  _start, @function
_start:
    /* 1. 保存 shell 的上下文（应用的数据区此时已经由 shell 灌好了） */
    la      t0, app_shell_ctx
    sw      gp, 0(t0)
    sw      ra, 4(t0)
    sw      sp, 8(t0)

    /* 2. 换成应用自己的 gp / sp */
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __app_stack_top

    /* 3. 清应用自己的 .bss（.data 已由容器镜像写好，不拷） */
    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    /* 4. 还原 shell 的上下文，ret 回去 */
    la      t0, app_shell_ctx
    lw      gp, 0(t0)
    lw      ra, 4(t0)
    lw      sp, 8(t0)
    ret
    .size _start, . - _start

    .section .data
    .align 4
    .globl app_shell_ctx
app_shell_ctx:
    .word 0
    .word 0
    .word 0
