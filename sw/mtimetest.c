/* =============================================================================
 * sw/mtimetest.c -- mtime 走时自检（只读，不发中断）
 * -----------------------------------------------------------------------------
 * 背景：timertest 里第一次中断之后 mtime 就停在读到的那个值（0x1fa）不再增长。
 * 怀疑"读 mtime 这条 CSR 指令顺带把它写回/卡住"。这里做一个最小对照：
 *   1) 读 mtime → 打印
 *   2) 空转约 20000 拍（mtime 应前进约 200）
 *   3) 再读 mtime → 打印
 *   4) 再读一次 mcycle，确认"拍"确实在涨（排除程序没在跑）
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define DONE_FLAG   (*(volatile unsigned int *)0x100000f0u)

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
static unsigned int rd_mcycle(void)
{
    unsigned int v;
    __asm volatile("csrr %0, 0xb00" : "=r"(v));
    return v;
}

int main(void)
{
    unsigned int t0, t1, c0, c1;
    volatile unsigned int i;

    puts_("MTIMETEST\n");

    c0 = rd_mcycle();
    t0 = rd_mtime();

    /* ★ 关键对照：如果不发中断、只做一次 `csrw mtimecmp`（把比较值放到很远的未来），
     *   mtime 还会不会继续走？timertest 里第一次中断之后 mtime 就冻住了，
     *   所以这里单独隔离"写 mtimecmp"这个动作。 */
    {
        unsigned int far = t0 + 0x1000000u;   /* 远到不会触发中断 */
        __asm volatile("csrw 0x7c1, %0" ::"r"(far));
    }

    for (i = 0; i < 4000u; i++)
        ;                       /* 约 12000~20000 拍 */

    t1 = rd_mtime();
    c1 = rd_mcycle();

    puts_("mcycle0="); puthex_(c0); puts_("\n");
    puts_("mcycle1="); puthex_(c1); puts_("\n");
    puts_("mtime0=");  puthex_(t0); puts_("\n");
    puts_("mtime1=");  puthex_(t1); puts_("\n");

    if (c1 > c0 && t1 > t0)
        puts_("MTIMETEST-PASS\n");
    else
        puts_("MTIMETEST-FAIL\n");

    DONE_FLAG = 0x5A5A5A5A;
    return 0;
}
