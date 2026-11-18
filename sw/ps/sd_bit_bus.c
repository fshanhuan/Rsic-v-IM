/* =============================================================================
 * sw/ps/sd_bit_bus.c -- 用 MIO GPIO 位翻转实现 SD 模式(1-bit) 的硬件层
 * -----------------------------------------------------------------------------
 * 为什么走这条：
 *   · PS 的 SD0 控制器（SDHCI）发命令后既不完成也不报错，官方/手写驱动都一样；
 *   · SPI 模式需要卡在上电初始阶段被"CS 低 + CMD0"抓住，而卡停在 SD 模式里就进不去；
 *   · **SD 模式本身就是卡的默认模式** —— 于是用 GPIO 位翻转自己实现 1-bit SD，
 *     既不依赖 SDHCI，也不需要断电。
 *
 * 关键前提（已实测）：MIO_PIN 的功能选择在 **[7:5]**，GPIO = 0x0700（SD0 = 0x0780）。
 * 改成 0x0700 后 MIO40 立刻能当 GPIO 输出（写 1 读 1、写 0 读 0）。
 *
 * 走线：MIO40 = CLK(输出) · MIO41 = CMD(双向) · MIO42 = DAT0(输入)
 *       MIO43/44/45 = DAT1/2/3，1-bit 模式下不用（当输入，靠外部上拉）
 *
 * 协议要点（SD 物理层规范）：
 *   · 命令 48 bit：0 | 6bit 命令号 | 32bit 参数 | 7bit CRC7 | 1
 *   · 响应 R1/R3/R6/R7 也是 48 bit；R2 是 136 bit
 *   · 命令/响应在 CLK 上升沿采样；主机在下降沿改数据
 *   · CMD 线是**半双工**的：发完命令必须立刻交还（TRI=1 / DIRM=0），
 *     否则卡没法把响应打上来。这一点由 sd_bit_bus() 里的 dir 回调保证。
 * ============================================================================= */
#include "sd_bit.h"
#include "sd_crc.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

/* ------------------------------- GPIO / MIO ------------------------------- */
#define GPIO_BASE       0xE000A000U
#define GPIO_DATA_RO_1  (GPIO_BASE + 0x64U)
#define GPIO_MASK_1_LSW (GPIO_BASE + 0x08U)
#define GPIO_DIRM_1     (GPIO_BASE + 0x244U)

#define SLCR_UNLOCK     0xF8000008U
#define SLCR_LOCK       0xF8000004U
#define ADDR_MIO_TRI1   0xF8000834U
#define MIO_PIN(n)      (0xF8000700U + 4U * (u32)(n))

#define MIO_GPIO_VAL    0x00000700U

#define B_CLK   8U    /* MIO40 */
#define B_CMD   9U    /* MIO41 */
#define B_D0   10U    /* MIO42 */
#define B_D3   13U    /* MIO45 */

#define M_CK    (1U << B_CLK)
#define M_CMDP  (1U << B_CMD)
#define M_D0P   (1U << B_D0)
#define M_D3P   (1U << B_D3)
#define TRI_CMD (1U << B_CMD)   /* MIO_MST_TRI1 里 MIO41 的位 */

#define UART1_BASE 0xE0001000U

static u32 g_half = 300U;   /* 半周期循环次数（约 5 µs -> ~100 kHz，识别阶段要求 100~400 kHz） */
static u32 g_waitbits;      /* 诊断：wait_start 期间采样到的（最近 32）位 */
static u32 g_ncr;           /* 诊断：这次响应前打掉了多少个时钟（NCR，单位 bit） */

static void mask_wr(u32 addr, u32 mask, u32 val)
{
    u32 v = Xil_In32(addr);
    v = (v & ~mask) | (val & mask);
    Xil_Out32(addr, v);
}

static void gpio_wr(u32 mask, u32 val)
{
    Xil_Out32(GPIO_MASK_1_LSW, ((mask & 0xFFFFU) << 16) | (val & mask & 0xFFFFU));
}

static u32 gpio_rd(void)
{
    return Xil_In32(GPIO_DATA_RO_1) & 0xFFFFU;
}

static void dly(void)
{
    volatile u32 i;

    for (i = 0; i < g_half; i++) {
        ;
    }
}

/* CMD 线换向：输出 = DIRM 1 / TRI 0；输入 = DIRM 0 / TRI 1 */
static void cmd_out(void)
{
    Xil_Out32(GPIO_DIRM_1, Xil_In32(GPIO_DIRM_1) | M_CMDP);
    mask_wr(ADDR_MIO_TRI1, TRI_CMD, 0U);
}

static void cmd_in(void)
{
    Xil_Out32(GPIO_DIRM_1, Xil_In32(GPIO_DIRM_1) & ~M_CMDP);
    mask_wr(ADDR_MIO_TRI1, TRI_CMD, TRI_CMD);
}

static void clk_pulse(void)
{
    gpio_wr(M_CK, M_CK);
    dly();
    gpio_wr(M_CK, 0U);
    dly();
}

/* ------------------------------- 初始化 -------------------------------- */
int sd_bit_init(void)
{
    int i;
    u32 follow;

    Xil_Out32(SLCR_UNLOCK, 0x0000DF0DU);
    mask_wr(0xF800012CU, 0x01FFCCCDU, 0x016C040DU);      /* APER: GPIO/UART */
    mask_wr(0xF8000154U, 0x00003F33U, 0x00001002U);      /* UART 时钟     */
    for (i = 40; i <= 45; i++) {
        mask_wr(MIO_PIN(i), 0x00003FFFU, MIO_GPIO_VAL);   /* GPIO = 0x0700 */
    }
    mask_wr(ADDR_MIO_TRI1, 0x00003F00U, 0x00000000U);     /* 先全输出 */
    Xil_Out32(SLCR_LOCK, 0x0000767BU);

    /* DIRM：CLK 输出、CMD 先输出、D0/D3 输入 */
    Xil_Out32(GPIO_DIRM_1, (Xil_In32(GPIO_DIRM_1) | M_CK | M_CMDP) & ~(M_D0P | M_D3P));
    mask_wr(ADDR_MIO_TRI1, M_D0P | M_D3P, M_D0P | M_D3P);

    /* 自检：CLK 写 1 读 1（MIO 复用没配对时这里会是 0） */
    gpio_wr(M_CK, M_CK);
    dly();
    follow = (gpio_rd() >> B_CLK) & 1U;
    gpio_wr(M_CK, 0U);
    dly();

    /* 串口（波特率已校准 BDIV=6, BAUDGEN=67 => 115200） */
    Xil_Out32(UART1_BASE + 0x34U, 6U);
    Xil_Out32(UART1_BASE + 0x18U, 67U);
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);
    port_uart_init();

    xil_printf("  gpio: MIO=0x%04x CLK-follow=%u DATA_RO=0x%04x\n",
               (u32)MIO_GPIO_VAL, follow, gpio_rd());
    return (follow != 0U) ? 0 : -1;
}

void sd_bit_set_half(u32 n)
{
    if (n != 0U) { g_half = n; }
}

u32 sd_bit_half(void)
{
    return g_half;
}

/* ------------------------------- CRC ----------------------------------- */
/* CRC7 / CRC16 放在 sw/ps/sd_crc.c，因为它必须能被 PC 上的测试做已知答案检查
 * （CMD0 帧尾 0x95、CMD8 帧尾 0x87、XMODEM("123456789")=0x31C3）。 */

/* ---------------------------- 位级收发 -------------------------------- */
/* 发 1 位（主机驱动 CMD） */
static void tx_bit(u32 b)
{
    if (b) { gpio_wr(M_CMDP, M_CMDP); } else { gpio_wr(M_CMDP, 0U); }
    dly();
    gpio_wr(M_CK, M_CK);
    dly();
    gpio_wr(M_CK, 0U);
}

/* 收 1 位（CMD 线由卡驱动；调用前必须已经 cmd_in()） */
static u32 rx_bit(void)
{
    u32 v;

    gpio_wr(M_CMDP, M_CMDP);
    dly();
    gpio_wr(M_CK, M_CK);
    dly();
    v = (gpio_rd() >> B_CMD) & 1U;
    gpio_wr(M_CK, 0U);
    return v;
}

/* 发一个字节（MSB 先） */
static void tx_byte(u8 b)
{
    int i;

    for (i = 7; i >= 0; i--) {
        tx_bit((u32)((b >> i) & 1U));
    }
}

static u8 rx_byte(void)
{
    int i;
    u8 v = 0U;

    for (i = 0; i < 8; i++) {
        v = (u8)((v << 1) | (u8)rx_bit());
    }
    return v;
}

/* 等响应起始位（0），返回 0=等到，-1=超时。
 *
 * ★ 窗口长度：SD 规范里命令响应（R1）的 NCR 最长是 **8 个字节 = 64 个时钟**，
 *   早先只给 32 个时钟（4 字节）——真卡万一慢一点就会被误判成"没响应"，
 *   而现象和"没插卡"完全一样。现在给满 64 个时钟，并把实际等了多少个时钟
 *   记在 g_ncr 里，方便卡来了直接看数字。 */
static int wait_start(void)
{
    int n;

    g_waitbits = 0U;
    g_ncr = 0U;
    for (n = 0; n < 64; n++) {
        u32 b = rx_bit();

        g_ncr++;
        if (b == 0U) {
            return 0;
        }
        g_waitbits = (g_waitbits << 1) | b;   /* 只留最近 32 位，够诊断用 */
    }
    return -1;
}

/* 读 48 bit 响应，返回 32 bit 内容。
 *
 * 帧结构：0(起始) | 0(传输位) | cmd[5:0] | 内容[31:0] | crc7[6:0] | 1(结束) = 48 位
 * 所以跳过起始位之后，还要跳 **7 位**（传输位 + 6 位命令号）才是内容。
 *
 * ★ 2026-11-18 抓到的真 bug：这里原来只跳 6 位（漏了传输位），于是后面所有响应的
 *   内容都**左移一位**：RCA 从 0x1234 变成 0x891A、OCR 从 0xC0FF8000 变成 0xE07FC000、
 *   R1 状态平白多出 0x80000000（被当成"错误位"）。真卡上表现就是"能应答但全是废数据"，
 *   比"没响应"难查得多。是 PC 上位级仿真（tools/ps/host/sd_bit_sim_test.c）抓出来的。 */
static int rd48(u32 *out)
{
    u32 v = 0U;
    int i;

    if (wait_start() != 0) {
        return -1;
    }
    for (i = 0; i < 7; i++) {           /* 传输位 + 命令号，共 7 位 */
        (void)rx_bit();
    }
    for (i = 0; i < 32; i++) {          /* 内容 */
        v = (v << 1) | rx_bit();
    }
    for (i = 0; i < 8; i++) {           /* CRC7 + 结束位 */
        (void)rx_bit();
    }
    *out = v;
    return 0;
}

/* 发命令（48 bit），arg 为参数 */
static void send_cmd(u32 idx, u32 arg)
{
    u8 buf[5];
    u8 c;
    int i;

    buf[0] = (u8)(0x40U | (idx & 0x3FU));
    buf[1] = (u8)(arg >> 24);
    buf[2] = (u8)(arg >> 16);
    buf[3] = (u8)(arg >> 8);
    buf[4] = (u8)(arg);
    c = (u8)((sd_crc7(buf, 5U) << 1) | 0x01U);

    cmd_out();
    for (i = 0; i < 5; i++) {
        tx_byte(buf[i]);
    }
    tx_byte(c);
    cmd_in();                /* 立刻交还 CMD 线，卡才能打响应上来 */
}

/* 完整命令 + 48bit 响应；返回 0=有响应, -1=超时；resp 为 32bit 内容 */
static int sd_cmd48(u32 idx, u32 arg, u32 *resp)
{
    send_cmd(idx, arg);
    return rd48(resp);
}

/* ---------------------------- 上电 / 识别 ------------------------------ */
void sd_bit_powerup(void)
{
    int i;

    gpio_wr(M_CMDP | M_CK, M_CMDP | M_CK);
    usleep(2000UL);
    for (i = 0; i < 90; i++) {
        clk_pulse();
    }
}

int sd_bit_card_init(u32 *rca)
{
    u32 resp = 0U;
    u32 ocr = 0U;
    u32 r = 0U;
    int i, n;

    if (rca != 0) { *rca = 0U; }

    /* ---- CMD0：复位到 idle（SD 模式下无响应）---- */
    send_cmd(0U, 0U);
    for (i = 0; i < 8; i++) {
        clk_pulse();
    }
    xil_printf("[1] CMD0 sent (no response expected)\n");

    /* ---- CMD8：接口条件（R7）---- */
    n = sd_cmd48(8U, 0x000001AAU, &resp);
    xil_printf("[2] CMD8 -> %s resp=0x%08x (期望 &0xFFF=0x1AA) idle=%u waitbits=0x%08x ncr=%u\n",
               (n == 0) ? "ok" : "TIMEOUT", resp,
               (u32)((gpio_rd() >> B_CMD) & 1U), g_waitbits, g_ncr);
    if (n != 0) {
        return -1;
    }

    /* ---- ACMD41：初始化，等 OCR bit31 = 1 ---- */
    for (i = 0; i < 100; i++) {
        if (sd_cmd48(55U, 0U, &resp) != 0) { break; }
        if (sd_cmd48(41U, 0x40FF8000U, &ocr) != 0) { break; }
        if ((ocr & 0x80000000U) != 0U) { break; }
        usleep(10000UL);
    }
    xil_printf("[3] ACMD41 -> OCR=0x%08x after %d tries\n", ocr, i + 1);
    if ((ocr & 0x80000000U) == 0U) {
        return -2;
    }

    /* ---- CMD2：读 CID（R2，136 bit；这里只要它别超时）---- */
    send_cmd(2U, 0U);
    if (wait_start() == 0) {
        xil_printf("[4] CMD2 (CID) responded, draining 136 bit\n");
        for (i = 0; i < 135; i++) {      /* 已经吃掉起始位 */
            (void)rx_bit();
        }
    } else {
        xil_printf("[4] CMD2 TIMEOUT\n");
        return -3;
    }

    /* ---- CMD3：要 RCA（R6）---- */
    if (sd_cmd48(3U, 0U, &resp) != 0) {
        xil_printf("[5] CMD3 TIMEOUT\n");
        return -4;
    }
    r = (resp >> 16) & 0xFFFFU;
    xil_printf("[5] CMD3 -> RCA=0x%04x\n", r);

    /* ---- CMD7：选中卡（R1b）---- */
    if (sd_cmd48(7U, r << 16, &resp) != 0) {
        xil_printf("[6] CMD7 TIMEOUT\n");
        return -5;
    }
    xil_printf("[6] CMD7 -> R1=0x%08x\n", resp);

    /* ---- CMD16：块长 512（R1）---- */
    if (sd_cmd48(16U, 512U, &resp) != 0) {
        xil_printf("[7] CMD16 TIMEOUT\n");
        return -6;
    }
    xil_printf("[7] CMD16 -> R1=0x%08x\n", resp);

    if (rca != 0) { *rca = r; }
    return 0;
}

u32 sd_bit_waitbits(void)
{
    return g_waitbits;
}

u32 sd_bit_waitcount(void)
{
    return g_ncr;
}

/* 提速后先试一次，不行就退回慢速。返回 1=高速可用，0=已退回慢速，-1=都不行。
 * 为什么需要：位翻转的时钟是靠忙等循环"凑"出来的，真卡能跑多快事先不知道。
 * 与其等它读盘失败再人工排查，不如自己试一次、失败自动降速。 */
int sd_bit_speed_probe(u32 fast_half, u8 *blk512)
{
    u32 slow = g_half;
    int rc;

    if ((fast_half == 0U) || (fast_half >= slow)) {
        return 1;                       /* 没提速，没什么好试的 */
    }
    g_half = fast_half;
    rc = sd_read_block(sd_bit_bus(), 0U, blk512);
    if (rc == SDW_OK) {
        xil_printf("  speed: half %u -> %u ok\n", slow, fast_half);
        return 1;
    }
    xil_printf("  speed: half %u failed (rc=%d), fall back to %u\n", fast_half, rc, slow);
    g_half = slow;
    rc = sd_read_block(sd_bit_bus(), 0U, blk512);
    if (rc == SDW_OK) {
        return 0;
    }
    xil_printf("  speed: slow clock also failed (rc=%d)\n", rc);
    return -1;
}

/* --------------------- 适配成 sd_bus（给 sd_wr.c 用）--------------------- */
static void bb_cmd(void *ctx, u32 idx, u32 arg)
{
    (void)ctx;
    send_cmd(idx, arg);
}

static int bb_resp48(void *ctx, u32 *r)
{
    (void)ctx;
    return rd48(r);
}

static void bb_dir(void *ctx, int host_out)
{
    (void)ctx;
    if (host_out) {
        cmd_out();
    } else {
        cmd_in();
    }
}

static void bb_tx(void *ctx, u8 b)
{
    (void)ctx;
    tx_byte(b);
}

static u8 bb_rx(void *ctx)
{
    (void)ctx;
    return rx_byte();
}

static u32 bb_rxbit(void *ctx)
{
    (void)ctx;
    return rx_bit();
}

static const sd_bus g_bb_bus = {
    bb_cmd, bb_resp48, bb_dir, bb_tx, bb_rx, bb_rxbit, 0
};

const sd_bus *sd_bit_bus(void)
{
    return &g_bb_bus;
}
