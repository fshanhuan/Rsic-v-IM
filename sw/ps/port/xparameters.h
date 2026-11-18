/* =============================================================================
 * sw/ps/port/xparameters.h -- 本工程用到的那几个参数（手写，够用即可）
 * -----------------------------------------------------------------------------
 * SD0 基地址 0xE0_1000_0000 的说明：Zynq-7000 里 SD0 = 0xE010_0000，
 * SD1 = 0xE010_1000。板上卡槽接的是 SD0（EES331 手册 §9）。
 *
 * SDIO 输入时钟：由 SLCR 0xF8000150 决定 —— IO_PLL/16。IO_PLL 在本设计里是
 * 1000 MHz（见 ps7_init 里 0xF8000108/0xF8000118 的配置），所以 62.5 MHz。
 * 驱动只用它算分频，即使估偏一点也只影响实际时钟（识别阶段本来就 ≤400 kHz）。
 * ============================================================================= */
#ifndef XPARAMETERS_H
#define XPARAMETERS_H

#define XPAR_XSDPS_NUM_INSTANCES        1U
#define XPAR_XSDPS_0_DEVICE_ID          0U
#define XPAR_XSDPS_0_BASEADDR           0xE0100000U
#define XPAR_XSDPS_0_SDIO_CLK_FREQ_HZ   62500000U

#define XPS_SYS_CTRL_BASEADDR           0xF8000000U
#define XPAR_CPU_CORTEXA9_CORE_CLOCK_FREQ_HZ 667000000U

#endif /* XPARAMETERS_H */
