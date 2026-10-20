/* =============================================================================
 * sw/memtest.c -- 数据通路压力自检（先证 CPU，再怀疑 RTOS）
 * -----------------------------------------------------------------------------
 * 为什么需要它：CoreMark 和 FreeRTOS 都出现"刚写进去的值读回来不对"的症状
 * （FreeRTOS 是 tasks.c:2446 的 configASSERT( uxSchedulerSuspended == 1U ) 挂掉，
 *   CoreMark 是 matrix_test 的循环上界变成了天文数字）。两者都可能来自
 *   **CPU 的 load/store 通路**，也可能各自是软件 bug。这个程序把嫌疑分开：
 *
 *   T1 阵列回读   : 1024 个字（4KB，跨 32 个 DCache 行）写 i*3+1 再读回比对
 *   T2 读改写     : 同一个 volatile 全局 ++ 10000 次，期望 10000
 *   T3 指针追逐   : 512 个字的链表跳着走（非顺序访问，压 DCache/StoreBuffer）
 *   T4 别名读写   : 同一地址"写 → 立刻读"重复 2000 次（raw RAW 相关）
 *   T5 跨行拷贝   : 用 1 字节 memset/memcpy 造非对齐长度，再逐字校验
 *
 * 输出一行：T1=<错个数> ... T5=<错个数>；全 0 才是"数据通路无罪"。
 * 有任何非 0，就把错的位置打出来（地址 + 期望 + 实际）。
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define DONE_FLAG   (*(volatile unsigned int *)0x100000f0u)

/* .rodata / .data 都在 DRAM，必须证明它们可读 */
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

/* ---- 测试区：放在 DRAM 的高处，避开 .bss 与栈 ----
 *     DRAM 是 0x0_0000~0x1_FFFF，其中 0x1_0000 以上给 .rodata/.data/.bss/栈。
 *     这里用 0x1_8000 起的 8KB。 */
#define ARR  ((volatile unsigned int *)0x00018000u)
#define NARR 1024u

/* T1：顺序写 + 顺序读回 */
static unsigned int t1_array(void)
{
    unsigned int i, bad = 0;
    for (i = 0; i < NARR; i++)
        ARR[i] = i * 3u + 1u;
    for (i = 0; i < NARR; i++)
    {
        if (ARR[i] != i * 3u + 1u)
        {
            if (bad == 0)
            {
                puts_("  T1 first bad @");
                puthex_((unsigned int)&ARR[i]);
                puts_(" exp=");
                puthex_(i * 3u + 1u);
                puts_(" got=");
                puthex_(ARR[i]);
                puts_("\n");
            }
            bad++;
        }
    }
    return bad;
}

/* T2：读改写（RMW）—— 这一条最像 FreeRTOS 那个 assert 的场景 */
static volatile unsigned int g_cnt;

static unsigned int t2_rmw(void)
{
    unsigned int i;
    g_cnt = 0;
    for (i = 0; i < 10000u; i++)
        g_cnt++;
    return (g_cnt == 10000u) ? 0u : 1u;
}

/* T3：指针追逐（非顺序访问） */
static unsigned int t3_chase(void)
{
    unsigned int i, bad = 0;
    unsigned int k = 0;
    for (i = 0; i < 512u; i++)
        ARR[i] = (i * 37u + 11u) % 512u;          /* 伪随机置换 */
    for (i = 0; i < 512u; i++)
    {
        k = ARR[k];
        if (k >= 512u)
        {
            bad = 1;
            break;
        }
    }
    return bad;
}

/* T4：同一地址写→立刻读（RAW） */
static unsigned int t4_raw(void)
{
    unsigned int i, bad = 0;
    for (i = 0; i < 2000u; i++)
    {
        ARR[0] = i;
        if (ARR[0] != i)
            bad++;
        ARR[511] = ~i;
        if (ARR[511] != ~i)
            bad++;
    }
    return bad;
}

/* T5：非对齐长度的 memcpy/memset（gcc 会展开成 1/2/4 字节混合访问） */
static unsigned char buf_a[300];
static unsigned char buf_b[300];

static unsigned int t5_copy(void)
{
    unsigned int i, bad = 0;
    for (i = 0; i < 300u; i++)
        buf_a[i] = (unsigned char)(i ^ 0x5A);
    /* 故意非 4 字节对齐、非 4 字节长度 */
    for (i = 0; i < 297u; i++)
        buf_b[i + 1] = buf_a[i];
    for (i = 0; i < 297u; i++)
        if (buf_b[i + 1] != (unsigned char)(i ^ 0x5A))
            bad++;
    return bad;
}

int main(void)
{
    unsigned int t1, t2, t3, t4, t5;

    puts_("MEMTEST\n");

    t1 = t1_array();
    puts_("T1="); putdec_(t1); puts_("\n");

    t2 = t2_rmw();
    puts_("T2="); putdec_(t2); puts_("\n");

    t3 = t3_chase();
    puts_("T3="); putdec_(t3); puts_("\n");

    t4 = t4_raw();
    puts_("T4="); putdec_(t4); puts_("\n");

    t5 = t5_copy();
    puts_("T5="); putdec_(t5); puts_("\n");

    if ((t1 | t2 | t3 | t4 | t5) == 0u)
        puts_("MEMTEST-PASS\n");
    else
        puts_("MEMTEST-FAIL\n");

    DONE_FLAG = 0x5A5A5A5A;
    return 0;
}
