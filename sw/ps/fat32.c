/* =============================================================================
 * sw/ps/fat32.c -- 极简 FAT32 写入器（整卷格式化 + 写一个 8.3 文件）
 * -----------------------------------------------------------------------------
 * 设计取舍：
 *   · **整卷格式化**而不是"往已有文件系统里加文件"：解析已有 BPB/FAT/目录/簇链
 *     代码量大且易错；自己格式化则结构完全可控、可复现。
 *     代价是**会清掉卡上原有数据**，所以只该在测试卡上用。
 *   · 几何参数可调：真卡用 64 MB/512B 簇（Windows 只把"簇数>=65525"的卷认成
 *     FAT32），板上内存假盘只有 64 KB，就用小几何验证同一套代码。
 *
 * 目录项按 8.3 短名写（不用长文件名），这样代码最短、最不容易出错。
 * ============================================================================= */
#include "fat32.h"
#include "xil_printf.h"

#define SECSZ 512U

/* ★ 2026-11-18 的大坑：这些"逐字节"的 16/32 位写入，在 -O2 下会被 gcc
 * **合并成一条 strh/str**。而 FAT32 的引导扇区里有大量奇地址字段
 * (bs[11]、bs[17]、bs[67]…)，合并后就是非对齐访问 -> Cortex-A9 直接对齐异常
 * (DFSR=0x801 DFAR=奇数)。这里用 volatile 逐字节访问，禁止编译器合并。 */
static u16 rd16(const u8 *p)
{
    const volatile u8 *q = p;
    return (u16)(q[0] | ((u16)q[1] << 8));
}

static u32 rd32(const u8 *p)
{
    const volatile u8 *q = p;
    return (u32)q[0] | ((u32)q[1] << 8) | ((u32)q[2] << 16) | ((u32)q[3] << 24);
}

static void wr16(u8 *p, u16 v)
{
    volatile u8 *q = p;
    q[0] = (u8)v;
    q[1] = (u8)(v >> 8);
}

static void wr32(u8 *p, u32 v)
{
    volatile u8 *q = p;
    q[0] = (u8)v;
    q[1] = (u8)(v >> 8);
    q[2] = (u8)(v >> 16);
    q[3] = (u8)(v >> 24);
}

static void mem_set(void *d, int c, u32 n)
{
    u8 *p = (u8 *)d;

    while (n-- > 0U) { *p++ = (u8)c; }
}

static void mem_cpy(void *d, const void *s, u32 n)
{
    u8 *p = (u8 *)d;
    const u8 *q = (const u8 *)s;

    while (n-- > 0U) { *p++ = *q++; }
}

/* ------------------------------ 几何参数 -------------------------------- */
void fat32_geo_default(fat32_geo *g)
{
    u32 i;

    g->total_sec    = 131072U;   /* 64 MB */
    g->sec_per_clus = 1U;
    g->reserved     = 32U;
    g->fat_sec      = 1024U;
    g->root_clus    = 2U;
    g->nfats        = 1U;
    for (i = 0; i < 11U; i++) { g->label[i] = ' '; }
    mem_cpy(g->label, "RECORDER   ", 11U);
    g->label[11] = '\0';
}

void fat32_geo_small(fat32_geo *g, u32 total_sec)
{
    u32 i;

    g->total_sec    = total_sec;
    g->sec_per_clus = 1U;
    g->reserved     = 2U;
    g->fat_sec      = 1U;
    g->root_clus    = 2U;
    g->nfats        = 1U;
    for (i = 0; i < 11U; i++) { g->label[i] = ' '; }
    mem_cpy(g->label, "RECORDER   ", 11U);
    g->label[11] = '\0';
}

static u32 data_lba(const fat32_geo *g, u32 clus)
{
    return g->reserved + (u32)g->nfats * g->fat_sec +
           (clus - 2U) * (u32)g->sec_per_clus;
}

static int set_fat(fat32_io *io, const fat32_geo *g, u32 idx, u32 val)
{
    u32 byte = idx * 4U;
    u32 sec  = g->reserved + byte / SECSZ;
    u32 off  = byte % SECSZ;
    static u8 buf[SECSZ] __attribute__((aligned(4)));

    if (io->read(io->ctx, sec, buf) != 0) {
        mem_set(buf, 0, SECSZ);
    }
    wr32(&buf[off], val);
    return io->write(io->ctx, sec, buf);
}

/* ------------------------------ 格式化 ---------------------------------- */
int fat32_format(fat32_io *io, const fat32_geo *g)
{
    static u8 bs[SECSZ] __attribute__((aligned(4)));
    static u8 fi[SECSZ] __attribute__((aligned(4)));
    static u8 z[SECSZ]  __attribute__((aligned(4)));
    u32 i;

    /* --- 引导扇区 --- */
    mem_set(bs, 0, SECSZ);
    bs[0] = 0xEBU; bs[1] = 0x58U; bs[2] = 0x90U;
    mem_cpy(&bs[3], "MSDOS5.0", 8U);
    wr16(&bs[11], SECSZ);
    bs[13] = (u8)g->sec_per_clus;
    wr16(&bs[14], (u16)g->reserved);
    bs[16] = g->nfats;
    wr16(&bs[17], 0);                       /* root entries = 0 (FAT32) */
    wr16(&bs[19], 0);
    bs[21] = 0xF8U;
    wr16(&bs[22], 0);                       /* FAT size 16 = 0 */
    wr16(&bs[24], 63);
    wr16(&bs[26], 255);
    wr32(&bs[28], 0);
    wr32(&bs[32], g->total_sec);
    wr32(&bs[36], g->fat_sec);
    wr16(&bs[40], 0);
    wr16(&bs[42], 0);
    wr32(&bs[44], g->root_clus);
    wr16(&bs[48], 1);                       /* FSInfo 扇区号 */
    wr16(&bs[50], 6);                       /* 备份引导扇区 */
    bs[64] = 0x80U;
    bs[66] = 0x29U;
    wr32(&bs[67], 0x12345678U);
    mem_cpy(&bs[71], g->label, 11U);
    mem_cpy(&bs[82], "FAT32   ", 8U);
    xil_printf("  f1 bpb built\n");
    bs[510] = 0x55U; bs[511] = 0xAAU;
    if (io->write(io->ctx, 0U, bs) != 0) { return -1; }
    if (g->reserved > 6U) {
        if (io->write(io->ctx, 6U, bs) != 0) { return -1; }
    }

    xil_printf("  f2 boot written\n");

    /* --- FSInfo --- */
    mem_set(fi, 0, SECSZ);
    wr32(&fi[0],   0x41615252U);
    wr32(&fi[484], 0x61417272U);
    wr32(&fi[488], 0xFFFFFFFFU);
    wr32(&fi[492], 0xFFFFFFFFU);
    wr32(&fi[508], 0xAA550000U);
    if (g->reserved > 1U) {
        if (io->write(io->ctx, 1U, fi) != 0) { return -1; }
    }

    xil_printf("  f3 fsinfo written\n");

    /* --- 清 FAT --- */
    mem_set(z, 0, SECSZ);
    for (i = 0; i < g->fat_sec; i++) {
        if (io->write(io->ctx, g->reserved + i, z) != 0) { return -1; }
    }
    xil_printf("  f4 fat cleared\n");

    /* FAT[0]/FAT[1] 标记 */
    mem_set(z, 0, SECSZ);
    wr32(&z[0], 0x0FFFFFF8U);
    wr32(&z[4], 0x0FFFFFFFU);
    if (io->write(io->ctx, g->reserved, z) != 0) { return -1; }

    xil_printf("  f5 fat marks written\n");

    /* --- 清根目录簇并标记链尾 --- */
    mem_set(z, 0, SECSZ);
    if (io->write(io->ctx, data_lba(g, g->root_clus), z) != 0) { return -1; }
    if (set_fat(io, g, g->root_clus, 0x0FFFFFFFU) != 0) { return -1; }
    if (set_fat(io, g, 0U, 0x0FFFFFF8U) != 0) { return -1; }
    if (set_fat(io, g, 1U, 0x0FFFFFFFU) != 0) { return -1; }

    xil_printf("  fat32: format %u sec, spc=%u, reserved=%u, fat=%u sec, root=%u\n",
               g->total_sec, (u32)g->sec_per_clus, g->reserved, g->fat_sec,
               g->root_clus);
    return 0;
}

/* ---------------------------- 写一个文件 -------------------------------- */
int fat32_write_file(fat32_io *io, const fat32_geo *g,
                     const char *name11, const u8 *data, u32 len)
{
    static u8 sec[SECSZ] __attribute__((aligned(4)));
    static u8 de[32] __attribute__((aligned(4)));
    u32 nclus = (len + SECSZ - 1U) / SECSZ;
    u32 first;
    u32 c, off, i;

    if (nclus == 0U) { nclus = 1U; }
    first = g->root_clus + 1U;          /* 数据紧接着根目录簇 */

    /* 容量检查：别写出卷外 */
    if (first + nclus > (g->reserved + (u32)g->nfats * g->fat_sec) / (u32)g->sec_per_clus + 2U) {
        /* 用更直白的判据：数据区可用簇数 */
    }
    if ((first + nclus - 2U) * (u32)g->sec_per_clus + 1U >
        g->total_sec - (g->reserved + (u32)g->nfats * g->fat_sec)) {
        xil_printf("  fat32: file too big for volume (%u clusters)\n", nclus);
        return -2;
    }

    /* 簇链 */
    for (c = 0; c < nclus; c++) {
        u32 clus = first + c;
        u32 next = (c + 1U < nclus) ? (clus + 1U) : 0x0FFFFFFFU;

        if (set_fat(io, g, clus, next) != 0) { return -1; }
    }

    /* 数据 */
    for (c = 0; c < nclus; c++) {
        u32 o = c * SECSZ;
        u32 n = len - o;

        mem_set(sec, 0, SECSZ);
        if (n > SECSZ) { n = SECSZ; }
        mem_cpy(sec, data + o, n);
        if (io->write(io->ctx, data_lba(g, first + c), sec) != 0) { return -1; }
    }

    /* 目录项 */
    mem_set(de, 0, 32U);
    for (i = 0; i < 11U; i++) { de[i] = (u8)name11[i]; }
    de[11] = 0x20U;
    wr16(&de[20], (u16)(first >> 16));
    wr16(&de[26], (u16)first);
    wr32(&de[28], len);

    if (io->read(io->ctx, data_lba(g, g->root_clus), sec) != 0) {
        mem_set(sec, 0, SECSZ);
    }
    for (off = 0; off + 32U <= SECSZ; off += 32U) {
        if ((sec[off] == 0x00U) || (sec[off] == 0xE5U)) { break; }
    }
    if ((off + 32U) > SECSZ) {
        return -3;                       /* 根目录满 */
    }
    mem_cpy(&sec[off], de, 32U);
    if (io->write(io->ctx, data_lba(g, g->root_clus), sec) != 0) { return -1; }

    xil_printf("  fat32: wrote %u bytes, %u clusters from %u\n", len, nclus, first);
    return 0;
}

/* --------------------------- CSV 文本化 --------------------------------- */
u32 fat32_csv_from_samples(u8 *out, u32 out_cap, const u16 *s, u32 n)
{
    static const char hdr[] = "idx,adc\r\n";
    u32 pos = 0U;
    u32 i;
    char num[12];

    for (i = 0; (hdr[i] != '\0') && (pos < out_cap); i++) {
        out[pos++] = (u8)hdr[i];
    }

    for (i = 0; (i < n) && (pos + 24U < out_cap); i++) {
        int m = 0;
        u32 t = i;

        do {
            num[m++] = (char)('0' + (t % 10U));
            t /= 10U;
        } while ((t != 0U) && (m < 11));
        while (m > 0) { out[pos++] = (u8)num[--m]; }

        out[pos++] = (u8)',';
        m = 0;
        t = s[i];
        do {
            num[m++] = (char)('0' + (t % 10U));
            t /= 10U;
        } while ((t != 0U) && (m < 11));
        while (m > 0) { out[pos++] = (u8)num[--m]; }

        out[pos++] = (u8)'\r';
        out[pos++] = (u8)'\n';
    }
    return pos;
}
