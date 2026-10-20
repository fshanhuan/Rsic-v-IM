/* =============================================================================
 * sw/timertest.c -- 最小定时器中断测试（不经过任何 RTOS/端口）
 * -----------------------------------------------------------------------------
 * 为什么需要：FreeRTOS 里 mstatus.MIE=1、mie.MTIE=1，但几百万拍内一次中断都没进
 * （intr=0）。要分清是"CPU 的定时器中断不工作"还是"FreeRTOS 端口没配好"，
 * 这个程序做了最小闭环：
 *
 *   1) 设 mtvec = handler
 *   2) mtimecmp = mtime + 500（本核 mtime 500kHz → 每 1ms 一次）
 *   3) mie.MTIE=1、mstatus.MIE=1
 *   4) 主循环：每收到一次中断，把计数写到串口；收到 5 次后打印 PASS 并结束
 *
 * handler 里必须**重新装** mtimecmp（写新值即清中断），否则只会进一次。
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
static void putdec_(unsigned int v)
{
    char b[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v > 0) { b[i++] = (char)('0' + v % 10u); v /= 10u; }
    while (i > 0) putc_(b[--i]);
}
static void puthex_(unsigned int v)
{
    int i;
    puts_("0x");
    for (i = 7; i >= 0; i--)
        putc_(digits[(v >> (i * 4)) & 0xF]);
}

static volatile unsigned int g_ticks = 0;
static volatile unsigned int g_traps = 0;

/* ---- 陷入入口：只是普通函数，用 mtvec 指过来 ---- */
void trap_entry(void)
{
    unsigned int mcause, mtime;

    __asm volatile("csrr %0, 0x342" : "=r"(mcause));
    g_traps++;

    if (mcause == 0x80000007u)          /* machine timer interrupt */
    {
        unsigned int cmp;
        __asm volatile("csrr %0, 0x7c0" : "=r"(mtime));
        putc_('@');
        puthex_(mtime);                  /* 每次进中断都打当前 mtime：看它有没有在走 */
        mtime += 500u;                   /* 1 ms @ 500kHz */
        __asm volatile("csrw 0x7c1, %0" ::"r"(mtime));
        __asm volatile("csrr %0, 0x7c1" : "=r"(cmp));
        putc_('/');
        puthex_(cmp);                    /* 回读 mtimecmp：看写有没有落地 */
        putc_('\n');
        g_ticks++;
    }
    else
    {
        puts_("unexpected mcause=");
        puthex_(mcause);
        puts_("\n");
        DONE_FLAG = 0x5A5A5A5A;
    }
    __asm volatile("mret");
}

int main(void)
{
    unsigned int mtime, mstatus;
    int          guard;
    int          no_int = 0;

    puts_("TIMERTEST\n");

#ifdef NO_INTERRUPT
    /* 对照组：不使能中断，但跑**同样长度**的 guard 循环。
     * 若这一版耗时 ~10M 拍、开中断那版只有 ~50k 拍，就说明"中断返回后程序跳过了循环"。 */
    no_int = 1;
#endif

    __asm volatile("csrw 0x305, %0" ::"r"(trap_entry));   /* mtvec */
    __asm volatile("csrr %0, 0x7c0" : "=r"(mtime));
    if (no_int)
        mtime += 0x40000000u;            /* 远到不会触发 */
    else
        mtime += 500u;
    __asm volatile("csrw 0x7c1, %0" ::"r"(mtime));        /* 第一次比较值 */
    if (!no_int)
    {
        __asm volatile("csrs 0x304, %0" ::"r"(0x80u));    /* mie.MTIE */
        __asm volatile("csrs 0x300, %0" ::"r"(0x8u));     /* mstatus.MIE */
    }
    __asm volatile("csrr %0, 0x300" : "=r"(mstatus));
    puts_("mstatus="); puthex_(mstatus); puts_("\n");

    /* 等 5 次中断；guard 防止死等（每次迭代约 4 拍，2e6 次 ≈ 8M 拍） */
    for (guard = 0; guard < 2000000; guard++)
    {
        if (g_ticks >= 5u)
            break;
        __asm volatile("nop");
    }

    puts_("ticks="); putdec_(g_ticks);
    puts_(" traps="); putdec_(g_traps);
    puts_("\n");

    /* 结尾把相关 CSR 全打出来：判断到底是"没挂起"还是"挂起了不让进" */
    {
        unsigned int t, c, mi, mp, ms;
        __asm volatile("csrr %0, 0x7c0" : "=r"(t));
        __asm volatile("csrr %0, 0x7c1" : "=r"(c));
        __asm volatile("csrr %0, 0x304" : "=r"(mi));
        __asm volatile("csrr %0, 0x344" : "=r"(mp));
        __asm volatile("csrr %0, 0x300" : "=r"(ms));
        puts_("mtime=");   puthex_(t);  puts_("\n");
        puts_("mtimecmp=");puthex_(c);  puts_("\n");
        puts_("mie=");     puthex_(mi); puts_("\n");
        puts_("mip=");     puthex_(mp); puts_("\n");
        puts_("mstatus="); puthex_(ms); puts_("\n");
    }

    if (g_ticks >= 5u)
        puts_("TIMERTEST-PASS\n");
    else
        puts_("TIMERTEST-FAIL\n");

    DONE_FLAG = 0x5A5A5A5A;
    return 0;
}
