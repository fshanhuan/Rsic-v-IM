/* =============================================================================
 * tools/ps/host/fat32_host_test.c -- 在 PC 上跑**同一份** fat32.c + sd_wr.c
 * -----------------------------------------------------------------------------
 * 为什么需要它（解决一个真实缺口）：
 *   板上那套测试跑的是"小几何"（128 扇区、1 扇区/簇、reserved=2、1 份 FAT），
 *   因为 OCM 只有 192 KB。但**真卡用的是 64 MB 几何**：
 *   131072 扇区、reserved=32、每份 FAT 1024 扇区、65525+ 个簇。
 *   这两条路径在 fat32.c 里是**同一个函数的不同参数**，谁也没保证大几何没写错
 *   （FAT 要 1016 个扇区才装得下 130018 个条目，差一点就写坏了）。
 *   本机正好有 MinGW gcc（E:\MinGW\bin\gcc.exe），于是把 fat32.c / sd_wr.c
 *   **原封不动**编译成 PC 程序，用 malloc 的 64 MB 当"卡"，把大几何跑一遍。
 *
 * 编译（见 tools/ps/host/build_and_run.ps1）：
 *   E:\MinGW\bin\gcc.exe -O2 -Wall -Isw/ps -Isw/ps/port ^
 *       tools/ps/host/fat32_host_test.c sw/ps/fat32.c sw/ps/sd_wr.c -o host_test.exe
 *
 * 产出：
 *   sim/build/sd/host_small.img   (64 KB，小几何，回归)
 *   sim/build/sd/host_64mb.img    (64 MB，真卡几何)
 * 两镜像都交给 tools/ps/fat32_verify.py 按 FAT32 规范独立复核。
 *
 * 注意：这里的"假卡"和板上 sd_wr_test.c 里的那份是**两处独立实现**（都是测试
 *       代码，一个跑在 ARM 裸机、一个跑在 PC）。协议语义一样：令牌前缀、卡侧
 *       自己重算 CRC16、数据响应令牌、忙信号。
 * ============================================================================= */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "fat32.h"
#include "sd_wr.h"
#include "sd_record.h"
#include "sd_crc.h"

/* fat32.c / sd_wr.c 需要的三个外部符号（裸机上是 UART + 内存日誌） */
void port_uart_init(void) { }
void port_log_reset(void) { }

int xil_printf(const char *fmt, ...)
{
    va_list ap;
    int r;

    va_start(ap, fmt);
    r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}

/* ============================ 假卡（协议模型） ============================ */
#define FS_IDLE   0
#define FS_READ   1
#define FS_WRITE  2

static u8  *g_disk;          /* 卡存储 */
static u32  g_nsec;          /* 卡容量（扇区） */

static u32  fc_stream;
static u32  fc_arg;
static u32  fc_spos;
static u32  fc_pad;          /* 读流前缀 0xFF 个数 */
static u32  fc_pending;
static u8   fc_buf[512];
static u8   fc_crc[2];
static u8   fc_tok;
static u32  fc_dr;           /* 0=未发 1=已发 0xFF 2=已发令牌 */
static u32  fc_busy;

static u32  fc_wr_ok;
static u32  fc_wr_crc_bad;
static u32  fc_wr_range_bad;
static u32  fc_rd_ok;
static u32  fc_badtok;

static u16 c16(const u8 *d, u32 n)
{
    u16 crc = 0U;
    u32 i;
    int b;

    for (i = 0; i < n; i++) {
        crc ^= (u16)((u16)d[i] << 8);
        for (b = 0; b < 8; b++) {
            crc = (crc & 0x8000U) ? (u16)((crc << 1) ^ 0x1021U) : (u16)(crc << 1);
        }
    }
    return crc;
}

static void fc_cmd(void *ctx, u32 idx, u32 arg)
{
    (void)ctx;
    fc_arg = arg;
    fc_pending = 0U;
    fc_spos = 0U;
    fc_dr = 0U;
    if (idx == 17U) {
        fc_stream = FS_READ;
    } else if (idx == 24U) {
        fc_stream = FS_WRITE;
        fc_tok = 0x05U;
        fc_busy = 0U;
    } else {
        fc_stream = FS_IDLE;
    }
}

static int fc_resp48(void *ctx, u32 *r)
{
    (void)ctx;
    *r = 0U;
    return 0;
}

static void fc_dir(void *ctx, int host_out)
{
    (void)ctx;
    (void)host_out;
}

static void fc_tx(void *ctx, u8 b)
{
    (void)ctx;

    if (fc_stream != FS_WRITE) {
        fc_badtok++;
        return;
    }
    if (fc_pending == 0U) {
        if (b == 0xFEU) {
            fc_pending = 1U;
        } else {
            fc_badtok++;
        }
        return;
    }
    if (fc_pending <= 512U) {
        fc_buf[fc_pending - 1U] = b;
        fc_pending++;
        return;
    }
    fc_crc[fc_pending - 513U] = b;
    fc_pending++;
    if (fc_pending < 515U) {
        return;
    }

    {
        u16 want = c16(fc_buf, 512U);
        u16 got  = (u16)(((u16)fc_crc[0] << 8) | (u16)fc_crc[1]);

        if (want != got) {
            fc_wr_crc_bad++;
            fc_tok = 0x0BU;
        } else if (fc_arg >= g_nsec) {
            fc_wr_range_bad++;
            fc_tok = 0x0DU;
        } else {
            memcpy(g_disk + (size_t)fc_arg * 512U, fc_buf, 512U);
            fc_wr_ok++;
            fc_tok = 0x05U;
            fc_busy = 16U;
        }
    }
    fc_pending = 0U;
}

static u8 fc_rx(void *ctx)
{
    (void)ctx;

    if (fc_stream == FS_READ) {
        if (fc_spos < fc_pad) {
            fc_spos++;
            return 0xFFU;
        }
        if (fc_spos == fc_pad) {
            fc_spos++;
            return 0xFEU;
        }
        {
            u32 k = fc_spos - fc_pad - 1U;
            u8 v;

            if (k < 512U) {
                v = (fc_arg < g_nsec) ? g_disk[(size_t)fc_arg * 512U + k] : 0x00U;
            } else {
                u16 c = (fc_arg < g_nsec)
                      ? c16(g_disk + (size_t)fc_arg * 512U, 512U) : 0x0000U;

                v = (k == 512U) ? (u8)(c >> 8) : (u8)c;
            }
            fc_spos++;
            if (fc_spos >= fc_pad + 1U + 514U) {
                fc_rd_ok++;
                fc_stream = FS_IDLE;
            }
            return v;
        }
    }
    if (fc_stream == FS_WRITE) {
        if (fc_dr == 0U) { fc_dr = 1U; return 0xFFU; }
        if (fc_dr == 1U) { fc_dr = 2U; return fc_tok; }
        return 0xFFU;
    }
    return 0xFFU;
}

static u32 fc_rxbit(void *ctx)
{
    (void)ctx;
    if (fc_busy > 0U) {
        fc_busy--;
        return 0U;
    }
    return 1U;
}

static const sd_bus card_bus = { fc_cmd, fc_resp48, fc_dir, fc_tx, fc_rx, fc_rxbit, 0 };

/* ============================== 测试框架 ================================= */
static u32 t_pass;
static u32 t_fail;

static void chk(const char *what, int got, int want)
{
    if (got == want) {
        t_pass++;
        printf("  [ok] %s = %d\n", what, got);
    } else {
        t_fail++;
        printf("  [FAIL] %s = %d (want %d)\n", what, got, want);
    }
}

static u32 djb2(const u8 *p, u32 n)
{
    u32 h = 5381U;
    u32 i;

    for (i = 0; i < n; i++) {
        h = ((h << 5) + h + (u32)p[i]);
    }
    return h;
}

static int save(const char *path, const u8 *p, u32 n)
{
    FILE *f = fopen(path, "wb");

    if (f == 0) {
        printf("  cannot write %s\n", path);
        return -1;
    }
    fwrite(p, 1U, n, f);
    fclose(f);
    printf("  saved %s (%u bytes)\n", path, n);
    return 0;
}

/* -----------------------------------------------------------------------------
 * 证据缓冲区（板上 sd_dump.c 用同一个格式、同一套选取规则，这样"能读卡之后"的
 * 验证流程现在就能在 PC 上整条跑通）：
 *   +0      4 字节 'S','D','C','1'
 *   +4      u32 n
 *   +8      n 个 { u32 lba, u32 off }   off = 该扇区数据在缓冲区里的字节偏移
 *   +8+8n   扇区数据（每扇区 512 字节）
 *
 * 选哪些扇区：引导、FSInfo、备份引导、FAT 第一扇区、根目录簇，**再加上文件占用的
 * 全部数据扇区**（个数由目录项里的长度算）。早先写死"文件前两簇"，结果文件一变大
 * （9603 字节 = 19 簇）就只 dump 到 2 簇，验证在第 1024 字节对不上 —— 这个 bug 就是
 * 这轮测试自己抓出来的。
 * -------------------------------------------------------------------------- */
static int build_ev_lbas(u32 *out, u32 max, u32 *pn)
{
    static sd_evid_plan_t p;
    const u8 *boot = g_disk;
    const u8 *root;
    u32 i;
    int rc;

    /* 板上 sd_dump.c 走的是同一对调用：先要结构扇区拿 root_lba，再读根目录算完整计划 */
    rc = sd_evid_plan(boot, 0, &p);
    if (rc != 0) {
        printf("  sd_evid_plan(structure) rc=%d\n", rc);
        return -1;
    }
    root = g_disk + (size_t)p.root_lba * 512U;
    rc = sd_evid_plan(boot, root, &p);
    if (rc != 0) {
        printf("  sd_evid_plan(full) rc=%d\n", rc);
        return -1;
    }
    if (p.n > max) {
        printf("  plan has %u sectors, max %u\n", p.n, max);
        return -1;
    }
    for (i = 0U; i < p.n; i++) { out[i] = p.lba[i]; }

    printf("  evidence sectors: %u fixed + %u data (file %u bytes) via sd_evid_plan\n",
           p.n - p.data_secs, p.data_secs, p.file_len);
    chk("plan starts with boot", (int)p.lba[0], 0);
    chk("plan has 5 fixed sectors", (int)(p.n - p.data_secs), 5);
    chk("plan data sectors", (int)p.data_secs, 19);
    chk("plan root lba", (int)p.root_lba, 1056);
    *pn = p.n;
    return 0;
}

static int emit_dump(const char *path, const u32 *lbas, u32 n)
{
    static u8 buf[16384];      /* 与板上 EVID_MAX 一致 */
    u32 i;
    u32 data_off = 8U + 8U * n;
    FILE *f;

    if (data_off + n * 512U > sizeof(buf)) {
        printf("  dump would need %u bytes, buffer is %u\n",
               data_off + n * 512U, (u32)sizeof(buf));
        return -1;
    }
    buf[0] = 'S'; buf[1] = 'D'; buf[2] = 'C'; buf[3] = '1';
    buf[4] = (u8)(n); buf[5] = 0U; buf[6] = 0U; buf[7] = 0U;
    for (i = 0; i < n; i++) {
        u32 off = data_off + i * 512U;
        u8 *h = &buf[8U + 8U * i];

        h[0] = (u8)(lbas[i]);      h[1] = (u8)(lbas[i] >> 8);
        h[2] = (u8)(lbas[i] >> 16); h[3] = (u8)(lbas[i] >> 24);
        h[4] = (u8)(off);          h[5] = (u8)(off >> 8);
        h[6] = (u8)(off >> 16);    h[7] = (u8)(off >> 24);
        if (lbas[i] * 512U + 512U <= g_nsec * 512U) {
            memcpy(&buf[off], g_disk + (size_t)lbas[i] * 512U, 512U);
        } else {
            memset(&buf[off], 0, 512U);
        }
    }

    f = fopen(path, "wb");
    if (f == 0) {
        printf("  cannot write %s\n", path);
        return -1;
    }
    fwrite(buf, 1U, data_off + n * 512U, f);
    fclose(f);
    printf("  saved %s (%u bytes, %u sectors: %u..%u)\n",
           path, data_off + n * 512U, n, lbas[0], lbas[n - 1U]);
    return 0;
}

/* 一份完整的"格式化 -> 写 CSV -> 回读比对"，几何参数由调用者给 */
static void run_case(const char *tag, const fat32_geo *g, const char *img_path)
{
    static u8 sec[512];
    static u8 sec2[512];
    static u16 samp[100];
    static u8 csv[8192];
    fat32_io io;
    u32 csvlen, h_ref, h_got, i, n;
    u32 root_lba;
    u32 clusters, fat_cap;
    int rc;

    printf("\n=== %s: %u sectors (%u MB), spc=%u, reserved=%u, fat=%u sec ===\n",
           tag, g->total_sec, (u32)((g->total_sec * 512U) / (1024U * 1024U)),
           (u32)g->sec_per_clus, g->reserved, g->fat_sec);

    clusters = g->total_sec - g->reserved - (u32)g->nfats * g->fat_sec;
    fat_cap  = g->fat_sec * (512U / 4U);
    printf("  clusters=%u, fat entries capacity=%u (need %u) %s\n",
           clusters, fat_cap, clusters + 2U,
           (fat_cap >= clusters + 2U) ? "OK" : "TOO SMALL");
    chk("fat fits clusters", (fat_cap >= clusters + 2U) ? 1 : 0, 1);

    for (i = 0; i < 100U; i++) {
        samp[i] = (u16)((0x800U + 7U * i) & 0xFFFU);
    }
    csvlen = fat32_csv_from_samples(csv, 8192U, samp, 100U);
    h_ref = djb2(csv, csvlen);
    printf("  csv %u bytes, djb2=0x%08x\n", csvlen, h_ref);

    io.ctx   = (void *)&card_bus;
    io.read  = sd_fat_read;
    io.write = sd_fat_write;

    rc = fat32_format(&io, g);
    chk("format rc", rc, 0);

    rc = fat32_write_file(&io, g, "REC     CSV", csv, csvlen);
    chk("write_file rc", rc, 0);

    root_lba = g->reserved + (u32)g->nfats * g->fat_sec;
    rc = sd_read_block(&card_bus, root_lba, sec);
    chk("read root dir", rc, 0);
    {
        u32 first = ((u32)(((u32)sec[21] << 8) | sec[20]) << 16) |
                    (u32)(((u32)sec[27] << 8) | sec[26]);
        u32 flen  = (u32)sec[28] | ((u32)sec[29] << 8) |
                    ((u32)sec[30] << 16) | ((u32)sec[31] << 24);

        printf("  dirent attr=0x%02x clus=%u size=%u name=[", (u32)sec[11], first, flen);
        for (i = 0; i < 11U; i++) { printf("%c", sec[i]); }
        printf("]\n");
        chk("dirent first_clus", (int)first, (int)(g->root_clus + 1U));
        chk("dirent size", (int)flen, (int)csvlen);

        n = flen;
        h_got = 5381U;
        for (i = 0; (i < 64U) && (n > 0U); i++) {
            u32 k;
            if (sd_read_block(&card_bus, root_lba + 1U + i, sec2) != 0) { break; }
            for (k = 0; (k < 512U) && (n > 0U); k++, n--) {
                h_got = (h_got << 5) + h_got + (u32)sec2[k];
            }
        }
        printf("  readback djb2=0x%08x (expect 0x%08x)\n", h_got, h_ref);
        chk("content match", (h_got == h_ref) ? 1 : 0, 1);
    }

    chk("card crc_bad", (int)fc_wr_crc_bad, 0);
    chk("card range_bad", (int)fc_wr_range_bad, 0);
    chk("card bad_token", (int)fc_badtok, 0);

    save(img_path, g_disk, g->total_sec * 512U);
}

/* -----------------------------------------------------------------------------
 * CRC 已知答案测试
 *
 * 为什么必须有：CRC7 只用在命令帧上，而卡只在 CMD0/CMD8 阶段真的检查它。
 * 如果 CRC7 算错，CMD0 不会把卡复位、CMD8 被拒 —— 现象和"没插卡"一模一样，
 * 到时候根本分不出是卡的问题还是 CRC 的问题。所以这里拿 SD 规范里**公开的帧**
 * 当标准答案，而不是"自己算的和自己算的一致"。
 *
 *   命令帧 6 字节：0x40|cmd, arg[31:24..0], (crc7<<1)|1
 *   CMD0 : 40 00 00 00 00 95   -> crc7 = 0x4A
 *   CMD8 : 48 00 00 01 AA 87   -> crc7 = 0x43
 *   CMD55: 77 00 00 00 00 65   -> crc7 = 0x32
 *   CRC16 XMODEM 标准检查值：XMODEM("123456789") = 0x31C3
 * -------------------------------------------------------------------------- */
static void t_crc(void)
{
    static const u8 f0[5]  = { 0x40U, 0x00U, 0x00U, 0x00U, 0x00U };
    static const u8 f8[5]  = { 0x48U, 0x00U, 0x00U, 0x01U, 0xAAU };
    static const u8 f55[5] = { 0x77U, 0x00U, 0x00U, 0x00U, 0x00U };
    static const u8 f41[5] = { 0x69U, 0x40U, 0xFFU, 0x80U, 0x00U };
    static const u8 vec[9] = { '1', '2', '3', '4', '5', '6', '7', '8', '9' };
    static u8 zero[512];

    printf("\n[T0] CRC known-answer tests\n");

    chk("crc7 CMD0  (frame 0x95)", (int)sd_crc7(f0, 5U), 0x4A);
    chk("crc7 CMD8  (frame 0x87)", (int)sd_crc7(f8, 5U), 0x43);
    chk("crc7 CMD55 (frame 0x65)", (int)sd_crc7(f55, 5U), 0x32);
    chk("crc7 CMD41", (int)sd_crc7(f41, 5U), 0x0B);
    chk("crc16 XMODEM(\"123456789\")", (int)sd_crc16(vec, 9U), 0x31C3);
    chk("crc16 zero 512B", (int)sd_crc16(zero, 512U), 0x0000);
}

/* -----------------------------------------------------------------------------
 * 产品路径：sw/ps/sd_record.c（板上 sd_fat_sd.c 调的就是这一个函数）
 * -------------------------------------------------------------------------- */
#define REC_NSAMP 1000U

static void run_record_case(const fat32_geo *g, const char *img_path)
{
    static u16 samp[REC_NSAMP];
    static u8  csv[16384];
    static u8  rblk[512];
    static sd_record_stat st;
    u32 i;
    int rc;

    printf("\n=== product path: sd_record_to_card, %u samples on a 64 MB volume ===\n",
           (u32)REC_NSAMP);

    for (i = 0; i < REC_NSAMP; i++) {
        samp[i] = (u16)((0x800U + 7U * i) & 0xFFFU);
    }
    memset(g_disk, 0, (size_t)g_nsec * 512U);
    fc_wr_ok = fc_wr_crc_bad = fc_wr_range_bad = fc_rd_ok = fc_badtok = 0U;

    rc = sd_record_to_card(&card_bus, g, samp, REC_NSAMP, csv, sizeof(csv), rblk, &st);
    chk("sd_record rc", rc, SDR_OK);
    printf("  csv=%u bytes djb2=0x%08x, card djb2=0x%08x, diff=%u, compared=%u\n",
           st.csv_bytes, st.djb2_csv, st.djb2_card, st.bytes_diff, st.bytes_compared);
    printf("  first_clus=%u clusters=%u, card accepted=%u blocks, read=%u blocks\n",
           st.first_clus, st.clusters, fc_wr_ok, fc_rd_ok);
    chk("bytes diff", (int)st.bytes_diff, 0);
    chk("compared == csv bytes", (int)st.bytes_compared, (int)st.csv_bytes);
    chk("djb2 card == csv", (st.djb2_card == st.djb2_csv) ? 1 : 0, 1);
    chk("clusters >= 1", (st.clusters >= 1U) ? 1 : 0, 1);
    chk("card crc_bad", (int)fc_wr_crc_bad, 0);

    save(img_path, g_disk, g->total_sec * 512U);
}

int main(void)
{
    fat32_geo g;
    static u8 small_disk[128U * 512U];

    printf("=== host-side fat32/sd_wr test (same C sources as the board) ===\n");

    t_crc();
    /* --- 小几何（回归：和板上的结果对齐） --- */
    g_disk = small_disk;
    g_nsec = 128U;
    memset(g_disk, 0, (size_t)g_nsec * 512U);
    fat32_geo_small(&g, g_nsec);
    run_case("small geometry", &g, "sim/build/sd/host_small.img");

    /* --- 真卡几何：64 MB / 512 B 簇（Windows 才认 FAT32） --- */
    g_nsec = 131072U;
    g_disk = (u8 *)calloc(1, (size_t)g_nsec * 512U);
    if (g_disk == 0) {
        printf("cannot allocate 64 MB card image\n");
        return 1;
    }
    fat32_geo_default(&g);

    fc_wr_ok = fc_wr_crc_bad = fc_wr_range_bad = fc_rd_ok = fc_badtok = 0U;
    run_case("real-card geometry (64 MB)", &g, "sim/build/sd/host_64mb.img");
    printf("\n  card: accepted=%u read=%u\n", fc_wr_ok, fc_rd_ok);

    /* --- 产品路径本身：sw/ps/sd_record.c（板上 sd_fat_sd.c 调的就是它） --- */
    run_record_case(&g, "sim/build/sd/host_record.img");

    /* 用板上 sd_dump.c 的同一格式、同一套选取规则导出"证据扇区" */
    printf("\n=== evidence dump (same format as sw/ps/sd_dump.c) ===\n");
    {
        static u32 ev[64];
        u32 nev = 0U;

        if (build_ev_lbas(ev, 32U, &nev) != 0) {
            t_fail++;
            printf("  [FAIL] build_ev_lbas\n");
        } else if (emit_dump("sim/build/sd/host_dump.bin", ev, nev) != 0) {
            t_fail++;
            printf("  [FAIL] emit_dump\n");
        }
    }

    /* 顺带验证 Windows 认 FAT32 的两个硬条件 */
    chk("clusters >= 65525", (int)((g.total_sec - g.reserved -
         (u32)g.nfats * g.fat_sec) >= 65525U) ? 1 : 0, 1);

    printf("\nchecks: %u passed, %u failed\n", t_pass, t_fail);
    printf((t_fail == 0U) ? "RESULT PASS\n" : "RESULT FAIL\n");
    free(g_disk);
    return (t_fail == 0U) ? 0 : 1;
}
