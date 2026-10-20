/* =============================================================================
 * sw/board_ping.c -- 上板冒烟测试：每 0.5 s 打印一次 "PING <计数> <mtime>"
 * -----------------------------------------------------------------------------
 * 为什么需要它：引导成功与否只能看串口有没有输出，而"打印一次就结束"的程序
 * 很容易被"宿主机还在灌数据、没开始读"这一段吃掉。这个程序**永久循环打印**，
 * 所以只要板子起来了，任何时刻开始监听都能看到东西。
 *
 * 顺带验证：mtime 走时（用它做延时）、DCache 读写（计数在内存里）、UART 发送。
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define LED_REG     (*(volatile unsigned int *)0x10000010u)

static const char digits[] = "0123456789abcdef";

static void putc_(char c)
{
    while (UART_TXSTAT & 1u)
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex_(unsigned int v)
{
    int i;
    puts_("0x");
    for (i = 7; i >= 0; i--)
        putc_(digits[(v >> (i * 4)) & 0xF]);
}

static unsigned int rd_mtime(void)
{
    unsigned int v;
    __asm volatile("csrr %0, 0x7c0" : "=r"(v));
    return v;
}

static volatile unsigned int g_cnt;
static volatile unsigned int g_arr[64];

int main(void)
{
    unsigned int i;

    /* 先把一个 64 字的数组写满再读回（顺带压一下 DCache 的写/读路径） */
    for (i = 0; i < 64u; i++)
        g_arr[i] = i * 7u + 3u;
    for (i = 0; i < 64u; i++)
        if (g_arr[i] != i * 7u + 3u)
            puts_("ARRBAD\n");

    for (;;)
    {
        unsigned int t0, t;
        g_cnt++;
        LED_REG = g_cnt & 0x7Fu;

        puts_("PING ");
        puthex_(g_cnt);
        puts_(" t=");
        puthex_(rd_mtime());
        puts_("\n");

        /* 0.5 s @ 500 kHz = 250000 个 mtime 计数 */
        t0 = rd_mtime();
        do { t = rd_mtime(); } while ((t - t0) < 250000u);
    }
    return 0;
}
