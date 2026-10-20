/* =============================================================================
 * sw/hello.c -- C 工具链的最小自检程序（不依赖 CoreMark 的移植层）
 * -----------------------------------------------------------------------------
 * 它一次验证四件事，任何一件错了都会在同一行输出里看出来：
 *   1) .text 能被取指口读到（能跑起来才算）；
 *   2) .data 的**初值**被正确装进 DRAM（数据镜像是单独一帧，见 boot_loader.sv）；
 *   3) .bss 被 crt0 清零（8 个 word 全 0）；
 *   4) 函数调用/栈/参数传递正常（puthex 是独立函数，走 a0 传参 + ra 返回）。
 *
 * 输出格式刻意用十进制 + 十六进制两行，便于肉眼对：
 *     HELLO
 *     DATA=5          (g_data[0]+g_data[3] = 1+4)
 *     BSS=0           (8 个零相加)
 *     OK
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define DONE_FLAG   (*(volatile unsigned int *)0x100000f0u)

static void putc_(char c)
{
    while (UART_TXSTAT & 1u)      /* 忙时写会被硬件丢弃，必须等 */
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
}

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static void puthex_(unsigned int v)
{
    const char *digits = "0123456789abcdef";
    int i;
    puts_("0x");
    for (i = 7; i >= 0; i--)
        putc_(digits[(v >> (i * 4)) & 0xF]);
}

/* .data：必须由数据镜像预装进 DRAM，改成运行时赋值就失去意义了 */
volatile unsigned int g_data[4] = {1u, 2u, 3u, 4u};
/* .bss：必须被 crt0 清零 */
volatile unsigned int g_bss[8];

int main(void)
{
    unsigned int sum = 0;
    int i;

    puts_("HELLO\n");

    puts_("DATA=");
    puthex_(g_data[0] + g_data[3]);          /* 期望 0x00000005 */
    puts_("\n");

    for (i = 0; i < 8; i++)
        sum += g_bss[i];
    puts_("BSS=");
    puthex_(sum);                            /* 期望 0x00000000 */
    puts_("\n");

    puts_("OK\n");
    DONE_FLAG = 0x5A5A5A5A;                  /* 让仿真台停机（crt0 里也有一份） */
    return 0;
}
