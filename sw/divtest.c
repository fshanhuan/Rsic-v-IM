/* =============================================================================
 * sw/divtest.c -- 乘除法自检（不依赖外部参考值，用数学恒等式判定）
 * -----------------------------------------------------------------------------
 * 为什么查这个：CoreMark 在我们核上只跑了 59893 拍，而 x86 上同一份代码每次迭代
 * 约 18 万拍（≈10 倍工作量），且 crclist 与官方值不符。CoreMark 的数据规模是
 * `blksize / per_item`、各类循环上界都靠 `/` 和 `%` 算出来 —— 只要除法偶尔给出
 * 偏小的商，整段 benchmark 就会"少做很多活、CRC 也不对"。
 *
 * 判据（全部是恒等式，不需要参考实现）：
 *   D1 无符号： (a/b)*b + a%b == a   （b != 0）
 *   D2 有符号： (a/b)*b + a%b == a   （C99 截断语义）
 *   D3 定点值： 666/20==33  666%20==6  1000000/17==58823  0xFFFFFFFF/2==0x7FFFFFFF
 *   D4 乘法：   小范围 a*b 与"累加 b 次"结果一致；mulh 相关不测（CoreMark 不用）
 *   D5 边界：   除零不检查（RISC-V 定义商=-1、余数=被除数），这里只验 a/1、a/2、0/b
 *
 * 输出形如 D1=0 D2=0 ... ；全 0 才算乘除法无罪。
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

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

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
    if (v == 0)
    {
        putc_('0');
        return;
    }
    while (v > 0)
    {
        buf[i++] = (char)('0' + (v % 10u));
        v /= 10u;
    }
    while (i > 0)
        putc_(buf[--i]);
}

/* ---- D1：无符号恒等式 ---- */
static unsigned int d1_udiv(void)
{
    unsigned int a, b, bad = 0, checks = 0;
    for (a = 0; a < 600u; a += 7u)
    {
        for (b = 1; b < 40u; b++)
        {
            unsigned int q = a / b;
            unsigned int r = a % b;
            unsigned int back = q * b + r;
            checks++;
            if (back != a)
            {
                if (bad == 0)
                {
                    puts_("  D1 bad a=");
                    putdec_(a);
                    puts_(" b=");
                    putdec_(b);
                    puts_(" q=");
                    putdec_(q);
                    puts_(" r=");
                    putdec_(r);
                    puts_("\n");
                }
                bad++;
            }
        }
    }
    /* 几个固定值，任何人一眼能算 */
    if (666u / 20u != 33u)   bad++;
    if (666u % 20u != 6u)    bad++;
    if (1000000u / 17u != 58823u) bad++;
    if (0xFFFFFFFFu / 2u != 0x7FFFFFFFu) bad++;
    if (1000u / 1000u != 1u) bad++;
    if (0u / 5u != 0u)       bad++;
    return bad;
}

/* ---- D2：有符号恒等式（C99 向零截断） ---- */
static unsigned int d2_sdiv(void)
{
    int a, b, bad = 0;
    for (a = -300; a <= 300; a += 11)
    {
        for (b = -17; b <= 17; b++)
        {
            int q, r;
            if (b == 0)
                continue;
            q = a / b;
            r = a % b;
            if (q * b + r != a)
                bad++;
        }
    }
    /* 固定值 */
    if ((-7) / 2 != -3)  bad++;
    if ((-7) % 2 != -1)  bad++;
    if (7 / (-2) != -3)  bad++;
    if (7 % (-2) != 1)   bad++;
    return bad;
}

/* ---- D3：乘法（小范围，用累加做参考） ---- */
static unsigned int d3_mul(void)
{
    unsigned int a, b, bad = 0;
    for (a = 0; a < 100u; a++)
    {
        for (b = 0; b < 100u; b++)
        {
            unsigned int sum = 0, k;
            for (k = 0; k < b; k++)
                sum += a;
            if (a * b != sum)
                bad++;
        }
    }
    if (1234u * 5678u != 7006652u) bad++;
    return bad;
}

/* ---- D4：移位与符号扩展（CoreMark 大量用 >> 和 (ee_s16) 强转） ---- */
static unsigned int d4_shift(void)
{
    unsigned int bad = 0;
    int i;
    for (i = 0; i < 32; i++)
    {
        unsigned int v = 0x80000001u;
        if ((v >> i) != (unsigned int)(v / (1u << i) * 0u) + (v >> i))
            bad++;   /* 恒真，只为逼出编译器优化；主要看下面 */
    }
    /* 有符号右移：算术右移。
     * ★ 注意 0x8000 = 32768（正数），>>1 = 16384；只有 0x8000 0000 这种
     *   "最高位为 1" 的才是负数。（第一版这里写成 -16384，是测试自己的 bug。） */
    if ((-16) >> 2 != -4) bad++;
    if (((int)0x8000) >> 1 != 16384) bad++;
    if (((int)0x80000000) >> 1 != -1073741824) bad++;
    /* 16 位符号扩展 / 零扩展 */
    if ((int)(signed short)0x8000 != -32768) bad++;
    if ((unsigned int)(unsigned short)0x8000 != 0x8000u) bad++;
    if ((int)(signed char)0x80 != -128) bad++;
    /* 32 位左移溢出是 UB，这里只看低位 */
    if ((0x12345678u << 4) != 0x23456780u) bad++;
    return bad;
}

int main(void)
{
    unsigned int d1, d2, d3, d4;

    puts_("DIVTEST\n");

    d1 = d1_udiv();
    puts_("D1="); putdec_(d1); puts_("\n");
    d2 = d2_sdiv();
    puts_("D2="); putdec_(d2); puts_("\n");
    d3 = d3_mul();
    puts_("D3="); putdec_(d3); puts_("\n");
    d4 = d4_shift();
    puts_("D4="); putdec_(d4); puts_("\n");

    if ((d1 | d2 | d3 | d4) == 0u)
        puts_("DIVTEST-PASS\n");
    else
        puts_("DIVTEST-FAIL\n");

    DONE_FLAG = 0x5A5A5A5A;
    return 0;
}
