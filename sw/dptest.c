/* =============================================================================
 * sw/dptest.c -- IROM 数据窗口（0x0002_0000）自检：证明 `lw` 读得到自己的代码
 * -----------------------------------------------------------------------------
 * 背景：本核是哈佛结构 —— 取指走 IROM，访存走 DRAM。v14 给 IROM 加了**第二读口**
 *   并映射到数据地址 0x0002_0000..0x0002_FFFF（= IROM 字 [addr[15:2]]），
 *   于是软件第一次能"读自己的代码/常量"。这个程序就是那条通路的验收判据。
 *
 * 判据（全部为 0 才算通过）：
 *   D1 代码校验和：把窗口前 64 个字算一个 djb2 风格的校验和，与链接期算好、
 *      放在 .data（DRAM）里的期望值比对。★ 期望值必须是"变量"而不是立即数，
 *      否则编译器会把它编进 .text，校验和就自我指涉、永远对不上
 *      （build_dptest.sh 的两遍编译就是为这个准备的）。
 *   D2 指令合法性：窗口第 0 个字（= 复位向量那条指令）低 2 位必须是 2'b11
 *      （RV32 一定是 32 位编码；不对说明读回来的根本不是指令）。
 *   D3 幂等性：同一地址连读两次必须相等（读不能有副作用 —— 这也是 P4 的判据）。
 *   D4 字节通路：对同一字用 lbu 分别读 4 个字节，拼起来必须等于 lw 读到的字。
 *
 * 输出：DPTEST / D1..D4 / CK=0x........ / DPTEST-PASS|DPTEST-FAIL
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define DONE_FLAG   (*(volatile unsigned int *)0x100000f0u)

/* IROM 数据窗口基址（与 board_top 的 irom_win_sel 译码一致） */
#define IROM_WIN    ((volatile unsigned int *)0x00020000u)
#define IROM_WIN_B  ((volatile unsigned char *)0x00020000u)
#define CK_WORDS    64u

/* ★ 由 sw/build_dptest.sh 两遍编译回填；必须是**可写变量**（落在 .data / DRAM），
 *   不能是 #define 立即数 —— 立即数会进 .text，改变 .text 就改变了被校验的数据本身。 */
volatile unsigned int dp_expect_ck = 0x5E2E3BBD;

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
        buf[i++] = digits[v % 10u];
        v /= 10u;
    }
    while (i > 0)
        putc_(buf[--i]);
}

static void puthex_(unsigned int v)
{
    int i;
    puts_("0x");
    for (i = 7; i >= 0; i--)
        putc_(digits[(v >> (i * 4)) & 0xF]);
}

/* djb2：校验和必须与 build_dptest.sh 里的 python 实现逐位一致 */
static unsigned int cksum_window(void)
{
    unsigned int i, ck = 5381u;
    for (i = 0; i < CK_WORDS; i++)
        ck = (ck << 5) - ck + IROM_WIN[i];
    return ck;
}

int main(void)
{
    unsigned int ck, d1, d2, d3, d4;
    unsigned int w0, a, b, rebuilt;
    unsigned int i;

    puts_("DPTEST\n");

    /* ---- D1：代码校验和 ---- */
    ck = cksum_window();
    d1 = (ck == dp_expect_ck) ? 0u : 1u;
    puts_("D1="); putdec_(d1); puts_("\n");
    puts_("CK="); puthex_(ck); puts_("\n");
    if (d1)
    {
        puts_("  exp="); puthex_(dp_expect_ck); puts_("\n");
    }

    /* ---- D2：复位向量那条指令必须是 32 位编码 ---- */
    w0 = IROM_WIN[0];
    d2 = ((w0 & 3u) == 3u) ? 0u : 1u;
    puts_("D2="); putdec_(d2); puts_("\n");
    puts_("W0="); puthex_(w0); puts_("\n");

    /* ---- D3：幂等（连读两次） ---- */
    d3 = 0;
    for (i = 0; i < 16u; i++)
    {
        a = IROM_WIN[i];
        b = IROM_WIN[i];
        if (a != b)
            d3++;
    }
    puts_("D3="); putdec_(d3); puts_("\n");

    /* ---- D4：字节通路（lbu ×4 拼回 lw） ---- */
    d4 = 0;
    for (i = 0; i < 16u; i++)
    {
        rebuilt = (unsigned int)IROM_WIN_B[i * 4u + 0u]
                | ((unsigned int)IROM_WIN_B[i * 4u + 1u] << 8)
                | ((unsigned int)IROM_WIN_B[i * 4u + 2u] << 16)
                | ((unsigned int)IROM_WIN_B[i * 4u + 3u] << 24);
        if (rebuilt != IROM_WIN[i])
            d4++;
    }
    puts_("D4="); putdec_(d4); puts_("\n");

    if ((d1 | d2 | d3 | d4) == 0u)
        puts_("DPTEST-PASS\n");
    else
        puts_("DPTEST-FAIL\n");

    DONE_FLAG = 0x5A5A5A5A;
    return 0;
}
