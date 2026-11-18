/* =============================================================================
 * sw/ps/fat32.h -- 极简 FAT32 写入器接口（几何参数可调）
 * -----------------------------------------------------------------------------
 * 只依赖两个块读写回调，所以同一份代码可以跑在：
 *   · 真卡（SD 位翻转 / SDHCI）
 *   · 内存假盘（验证 FAT32 逻辑，不需要卡 —— `sw/ps/fat32_test.c` 就是这么用的）
 *
 * 之所以把几何参数暴露出来：真卡用 64 MB/512B 簇（Windows 才认 FAT32），
 * 而板上内存假盘只有 64 KB，必须用"小几何"才能验证同一套代码。
 * ============================================================================= */
#ifndef FAT32_H
#define FAT32_H

#include "xil_types.h"

typedef struct {
    void *ctx;
    int (*read)(void *ctx, u32 lba, u8 *buf);
    int (*write)(void *ctx, u32 lba, u8 *buf);
} fat32_io;

typedef struct {
    u32 total_sec;      /* 卷总扇区数 */
    u16 sec_per_clus;   /* 每簇扇区数（2 的幂） */
    u32 reserved;       /* 保留扇区（含引导扇区） */
    u32 fat_sec;        /* 每份 FAT 的扇区数 */
    u32 root_clus;      /* 根目录起始簇（通常 2） */
    u8  nfats;          /* FAT 份数 */
    char label[12];     /* 卷标，11 字节 + 0 */
} fat32_geo;

/* 真卡用的默认几何：64 MB 卷、512 字节簇（保证 Windows 认成 FAT32） */
void fat32_geo_default(fat32_geo *g);

/* 小几何：给内存假盘验证用（total_sec 个扇区、1 扇区/簇、1 份 FAT） */
void fat32_geo_small(fat32_geo *g, u32 total_sec);

int fat32_format(fat32_io *io, const fat32_geo *g);
int fat32_write_file(fat32_io *io, const fat32_geo *g,
                     const char *name11, const u8 *data, u32 len);

/* 把 16 位样本数组转成 CSV 文本，返回字节数 */
u32 fat32_csv_from_samples(u8 *out, u32 out_cap, const u16 *s, u32 n);

/* 真卡最少要多少扇区才够 Windows 认 FAT32（64 MB） */
#define FAT32_MIN_SECTORS  131072U

#endif /* FAT32_H */
