/* =============================================================================
 * sw/ps/uart_beacon.c -- 波特率标定用：反复打印固定串，PC 端扫波特率
 * -----------------------------------------------------------------------------
 * 为什么需要：PS UART1 的输入时钟不是 ps7_init 假设的 86.4 MHz，
 * 也不是我一度以为的 62.5 MHz —— 按这两个值算出来的波特率在 PC 上都读不出字。
 * 与其继续猜，不如让程序不停地发同一个短串，PC 端从 9600 到 230400 逐个试，
 * 哪个能读出 "UART-BEACON" 就是真波特率，再反推时钟。
 * ============================================================================= */
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define SLCR_UNLOCK 0xF8000008U
#define SLCR_LOCK   0xF8000004U
#define UART1_BASE  0xE0001000U

static void mask_wr(u32 addr, u32 mask, u32 val)
{
    u32 v = Xil_In32(addr);
    v = (v & ~mask) | (val & mask);
    Xil_Out32(addr, v);
}

static void bringup(void)
{
    Xil_Out32(SLCR_UNLOCK, 0x0000DF0DU);
    mask_wr(0xF800012CU, 0x01FFCCCDU, 0x016C040DU);
    mask_wr(0xF8000154U, 0x00003F33U, 0x00001002U);   /* UART 时钟 */
    mask_wr(0xF80007C0U, 0x00003FFFU, 0x000016E0U);   /* MIO48 TX  */
    mask_wr(0xF80007C4U, 0x00003FFFU, 0x000016E1U);   /* MIO49 RX  */
    Xil_Out32(SLCR_LOCK, 0x0000767BU);

    Xil_Out32(UART1_BASE + 0x34U, 6U);                /* BAUDDIV: CD=6  */
    Xil_Out32(UART1_BASE + 0x18U, 124U);              /* BAUDGEN: 124   */
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);             /* 8N1            */
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);
    port_uart_init();
}

int main(void)
{
    port_log_reset();
    bringup();

    for (;;) {
        xil_printf("UART-BEACON\n");
        usleep(100000UL);
    }
    return 0;
}
