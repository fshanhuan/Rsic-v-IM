/* =============================================================================
 * sw/ps/sd_cd.c -- 用 MIO0（SD0 的 Card Detect）判断卡到底插没插
 * -----------------------------------------------------------------------------
 * 为什么需要：SDHCI、SPI 位翻转、SD 模式位翻转三条路径都报"卡没响应"。
 * 在继续折腾协议之前，先把最基础的问题定死：**卡在不在卡槽里**。
 *
 * EES331 的 PS7 配置把 SD0 的卡检测放在 **MIO0**（Vivado 生成物里能看到
 * SDIO0_CD_SEL=56 / PCW 里的 MIO 0 配成 cd）。卡槽的 C/D 脚通常是
 * "插入就接地"的机械开关，所以：
 *     MIO0 = 0  -> 卡已插入
 *     MIO0 = 1  -> 没有卡（或被内部/外部上拉拉住）
 *
 * 顺带把 SD0 那几根线的静态电平也读出来（DAT0/DAT3 有外部上拉，正常应为 1）。
 * ============================================================================= */
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define GPIO_BASE       0xE000A000U
#define GPIO_DATA_RO_0  (GPIO_BASE + 0x60U)
#define GPIO_DATA_RO_1  (GPIO_BASE + 0x64U)
#define GPIO_DIRM_0     (GPIO_BASE + 0x204U)
#define GPIO_DIRM_1     (GPIO_BASE + 0x244U)

#define SLCR_UNLOCK     0xF8000008U
#define SLCR_LOCK       0xF8000004U
#define ADDR_TRI0       0xF8000830U
#define ADDR_TRI1       0xF8000834U
#define MIO_PIN(n)      (0xF8000700U + 4U * (u32)(n))

#define MIO_GPIO_VAL    0x00000700U
#define UART1_BASE      0xE0001000U

static void mask_wr(u32 addr, u32 mask, u32 val)
{
    u32 v = Xil_In32(addr);
    v = (v & ~mask) | (val & mask);
    Xil_Out32(addr, v);
}

int main(void)
{
    u32 v0, v1;
    int i;

    port_log_reset();

    Xil_Out32(SLCR_UNLOCK, 0x0000DF0DU);
    mask_wr(0xF800012CU, 0x01FFCCCDU, 0x016C040DU);
    mask_wr(0xF8000154U, 0x00003F33U, 0x00001002U);

    /* MIO0 = GPIO 输入（卡检测）；MIO40..45 = GPIO 输入（看静态电平） */
    mask_wr(MIO_PIN(0), 0x00003FFFU, MIO_GPIO_VAL);
    for (i = 40; i <= 45; i++) {
        mask_wr(MIO_PIN(i), 0x00003FFFU, MIO_GPIO_VAL);
    }
    mask_wr(ADDR_TRI0, 0x00000001U, 0x00000001U);      /* MIO0 三态=输入 */
    mask_wr(ADDR_TRI1, 0x00003F00U, 0x00003F00U);      /* MIO40..45 输入 */
    Xil_Out32(SLCR_LOCK, 0x0000767BU);

    Xil_Out32(GPIO_DIRM_0, Xil_In32(GPIO_DIRM_0) & ~0x00000001U);
    Xil_Out32(GPIO_DIRM_1, Xil_In32(GPIO_DIRM_1) & ~0x00003F00U);

    /* 串口 */
    Xil_Out32(UART1_BASE + 0x34U, 6U);
    Xil_Out32(UART1_BASE + 0x18U, 67U);
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);
    port_uart_init();

    usleep(5000UL);
    v0 = Xil_In32(GPIO_DATA_RO_0);
    v1 = Xil_In32(GPIO_DATA_RO_1);

    xil_printf("\n=== SD card-detect (MIO0) ===\n");
    xil_printf("DATA_RO_0 = 0x%08x   MIO0(CD) = %u\n", v0, v0 & 1U);
    xil_printf("DATA_RO_1 = 0x%04x   MIO40..45 = %u %u %u %u %u %u\n",
               v1,
               (u32)((v1 >> 8) & 1U), (u32)((v1 >> 9) & 1U), (u32)((v1 >> 10) & 1U),
               (u32)((v1 >> 11) & 1U), (u32)((v1 >> 12) & 1U), (u32)((v1 >> 13) & 1U));
    xil_printf("=> MIO0=%u : %s\n",
               v0 & 1U,
               ((v0 & 1U) == 0U) ? "CARD PRESENT (switch to GND)"
                                 : "NO CARD (or CD not wired to MIO0)");

    /* 再读几次，排除毛刺 */
    for (i = 0; i < 5; i++) {
        usleep(20000UL);
        xil_printf("   sample %d: MIO0=%u  DATA_RO_1=0x%04x\n",
                   i, (u32)(Xil_In32(GPIO_DATA_RO_0) & 1U), (u32)Xil_In32(GPIO_DATA_RO_1));
    }

    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
