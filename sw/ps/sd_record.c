/* =============================================================================
 * sw/ps/sd_record.c -- 样本 -> CSV -> 格式化 -> 落盘 -> 回读逐字节比对
 * -----------------------------------------------------------------------------
 * 纯逻辑，不碰硬件（见 sd_record.h 里"为什么抽出来"）。
 *
 * 回读比对不用校验和就下结论，而是**逐字节比**：卡上读回来的字节直接和
 * csv[] 里的对应字节比，统计不同的个数（bytes_diff 必须为 0）。校验和只是
 * 方便人看和跨平台对账。
 *
 * 注意簇链：fat32_write_file() 一定是"从 first_clus 开始连续分配"，
 * 所以这里按 first_clus..first_clus+nclus-1 顺序读即可。如果以后换成
 * "从空闲链表里挑"的分配器，这里必须改成真的走 FAT 链。
 * ============================================================================= */
#include "sd_record.h"
#include "xil_printf.h"

#define BLK 512U

static u32 djb2(const u8 *p, u32 n)
{
    u32 h = 5381U;
    u32 i;

    for (i = 0; i < n; i++) {
        h = ((h << 5) + h + (u32)p[i]);
    }
    return h;
}

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

int sd_record_to_card(const sd_bus *bus, const fat32_geo *g,
                      const u16 *samples, u32 n,
                      u8 *csv, u32 csv_cap,
                      u8 *blk,
                      sd_record_stat *st)
{
    fat32_io io;
    u32 csvlen;
    u32 h_csv;
    u32 root_lba;
    u32 first = 0U;
    u32 flen = 0U;
    u32 nclus;
    u32 c, off, k;
    u32 h_card = 5381U;
    u32 diff = 0U;
    u32 compared = 0U;
    int rc;

    if (st != 0) {
        u8 *p = (u8 *)st;
        u32 i;

        for (i = 0; i < (u32)sizeof(*st); i++) { p[i] = 0U; }
    }

    /* --- 1. CSV --- */
    csvlen = fat32_csv_from_samples(csv, csv_cap, samples, n);
    if ((csvlen == 0U) || (csvlen >= csv_cap)) {
        return SDR_ECSV;
    }
    h_csv = djb2(csv, csvlen);
    nclus = (csvlen + BLK - 1U) / BLK;
    xil_printf("  sdr: csv %u bytes djb2=0x%08x, %u clusters\n", csvlen, h_csv, nclus);

    io.ctx   = (void *)bus;
    io.read  = sd_fat_read;
    io.write = sd_fat_write;

    /* --- 2. 格式化 --- */
    rc = fat32_format(&io, g);
    if (rc != 0) {
        xil_printf("  sdr: format rc=%d\n", rc);
        return SDR_EFORMAT;
    }

    /* --- 3. 写文件 --- */
    rc = fat32_write_file(&io, g, "REC     CSV", csv, csvlen);
    if (rc != 0) {
        xil_printf("  sdr: write_file rc=%d\n", rc);
        return SDR_EWRITE;
    }

    /* --- 4. 回读目录项 --- */
    root_lba = g->reserved + (u32)g->nfats * g->fat_sec;
    rc = sd_read_block(bus, root_lba, blk);
    if (rc != 0) {
        xil_printf("  sdr: read root rc=%d\n", rc);
        return SDR_EROOT;
    }
    first = ((u32)rd16(&blk[20]) << 16) | (u32)rd16(&blk[26]);
    flen  = rd32(&blk[28]);
    xil_printf("  sdr: dirent clus=%u len=%u\n", first, flen);
    if (flen != csvlen) {
        xil_printf("  sdr: len mismatch card=%u csv=%u\n", flen, csvlen);
        return SDR_ELEN;
    }

    /* --- 5. 回读数据并逐字节比对 --- */
    off = 0U;
    for (c = 0U; c < nclus; c++) {
        u32 lba = root_lba + (first - g->root_clus) * (u32)g->sec_per_clus + c;

        rc = sd_read_block(bus, lba, blk);
        if (rc != 0) {
            xil_printf("  sdr: read data lba=%u rc=%d\n", lba, rc);
            return SDR_EREAD;
        }
        for (k = 0U; (k < BLK) && (off < csvlen); k++, off++) {
            h_card = (h_card << 5) + h_card + (u32)blk[k];
            compared++;
            if (blk[k] != csv[off]) {
                diff++;
            }
        }
    }
    /* 最后一个扇区的尾部（文件长度之后的填充）应该是 0：确认没写脏。
     * 注意 csvlen 正好是 512 的整数倍时没有填充，不能查。 */
    if ((csvlen % BLK) != 0U) {
        for (k = csvlen % BLK; k < BLK; k++) {
            if (blk[k] != 0U) { diff++; }
        }
    }

    xil_printf("  sdr: compared %u bytes, diff=%u, djb2 card=0x%08x\n",
               compared, diff, h_card);

    if (st != 0) {
        st->csv_bytes      = csvlen;
        st->djb2_csv       = h_csv;
        st->djb2_card      = h_card;
        st->bytes_compared = compared;
        st->bytes_diff     = diff;
        st->first_clus     = first;
        st->clusters       = nclus;
    }
    if (diff != 0U) {
        return SDR_EMISMATCH;
    }
    return SDR_OK;
}

/* -----------------------------------------------------------------------------
 * 证据扇区计划（逻辑说明见 sd_record.h）
 * -------------------------------------------------------------------------- */
int sd_evid_plan(const u8 *boot, const u8 *root, sd_evid_plan_t *p)
{
    u32 rsv, nfat, spc, fatsec, root_clus, fsinfo_lba, backup_lba, total;
    u32 root_lba, first, flen, nclus, d0, n, i;

    if (p == 0) { return -1; }

    rsv        = rd16(&boot[14]);
    nfat       = boot[16];
    spc        = boot[13];
    fatsec     = rd32(&boot[36]);
    root_clus  = rd32(&boot[44]);
    fsinfo_lba = rd16(&boot[48]);
    backup_lba = rd16(&boot[50]);
    total      = rd32(&boot[32]);

    if ((total == 0U) || (rsv == 0U) || (fatsec == 0U) || (spc == 0U) ||
        (root_clus < 2U)) {
        return -1;
    }

    root_lba = rsv + nfat * fatsec;

    first = (root != 0) ? ((((u32)rd16(&root[20]) << 16) | (u32)rd16(&root[26]))) : 0U;
    flen  = (root != 0) ? rd32(&root[28]) : 0U;
    if ((root == 0) || (first < root_clus) || (flen == 0U)) {
        nclus = 0U;                 /* 根目录里没有文件 */
        d0 = root_lba;
    } else {
        nclus = (flen + 511U) / 512U;
        d0 = root_lba + (first - root_clus) * spc;
    }

    n = 0U;
    p->lba[n++] = 0U;
    if (fsinfo_lba != 0U) { p->lba[n++] = fsinfo_lba; }
    if (backup_lba != 0U) { p->lba[n++] = backup_lba; }
    p->lba[n++] = rsv;
    p->lba[n++] = root_lba;
    if ((n + nclus) > SD_EVID_MAX) {
        p->n = n;
        return -2;
    }
    for (i = 0U; i < nclus; i++) {
        p->lba[n++] = d0 + i;
    }

    p->n         = n;
    p->total_sec = total;
    p->reserved  = rsv;
    p->fat_sec   = fatsec;
    p->root_lba  = root_lba;
    p->first_clus = first;
    p->file_len  = flen;
    p->data_secs = nclus;
    return 0;
}
