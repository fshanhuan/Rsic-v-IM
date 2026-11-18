/* =============================================================================
 * sw/ps/sd_record.h -- "样本 -> CSV -> 格式化 -> 落盘 -> 回读逐字节比对" 的纯逻辑
 * -----------------------------------------------------------------------------
 * 为什么把这段单独抽出来：
 *   `sd_fat_sd.c`（真卡产品路径）原来把这段流程写死在 main() 里，而 main() 里有
 *   OCM 地址、有记录仪 MMIO、有卡初始化 —— 于是**没卡就一行都跑不到**，只能
 *   "编译通过"。抽出来之后：
 *     · 板上：sd_fat_sd.c = 初始化 + 抓样本 + 调这里（同一份代码）；
 *     · PC 上：tools/ps/host 的测试把这里和 64 MB 假卡一起跑，
 *       于是产品流程本身就有了可执行证据（不需要卡、不需要板子）。
 *
 * 这个文件不碰任何硬件：所有 I/O 都走 sd_bus，所有缓冲都由调用者给。
 * ============================================================================= */
#ifndef SD_RECORD_H
#define SD_RECORD_H

#include "fat32.h"
#include "sd_wr.h"

typedef struct {
    u32 csv_bytes;        /* 生成的 CSV 字节数 */
    u32 djb2_csv;         /* 写之前 CSV 的校验和 */
    u32 djb2_card;        /* 从卡上读回来重算的校验和 */
    u32 bytes_compared;   /* 逐字节比对了多少字节 */
    u32 bytes_diff;       /* 其中不同的字节数（必须是 0） */
    u32 first_clus;       /* 目录项里的首簇 */
    u32 clusters;         /* 文件占用簇数 */
    u32 blocks_written;   /* 一共写了多少扇区 */
} sd_record_stat;

/* 返回码 */
#define SDR_OK            0
#define SDR_ECSV        (-1)   /* CSV 生成失败（容量不足） */
#define SDR_EFORMAT     (-2)   /* 格式化失败 */
#define SDR_EWRITE      (-3)   /* 写文件失败 */
#define SDR_EROOT       (-4)   /* 回读根目录失败 */
#define SDR_ELEN        (-5)   /* 目录项里的长度和 CSV 长度不一致 */
#define SDR_EREAD       (-6)   /* 回读文件数据失败 */
#define SDR_EMISMATCH   (-7)   /* 回读内容与 CSV 不是逐字节相同 */

/* 把 n 个样本写成 CSV，整卷格式化后写进 bus 指向的卡，再从卡上读回来
 * **逐字节**比对。全部成功返回 0 并填 st（st 可以为 NULL）。
 *
 * csv / csv_cap : CSV 文本缓冲（真卡上建议 >= 16 KB）
 * blk           : 512 字节、4 字节对齐的临时扇区缓冲
 */
int sd_record_to_card(const sd_bus *bus, const fat32_geo *g,
                      const u16 *samples, u32 n,
                      u8 *csv, u32 csv_cap,
                      u8 *blk,
                      sd_record_stat *st);

/* -----------------------------------------------------------------------------
 * 证据扇区计划：决定"验证 FAT32 布局要 dump 哪些扇区"
 * -----------------------------------------------------------------------------
 * 抽出来的原因：这段逻辑原来只写在 sw/ps/sd_dump.c 里（板上程序，没卡就一行跑不到）。
 * 抽成纯函数之后，PC 上的测试拿同一份代码算一遍，就不用"两个实现互相看着像"。
 *
 * 输入：boot = 引导扇区（LBA0，512 字节），root = 根目录簇那个扇区（512 字节）
 * 输出：p->n 个扇区号；顺序固定为 引导 / FSInfo / 备份引导 / FAT 第一扇区 /
 *       根目录 / 文件占用的**全部**数据扇区。
 *
 * 早期写死"文件前两簇"，899 字节的文件没事，9603 字节（19 簇）的文件在第 1024
 * 字节就对不上了 —— 见方案 §42.3。
 * 返回 0 = 成功；-1 = 引导扇区不像 FAT32；-2 = 扇区数超出 max（p->n 个都放不下）。
 * -------------------------------------------------------------------------- */
#define SD_EVID_MAX 32U

typedef struct {
    u32 n;              /* 一共几个扇区 */
    u32 lba[SD_EVID_MAX];
    u32 total_sec;      /* BPB 里的卷总扇区数 */
    u32 reserved;
    u32 fat_sec;
    u32 root_lba;
    u32 first_clus;
    u32 file_len;
    u32 data_secs;      /* 其中数据扇区个数 */
} sd_evid_plan_t;

int sd_evid_plan(const u8 *boot, const u8 *root, sd_evid_plan_t *p);

#endif /* SD_RECORD_H */
