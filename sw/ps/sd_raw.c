/* =============================================================================
 * sw/ps/sd_raw.c -- PS 侧裸机：**手写最小 SDHCI 驱动**（不用 Xilinx xsdps）
 * -----------------------------------------------------------------------------
 * 为什么另写一份：
 *   1) 这块板的 SDHCI 在识别阶段会停在 "命令已发、既不完成也不报错" 的状态，
 *      官方驱动是个大状态机，卡在里面时看不出到底哪一步出的问题；
 *   2) 手写版本每一步都打寄存器（NSTS/ESTS/RESP0），失败点一目了然；
 *   3) 只需要"读一个扇区 / 写一个扇区"，用不到 ADMA/UHS/调谐这些复杂功能。
 *
 * 时序（SD 规范）：
 *   CMD0  -> 卡进 idle
 *   CMD8  -> 读电压/版本（R7，期望 0x1AA）
 *   CMD55+ACMD41 -> 卡初始化完成（R3，bit31 = ready）
 *   CMD2  -> 读 CID（R2，136 bit）
 *   CMD3  -> 要 RCA（R6，bit31:16 = RCA）
 *   CMD7  -> 选中卡（R1b，带 busy）
 *   CMD16 -> 设块长 512
 *   CMD17 -> 读单块（PIO，走 Buffer Data Port 0x20）
 *   CMD24 -> 写单块
 *
 * 寄存器偏移来自 SDHCI 规范（与 xsdps_hw.h 一致）：
 *   0x04 BLK_SIZE, 0x06 BLK_CNT, 0x08 ARG, 0x0C TRANSFER_MODE, 0x0E COMMAND,
 *   0x10..0x1C RESP0..3, 0x20 BUF_DATA, 0x24 PRES_STATE, 0x28 HOST_CTRL1,
 *   0x29 POWER, 0x2C CLK_CTRL, 0x2E TIMEOUT, 0x2F SW_RST,
 *   0x30 NSTS, 0x32 ESTS, 0x3E HOST_CTRL2, 0xFE HOST_VER
 * ============================================================================= */
#include "xsdps.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define SD0 0xE0100000U

/* SLCR */
#define SLCR_UNLOCK 0xF8000008U
#define SLCR_LOCK   0xF8000004U
#define UART1_BASE  0xE0001000U

/* ---- SDHCI 寄存器偏移 ---- */
#define R_BLKSIZE  0x04U
#define R_BLKCNT   0x06U
#define R_ARG      0x08U
#define R_TM       0x0CU
#define R_CMD      0x0EU
#define R_RESP0    0x10U
#define R_RESP1    0x14U
#define R_RESP2    0x18U
#define R_RESP3    0x1CU
#define R_BUF      0x20U
#define R_PRES     0x24U
#define R_HC1      0x28U
#define R_PWR      0x29U
#define R_CLK      0x2CU
#define R_TMO      0x2EU
#define R_SWRST    0x2FU
#define R_NSTS     0x30U
#define R_ESTS     0x32U
#define R_HC2      0x3EU
#define R_VER      0xFEU

/* ---- 中断位 ---- */
#define NSTS_CC      0x0001U
#define NSTS_TC      0x0002U
#define NSTS_BWR     0x0020U
#define NSTS_ERR     0x8000U

/* ---- 命令标志（写进 COMMAND 寄存器低字节）---- */
#define F_R48      0x02U   /* 48 bit response          */
#define F_R48B     0x03U   /* 48 bit response + busy   */
#define F_R136     0x01U   /* 136 bit response         */
#define F_CRC      0x04U
#define F_IDX      0x08U
#define F_DATA     0x20U   /* 带数据                   */

static u32 sdhci_r(u32 off)        { return Xil_In32(SD0 + off); }
static u32 sdhci_r16(u32 off)      { return (u32)Xil_In16(SD0 + off); }
static void sdhci_w(u32 off, u32 v) { Xil_Out32(SD0 + off, v); }
static void sdhci_w16(u32 off, u32 v) { Xil_Out16(SD0 + off, (u16)v); }
static void sdhci_w8(u32 off, u32 v)  { Xil_Out8(SD0 + off, (u8)v); }

static void mask_wr(u32 addr, u32 mask, u32 val)
{
    u32 v = Xil_In32(addr);
    v = (v & ~mask) | (val & mask);
    Xil_Out32(addr, v);
}

/* 与 ps7_init 一致（数值来源见 _diag/gen_ps7_sd.tcl） */
static void ps_io_bringup(void)
{
    int i;

    Xil_Out32(SLCR_UNLOCK, 0x0000DF0DU);
    mask_wr(0xF800012CU, 0x01FFCCCDU, 0x016C040DU);   /* APER: UART1 + SDI0 */
    mask_wr(0xF8000154U, 0x00003F33U, 0x00001002U);   /* UART clk          */
    mask_wr(0xF8000150U, 0x00003F33U, 0x00001001U);   /* SD0 clk           */
    mask_wr(0xF80007C0U, 0x00003FFFU, 0x000016E0U);   /* MIO48 UART TX     */
    mask_wr(0xF80007C4U, 0x00003FFFU, 0x000016E1U);   /* MIO49 UART RX     */
    for (i = 0; i < 6; i++) {                          /* MIO40..45 = SD0   */
        mask_wr(0xF80007A0U + (u32)i * 4U, 0x00003FFFU, 0x00000780U);
    }
    mask_wr(0xF8000830U, 0x003F003FU, 0x00380037U);
    Xil_Out32(SLCR_LOCK, 0x0000767BU);

    /* UART 时钟实测推断 ≈ 102 MHz（IO PLL 1633/16）：
     *   baud = 102e6/(6*(147+1)) = 114.9k -> 按 115200 读应可读 */
    Xil_Out32(UART1_BASE + 0x34U, 6U);
    Xil_Out32(UART1_BASE + 0x18U, 67U);
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);

    port_uart_init();
}

/* 等某寄存器的位满足条件；返回 0=成功，-1=超时 */
static int wait_until(u32 off, u32 mask, u32 want, u32 loops, u32 *lastv)
{
    while (loops-- > 0U) {
        u32 v = sdhci_r(off);
        if ((v & mask) == want) {
            if (lastv != NULL) { *lastv = v; }
            return 0;
        }
    }
    if (lastv != NULL) { *lastv = sdhci_r(off); }
    return -1;
}

/* NSTS/ESTS 是 16 位寄存器：0x32 不在 4 字节边界上，用 32 位访问会触发
 * Cortex-A9 的**对齐异常**（DFSR=0x801、DFAR=0xE0100032，2026-11-18 实测），
 * 表现是程序"凭空断掉"。所以这两个寄存器一律用 16 位访问。 */
static int wait_until16(u32 off, u32 mask, u32 want, u32 loops, u32 *lastv)
{
    while (loops-- > 0U) {
        u32 v = sdhci_r16(off);
        if ((v & mask) == want) {
            if (lastv != NULL) { *lastv = v; }
            return 0;
        }
    }
    if (lastv != NULL) { *lastv = sdhci_r16(off); }
    return -1;
}

/* 设 SD 时钟。divider 为 SDHCI 的分频值 N：SDCLK = base/(2*N)
 * ★ 2026-11-18 的坑：分频值在**高字节**（[15:8]），低 6 位是标志位
 *   （bit0 内部时钟使能 / bit1 稳定 / bit2 SD 时钟使能）。
 *   一开始按 8 位写 0x4E，结果只把标志位写乱、内部时钟根本没开，
 *   表现为"clock 永远 stable=NO、命令永远不完成"。 */
static int clk_set(u32 divider)
{
    u32 v = 0xFFFFFFFFU;
    u16 ctrl;
    int rc;

    /* ★ 不要先写 0 去"关时钟"：2026-11-18 实测，一关 SD 时钟，之后对 SDHCI
     *   的任何访问都会挂在总线上（AXI 无响应，程序停在读寄存器那一步）。
     *   所以直接"设分频 + 开内部时钟 + 等稳定 + 开 SD 时钟"。 */
    sdhci_w8(R_PWR, 0x0FU);                      /* 总线供电 3.3V */

    ctrl = (u16)(((divider & 0xFFU) << 8) | 0x0001U);   /* 内部时钟使能 */
    sdhci_w16(R_CLK, ctrl);
    rc = wait_until(R_CLK, 0x0002U, 0x0002U, 200000U, &v);
    xil_printf("  clk: div=%u ctrl=0x%04x stable=%s CLK=0x%04x\n",
               divider, (u32)ctrl, (rc == 0) ? "yes" : "NO", sdhci_r16(R_CLK));
    if (rc != 0) {
        return -1;
    }

    xil_printf("  clk: A before card-clk write\n");
    sdhci_w16(R_CLK, (u16)(ctrl | 0x0004U));     /* 再开 SD 时钟 */
    xil_printf("  clk: B write done\n");
    xil_printf("  clk: C CLK=0x%04x\n", sdhci_r16(R_CLK));
    xil_printf("  clk: D PRES=0x%08x\n", sdhci_r(R_PRES));
    usleep(2000UL);
    xil_printf("  clk: E done\n");
    return 0;
}

/* 发一条命令；resp!=NULL 时回填 RESP0 */
static int sd_cmd(u32 idx, u32 arg, u32 flags, u32 *resp)
{
    u32 n;
    u32 nsts, ests;

    /* 1) 等 CMD 线空闲 */
    for (n = 0U; n < 200000U; n++) {
        if ((sdhci_r(R_PRES) & 0x0001U) == 0U) { break; }
    }
    if (n >= 200000U) {
        xil_printf("  CMD%u: CMD_INHIBIT stuck (PRES=0x%08x)\n", idx, sdhci_r(R_PRES));
        return -1;
    }

    /* 2) 清状态、拉满超时 */
    sdhci_w16(R_NSTS, 0xFFFFU);
    sdhci_w16(R_ESTS, 0xFFFFU);
    sdhci_w8(R_TMO, 0x0EU);

    /* 3) 写参数 + 命令 */
    sdhci_w(R_ARG, arg);
    sdhci_w16(R_CMD, (u16)((idx << 8) | (flags & 0xFFU)));

    /* 4) 等命令完成或出错 */
    for (n = 0U; n < 1000000U; n++) {
        nsts = sdhci_r16(R_NSTS);
        if ((nsts & NSTS_CC) != 0U || (nsts & NSTS_ERR) != 0U) { break; }
    }
    nsts = sdhci_r16(R_NSTS);
    ests = sdhci_r16(R_ESTS);
    if (resp != NULL) { *resp = sdhci_r(R_RESP0); }

    if ((nsts & NSTS_CC) == 0U) {
        xil_printf("  CMD%u arg=0x%08x: no completion (NSTS=0x%04x ESTS=0x%04x PRES=0x%08x)\n",
                   idx, arg, nsts, ests, sdhci_r(R_PRES));
        return -1;
    }
    if ((nsts & NSTS_ERR) != 0U) {
        xil_printf("  CMD%u arg=0x%08x: ERROR ests=0x%04x\n", idx, arg, ests);
        return -1;
    }
    if (resp != NULL) {
        xil_printf("  CMD%u arg=0x%08x: ok resp=0x%08x\n", idx, arg, *resp);
    } else {
        xil_printf("  CMD%u arg=0x%08x: ok\n", idx, arg);
    }
    return 0;
}

/* 读一个 512 字节扇区（PIO，走 Buffer Data Port） */
static int sd_read_block(u32 lba, u8 *buf)
{
    u32 i, n;
    u32 v;

    /* 等 DAT 线空闲 */
    if (wait_until(R_PRES, 0x0002U, 0x0000U, 200000U, &v) != 0) {
        xil_printf("  read: DAT_INHIBIT stuck PRES=0x%08x\n", v);
        return -1;
    }

    sdhci_w16(R_BLKSIZE, 512U);
    sdhci_w16(R_BLKCNT, 1U);
    sdhci_w16(R_TM, 0x0012U);          /* 块计数使能 + 数据方向=读 */

    if (sd_cmd(17U, lba, F_R48 | F_CRC | F_IDX | F_DATA, NULL) != 0) {
        return -1;
    }

    for (i = 0U; i < 128U; i++) {
        if (wait_until16(R_NSTS, NSTS_BWR, NSTS_BWR, 500000U, &n) != 0) {
            xil_printf("  read: BWR timeout at word %u (NSTS=0x%04x ESTS=0x%04x)\n",
                       i, sdhci_r16(R_NSTS), sdhci_r16(R_ESTS));
            return -1;
        }
        v = sdhci_r(R_BUF);
        buf[i * 4U + 0U] = (u8)(v & 0xFFU);
        buf[i * 4U + 1U] = (u8)((v >> 8) & 0xFFU);
        buf[i * 4U + 2U] = (u8)((v >> 16) & 0xFFU);
        buf[i * 4U + 3U] = (u8)((v >> 24) & 0xFFU);
    }

    if (wait_until16(R_NSTS, NSTS_TC, NSTS_TC, 500000U, &n) != 0) {
        xil_printf("  read: TC not set (NSTS=0x%04x ESTS=0x%04x)\n",
                   sdhci_r16(R_NSTS), sdhci_r16(R_ESTS));
        return -1;
    }
    xil_printf("  read LBA%u: ok\n", lba);
    return 0;
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

/* =============================================================================
 * try_sdio_clk -- 换一种 SLCR SDIO 时钟编码，看 SDHCI 能不能真的跑起来
 * -----------------------------------------------------------------------------
 * 现象：SDHCI 的寄存器能读写（APER 时钟没问题），但命令状态机不动 ——
 * 最可能是"卡侧 SDCLK 没跑"。而 SLCR 里 SDIO_CLK_CTRL 的位定义在这颗芯片上
 * 有点绕（UART_CLK_CTRL 的 CLKACT 在 bit1，SDIO 的在 bit0），所以直接把
 * 几种可能的编码都试一遍，用"CMD0 能不能完成"当判据。
 * ========================================================================== */
static int try_sdio_clk(u32 slcr_val, u32 divider)
{
    u32 n;

    Xil_Out32(SLCR_UNLOCK, 0x0000DF0DU);
    mask_wr(0xF8000150U, 0x003F3F33U, slcr_val);
    Xil_Out32(SLCR_LOCK, 0x0000767BU);

    xil_printf("  [clk] SLCR=0x%08x (now 0x%08x)\n",
               slcr_val, (u32)Xil_In32(0xF8000150U));

    if (clk_set(divider) != 0) {
        return -1;
    }

    /* CMD0：不需要卡回应，能完成就说明命令状态机在跑 */
    sdhci_w16(R_NSTS, 0xFFFFU);
    sdhci_w16(R_ESTS, 0xFFFFU);
    sdhci_w8(R_TMO, 0x0EU);
    sdhci_w(R_ARG, 0U);
    sdhci_w16(R_CMD, 0x0000U);
    for (n = 0U; n < 300000U; n++) {
        u32 st = sdhci_r16(R_NSTS);
        if ((st & (NSTS_CC | NSTS_ERR)) != 0U) {
            break;
        }
    }
    xil_printf("  [clk] CMD0 -> NSTS=0x%04x ESTS=0x%04x loops=%u\n",
               (u32)sdhci_r16(R_NSTS), (u32)sdhci_r16(R_ESTS), n);
    if ((sdhci_r16(R_NSTS) & NSTS_CC) != 0U) {
        return 0;
    }
    return -1;
}

int main(void)
{
    u32 resp = 0U;
    u32 rca = 0U;
    u32 pres;
    u8 *buf = (u8 *)0x00020000U;
    int i;
    int ok = 0;

    ps_io_bringup();
    port_log_reset();

    xil_printf("\n=== SD raw probe (hand-written SDHCI, PIO) ===\n");
    xil_printf("VER=0x%04x CAPS=0x%08x PRES=0x%08x\n",
               sdhci_r16(R_VER), sdhci_r(R_BLKSIZE + 0x3CU), sdhci_r(R_PRES));
    xil_printf("CLK before: 0x%04x\n", sdhci_r16(R_CLK));

    /* ---- 0) 中断状态使能 ----
     * SDHCI 规范里 NSTS/ESTS 的每一位都受 "Status Enable" 门控：使能位为 0 时
     * 对应状态位**不会被置起来**。之前没写这两个寄存器，所以命令可能已经执行完，
     * 我们却只看到 NSTS=0、ESTS=0（"既不完成也不报错"很可能就是这个假象）。 */
    sdhci_w16(0x34U, 0xFFFFU);        /* NORMAL_INTR_STS_EN */
    sdhci_w16(0x36U, 0xFFFFU);        /* ERR_INTR_STS_EN    */
    sdhci_w16(0x38U, 0x0000U);        /* NORMAL_INTR_SIG_EN  */
    sdhci_w16(0x3AU, 0x0000U);        /* ERR_INTR_SIG_EN     */
    sdhci_w8(R_HC1, 0x00U);           /* HOST_CTRL1: 1 bit  */
    sdhci_w16(R_HC2, 0x0000U);        /* HOST_CTRL2         */
    xil_printf("init: NSTS_EN=0x%04x ESTS_EN=0x%04x\n",
               (u32)sdhci_r16(0x34U), (u32)sdhci_r16(0x36U));

    /* ---- 1) 软件复位（CMD 线 + 数据线） ---- */
    sdhci_w8(R_SWRST, 0x07U);                 /* 全部复位 */
    for (i = 0; i < 100000; i++) {
        if ((Xil_In8(SD0 + R_SWRST) & 0x07U) == 0U) { break; }
    }
    xil_printf("after SW reset: loops=%d SWRST=0x%02x PRES=0x%08x\n",
               i, (u32)Xil_In8(SD0 + R_SWRST), sdhci_r(R_PRES));

    /* ---- 2) SDIO 时钟编码扫描（见 try_sdio_clk 的注释） ---- */
    {
        static const u32 cand[] = {
            0x00001001U,   /* CLKACT0=1, SRCSEL=IO PLL,  DIV=16  （Vivado 的写法） */
            0x00001003U,   /* 再把 CLKACT1 也置上                              */
            0x00001011U,   /* SRCSEL=1 (ARM PLL)                              */
            0x00001021U,   /* SRCSEL=2 (DDR PLL)                              */
            0x00000101U,   /* DIV=1，最快（排除分频写错）                     */
            0x00001201U,   /* DIV=18（约 55 MHz）                             */
        };
        int ci;
        int got = -1;

        xil_printf("[2] SDIO clock sweep\n");
        for (ci = 0; ci < (int)(sizeof(cand) / sizeof(cand[0])); ci++) {
            if (try_sdio_clk(cand[ci], 78U) == 0) { got = ci; break; }
        }
        if (got < 0) {
            xil_printf("RESULT FAIL_sdclk (所有 SDIO 时钟编码都发不出命令)\n");
            goto idle;
        }
        xil_printf("[2] working SLCR value = 0x%08x (cand %d)\n", cand[got], got);
        clk_set(78U);
    }
    xil_printf("PRES after clk: 0x%08x\n", sdhci_r(R_PRES));

    /* ---- 3) 识别序列 ---- */
    if (sd_cmd(0U, 0x00000000U, 0x00U, NULL) != 0) { goto idle; }
    if (sd_cmd(8U, 0x000001AAU, F_R48 | F_CRC | F_IDX, &resp) != 0) {
        xil_printf("  (CMD8 失败：可能没插卡，或卡不支持 v2)\n");
        goto idle;
    }
    xil_printf("  CMD8 resp=0x%08x (期望 &0xFFF == 0x1AA)\n", resp);

    /* ACMD41：循环直到 bit31 = 1（容量就绪） */
    for (i = 0; i < 200; i++) {
        if (sd_cmd(55U, 0U, F_R48 | F_CRC | F_IDX, &resp) != 0) { goto idle; }
        if (sd_cmd(41U, 0x40FF8000U, F_R48, &resp) != 0) { goto idle; }
        if ((resp & 0x80000000U) != 0U) { break; }
        usleep(10000UL);
    }
    if ((resp & 0x80000000U) == 0U) {
        xil_printf("  ACMD41 never ready (OCR=0x%08x)\n", resp);
        goto idle;
    }
    xil_printf("  ready, OCR=0x%08x  CCS=%u\n", resp, (resp >> 30) & 1U);

    /* CMD2：读 CID */
    if (sd_cmd(2U, 0U, F_R136 | F_CRC, NULL) != 0) { goto idle; }
    xil_printf("  CID = %08x %08x %08x %08x\n",
               sdhci_r(R_RESP3), sdhci_r(R_RESP2), sdhci_r(R_RESP1), sdhci_r(R_RESP0));

    /* CMD3：要 RCA */
    if (sd_cmd(3U, 0U, F_R48 | F_CRC | F_IDX, &resp) != 0) { goto idle; }
    rca = (resp >> 16) & 0xFFFFU;
    xil_printf("  RCA = 0x%04x\n", rca);

    /* CMD7：选中 */
    if (sd_cmd(7U, rca << 16, F_R48B | F_CRC | F_IDX, &resp) != 0) { goto idle; }

    /* CMD16：块长 512 */
    if (sd_cmd(16U, 512U, F_R48 | F_CRC | F_IDX, &resp) != 0) { goto idle; }

    /* ---- 4) 读第 0 扇区 ---- */
    for (i = 0; i < 512; i++) { buf[i] = 0xEE; }
    if (sd_read_block(0U, buf) != 0) { goto idle; }

    dump_hex(buf, 64U);
    if ((buf[510] == 0x55U) && (buf[511] == 0xAAU)) {
        xil_printf("  MBR 0x55AA -> OK  (part0 type=0x%02x)\n", (u32)buf[450]);
        ok = 1;
    } else if ((buf[82] == 'F') && (buf[83] == 'A') && (buf[84] == 'T')) {
        xil_printf("  superfloppy FAT boot sector -> OK\n");
        ok = 1;
    } else {
        xil_printf("  no MBR/FAT signature\n");
    }

    xil_printf(ok ? "RESULT PASS\n" : "RESULT FAIL_Read\n");

idle:
    pres = sdhci_r(R_PRES);
    xil_printf("PRES final=0x%08x CLK=0x%04x\n", pres, sdhci_r16(R_CLK));
    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
