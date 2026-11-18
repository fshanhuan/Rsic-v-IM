/* =============================================================================
 * sw/ps/mio_test.c -- 搞清楚 Zynq MIO 的"功能选择"到底怎么编码
 * -----------------------------------------------------------------------------
 * 背景：要把 SD0 的四根线（MIO40 CLK / 41 CMD / 42 D0 / 45 D3）当 GPIO 用，
 * 好绕开不动弹的 SDHCI，走 SPI 模式。但把 MIO_PIN_40 的低 6 位从 0x00 扫到
 * 0x3F，**没有一个值**能让"写 1 读回 1"。
 *
 * 于是做**对照实验**：拿一根已知好用的引脚 MIO48（UART1 TX，实测能发出串口数据）
 * 做同样的扫描。如果 MIO48 能扫出可用值，说明我的 GPIO 手法没问题，
 * 是 SD 那几根针的问题；如果 MIO48 也扫不出来，那就是功能编码/写法错了。
 *
 * 关键技巧：不要用拍脑袋的 0x0780 当基准，而是用**厂商给 MIO48 的现值**
 * (0x16E0, 来自 ps7_init)，只改低 6 位（功能选择位），其余（IO 类型、
 * 上下拉、驱动强度）保持厂商配置。
 * ============================================================================= */
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define GPIO_BASE       0xE000A000U
#define GPIO_DATA_RO_1  (GPIO_BASE + 0x64U)
#define GPIO_MASK_1_LSW (GPIO_BASE + 0x08U)
#define GPIO_DIRM_1     (GPIO_BASE + 0x244U)
#define GPIO_OEN_1      (GPIO_BASE + 0x248U)

#define SLCR_UNLOCK     0xF8000008U
#define SLCR_LOCK       0xF8000004U
#define ADDR_MIO_TRI1   0xF8000834U
#define MIO_PIN(n)      (0xF8000700U + 4U * (u32)(n))

#define UART1_BASE      0xE0001000U

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

/* pin: MIO 引脚号（32..53 在 bank1）；base_reg: 该引脚的"厂商配置"原值 */
static int probe_pin(u32 pin, u32 base_reg)
{
    u32 bit = pin - 32U;
    u32 base = base_reg & ~0x0000003FU;   /* 只留低 6 位以外的配置 */
    u32 v;
    int found = -1;

    Xil_Out32(GPIO_DIRM_1, Xil_In32(GPIO_DIRM_1) | (1U << bit));
    Xil_Out32(GPIO_OEN_1,  Xil_In32(GPIO_OEN_1)  | (1U << bit));
    mask_wr(ADDR_MIO_TRI1, 0x00003F00U, 0x00000000U);

    for (v = 0U; v < 64U; v++) {
        u32 r0, r1;

        mask_wr(MIO_PIN(pin), 0x00003FFFU, base | v);

        gpio_wr(1U << bit, 1U << bit);
        usleep(5UL);
        r1 = (Xil_In32(GPIO_DATA_RO_1) >> bit) & 1U;

        gpio_wr(1U << bit, 0U);
        usleep(5UL);
        r0 = (Xil_In32(GPIO_DATA_RO_1) >> bit) & 1U;

        if ((r1 == 1U) && (r0 == 0U)) {
            xil_printf("  MIO%u: v=0x%02x works\n", pin, v);
            found = (int)v;
            break;
        }
    }
    if (found < 0) {
        xil_printf("  MIO%u: no working value (base=0x%04x, final=0x%04x, DATA_RO=0x%08x)\n",
                   pin, base_reg & ~0x3FU,
                   (u32)Xil_In32(MIO_PIN(pin)), (u32)Xil_In32(GPIO_DATA_RO_1));
    }
    return found;
}

int main(void)
{
    u32 vendor48, vendor40;
    int v48, v40;

    port_log_reset();

    Xil_Out32(SLCR_UNLOCK, 0x0000DF0DU);

    /* UART1 先配好，日志同时从串口出（波特率已校准：BDIV=6, BAUDGEN=67） */
    mask_wr(0xF800012CU, 0x01FFCCCDU, 0x016C040DU);
    mask_wr(0xF8000154U, 0x00003F33U, 0x00001002U);
    Xil_Out32(UART1_BASE + 0x34U, 6U);
    Xil_Out32(UART1_BASE + 0x18U, 67U);
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);
    port_uart_init();

    xil_printf("\n=== MIO function-select probe ===\n");

    vendor48 = Xil_In32(MIO_PIN(48));
    vendor40 = Xil_In32(MIO_PIN(40));
    xil_printf("before: MIO_PIN_48=0x%04x MIO_PIN_40=0x%04x DATA_RO_1=0x%08x\n",
               vendor48, vendor40, (u32)Xil_In32(GPIO_DATA_RO_1));

    /* 对照：已知能工作的引脚（UART1 TX） */
    v48 = probe_pin(48U, 0x000016E0U);

    /* 目标：SD0 的 CLK 脚 */
    v40 = probe_pin(40U, 0x00000780U);

    xil_printf("RESULT: MIO48 v=%d ; MIO40 v=%d\n", v48, v40);

    /* 如果把 MIO48 改成了 GPIO，恢复成 UART 功能，别把串口弄坏 */
    mask_wr(MIO_PIN(48), 0x00003FFFU, 0x000016E0U);
    mask_wr(MIO_PIN(40), 0x00003FFFU, 0x00000780U);
    Xil_Out32(SLCR_LOCK, 0x0000767BU);

    xil_printf("=== done ===\n");
    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
