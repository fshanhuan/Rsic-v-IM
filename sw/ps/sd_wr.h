/* =============================================================================
 * sw/ps/sd_wr.h -- 块读写（CMD17/CMD24）的"总线无关"实现
 * -----------------------------------------------------------------------------
 * 为什么要抽一层：SD 协议的**时序细节**（令牌、CRC、忙等）和**底层怎么翻位**
 * （GPIO 位翻转 / SDHCI / 内存假卡）是两件事。把前者写成只依赖几个回调的模块，
 * 就能：
 *   · 现在先编译验证、用内存假卡把逻辑跑一遍（不需要真的卡）；
 *   · 等卡到了直接接上，不用改协议代码；
 *   · 以后换成 SDHCI 也只需要重写回调。
 *
 * 回调顺序（读完/写完一个块）：
 *     cmd -> resp48 -> dir(1 主机发) -> tx_d0 ... -> dir(0 卡发) -> rx_d0 ...
 * dir 是**可选**的：位翻转驱动里 CMD 线是半双工的，写完数据必须把线交还，
 * 否则收不到数据响应令牌；内存假卡不需要它，传 NULL 即可。
 * ============================================================================= */
#ifndef SD_WR_H
#define SD_WR_H

#include "xil_types.h"

typedef struct {
    /* 发一条命令（48 bit，含 CRC7），然后释放 CMD 线 */
    void (*cmd)(void *ctx, u32 idx, u32 arg);
    /* 读 48 bit 响应；0 = 成功，-1 = 超时；r 回填 32 bit 内容 */
    int  (*resp48)(void *ctx, u32 *r);
    /* 可选：切数据线方向（1 = 主机驱动，0 = 卡驱动）。可为 NULL */
    void (*dir)(void *ctx, int host_out);
    /* 往 DAT0 发一个字节（数据阶段） */
    void (*tx_d0)(void *ctx, u8 b);
    /* 从 DAT0 收一个字节 */
    u8   (*rx_d0)(void *ctx);
    /* 从 DAT0 收一位（等忙用） */
    u32  (*rx_bit_d0)(void *ctx);
    void *ctx;
} sd_bus;

/* sd_read_block / sd_write_block 的返回码 */
#define SDW_OK          0
#define SDW_ENORESP   (-1)   /* 命令没有响应 */
#define SDW_ER1       (-2)   /* R1 里报了错位 */
#define SDW_ENOTOKEN  (-3)   /* 读：等不到 0xFE 起始令牌 */
#define SDW_EDCRC     (-4)   /* 读：CRC16 不对（数据坏了） */
#define SDW_ECRC      (-5)   /* 写：卡回 CRC 错令牌 */
#define SDW_EWRITE    (-6)   /* 写：卡回写错令牌 */
#define SDW_ENODR     (-7)   /* 写：收不到数据响应令牌 */
#define SDW_EBUSY     (-8)   /* 写：卡一直忙，等不到释放 */

/* 读一个 512 字节块：CMD17 + 等 0xFE + 512 数据 + 2 字节 CRC */
int sd_read_block(const sd_bus *b, u32 lba, u8 *buf);

/* 写一个 512 字节块：CMD24 + 0xFE + 512 数据 + CRC16 + 数据响应 + 等忙释放 */
int sd_write_block(const sd_bus *b, u32 lba, const u8 *buf);

/* 给 fat32_io 用的适配器（ctx 就是 const sd_bus *） */
int sd_fat_read(void *ctx, u32 lba, u8 *buf);
int sd_fat_write(void *ctx, u32 lba, u8 *buf);

#endif /* SD_WR_H */
