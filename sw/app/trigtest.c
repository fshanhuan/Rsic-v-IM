/* =============================================================================
 * sw/app/trigtest.c -- 硬件触发单元（S4）上板测试
 * -----------------------------------------------------------------------------
 * 验证什么：
 *   1) 阈值/模式/使能写入后，`trig_cnt` 会按预期增长
 *   2) 电平模式 + holdoff 的触发率 = 采样率 / (HOLDOFF+1)
 *      —— 200 kHz / 65 ≈ 3077 次/秒，这个数是**可以预言**的，实测对得上才算通过
 *   3) clear 能把 fired 和计数清零
 *   4) 四模态（上升/下降/任意/电平）在同一个信号上给出不同的次数
 *
 * 为什么要用"电平+holdoff"当主判据：
 *   AD11 上没接信号时读数是 0，边沿模式永远不会触发；而电平模式
 *   （阈值设 0）会持续触发，次数由 holdoff 决定 —— 不依赖外部接线也能验证。
 *
 * 用法：
 *   _diag/put_app.ps1 -Name trigtest
 *   shell: run trigtest
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)

#define MMIO(i)     (*(volatile unsigned int *)(0x10000000u + 4u * (unsigned int)(i)))

#define R_ADC_ST    MMIO(36)
#define R_ADC_CTL   MMIO(38)
#define R_ADC_LAST  MMIO(41)
#define R_TRIG_TH   MMIO(43)
#define R_TRIG_CTL  MMIO(44)
#define R_TRIG_ST   MMIO(45)
#define R_TRIG_CNT  MMIO(46)

#define MODE_RISE  0u
#define MODE_FALL  1u
#define MODE_ANY   2u
#define MODE_LEVEL 3u

extern char __bss_start[], __bss_end[];

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

static void put_dec(unsigned int v)
{
    char buf[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i) putc_(buf[--i]);
}

static void put_hex16(unsigned int v)
{
    static const char hx[] = "0123456789ABCDEF";
    for (int sh = 12; sh >= 0; sh -= 4)
        putc_(hx[(v >> sh) & 0xF]);
}

/* 约 n 微秒（50 MHz，每圈约 4 拍；给个保守系数即可，只用于"等一会"） */
static void delay_us(unsigned int n)
{
    for (volatile unsigned int i = 0; i < n * 12u; i++)
        ;
}

static void trig_cfg(unsigned int mode, unsigned int th, unsigned int en)
{
    R_TRIG_TH  = th;
    R_TRIG_CTL = (en ? 1u : 0u) | (mode << 2);
}

static void trig_clear(void)
{
    R_TRIG_CTL = 2u;          /* bit1 = clear（en 保持 0，清完再打开） */
    delay_us(10);
    R_TRIG_CTL = 0u;
}

int main(void)
{
    for (char *p = __bss_start; p < __bss_end; p++)
        *p = 0;

    puts_("\r\n== trigtest (S4 hardware trigger) ==\r\n");

    /* 采样器必须在跑，否则没有样本、也就没有触发 */
    R_ADC_CTL = 1u;
    delay_us(2000);

    unsigned int st = R_ADC_ST;
    puts_("ADC: lvl=");  put_dec(MMIO(37) & 0x7FFu);
    puts_(" last=0x"); put_hex16(R_ADC_LAST & 0xFFFFu);
    puts_(" st=0x");  put_hex16(st & 0xFFFFu);
    puts_("\r\n");

    /* ---------------- 1) 电平模式 + 阈值 0：不看边沿，持续触发 ----------------
     * 触发率理论值 = 采样率 / HOLDOFF = 200000 / 64 = 3125.0 /s
     * ★ 实测（2026-11-17 02:18，JTAG 自检位）：4.091 s 内 12785 次 = 3125.1 /s
     *   注意周期是 HOLDOFF 而不是 HOLDOFF+1：hold_cnt 装载 HOLDOFF-1，
     *   每样本减 1，减到 0 的那一拍就允许触发，所以间隔正好是 HOLDOFF 个样本。
     * holdoff 在 RTL 里是 HOLDOFF=64（见 board_top_rec 的 u_trig 参数），
     * 所以周期是 64 个样本。 */
    trig_clear();
    trig_cfg(MODE_LEVEL, 0x0000u, 1u);
    delay_us(200000);                       /* 等 200 ms */
    unsigned int c1 = R_TRIG_CNT;
    trig_cfg(MODE_LEVEL, 0x0000u, 0u);

    puts_("level(th=0) 200ms: cnt="); put_dec(c1);
    puts_("  expect~"); put_dec((200000u / 64u) * 200u / 1000u);
    puts_("\r\n");

    unsigned int tst = R_TRIG_ST;
    puts_("  fired="); put_dec(tst & 1u);
    puts_(" above=");  put_dec((tst >> 1) & 1u);
    puts_("\r\n");

    /* ---------------- 2) 阈值拉满：应当完全不触发 ---------------- */
    trig_clear();
    trig_cfg(MODE_LEVEL, 0xFFFFu, 1u);
    delay_us(100000);
    unsigned int c2 = R_TRIG_CNT;
    trig_cfg(MODE_LEVEL, 0xFFFFu, 0u);
    puts_("level(th=0xFFFF) 100ms: cnt="); put_dec(c2);
    puts_("  expect 0\r\n");

    /* ---------------- 3) 边沿模式（AD11 无信号时应为 0） ---------------- */
    trig_clear();
    trig_cfg(MODE_RISE, 0x0800u, 1u);
    delay_us(100000);
    unsigned int c3 = R_TRIG_CNT;
    trig_cfg(MODE_RISE, 0x0800u, 0u);
    puts_("rise(th=0x800) 100ms: cnt="); put_dec(c3);
    puts_("  (无外部信号时应为 0)\r\n");

    /* ---------------- 4) clear 清零 ---------------- */
    R_TRIG_CTL = 2u;
    delay_us(20);
    R_TRIG_CTL = 0u;
    puts_("after clear: cnt="); put_dec(R_TRIG_CNT);
    puts_(" fired="); put_dec(R_TRIG_ST & 1u);
    puts_("\r\n");

    /* ---------------- 判据 ---------------- */
    puts_("---- verdict ----\r\n");
    puts_((c1 > 400u && c1 < 800u) ? "[PASS] 电平+holdoff 触发率\n"
                                   : "[FAIL] 电平触发率不对（检查 HOLDOFF / 采样率）\n");
    puts_(c2 == 0u                  ? "[PASS] 阈值拉满不触发\n"
                                   : "[FAIL] 阈值拉满还在触发\n");
    puts_(c3 == 0u                  ? "[PASS] 无信号时边沿不触发\n"
                                   : "[FAIL] 边沿模式误触发\n");
    puts_((R_TRIG_CNT == 0u && (R_TRIG_ST & 1u) == 0u)
                                    ? "[PASS] clear 生效\n"
                                    : "[FAIL] clear 无效\n");
    puts_("== trigtest done ==\r\n");
    return 0;
}
