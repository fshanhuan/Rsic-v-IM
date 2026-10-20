/* =============================================================================
 * sw/fenceitest.c -- fence.i 的最小复现/验收程序
 * -----------------------------------------------------------------------------
 * 背景：v16 里 monitor 的 `load`/`run` 命令各自插了一条 fence.i（`.word 0x0000100f`），
 *   上板/仿真都在执行到它之后**不再响应**（没有 banner 重启、也没有后续输出）。
 *   但 `tb_sys fencei` 是过的 —— 说明那个测试只覆盖了"能退休、不崩"，没覆盖
 *   "fence.i 之后还能继续取指执行"。
 *
 * 这个程序就是补上那条：四段打印，fence.i 夹在中间，最后写 DONE_FLAG。
 *   F1  进入（证明程序起来了）
 *   fence.i
 *   F2  关键判据：**能到 F2 就说明 fence.i 之后流水线还在正常工作**
 *   (再来一次，fence.i 紧跟一条 store 之后的场景)
 *   F3
 *   fence.i 在循环里（重复执行同一个 fence.i）
 *   F4 / FENCEITEST-PASS
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define DONE_FLAG   (*(volatile unsigned int *)0x100000f0u)

static void putc_(char c)
{
    while (UART_TXSTAT & 1u)
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
}

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

#define FENCE_I() __asm volatile(".word 0x0000100f" ::: "memory")

int main(void)
{
    volatile unsigned int i;
    volatile unsigned int acc = 0;

    puts_("F1\n");

    /* 1) 裸 fence.i，前后都是普通指令 */
    FENCE_I();
    puts_("F2\n");

    /* 2) store 之后紧跟 fence.i（store 可能还在流水里） */
    acc = 0x1234;
    FENCE_I();
    puts_("F3\n");

    /* 3) 循环里重复执行 fence.i（同一地址多条） */
    for (i = 0; i < 4u; i++) {
        acc += i;
        FENCE_I();
    }
    puts_("F4\n");

    if (acc != 0x1234u + 0u + 1u + 2u + 3u) {
        puts_("FENCEITEST-BADACC\n");
        DONE_FLAG = 0x5A5A5A5A;
        return 1;
    }
    puts_("FENCEITEST-PASS\n");
    DONE_FLAG = 0x5A5A5A5A;
    return 0;
}
