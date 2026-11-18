/* =============================================================================
 * sw/ps/sd_probe.c -- PS 侧（Cortex-A9）裸机：SD0 卡识别 + 读第 0 扇区
 * -----------------------------------------------------------------------------
 * 这一步要证明什么（S5 的 SD 卡部分，第一级）：
 *   1) SLCR 里 SD0 的 MIO/时钟配好了（用的是 Vivado 为 EES331 生成的**官方值**，
 *      见 _diag/gen_ps7_sd.tcl，不是猜的）；
 *   2) SDHCI 控制器能起来（读得到 HOST version / caps）；
 *   3) 卡能完成识别（CMD0→CMD8→ACMD41→CMD2→CMD3→CMD7）；
 *   4) 能真的读出一个扇区（ADMA2），并在扇区尾看到 0x55AA。
 *
 * ★ 为什么不调用 ps7_init：2026-11-18 实测，从 JTAG 跑 ps7_init 会卡死
 *   （DAP 读回全 0，里面的 mask_poll 永远不满足）。所以由 CPU 自己
 *   ps_io_bringup() 重放 ps7_init.tcl 里与本程序相关的那几组值。
 *
 * 编译/运行：
 *   powershell -NoProfile -File sw\build_ps_sd.ps1 -App sd_probe
 *   D:\vivado\2025.2\Vivado\bin\xsdb.bat _diag\ps_run_sd.tcl
 * 输出在 PS UART1（当前枚举为 COM13）；另在 0x2F00 写进度标记供 JTAG 读。
 * ============================================================================= */
#include "xsdps.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"
#include "xparameters.h"

/* ------------------------------ SLCR 小工具 ------------------------------ */
#define SLCR_UNLOCK_ADDR  0xF8000008U
#define SLCR_LOCK_ADDR    0xF8000004U
#define SLCR_UNLOCK_KEY   0x0000DF0DU
#define SLCR_LOCK_KEY     0x0000767BU

#define ADDR_SD0_CLK_CTRL  0xF8000150U  /* SD0 时钟：IO_PLL/16 = 62.5 MHz */
#define ADDR_UART_CLK_CTRL 0xF8000154U  /* UART 时钟：IO_PLL/16，CLKACT */
#define ADDR_APER_CLK_CTRL 0xF800012CU  /* 外设门控：UART1 + SDI0 */
#define ADDR_MIO_PIN_40    0xF80007A0U  /* MIO40..45 = SD0 的 CLK/CMD/D0..D3 */
#define ADDR_MIO_PIN_48    0xF80007C0U  /* UART1 TX */
#define ADDR_MIO_PIN_49    0xF80007C4U  /* UART1 RX */
#define ADDR_MIO_MST_TRI0  0xF8000830U

#define UART1_BASE         0xE0001000U

/* 进度标记：写在 OCM 末尾，JTAG 直接读，不依赖 UART 是否可用 */
#define PROG_MARK_ADDR     0x0002FFFCU

static void mask_wr(u32 addr, u32 mask, u32 val)
{
    u32 v = Xil_In32(addr);
    v = (v & ~mask) | (val & mask);
    Xil_Out32(addr, v);
}

static void mark(u32 v)
{
    Xil_Out32(PROG_MARK_ADDR, v);
}

/* =============================================================================
 * ps_io_bringup -- 把 ps7_init 里与本程序相关的几组值在 CPU 上重放一遍
 * -----------------------------------------------------------------------------
 * 数值逐条来自 sim/build/ps7_init.tcl（Vivado 生成）：
 *   0xF800012C APER_CLK_CTRL : 0x016C040D  (UART1 门控 + SDI0 门控)
 *   0xF8000154 UART_CLK_CTRL : 0x1002      (div=16, CLKACT)
 *   0xF8000150 SD0_CLK_CTRL  : 0x1001      (div=16, CLKACT)
 *   0xF80007C0/0xC4 MIO48/49 : 0x16E0 / 0x16E1
 *   0xF80007A0..B4 MIO40..45 : 0x0780      (SD0，1.8V，fast，无上拉)
 *   0xE0001034 BAUDDIV=6, 0xE0001018 BAUDGEN=124, MR=0x20, CR=0x17
 * ========================================================================== */
static void ps_io_bringup(void)
{
    int i;

    mark(0x1001U);

    Xil_Out32(SLCR_UNLOCK_ADDR, SLCR_UNLOCK_KEY);

    mask_wr(ADDR_APER_CLK_CTRL, 0x01FFCCCDU, 0x016C040DU);
    mask_wr(ADDR_UART_CLK_CTRL, 0x00003F33U, 0x00001002U);
    mask_wr(ADDR_SD0_CLK_CTRL,  0x00003F33U, 0x00001001U);
    mask_wr(ADDR_MIO_PIN_48,    0x00003FFFU, 0x000016E0U);
    mask_wr(ADDR_MIO_PIN_49,    0x00003FFFU, 0x000016E1U);
    for (i = 0; i < 6; i++) {
        mask_wr(ADDR_MIO_PIN_40 + (u32)i * 4U, 0x00003FFFU, 0x00000780U);
    }
    mask_wr(ADDR_MIO_MST_TRI0,  0x003F003FU, 0x00380037U);

    Xil_Out32(SLCR_LOCK_ADDR, SLCR_LOCK_KEY);

    /* UART1：BAUDDIV/BAUDGEN 按**实测**的 UART 时钟重算
     *   实测 UART_CLK = IO PLL/16 = 1000/16 = 62.5 MHz
     *   （ps7_init 里的 124 是按 86.4 MHz 算的，所以以前读串口全是乱码）
     *   baud = 62.5e6 / (CD × (BDIV+1)) = 62.5e6/(6×90) = 115740 ≈ 115200 */
    Xil_Out32(UART1_BASE + 0x34U, 0x00000006U);   /* BAUDDIV: CD = 6  */
    Xil_Out32(UART1_BASE + 0x18U, 0x00000059U);   /* BAUDGEN: 89      */
    Xil_Out32(UART1_BASE + 0x04U, 0x00000020U);   /* MR: 8N1        */
    Xil_Out32(UART1_BASE + 0x00U, 0x00000017U);   /* CR: TX/RX 复位+使能 */

    port_uart_init();      /* 再按本工程既有做法兜一遍 */

    mark(0x1002U);
}

/* ---------------------------------- 工具 --------------------------------- */
static void dump_hex(const u8 *p, u32 n)
{
    u32 i;

    for (i = 0; i < n; i++) {
        if ((i % 16U) == 0U) {
            xil_printf("\n  %04x:", (u32)i);
        }
        xil_printf(" %02x", (u32)p[i]);
    }
    xil_printf("\n");
}

/* ---------------------------------- 主体 --------------------------------- */
static XSdPs sd;

static XSdPs_Config sd_cfg = {
    .DeviceId        = 0U,
    .BaseAddress     = XPAR_XSDPS_0_BASEADDR,
    .InputClockHz    = XPAR_XSDPS_0_SDIO_CLK_FREQ_HZ,
    .CardDetect      = 0U,          /* 板上 CD 接 MIO0，本程序不用它 */
    .WriteProtect    = 0U,
    .BusWidth        = XSDPS_4_BIT_WIDTH,
    .BankNumber      = 1U,          /* MIO40..45 属 bank1 */
    .HasEMIO         = 0U,
    .SlotType        = 0U,
    .IsCacheCoherent = 0U,
    .ITapDly_SDR_Clk50  = 0U,
    .OTapDly_SDR_Clk50  = 0U,
    .ITapDly_DDR_Clk50  = 0U,
    .OTapDly_DDR_Clk50  = 0U,
    .OTapDly_SDR_Clk100 = 0U,
    .OTapDly_SDR_Clk200 = 0U,
    .OTapDly_DDR_Clk200 = 0U,
};

int main(void)
{
    s32 st;
    u32 caps;
    u8 *buf = (u8 *)0x00020000U;     /* 见 link_ps_sd.ld */
    int i;

    port_log_reset();
    ps_io_bringup();

    xil_printf("\n=== SD0 probe (EES331 micro SD, MIO40..45) ===\n");
    xil_printf("SD0 base = 0x%08x   input clk = %u Hz\n",
               (u32)XPAR_XSDPS_0_BASEADDR, (u32)XPAR_XSDPS_0_SDIO_CLK_FREQ_HZ);

    /* ---- 1) MIO/时钟 ---- */
    xil_printf("[1] SLCR: SD0_CLK=0x%08x UART_CLK=0x%08x APER=0x%08x MIO40=0x%08x MIO48=0x%08x\n",
               (u32)Xil_In32(ADDR_SD0_CLK_CTRL), (u32)Xil_In32(ADDR_UART_CLK_CTRL),
               (u32)Xil_In32(ADDR_APER_CLK_CTRL), (u32)Xil_In32(ADDR_MIO_PIN_40),
               (u32)Xil_In32(ADDR_MIO_PIN_48));
    xil_printf("    UART: BAUDDIV=0x%02x BAUDGEN=%u MR=0x%02x\n",
               (u32)Xil_In32(UART1_BASE + 0x34U) & 0xFFU,
               (u32)Xil_In32(UART1_BASE + 0x18U) & 0xFFFFU,
               (u32)Xil_In32(UART1_BASE + 0x04U) & 0xFFU);
    mark(0x2001U);

    /* ---- 2) 控制器本身 ---- */
    caps = Xil_In32((u32)XPAR_XSDPS_0_BASEADDR + 0x40U);
    xil_printf("[2] HOST ver=0x%04x  caps=0x%08x\n",
               (u32)(Xil_In16((u32)XPAR_XSDPS_0_BASEADDR + 0xFEU)), (u32)caps);
    xil_printf("    baseclk=%u MHz  4bit=%u  1.8V=%u\n",
               (u32)((caps >> 8) & 0xFFU), (u32)((caps >> 16) & 1U),
               (u32)((caps >> 26) & 1U));

    /* ---- 3) 驱动初始化 ---- */
    mark(0x2002U);
    st = XSdPs_CfgInitialize(&sd, &sd_cfg, (u32)XPAR_XSDPS_0_BASEADDR);
    xil_printf("[3] CfgInitialize = %d (0=ok)\n", (int)st);
    if (st != XST_SUCCESS) {
        mark(0x3000U | (u32)st);
        xil_printf("RESULT FAIL_CfgInit\n");
        goto idle;
    }

    /* ---- 4) 卡识别 ---- */
    mark(0x2003U);

    /* 4a) 先看控制器状态：CMD_INHIBIT(bit0) 必须为 0 才能发命令。
     *     2026-11-18 实测第一次跑时 PRES=0x01FF0001，bit0 卡在 1，
     *     后面 CardInitialize 必然失败 —— 这一行就是那次失败的直接证据。 */
    {
        u32 b = (u32)XPAR_XSDPS_0_BASEADDR;
        u32 pres = Xil_In32(b + 0x24U);

        xil_printf("[4a] pre  PRES=0x%08x (CMD_INHIBIT=%u) CLK=0x%04x PWR=0x%02x\n",
                   (u32)pres, (u32)(pres & 1U),
                   (u32)Xil_In16(b + 0x2CU), (u32)Xil_In8(b + 0x29U));

        if ((pres & 1U) != 0U) {
            int n;
            /* 软件复位一次，看能不能把 CMD_INHIBIT 清掉 */
            Xil_Out8(b + 0x2FU, 0x01U);
            for (n = 0; n < 200000; n++) {
                if ((Xil_In8(b + 0x2FU) & 0x01U) == 0U) { break; }
            }
            pres = Xil_In32(b + 0x24U);
            xil_printf("[4b] post PRES=0x%08x (CMD_INHIBIT=%u) SWRST=0x%02x loops=%d\n",
                       (u32)pres, (u32)(pres & 1U), (u32)Xil_In8(b + 0x2FU), n);

            if ((pres & 1U) != 0U) {
                /* 仍然卡着：把 SD 时钟关掉再打开，最后一招 */
                Xil_Out16(b + 0x2CU, 0x0000U);
                usleep(1000UL);
                Xil_Out16(b + 0x2CU, 0x8007U);
                usleep(1000UL);
                pres = Xil_In32(b + 0x24U);
                xil_printf("[4c] clk-toggle PRES=0x%08x (CMD_INHIBIT=%u) CLK=0x%04x\n",
                           (u32)pres, (u32)(pres & 1U), (u32)Xil_In16(b + 0x2CU));
            }
        }
    }

    st = XSdPs_CardInitialize(&sd);
    xil_printf("[4] CardInitialize = %d (0=ok)\n", (int)st);
    if (st != XST_SUCCESS) {
        u32 b = (u32)XPAR_XSDPS_0_BASEADDR;
        mark(0x4000U | (u32)st);
        xil_printf("[4a] PRES=0x%08x CLK=0x%04x PWR=0x%02x NSTS=0x%04x ESTS=0x%04x\n",
                   (u32)Xil_In32(b + 0x24U),
                   (u32)Xil_In16(b + 0x2CU), (u32)Xil_In8(b + 0x29U),
                   (u32)Xil_In16(b + 0x30U), (u32)Xil_In16(b + 0x32U));
        xil_printf("[4b] RESP0=0x%08x RESP1=0x%08x\n",
                   (u32)Xil_In32(b + 0x10U), (u32)Xil_In32(b + 0x14U));

        /* ---- 手工 CMD0：绕过驱动，直接验证 SDHCI 能不能把命令发出去 ----
         * CMD0 不需要卡回应（no response），所以只要 SDHCI 和时钟是活的，
         * NSTS.CC（命令完成）一定会置位。它不置位 = 控制器/时钟侧的问题，
         * 不是"卡的问题"。这一段就是用来把这两类原因分开的。 */
        {
            int n;

            Xil_Out16(b + 0x2CU, 0x0000U);          /* 先关 SD 时钟 */
            usleep(1000UL);
            Xil_Out16(b + 0x2CU, 0x004EU);          /* 内部时钟, 分频 78 */
            for (n = 0; n < 200000; n++) {
                if ((Xil_In16(b + 0x2CU) & 0x0002U) != 0U) { break; }
            }
            xil_printf("[7a] clk stable after %d loops, CLK=0x%04x\n",
                       n, (u32)Xil_In16(b + 0x2CU));
            Xil_Out16(b + 0x2CU, 0x004EU | 0x0004U); /* 再开 SD 时钟 */
            Xil_Out8(b + 0x29U, 0x0FU);              /* 总线供电 3.3V */
            Xil_Out32(b + 0x30U, 0xFFFFFFFFU);       /* 清中断状态 */
            Xil_Out32(b + 0x32U, 0xFFFFFFFFU);
            Xil_Out8(b + 0x2EU, 0x0EU);              /* 超时计数拉满 */
            Xil_Out32(b + 0x08U, 0x00000000U);       /* ARG = 0 */
            Xil_Out16(b + 0x0EU, 0x0000U);           /* CMD0, 无响应 */

            for (n = 0; n < 500000; n++) {
                if ((Xil_In32(b + 0x30U) & 0x0001U) != 0U) { break; }
            }
            xil_printf("[7b] manual CMD0: loops=%d NSTS=0x%08x ESTS=0x%08x PRES=0x%08x\n",
                       n, (u32)Xil_In32(b + 0x30U), (u32)Xil_In32(b + 0x32U),
                       (u32)Xil_In32(b + 0x24U));
        }
        xil_printf("RESULT FAIL_CardInit (卡没插好? 或 1.8V IO 与卡不兼容)\n");
        goto idle;
    }
    mark(0x2004U);

    xil_printf("[5] card: type=%u hcs=%u sectors=%u busSpeed=%u busWidth=%u\n",
               (u32)sd.CardType, (u32)sd.HCS, (u32)sd.SectorCount,
               (u32)sd.BusSpeed, (u32)sd.BusWidth);
    xil_printf("    capacity = %u MB\n", (u32)(sd.SectorCount / 2048U));

    /* ---- 6) 读第 0 扇区（MBR） ---- */
    for (i = 0; i < 512; i++) {
        buf[i] = 0xEE;                       /* 先填脏值，能看出是否真被覆盖 */
    }
    st = XSdPs_ReadPolled(&sd, 0U, 1U, buf);
    xil_printf("[6] ReadPolled(LBA0) = %d (0=ok)\n", (int)st);
    dump_hex(buf, 64U);

    if ((buf[510] == 0x55U) && (buf[511] == 0xAAU)) {
        xil_printf("    MBR signature 0x55AA at 510/511 -> OK\n");
        xil_printf("    part0 type=0x%02x lba_start=%u\n",
                   (u32)buf[446 + 4], (u32)buf[446 + 8]);
        mark(0x6001U);
        xil_printf("RESULT PASS\n");
    } else if ((buf[82] == 'F') && (buf[83] == 'A') && (buf[84] == 'T')) {
        /* 没有分区表的"整盘 FAT"（superfloppy）格式化 */
        xil_printf("    no MBR, but FAT boot sector at 0x52 -> OK (superfloppy)\n");
        mark(0x6002U);
        xil_printf("RESULT PASS\n");
    } else {
        xil_printf("    no 0x55AA, no FAT -> 读回来的不是合法扇区\n");
        mark(0x6003U);
        xil_printf("RESULT FAIL_Read\n");
    }

idle:
    xil_printf("=== idle (CPU parked, beacon on) ===\n");
    mark(0x7000U);
    for (;;) {
        xil_printf("SD0PROBE-BEACON\n");
        usleep(500000UL);
    }
    return 0;
}

