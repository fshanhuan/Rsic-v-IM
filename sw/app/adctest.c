/* =============================================================================
 * sw/app/adctest.c -- DAC + XADC 自环测试（记录仪项目 S2）
 * -----------------------------------------------------------------------------
 * 目的：把 S2 从"数字链路通"变成"模拟读数可判定"。
 *
 * 做的事：
 *   1) 打印 ADC 状态（full / overflow / level / cnt / last）
 *   2) 依次写 DAC 码值 0xFF 0xC0 0x80 0x40 0x00，每档读几次 ADC 最新值
 *      —— DAC 输出经 LM324 **反相**，所以码值越大输出越低，ADC 读数也越低
 *   3) 把采样通道临时切到**片内温度** (DRP 0x00) 读一次
 *      —— 温度通道不依赖任何外部接线，它非 0 就证明 XADC 真的在转换；
 *         如果连它都是 0，说明序列器/DRP 配置有问题，与接线无关
 *   4) 恢复通道 0x1B(AD11)
 *
 * 用法（板子上，串口通了以后）：
 *   1) _diag/put_app.ps1 -Name adctest
 *   2) shell 里： run adctest
 *
 * 期望（DAC 输出经 330Ω 串联 + 100Ω 并联到地 = 1:4.3 分压后接 AD11）：
 *   DAC=0xFF → 输出≈0.00V → 分压 0.00V  → ADC≈0x0000
 *   DAC=0x80 → 输出≈2.00V → 分压 0.465V → ADC≈0x076F
 *   DAC=0x00 → 输出≈3.98V → 分压 0.926V → ADC≈0x0ECF
 * ★ 分压比必须 ≥1:4：1:3 得到 1.33V，仍然超 1V 量程。
 * ★ 330Ω 必须在 DAC 侧（串联）、100Ω 到地（并联）；接反 → 3.07V，会打坏 XADC。
 * ★ 没有分压直接接 AD11 会过压（手册：这两个脚只支持 0~1 V）。
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)

#define MMIO(i)     (*(volatile unsigned int *)(0x10000000u + 4u * (unsigned int)(i)))

#define R_DAC       MMIO(34)   /* 0x88 WO  {24'b0, dac[7:0]} */
#define R_ADC_DATA  MMIO(35)   /* 0x8C RO  队头（不弹） */
#define R_ADC_ST    MMIO(36)   /* 0x90 RO  bit0 full bit1 ovf bit2 有数据 */
#define R_ADC_LVL   MMIO(37)   /* 0x94 RO  FIFO 深度 */
#define R_ADC_CTL   MMIO(38)   /* 0x98 RW  bit0 en bit1 clr_ovf bit2 pop */
#define R_ADC_CH    MMIO(39)   /* 0x9C RW  {ch1_en, ch1[6:0], ch0[6:0]} */
#define R_ADC_CNT   MMIO(40)   /* 0xA0 RO  累计样本数 */
#define R_ADC_LAST  MMIO(41)   /* 0xA4 RO  最新一次转换 */

#define CH_AD11     0x1Bu      /* VAUX11 = 手册 AD11 (A18/A19) */
#define CH_TEMP     0x00u      /* 片内温度传感器 */

extern char __bss_start[], __bss_end[];

/* ------------------------------------------------------------------ 输出 */
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

static void put_hex8(unsigned int v)
{
    static const char hx[] = "0123456789ABCDEF";
    putc_(hx[(v >> 4) & 0xF]);
    putc_(hx[v & 0xF]);
}

static void put_hex16(unsigned int v)
{
    put_hex8((v >> 8) & 0xFF);
    put_hex8(v & 0xFF);
}

static void put_dec(unsigned int v)
{
    char buf[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i) putc_(buf[--i]);
}

/* 简单延时：50 MHz 下每圈约 2~3 个周期 */
static void delay(unsigned int n)
{
    for (volatile unsigned int i = 0; i < n; i++)
        ;
}

/* 读 ADC 最新值：取 8 次平均，丢掉抖动 */
static unsigned int adc_avg8(void)
{
    unsigned int acc = 0;
    for (int k = 0; k < 8; k++) {
        acc += (R_ADC_LAST & 0xFFFFu);
        delay(2000);
    }
    return acc / 8u;
}

/* XADC 的 DRP 数据是**左对齐**的：12 位结果在 DO[15:4]。
 * 实测证据：读片内温度通道得到 0xA028，>>4 = 0xA02 = 2562
 *           → 2562*503.975/4096-273.15 = 42.0 °C（板子刚跑完综合，合理）。
 *           若按低位解释会得到 0x028=40 → -268 °C，明显错。 */
static unsigned int adc12(unsigned int raw)
{
    return (raw >> 4) & 0xFFFu;
}

/* 把 12 位码值换算成毫伏（0~1 V 量程）：mV = code * 1000 / 4096 */
static unsigned int code_to_mv(unsigned int code)
{
    return (adc12(code) * 1000u) / 4096u;
}

int main(void)
{
    /* 清零 .bss（应用加载器不一定清） */
    for (char *p = __bss_start; p < __bss_end; p++)
        *p = 0;

    puts_("\r\n== adctest (S2: DAC -> XADC) ==\r\n");

    /* 1) 状态 */
    {
        unsigned int st = R_ADC_ST;
        puts_("ST    full="); put_dec((st >> 0) & 1u);
        puts_(" ovf=");       put_dec((st >> 1) & 1u);
        puts_(" data=");      put_dec((st >> 2) & 1u);
        puts_(" lvl=");       put_dec(R_ADC_LVL & 0x7FFu);
        puts_(" cnt=");       put_dec(R_ADC_CNT);
        puts_("\r\nLAST  = 0x"); put_hex16(R_ADC_LAST & 0xFFFFu);
        puts_(" (");  put_dec(code_to_mv(R_ADC_LAST & 0xFFFFu)); puts_(" mV)\r\n");
    }

    /* 2) XADC 自检：切到片内温度通道。
     *    温度≈25°C 时 12 位码约 0x0977（≈2423），非 0 即证明转换在工作。 */
    R_ADC_CH = CH_TEMP;            /* ch1 关，ch0 = 温度 */
    delay(200000);
    {
        unsigned int t = adc_avg8();
        puts_("XTEMP = 0x"); put_hex16(t);
        if (t == 0u) {
            puts_("  <-- 0! XADC 没有在转换（序列器/DRP 配置问题，与接线无关）\r\n");
        } else {
            /* XADC 温度公式：T(°C) = code * 503.975 / 4096 - 273.15
             * 这里只做整数近似：mC = code*503975/4096 - 273150 */
            int mc = (int)(((unsigned long long)adc12(t) * 503975ull) / 4096ull) - 273150;
            puts_("  = "); put_dec((unsigned int)(mc / 1000));
            puts_(".");    put_dec((unsigned int)((mc % 1000) < 0 ? -(mc % 1000) : (mc % 1000)));
            puts_(" C  (XADC 转换正常)\r\n");
        }
    }

    /* 3) DAC 扫频：码值从 0xFF 到 0x00（输出由低到高） */
    R_ADC_CH = CH_AD11;            /* 恢复 AD11 */
    delay(200000);

    puts_("-- DAC sweep (输出反相：码值越大电压越低) --\r\n");
    puts_("DAC  ADC    mV   note\r\n");

    static const unsigned int codes[5] = { 0xFFu, 0xC0u, 0x80u, 0x40u, 0x00u };
    for (int k = 0; k < 5; k++) {
        R_DAC = codes[k];
        delay(400000);              /* 等 DAC 稳定 + 让 ADC 采样几次 */

        unsigned int v = adc_avg8();   /* 左对齐原始值 */
        puts_("0x"); put_hex8(codes[k]);
        puts_(" 0x"); put_hex16(v);
        puts_("  ");   put_dec(code_to_mv(v));
        puts_("  ");

        /* DAC 输出电压估计：V = 3.98V * (255-code)/255，反相后 */
        {
            unsigned int mv_dac = (3980u * (255u - (codes[k] & 0xFFu))) / 255u;
            puts_("dac~"); put_dec(mv_dac); puts_("mV");
        }
        puts_("\r\n");
    }

    /* 4) 收尾：DAC 回到安全值 0xFF（≈0 V），避免输出长期顶在高压 */
    R_DAC = 0xFFu;
    puts_("DAC restored to 0xFF (safe, ~0V)\r\n");
    puts_("== adctest done ==\r\n");

    return 0;
}
