/* =============================================================================
 * sw/multest.c -- 32 位乘法自检（用"移位加法"做参考实现，不依赖乘法本身）
 * -----------------------------------------------------------------------------
 * 为什么单独查乘法：CoreMark 崩在 `lw a5,-1776(s8)` 这种地址上，说明 s8 的
 * **指针算错了**（落成 2 字节对齐）。这类地址大量来自 `i * sizeof(struct)`，
 * 也就是 mul。而 divtest 里的乘法只覆盖了 0..99 的小操作数。
 *
 * 判据：
 *   M1 无符号：a*b == shift_add(a,b)      （伪随机 32 位操作数）
 *   M2 有符号：a*b == 由无符号结果按符号修正
 *   M3 特值：0x80000000*2、0xFFFFFFFF*0xFFFFFFFF、1<<31 等边界
 *   M4 mulh/mulhu 不测（RV32IM 里 gcc 不用，CoreMark 也不用）
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
static void putdec_(unsigned int v)
{
    char buf[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v > 0) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i > 0) putc_(buf[--i]);
}

/* 参考实现：移位加法，只用加/移位 */
static unsigned int shift_add(unsigned int a, unsigned int b)
{
    unsigned int r = 0;
    int i;
    for (i = 0; i < 32; i++)
    {
        if ((b >> i) & 1u)
            r += (a << i);
    }
    return r;
}

static unsigned int g_seed = 0x12345678u;
static unsigned int lcg(void)
{
    g_seed = g_seed * 1103515245u + 12345u;
    return g_seed;
}

static unsigned int m1_umul(void)
{
    unsigned int i, bad = 0;
    for (i = 0; i < 300u; i++)
    {
        unsigned int a = lcg();
        unsigned int b = lcg();
        if (a * b != shift_add(a, b))
        {
            if (bad == 0)
            {
                puts_("  M1 bad a="); puthex_(a);
                puts_(" b="); puthex_(b);
                puts_(" got="); puthex_(a * b);
                puts_(" exp="); puthex_(shift_add(a, b));
                puts_("\n");
            }
            bad++;
        }
    }
    return bad;
}

static unsigned int m2_smul(void)
{
    int i, bad = 0;
    for (i = -120; i <= 120; i += 7)
    {
        int j;
        for (j = -120; j <= 120; j += 11)
        {
            int p = i * j;
            int ref = 0;
            int k;
            /* 参考：按符号展开成整数累加 */
            if (i >= 0 && j >= 0)
                ref = (int)shift_add((unsigned)i, (unsigned)j);
            else if (i < 0 && j >= 0)
                ref = -(int)shift_add((unsigned)(-i), (unsigned)j);
            else if (i >= 0 && j < 0)
                ref = -(int)shift_add((unsigned)i, (unsigned)(-j));
            else
                ref = (int)shift_add((unsigned)(-i), (unsigned)(-j));
            (void)k;
            if (p != ref)
                bad++;
        }
    }
    return bad;
}

static unsigned int m3_edge(void)
{
    unsigned int bad = 0;
    if (0x80000000u * 2u != 0u)              bad++;
    if (0xFFFFFFFFu * 0xFFFFFFFFu != 1u)     bad++;
    if (0x10000u * 0x10000u != 0u)           bad++;
    if (0x7FFFFFFFu * 0x7FFFFFFFu != 1u)     bad++;
    if (12345u * 6789u != 83810205u)         bad++;
    /* 指针运算的典型形状：i * sizeof(struct) */
    if ((unsigned)(17 * 24) != 408u)         bad++;
    if ((unsigned)(31 * 8) != 248u)          bad++;
    if ((unsigned)((int)-5 * (int)4) != (unsigned)-20) bad++;
    return bad;
}

int main(void)
{
    unsigned int m1, m2, m3;
    puts_("MULTEST\n");
    m1 = m1_umul();  puts_("M1="); putdec_(m1); puts_("\n");
    m2 = m2_smul();  puts_("M2="); putdec_(m2); puts_("\n");
    m3 = m3_edge();  puts_("M3="); putdec_(m3); puts_("\n");
    if ((m1 | m2 | m3) == 0u)
        puts_("MULTEST-PASS\n");
    else
        puts_("MULTEST-FAIL\n");
    DONE_FLAG = 0x5A5A5A5A;
    return 0;
}
