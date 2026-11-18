/* =============================================================================
 * sw/ps/sd_spi.c -- PS 侧裸机：**用 MIO GPIO 位翻转 SD 卡的 SPI 模式**
 * -----------------------------------------------------------------------------
 * 为什么要走这条路：
 *   2026-11-18 实测，PS 的 SD0 控制器（SDHCI）把命令写进 COMMAND 寄存器后
 *   **既不完成也不报错**（NSTS=0、ESTS=0，PRES 的 CMD_INHIBIT 反而卡住），
 *   Xilinx 官方驱动和手写驱动结果一致；能查到的一切（SDIO 时钟 CLKACT=1、
 *   APER 门控=1、内部时钟 stable=1、卡在位 PRES bit16/17/18=1）都对，
 *   但命令状态机就是不动。与其继续猜 SDHCI 内部，不如换一条**完全独立**的通道：
 *
 *   SD 卡本身支持 SPI 模式。而 SD0 的四根线都在 MIO 上，MIO 可以改成 GPIO：
 *       MIO40 = CLK   -> 输出
 *       MIO41 = CMD   -> 输出（SPI 的 MOSI）
 *       MIO42 = DAT0  -> 输入（SPI 的 MISO）
 *       MIO45 = DAT3  -> 输出（SPI 的 CS）
 *   于是可以用最笨、最可控的方式和卡说话，一步一个字节，全程有日志。
 *
 * SPI 模式要点（SD 规范 Part 1 第 7 章）：
 *   1) CS 高、先打 74 个以上 CLK，让卡进入 SPI 模式；
 *   2) CS 低，发 CMD0(0x40|0, 0x95) -> R1 = 0x01；
 *   3) CMD8(0x48, 0x1AA, 0x87) -> R7；
 *   4) 循环 CMD55(0x77,0x65)+ACMD41(0x69,0x40000000,0x77) 直到 R1 = 0；
 *   5) CMD58(0x7A,0,0xFD) 读 OCR；
 *   6) CMD17(0x51, lba, 0xFF) 读块：等 0xFE 令牌，512 字节，2 字节 CRC；
 *   7) CMD24(0x58, lba, 0xFF) 写块：发 0xFE，512 字节，2 字节假 CRC，
 *      收 data response（低 5 位 0b00101 = 接受），再等 busy 释放。
 *
 * 时钟：位翻转，半周期约 1.5 µs -> 约 330 kHz（识别阶段规范要求 100~400 kHz）。
 * ============================================================================= */
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

/* ------------------------------- GPIO / MIO ------------------------------- */
#define GPIO_BASE      0xE000A000U
#define GPIO_DATA_RO_1 (GPIO_BASE + 0x64U)
#define GPIO_MASK_1_LSW (GPIO_BASE + 0x08U)
#define GPIO_DIRM_1    (GPIO_BASE + 0x244U)
#define GPIO_OEN_1     (GPIO_BASE + 0x248U)

#define SLCR_UNLOCK    0xF8000008U
#define SLCR_LOCK      0xF8000004U
#define ADDR_MIO_TRI1  0xF8000834U
#define ADDR_MIO_PIN_40 0xF80007A0U

/* 位位置：MIO40..45 在 GPIO bank1 的 bit8..13 */
#define B_CLK   8U    /* MIO40 */
#define B_CMD   9U    /* MIO41 = MOSI */
#define B_D0   10U    /* MIO42 = MISO */
#define B_CS   13U    /* MIO45 = CS   */

#define UART1_BASE 0xE0001000U

static void mask_wr(u32 addr, u32 mask, u32 val)
{
    u32 v = Xil_In32(addr);
    v = (v & ~mask) | (val & mask);
    Xil_Out32(addr, v);
}

/* 写 GPIO bank1 的低 16 位（mask/val 用 bit 位置） */
static void gpio_wr(u32 mask, u32 val)
{
    Xil_Out32(GPIO_MASK_1_LSW, ((mask & 0xFFFFU) << 16) | (val & mask & 0xFFFFU));
}

static u32 gpio_rd(void)
{
    return Xil_In32(GPIO_DATA_RO_1) & 0xFFFFU;
}

/* ---- 位级 SPI ---- */
static u32 g_slow = 300U;  /* 半周期循环次数：约 5 µs -> 约 100 kHz（SPI 识别要求 100~400 kHz） */

static void spi_delay(void)
{
    volatile u32 i;

    for (i = 0; i < g_slow; i++) {
        ;
    }
}

static void cs_lo(void) { gpio_wr(1U << B_CS, 0U); }
static void cs_hi(void) { gpio_wr(1U << B_CS, 1U << B_CS); }

static void clk_pulse(void)
{
    gpio_wr(1U << B_CLK, 1U << B_CLK);
    spi_delay();
    gpio_wr(1U << B_CLK, 0U);
    spi_delay();
}

/* 一个字节：高位先出，同时收一位 */
static u8 spi_xfer(u8 out)
{
    int i;
    u8 in = 0U;

    for (i = 7; i >= 0; i--) {
        if ((out >> i) & 1U) {
            gpio_wr(1U << B_CMD, 1U << B_CMD);
        } else {
            gpio_wr(1U << B_CMD, 0U);
        }
        spi_delay();
        gpio_wr(1U << B_CLK, 1U << B_CLK);
        spi_delay();
        in = (u8)((in << 1) | (u8)((gpio_rd() >> B_D0) & 1U));
        gpio_wr(1U << B_CLK, 0U);
    }
    spi_delay();
    return in;
}

static void spi_idle_clocks(u32 n)
{
    u32 i;

    for (i = 0; i < n; i++) {
        clk_pulse();
    }
}

/* 发一条命令，返回 R1（0xFF = 无响应） */
static u8 sd_cmd(u8 cmd, u32 arg, u8 crc, u8 *extra, u32 extra_len)
{
    u8 r1;
    u32 i;

    cs_lo();
    spi_delay();
    (void)spi_xfer(0xFFU);                 /* 起始字节 */
    (void)spi_xfer((u8)(0x40U | cmd));
    (void)spi_xfer((u8)(arg >> 24));
    (void)spi_xfer((u8)(arg >> 16));
    (void)spi_xfer((u8)(arg >> 8));
    (void)spi_xfer((u8)(arg));
    (void)spi_xfer(crc);

    /* 等 R1：最多 16 个字节 */
    for (i = 0; i < 16U; i++) {
        r1 = spi_xfer(0xFFU);
        if ((r1 & 0x80U) == 0U) {
            break;
        }
    }
    if (i >= 16U) {
        r1 = 0xFFU;
    }

    for (i = 0; i < extra_len; i++) {
        extra[i] = spi_xfer(0xFFU);
    }
    return r1;
}

static void cs_release(void)
{
    cs_hi();
    (void)spi_xfer(0xFFU);                 /* 给卡 8 个时钟收尾 */
}

/* 等卡不忙（MISO 一直为 1），返回 0=空闲 */
static int wait_not_busy(u32 max_bytes)
{
    while (max_bytes-- > 0U) {
        if (spi_xfer(0xFFU) == 0xFFU) {
            return 0;
        }
    }
    return -1;
}

/* ------------------------------ 初始化 ------------------------------ */
/* ★ 2026-11-18 的关键发现（由 Vivado 给出，不是猜的）：
 *   让 Vivado 生成一份"把 MIO40..45 配成 GPIO"的 ps7_init（_diag/gen_ps7_gpio.tcl），
 *   它写的是 MIO_PIN_4x = **0x00000700**；而配成 SD0 时写的是 0x00000780。
 *   两者只差 **bit[7:5]**（SD0=4, GPIO=0）—— 也就是说**功能选择在 [7:5]**，
 *   不在低 6 位。之前把低 6 位从 0 扫到 0x3F 全部失败，就是因为我改错了地方。
 */
#define MIO_GPIO_VAL   0x00000700U
#define MIO_SD0_VAL    0x00000780U

static void gpio_init(void)
{
    int i;
    u32 r1;

    Xil_Out32(SLCR_UNLOCK, 0x0000DF0DU);

    /* APER：沿用 ps7_init 的值（含 GPIO / UART1 门控） */
    mask_wr(0xF800012CU, 0x01FFCCCDU, 0x016C040DU);

    /* MIO40..45 -> GPIO 功能（0x0700） */
    for (i = 0; i < 6; i++) {
        mask_wr(ADDR_MIO_PIN_40 + (u32)i * 4U, 0x00003FFFU, MIO_GPIO_VAL);
    }
    /* MIO_MST_TRI1：全部当输出（输入的那位稍后单独设） */
    mask_wr(ADDR_MIO_TRI1, 0x00003F00U, 0x00000000U);

    Xil_Out32(SLCR_LOCK, 0x0000767BU);

    /* 方向：CLK/CMD/CS 输出，D0 输入 */
    {
        u32 out_mask = (1U << B_CLK) | (1U << B_CMD) | (1U << B_CS);
        u32 in_mask  = (1U << B_D0);

        Xil_Out32(GPIO_DIRM_1, (Xil_In32(GPIO_DIRM_1) | out_mask) & ~in_mask);
        Xil_Out32(GPIO_OEN_1,  (Xil_In32(GPIO_OEN_1)  | out_mask) & ~in_mask);
    }

    /* 自检：CLK 写 1/0，看 DATA_RO 跟不跟 */
    gpio_wr(1U << B_CLK, 1U << B_CLK);
    usleep(5UL);
    r1 = (gpio_rd() >> B_CLK) & 1U;
    gpio_wr(1U << B_CLK, 0U);
    usleep(5UL);

    /* 初态：CLK 低、CMD 高、CS 高 */
    gpio_wr((1U << B_CMD) | (1U << B_CS) | (1U << B_CLK), (1U << B_CMD) | (1U << B_CS));

    xil_printf("  gpio_init: MIO=0x%04x  CLK-follow(写1读)=%u  DATA_RO=0x%04x\n",
               MIO_GPIO_VAL, r1, gpio_rd());

    /* UART（波特率已校准：BDIV=6, BAUDGEN=67） */
    Xil_Out32(UART1_BASE + 0x34U, 6U);
    Xil_Out32(UART1_BASE + 0x18U, 67U);
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);
    port_uart_init();
}

static void dump_hex(const u8 *p, u32 n)
{
    u32 i;

    for (i = 0U; i < n; i++) {
        if ((i % 16U) == 0U) { xil_printf("\n  %04x:", i); }
        xil_printf(" %02x", (u32)p[i]);
    }
    xil_printf("\n");
}

int main(void)
{
    u8 r1, r7[4], ocr[4];
    u8 *buf = (u8 *)0x00020000U;
    int i;
    int ok = 0;

    port_log_reset();
    gpio_init();

    xil_printf("\n=== SD SPI-mode probe (MIO40..45 as GPIO) ===\n");
    xil_printf("GPIO DATA_RO_1=0x%04x DIRM=0x%08x TRI1=0x%08x\n",
               gpio_rd(), Xil_In32(GPIO_DIRM_1), Xil_In32(ADDR_MIO_TRI1));

    /* ---- 1) 上电时序：CS/CMD 高，打 80 个时钟 ---- */
    cs_hi();
    gpio_wr(1U << B_CMD, 1U << B_CMD);
    spi_idle_clocks(80U);

    /* ---- 2) CMD0：进 idle（重试几次：卡上电后常有几百毫秒准备时间）---- */
    r1 = 0xFFU;
    for (i = 0; i < 10; i++) {
        r1 = sd_cmd(0U, 0x00000000U, 0x95U, NULL, 0U);
        cs_release();
        if ((r1 & 0x7FU) == 0x01U) { break; }
        usleep(20000UL);
    }
    xil_printf("[1] CMD0  -> R1=0x%02x after %d tries (期望 0x01)\n", (u32)r1, i + 1);
    if ((r1 & 0x7FU) != 0x01U) {
        xil_printf("RESULT FAIL_no_card_or_no_spi (R1=0x%02x)\n", (u32)r1);
        goto idle;
    }

    /* ---- 3) CMD8：电压/版本 ---- */
    r1 = sd_cmd(8U, 0x000001AAU, 0x87U, r7, 4U);
    cs_release();
    xil_printf("[2] CMD8  -> R1=0x%02x echo=%02x %02x %02x %02x\n",
               (u32)r1, (u32)r7[0], (u32)r7[1], (u32)r7[2], (u32)r7[3]);

    /* ---- 4) ACMD41 循环 ---- */
    for (i = 0; i < 100; i++) {
        r1 = sd_cmd(55U, 0x00000000U, 0x65U, NULL, 0U);
        cs_release();
        r1 = sd_cmd(41U, 0x40000000U, 0x77U, NULL, 0U);
        cs_release();
        if (r1 == 0x00U) { break; }
        usleep(10000UL);
    }
    xil_printf("[3] ACMD41 -> R1=0x%02x after %d tries\n", (u32)r1, i);
    if (r1 != 0x00U) {
        xil_printf("RESULT FAIL_acmd41\n");
        goto idle;
    }

    /* ---- 5) CMD58：OCR ---- */
    r1 = sd_cmd(58U, 0x00000000U, 0xFD, ocr, 4U);
    cs_release();
    xil_printf("[4] CMD58 -> R1=0x%02x OCR=%02x %02x %02x %02x\n",
               (u32)r1, (u32)ocr[0], (u32)ocr[1], (u32)ocr[2], (u32)ocr[3]);

    /* ---- 6) CMD17：读 LBA0 ---- */
    for (i = 0; i < 512; i++) { buf[i] = 0xEE; }

    r1 = sd_cmd(17U, 0x00000000U, 0xFFU, NULL, 0U);
    if (r1 != 0x00U) {
        cs_release();
        xil_printf("[5] CMD17 -> R1=0x%02x\n", (u32)r1);
        goto idle;
    }
    /* 等 0xFE 数据令牌 */
    for (i = 0; i < 100000; i++) {
        u8 t = spi_xfer(0xFFU);
        if (t == 0xFEU) { break; }
    }
    if (i >= 100000) {
        cs_release();
        xil_printf("[5] CMD17: no 0xFE token\n");
        goto idle;
    }
    for (i = 0; i < 512; i++) {
        buf[i] = spi_xfer(0xFFU);
    }
    (void)spi_xfer(0xFFU);
    (void)spi_xfer(0xFFU);
    cs_release();
    xil_printf("[5] CMD17: read 512 bytes ok\n");
    dump_hex(buf, 64U);

    if ((buf[510] == 0x55U) && (buf[511] == 0xAAU)) {
        xil_printf("    MBR 0x55AA at 510/511 -> OK\n");
        ok = 1;
    } else if ((buf[82] == 'F') && (buf[83] == 'A') && (buf[84] == 'T')) {
        xil_printf("    superfloppy FAT boot sector -> OK\n");
        ok = 1;
    }
    xil_printf(ok ? "RESULT PASS\n" : "RESULT FAIL_no_signature\n");

idle:
    xil_printf("=== done ===\n");
    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
