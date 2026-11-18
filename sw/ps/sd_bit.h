/* =============================================================================
 * sw/ps/sd_bit.h -- 用 MIO GPIO 位翻转跑 SD 模式(1-bit) 的对外接口
 * -----------------------------------------------------------------------------
 * 分两层：
 *   · 本文件 + sd_bit_bus.c : **硬件层**（MIO 复用、DIRM/TRI、时钟、命令/响应、
 *     以及一个把位级原语包成 sd_bus 的适配器）
 *   · sd_wr.c               : **协议层**（CMD17/CMD24 的块读写、CRC、忙等）
 * 这样 sd_wr.c 既能接真硬件（本文件），也能接内存假卡（sd_wr_test.c），
 * 后者不需要卡就能把协议逻辑跑一遍。
 *
 * 用法（真卡）：
 *     if (sd_bit_init() != 0)                 串口/GPIO 自检失败
 *     sd_bit_powerup();                       74+ 时钟
 *     if (sd_bit_card_init(&rca) != 0)        识别失败（没插卡/没重新上电）
 *     bus = sd_bit_bus();                     之后交给 sd_wr / fat32
 * ============================================================================= */
#ifndef SD_BIT_H
#define SD_BIT_H

#include "xil_types.h"
#include "sd_wr.h"               /* 只为 sd_bus 这个类型 */

/* MIO 复用 + 方向 + 串口校准。返回 0 = OK；-1 = CLK 回读自检失败 */
int  sd_bit_init(void);

/* 半周期忙等循环次数。约 300 -> ~100 kHz（识别阶段必须 100~400 kHz）；
 * 识别完成后可以调小提速（例如 20 -> ~1 MHz），但位翻转跑不快的。 */
void sd_bit_set_half(u32 n);
u32  sd_bit_half(void);

/* 上电时序：CMD 拉高 + 打 90 个时钟（SD 规范要求 >= 74） */
void sd_bit_powerup(void);

/* 完整识别：CMD0 -> CMD8 -> ACMD41 -> CMD2 -> CMD3 -> CMD7 -> CMD16。
 * 成功返回 0 并通过 rca 回传 RCA；失败返回负的步骤号，同时把过程打进日志：
 *   -1 CMD8 无响应   -2 ACMD41 不完成   -3 CMD2 无响应
 *   -4 CMD3 无响应   -5 CMD7 无响应     -6 CMD16 无响应 */
int  sd_bit_card_init(u32 *rca);

/* 位级原语包成的 sd_bus（ctx 忽略，传 NULL 即可） */
const sd_bus *sd_bit_bus(void);

/* 诊断：最近一次等响应起始位期间采样到的位（最近 32 位；全 1 说明线一直是高） */
u32  sd_bit_waitbits(void);

/* 诊断：最近一次响应前打掉了多少个时钟（NCR，单位 bit；规范上限 64） */
u32  sd_bit_waitcount(void);

/* 提速试探：把时钟改成 fast_half 后读一次 LBA0，失败自动退回原速度。
 * 返回 1=高速可用  0=已退回慢速  -1=两种速度都读不出来
 * blk512 必须是 512 字节可写缓冲。 */
int  sd_bit_speed_probe(u32 fast_half, u8 *blk512);

#endif /* SD_BIT_H */
