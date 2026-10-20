/* =============================================================================
 * sw/coremark_port/crt0.S -- 启动代码
 * -----------------------------------------------------------------------------
 * 本 SoC 的存储是**哈佛双口、两套独立地址空间**：
 *   取指：irom（只读，地址从 0 开始）        数据：dram（读写，地址从 0 开始）
 * 所以链接脚本把 .text 放 irom[0..)、把 .rodata/.data/.bss 放 dram[0x10000..)，
 * 两者在**数值上**不重叠即可（不需要拷 .data：数据镜像由仿真台预装进 DRAM）。
 *
 * ★ 因此这里**没有** .data 从 LMA 拷到 VMA 的那段（普通哈佛平台必须有，
 *   我们做不到：lw 读不到 IROM）。上板时数据镜像要么由引导程序写 DRAM，
 *   要么由程序自己从串口收 —— 见 docs/COREMARK.md 的说明。
 * ============================================================================= */
    .section .text.init, "ax"
    .globl _start
    .type  _start, @function
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, _stack_top

    /* 清 .bss（.data 已由镜像预装，不需要拷） */
    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    /* main 返回：写 magic 到 0x1000_00F0，仿真台据此停机。
     * 板上这个地址无副作用（mmio_idx 未定义 → 写被忽略），程序停在这里等看门狗。 */
    li      t0, 0x100000F0
    li      t1, 0x5A5A5A5A
    sw      t1, 0(t0)
3:
    j       3b
    .size _start, . - _start
