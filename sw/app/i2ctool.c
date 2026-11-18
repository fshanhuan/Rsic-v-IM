/* =============================================================================
 * sw/app/i2ctool.c -- I2C 总线诊断应用（记录仪项目 S1a）
 * -----------------------------------------------------------------------------
 * 为什么做成 **应用** 而不是往 shell（monitor.c）里加命令：
 *   往 shell 里加 1.5 KB 代码会把 shell 的 .text 推出 0x0000_5FFF，
 *   而应用区固定从 0x0000_6000 起（见 sw/app/link_app.ld）——
 *   结果 `run hello_app` 直接被拒（"code must land in 0x7000..0xFFFF"），
 *   tb_monitor / tb_runapp 当场挂掉。实测踩过一次，这条注释就是记录。
 *   应用有自己的地址空间，改它不影响 shell，编一次几秒、灌一次几秒。
 *
 * 硬件：board/i2c_mmio.sv 的两路主控
 *   bus 0 = HDMI(ADV7511)   寄存器块 idx 16..20  (0x40..0x50)
 *   bus 1 = 音频(ADAU1761)  寄存器块 idx 21..25  (0x54..0x64)
 *
 * 用法（板子上）：
 *   1) _diag/put_app.ps1 -Name i2ctool     # 灌进 shell 的 ramdisk
 *   2) shell 里：  run i2ctool
 *
 * 输出格式故意做成"一行一件事"，方便直接从串口日志里 grep。
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)

#define MMIO_BASE   0x10000000u

/* 两路 I2C 主控的寄存器块 */
#define I2C_BASE(bus)  (MMIO_BASE + (16u + 5u * (unsigned int)(bus)) * 4u)
#define I2C_R(bus, k)  (*(volatile unsigned int *)(I2C_BASE(bus) + 4u * (unsigned int)(k)))
#define I2C_CTRL(bus)  I2C_R(bus, 0)
#define I2C_TXB(bus)   I2C_R(bus, 1)
#define I2C_RXB(bus)   I2C_R(bus, 2)
#define I2C_ST(bus)    I2C_R(bus, 3)
#define I2C_CLR(bus)   I2C_R(bus, 4)

#define I2C_ST_BUSY  1u
#define I2C_ST_DONE  2u
#define I2C_ST_ACK   4u

/* 上电自动探测的结果（只读） */
#define PRB_H_FOUND  (*(volatile unsigned int *)(MMIO_BASE + 26u * 4u))
#define PRB_H_ID     (*(volatile unsigned int *)(MMIO_BASE + 27u * 4u))
#define PRB_A_FOUND  (*(volatile unsigned int *)(MMIO_BASE + 28u * 4u))
#define PRB_A_ID     (*(volatile unsigned int *)(MMIO_BASE + 29u * 4u))
#define PRB_ST       (*(volatile unsigned int *)(MMIO_BASE + 30u * 4u))
#define LINE_HEALTH  (*(volatile unsigned int *)(MMIO_BASE + 31u * 4u))

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

static void puthex_(unsigned int v, int ndig)
{
    int i;
    static const char hx[] = "0123456789ABCDEF";
    for (i = ndig - 1; i >= 0; i--)
        putc_(hx[(v >> (4 * i)) & 0xFu]);
}

static void putdec_(unsigned int v)
{
    char b[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v && i < 11) { b[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i--) putc_(b[i]);
}

/* ------------------------------------------------------------------ I2C */
/* 等一次操作完成：1 = ACK/成功，0 = NACK，-1 = 超时 */
static int i2c_wait(int bus)
{
    unsigned int i, s;
    for (i = 0; i < 200000u; i++) {
        s = I2C_ST(bus);
        if (s & I2C_ST_DONE) {
            I2C_CLR(bus) = 1u;
            return (s & I2C_ST_ACK) ? 1 : 0;
        }
    }
    return -1;
}

static int i2c_start(int bus) { I2C_CTRL(bus) = 1u; return i2c_wait(bus); }
static int i2c_stop(int bus)  { I2C_CTRL(bus) = 4u; return i2c_wait(bus); }

static int i2c_wbyte(int bus, unsigned char b)
{
    I2C_TXB(bus) = b;
    I2C_CTRL(bus) = 2u;
    return i2c_wait(bus);
}

static int i2c_rbyte(int bus, int nack)
{
    I2C_CTRL(bus) = 2u | 8u | (nack ? 16u : 0u);
    if (i2c_wait(bus) < 0) return -1;
    return (int)(I2C_RXB(bus) & 0xFFu);
}

/* 7 位地址应答测试：1 = ACK */
static int i2c_ping(int bus, unsigned char a7)
{
    int r;
    if (i2c_start(bus) < 0) return -1;
    r = i2c_wbyte(bus, (unsigned char)(a7 << 1));
    i2c_stop(bus);
    return r;
}

/* 读一个寄存器：0 = 成功 */
static int i2c_read_reg(int bus, unsigned char a7, unsigned char reg, int *out)
{
    if (i2c_start(bus) < 0) return -1;
    if (i2c_wbyte(bus, (unsigned char)(a7 << 1)) <= 0) { i2c_stop(bus); return -2; }
    if (i2c_wbyte(bus, reg) <= 0)                     { i2c_stop(bus); return -3; }
    if (i2c_start(bus) < 0) return -1;
    if (i2c_wbyte(bus, (unsigned char)((a7 << 1) | 1u)) <= 0) { i2c_stop(bus); return -4; }
    { int r = i2c_rbyte(bus, 1);
      i2c_stop(bus);
      if (r < 0) return -5;
      *out = r; }
    return 0;
}

/* ------------------------------------------------------------------ 报告 */
static void show_health(void)
{
    unsigned int h = LINE_HEALTH;
    static const char *nm[4] = { "never-high", "alive", "always-high", "bad" };
    puts_("HEALTH hdmi_scl=");  puts_(nm[(h >> 2) & 3u]);
    puts_(" hdmi_sda=");        puts_(nm[(h >> 0) & 3u]);
    puts_(" aud_scl=");         puts_(nm[(h >> 6) & 3u]);
    puts_(" aud_sda=");         puts_(nm[(h >> 4) & 3u]);
    putc_('\n');
}

static void show_probe(void)
{
    unsigned int fh = PRB_H_FOUND, ih = PRB_H_ID;
    unsigned int fa = PRB_A_FOUND, ia = PRB_A_ID, st = PRB_ST;

    puts_("PROBE hdmi_found=0x"); puthex_(fh, 4);
    puts_(" addr=0x");            puthex_((ih >> 25) & 0x7Fu, 2);
    puts_(" id=");                puthex_((ih >> 16) & 0xFFu, 2); putc_(' ');
                                  puthex_((ih >> 8) & 0xFFu, 2);  putc_(' ');
                                  puthex_(ih & 0xFFu, 2);
    putc_('\n');
    puts_("PROBE aud_found=0x");  puthex_(fa, 4);
    puts_(" addr=0x");            puthex_((ia >> 25) & 0x7Fu, 2);
    puts_(" id=");                puthex_((ia >> 16) & 0xFFu, 2); putc_(' ');
                                  puthex_((ia >> 8) & 0xFFu, 2);  putc_(' ');
                                  puthex_(ia & 0xFFu, 2);
    putc_('\n');
    puts_("PROBE done="); putdec_((st >> 0) & 1u); putc_('/'); putdec_((st >> 1) & 1u);
    puts_(" busy=");      putdec_((st >> 2) & 1u); putc_('/'); putdec_((st >> 3) & 1u);
    putc_('\n');
}

static void scan(int bus)
{
    unsigned int a;
    int r, n = 0;

    puts_("SCAN bus="); putdec_((unsigned int)bus); puts_(" range=00..7F\n");
    for (a = 0; a < 0x80u; a++) {
        r = i2c_ping(bus, (unsigned char)a);
        if (r == 1) {
            puts_("  ACK 0x"); puthex_(a, 2); putc_('\n');
            n++;
        } else if (r < 0) {
            puts_("  TIMEOUT at 0x"); puthex_(a, 2); putc_('\n');
            return;
        }
    }
    puts_("SCAN found="); putdec_((unsigned int)n); putc_('\n');
}

static void dump_ids(int bus, unsigned char a7)
{
    static const unsigned char regs[8] = { 0x00, 0x41, 0x42, 0x48, 0xF5, 0xF6, 0xF9, 0xFE };
    int i, v;

    puts_("IDS  bus="); putdec_((unsigned int)bus);
    puts_(" addr=0x");  puthex_(a7, 2); putc_('\n');
    for (i = 0; i < 8; i++) {
        v = -1;
        if (i2c_read_reg(bus, a7, regs[i], &v) == 0) {
            puts_("  ["); puthex_(regs[i], 2); puts_("] = 0x"); puthex_((unsigned int)v, 2);
            if (regs[i] == 0xF5 && v == 0x41) puts_("  'A'");
            if (regs[i] == 0xF6 && v == 0x44) puts_("  'D'");
            putc_('\n');
        } else {
            puts_("  ["); puthex_(regs[i], 2); puts_("] read FAIL\n");
        }
    }
}

/* ------------------------------------------------------------------ 主 */
int main(void)
{
    char *p;
    unsigned int a;
    int r;

    for (p = __bss_start; p < __bss_end; p++)
        *p = 0;

    puts_("\n=== i2ctool (recorder S1a) ===\n");
    show_health();
    show_probe();

    /* 现场重扫两条总线（与上电自动探测互相印证） */
    scan(0);
    scan(1);

    /* 对上电探测选中的地址，把关键寄存器全读一遍 */
    r = (int)((PRB_H_ID >> 25) & 0x7Fu);
    if (r != 0) dump_ids(0, (unsigned char)r);
    r = (int)((PRB_A_ID >> 25) & 0x7Fu);
    if (r != 0) dump_ids(1, (unsigned char)r);

    /* 现场重扫若发现新设备（上电时显示器还没插），也读一遍 */
    for (a = 0; a < 0x80u; a++) {
        if (i2c_ping(0, (unsigned char)a) == 1) {
            puts_("HDMI live ack 0x"); puthex_(a, 2); putc_('\n');
        }
    }

    puts_("=== i2ctool done ===\n");
    return 0;
}
