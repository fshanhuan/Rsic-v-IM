/* =============================================================================
 * sw/ps/stub.S — stage-0 装载器（双核协同 第 1 步）
 * -----------------------------------------------------------------------------
 * 它住在 IROM 的**顶部 1 KB**（0xFC00），复位向量 0x0 只有一条 `j`。
 * 为什么要放到顶部：它要把镜像抄进代码窗口 0x2_0000 起的低地址区，如果它自己
 *   也在低地址区，抄到一半就把自己覆盖掉了（经典的自我修改陷阱）。
 *   镜像最大 24 KB（0xA000..0xFFFF 那块），抄完是 0x2_0000..0x2_5FFF，
 *   离 0xFC00 还远。
 *
 * 与 PS 的约定（见 sw/ps/riscv_loader.c）：
 *   DRAM[0xA000] = 镜像字数 N（<= 6144）
 *   DRAM[0xA004..] = N 个字（就是 monitor 的 .text，按字）
 *   PS 先把 .rodata 灌到 0x1_0000、把 .bss 清零，再写 HOLD=0 放行。
 *
 * 做完两件事：
 *   ① 把 N 个字抄到 0x2_0000（= IMEM word 0..N-1）
 *   ② 往 MMIO 0x1000_001C 写 bit2（"CPU 已到岗"，PS 侧可读 STATUS[6]）
 *   然后 `jal 0` —— 从 IMEM word 0 开始跑 monitor。
 *
 * 为什么 CPU 侧不自己清 .bss：stub 不知道 .bss 在哪（那是链接期信息），
 *   让 PS 顺手写 188 个零更便宜，而且这本来就是"主机准备环境"的职责。
 * ============================================================================= */

    .section .init, "ax"
    .globl _start
_start:
    j       stub                    /* 复位向量 0x0：一条跳转，占 4 字节 */

    /* 剩下的 0x04..0xFBFF 由链接脚本留空（$readmemh 读到 0 即 nop/非法，
     * 反正执行不到）。 */

    .section .stub, "ax"
    .globl stub
stub:
    li      a1, 0x0000A000          /* DRAM 里镜像描述符的地址 */
    lw      a0, 0(a1)               /* a0 = 字数 N */
    addi    a1, a1, 4               /* a1 -> 镜像首字 */

    /* 夹紧：N 超过 6144 就当 6144（防 PS 写了个垃圾值把 64 KB IMEM 抄穿） */
    li      t2, 6144
    bltu    a0, t2, 1f
    mv      a0, t2
1:
    li      a2, 0x00020000          /* 代码窗口基址（= IMEM word 0） */
    beqz    a0, 2f                  /* N == 0：什么都不抄，直接跳（调试用） */

3:  lw      t0, 0(a1)
    sw      t0, 0(a2)
    addi    a1, a1, 4
    addi    a2, a2, 4
    addi    a0, a0, -1
    bnez    a0, 3b

2:  fence.i                         /* 清 ICache（写指令区之后的必备动作） */

    /* 报平安：MMIO 0x1000_001C bit2 = 1 → ps_ctrl 的 STATUS[6] = ALIVE */
    li      a3, 0x10000000
    li      t1, 4
    sw      t1, 0x1C(a3)

    jal     zero, 0                 /* 从 IMEM word 0 开始跑 monitor */
