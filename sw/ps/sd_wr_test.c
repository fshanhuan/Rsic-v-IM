/* =============================================================================
 * sw/ps/sd_wr_test.c -- 不需要 SD 卡，把 sd_wr.c 的块读写**真跑一遍**
 * -----------------------------------------------------------------------------
 * 为什么需要它：
 *   sd_wr.c 里的协议逻辑（令牌、CRC16、数据响应令牌、忙等）在没卡的时候
 *   永远跑不到，只能"看着觉得对"。这里在 OCM 里摆一张**假卡**：它按 SD 物理层
 *   规范回应 CMD17/CMD24，并且**自己重算 CRC16**、自己产生忙信号、还能注入各种
 *   错误。于是：
 *     · 写块的 CRC 真的被第三方算法校验过（不是自己校验自己）；
 *     · 每条失败返回码都能被触发一次（证明错误处理是活的，不是死代码）；
 *     · fat32_io -> sd_fat_read/sd_fat_write -> sd_read_block/sd_write_block
 *       这条完整接线被跑到，产出的镜像再用 Python 按 FAT32 规范复核。
 *
 * 假卡布局：
 *   0x1_0000 ~ 0x1_FFFF : 64 KB 卡镜像（128 个扇区）
 *   0x2_0000 ~           : CSV 文本缓冲
 *   假卡状态、块缓冲都在 .bss；启动时检查栈顶没有越过 0x1_0000（否则会踩代码）。
 *
 * 返回码对照（sd_wr.h）：0 OK / -1 无响应 / -2 R1 报错 / -3 无令牌 / -4 读 CRC 错
 *   -5 卡报 CRC 错 / -6 卡报写错 / -7 无数据响应令牌 / -8 卡一直忙
 * ============================================================================= */
#include "fat32.h"
#include "sd_wr.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define CARD_BASE    0x00010000U
#define CARD_SEC     128U
#define CSV_BUF      0x00020000U
#define UART1_BASE   0xE0001000U

#define NSAMP        100U

/* 链接脚本里的栈顶符号：用来确认 .bss+栈 没伸进卡镜像 */
extern char _stack_top[];

/* =========================== 假卡（协议模型） ============================ */
/* 读流 / 写流状态 */
#define FS_IDLE   0
#define FS_READ   1
#define FS_WRITE  2

static u32 fc_idx;              /* 刚收到的命令号 */
static u32 fc_arg;              /* 参数（LBA） */
static u32 fc_stream;           /* FS_* */

/* 读流：前缀 0xFF 个数由 fc_pad 决定（验证令牌搜索是真的在搜） */
static u32 fc_spos;
static u32 fc_pad;
static u32 fc_notoken;          /* 1 = 永远发 0xFF，测 -3 */
static u32 fc_bad_rdcrc;        /* 1 = 故意把读的 CRC 弄错，测 -4 */

/* 写流 */
static u32 fc_pending;          /* 0 = 等令牌；1..515 = 正在收 */
static u8  fc_buf[512];
static u8  fc_crc[2];
static u8  fc_tok;              /* 要回的数据响应令牌 */
static u32 fc_nodr;             /* 1 = 不发数据响应令牌，测 -7 */
static u32 fc_dr_sent;
static u32 fc_busy;             /* 剩余忙位数 */
static u32 fc_busy_forever;     /* 1 = 永远忙，测 -8 */
static u32 fc_poison;           /* 1 = 故意改一个字节再算 CRC，验证卡侧 CRC 真的活着 */
static u32 fc_out_of_range_err; /* 1 = 越界时回写错令牌 */

/* 命令响应 */
static u32 fc_noresp;           /* 1 = 不回响应，测 -1 */
static u32 fc_r1_force;         /* 1 = R1 用 fc_r1 的值，测 -2 */
static u32 fc_r1;

/* 统计：这就是"证据"的数字 */
static u32 fc_wr_ok;            /* 卡接受的块数 */
static u32 fc_wr_crc_bad;       /* 卡算 CRC 不对的次数 */
static u32 fc_wr_range_bad;     /* 越界写次数 */
static u32 fc_rd_ok;            /* 卡发出的读块数 */
static u32 fc_badtok;           /* 写流里不是 0xFE 的首字节次数 */

static u16 c16(const u8 *d, u32 n)
{
    u16 crc = 0U;
    u32 i;
    int b;

    for (i = 0; i < n; i++) {
        crc ^= (u16)((u16)d[i] << 8);
        for (b = 0; b < 8; b++) {
            if ((crc & 0x8000U) != 0U) {
                crc = (u16)((crc << 1) ^ 0x1021U);
            } else {
                crc = (u16)(crc << 1);
            }
        }
    }
    return crc;
}

static volatile u8 *card_blk(u32 lba)
{
    return (volatile u8 *)(CARD_BASE + lba * 512U);
}

static void fc_cmd(void *ctx, u32 idx, u32 arg)
{
    (void)ctx;
    fc_idx = idx;
    fc_arg = arg;
    fc_pending = 0U;
    fc_spos = 0U;
    fc_dr_sent = 0U;

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
    if (fc_noresp != 0U) {
        return -1;
    }
    if (fc_r1_force != 0U) {
        *r = fc_r1;
    } else {
        *r = 0U;
    }
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
            fc_pending = 1U;         /* 令牌收到，开始收数据 */
        } else {
            fc_badtok++;             /* 0xFF 填塞可以容忍，其它就当异常计数 */
        }
        return;
    }

    if (fc_pending <= 512U) {
        fc_buf[fc_pending - 1U] = b;
        fc_pending++;
        return;
    }
    /* 数据收完，接着是两个 CRC 字节 */
    fc_crc[fc_pending - 513U] = b;
    fc_pending++;
    if (fc_pending < 515U) {
        return;
    }

    /* --- CRC 校验（卡侧独立实现） --- */
    {
        u16 want = c16(fc_buf, 512U);
        u16 got  = (u16)(((u16)fc_crc[0] << 8) | (u16)fc_crc[1]);

        if (fc_poison != 0U) {
            want = (u16)(want ^ 0x0001U);   /* 假装数据坏了 */
        }
        if (want != got) {
            fc_wr_crc_bad++;
            fc_tok = 0x0BU;                 /* CRC 错令牌 */
        } else if (fc_arg >= CARD_SEC) {
            fc_wr_range_bad++;
            fc_tok = 0x0DU;                 /* 写错令牌 */
        } else {
            volatile u8 *d = card_blk(fc_arg);
            u32 i;

            for (i = 0; i < 512U; i++) {
                d[i] = fc_buf[i];
            }
            fc_wr_ok++;
            fc_tok = 0x05U;
            fc_busy = 24U;                  /* 忙 24 位，测忙等 */
        }
    }
    fc_pending = 0U;
}

static u8 fc_rx(void *ctx)
{
    (void)ctx;

    if (fc_stream == FS_READ) {
        if (fc_notoken != 0U) {
            return 0xFFU;
        }
        if (fc_spos < fc_pad) {
            fc_spos++;
            return 0xFFU;
        }
        if (fc_spos == fc_pad) {
            fc_spos++;
            return 0xFEU;
        }
        {
            u32 k = fc_spos - fc_pad - 1U;   /* 0..513 */
            u8 v;

            if (k < 512U) {
                v = (fc_arg < CARD_SEC) ? card_blk(fc_arg)[k] : 0x00U;
            } else {
                u16 c = c16((const u8 *)(CARD_BASE + (fc_arg % CARD_SEC) * 512U), 512U);

                if (fc_bad_rdcrc != 0U) {
                    c = (u16)(c ^ 0x0100U);
                }
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
        /* 数据响应令牌：0xFF -> tok -> 之后一直 0xFF */
        if (fc_nodr != 0U) {
            return 0xFFU;
        }
        if (fc_dr_sent == 0U) {
            fc_dr_sent = 1U;
            return 0xFFU;
        }
        if (fc_dr_sent == 1U) {
            fc_dr_sent = 2U;
            return fc_tok;
        }
        return 0xFFU;
    }

    return 0xFFU;
}

static u32 fc_rxbit(void *ctx)
{
    (void)ctx;
    if (fc_busy_forever != 0U) {
        return 0U;
    }
    if (fc_busy > 0U) {
        fc_busy--;
        return 0U;
    }
    return 1U;
}

static const sd_bus card_bus = {
    fc_cmd, fc_resp48, fc_dir, fc_tx, fc_rx, fc_rxbit, 0
};

/* 复位注入开关（每次测试前调用，避免相互污染） */
static void inject_reset(void)
{
    fc_noresp = 0U;
    fc_r1_force = 0U;
    fc_r1 = 0U;
    fc_notoken = 0U;
    fc_bad_rdcrc = 0U;
    fc_nodr = 0U;
    fc_busy_forever = 0U;
    fc_poison = 0U;
}

/* ============================== 测试框架 ================================= */
static u32 t_pass;
static u32 t_fail;

static void chk(const char *what, int got, int want)
{
    if (got == want) {
        t_pass++;
        xil_printf("  [ok] %s = %d\n", what, got);
    } else {
        t_fail++;
        xil_printf("  [FAIL] %s = %d (want %d)\n", what, got, want);
    }
}

static void chk_true(const char *what, int cond)
{
    chk(what, cond ? 1 : 0, 1);
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

/* ============================== 各项测试 ================================= */
static u8 blk_a[512] __attribute__((aligned(4)));
static u8 blk_b[512] __attribute__((aligned(4)));
static u8 sec[512]   __attribute__((aligned(4)));
static u8 sec2[512]  __attribute__((aligned(4)));

/* T1：写 -> 读 -> 逐字节比对（假卡自己算 CRC，所以写块的 CRC16 也被验了） */
static void t_roundtrip(void)
{
    u32 i;
    u32 crc0 = fc_wr_crc_bad;
    int rc;

    xil_printf("[T1] write/read round trip\n");

    for (i = 0; i < 512U; i++) {
        blk_a[i] = (u8)((i * 37U + 0x5AU) & 0xFFU);
    }
    blk_a[0]   = 0xFEU;      /* 数据里故意放一个令牌字节，验证状态机不会搞混 */
    blk_a[100] = 0xFEU;
    blk_a[511] = 0x7EU;

    rc = sd_write_block(&card_bus, 5U, blk_a);
    chk("write rc", rc, SDW_OK);
    chk("card crc_bad", (int)(fc_wr_crc_bad - crc0), 0);

    for (i = 0; i < 512U; i++) { blk_b[i] = 0U; }
    rc = sd_read_block(&card_bus, 5U, blk_b);
    chk("read rc", rc, SDW_OK);

    {
        u32 bad = 0U;
        for (i = 0; i < 512U; i++) {
            if (blk_b[i] != blk_a[i]) { bad++; }
        }
        chk("byte diffs", (int)bad, 0);
    }
}

/* T2：全部 0 / 全部 0xFF 两个边界块，验证 512 字节计数不差一 */
static void t_edges(void)
{
    u32 i;

    xil_printf("[T2] all-00 / all-FF blocks\n");

    for (i = 0; i < 512U; i++) { blk_a[i] = 0x00U; }
    chk("write 00", sd_write_block(&card_bus, 6U, blk_a), SDW_OK);
    for (i = 0; i < 512U; i++) { blk_b[i] = 0x5AU; }
    chk("read 00", sd_read_block(&card_bus, 6U, blk_b), SDW_OK);
    chk("read 00 zero", (blk_b[0] + blk_b[255] + blk_b[511]) == 0 ? 1 : 0, 1);

    for (i = 0; i < 512U; i++) { blk_a[i] = 0xFFU; }
    chk("write FF", sd_write_block(&card_bus, 7U, blk_a), SDW_OK);
    chk("read FF", sd_read_block(&card_bus, 7U, blk_b), SDW_OK);
    chk("read FF ff", (blk_b[0] == 0xFFU) && (blk_b[511] == 0xFFU) ? 1 : 0, 1);
}

/* T3：令牌搜索（卡先发 5 个 0xFF 再发 0xFE） */
static void t_token_search(void)
{
    u32 i;
    u32 bad = 0U;

    xil_printf("[T3] token search (5x 0xFF before 0xFE)\n");

    for (i = 0; i < 512U; i++) { blk_a[i] = (u8)(0xC3U ^ (u8)i); }
    chk("write pat", sd_write_block(&card_bus, 10U, blk_a), SDW_OK);

    fc_pad = 5U;
    chk("read rc", sd_read_block(&card_bus, 10U, blk_b), SDW_OK);
    for (i = 0; i < 512U; i++) {
        if (blk_b[i] != blk_a[i]) { bad++; }
    }
    chk("byte diffs", (int)bad, 0);
    fc_pad = 0U;
}

/* T4：每个失败返回码都要被真的触发一次 */
static void t_errors(void)
{
    int rc;

    xil_printf("[T4] error injection\n");

    inject_reset();
    fc_noresp = 1U;
    chk("write no response", sd_write_block(&card_bus, 8U, blk_a), SDW_ENORESP);

    inject_reset();
    fc_r1_force = 1U; fc_r1 = 0x00200000U;      /* bit21 = 地址错 */
    chk("read R1 error", sd_read_block(&card_bus, 8U, blk_b), SDW_ER1);

    inject_reset();
    fc_notoken = 1U;
    chk("read no token", sd_read_block(&card_bus, 8U, blk_b), SDW_ENOTOKEN);

    inject_reset();
    fc_bad_rdcrc = 1U;
    chk("read bad crc", sd_read_block(&card_bus, 8U, blk_b), SDW_EDCRC);

    inject_reset();
    fc_poison = 1U;                              /* 卡侧故意算错 -> 回 0x0B */
    chk("write card crc err", sd_write_block(&card_bus, 8U, blk_a), SDW_ECRC);
    chk("card crc_bad +1", (fc_wr_crc_bad >= 1U) ? 1 : 0, 1);

    inject_reset();
    chk("write out of range", sd_write_block(&card_bus, CARD_SEC + 3U, blk_a), SDW_EWRITE);

    inject_reset();
    fc_nodr = 1U;
    chk("write no data resp", sd_write_block(&card_bus, 9U, blk_a), SDW_ENODR);

    inject_reset();
    fc_busy_forever = 1U;
    chk("write busy forever", sd_write_block(&card_bus, 9U, blk_a), SDW_EBUSY);

    inject_reset();
    fc_pad = 0U;
    chk("read out of range", sd_read_block(&card_bus, CARD_SEC + 1U, blk_b), SDW_OK);
    chk("  -> zero filler", (int)blk_b[0], 0);
}

/* T5：fat32_io 真的接到 sd_fat_read/sd_fat_write 上跑一遍完整流程 */
static void t_fat32(void)
{
    static fat32_io io;
    static fat32_geo g;
    static u16 samp[NSAMP];
    u8 *csv = (u8 *)CSV_BUF;
    u32 csvlen;
    u32 i;
    u32 h_ref;
    int rc;

    xil_printf("[T5] fat32 -> sd_fat_read/write end to end\n");

    /* 卡镜像清零 */
    for (i = 0; i < CARD_SEC * 512U; i++) {
        ((volatile u8 *)CARD_BASE)[i] = 0U;
    }
    inject_reset();

    io.ctx   = (void *)&card_bus;
    io.read  = sd_fat_read;
    io.write = sd_fat_write;
    fat32_geo_small(&g, CARD_SEC);

    rc = fat32_format(&io, &g);
    chk("format rc", rc, 0);
    if (rc != 0) { return; }

    for (i = 0; i < NSAMP; i++) {
        samp[i] = (u16)((0x800U + 7U * i) & 0xFFFU);
    }
    csvlen = fat32_csv_from_samples(csv, 8192U, samp, NSAMP);
    h_ref = djb2(csv, csvlen);
    xil_printf("  csv: %u bytes, djb2=0x%08x\n", csvlen, h_ref);

    rc = fat32_write_file(&io, &g, "REC     CSV", csv, csvlen);
    chk("write_file rc", rc, 0);
    if (rc != 0) { return; }

    /* 回读根目录项（同样走 sd_read_block） */
    rc = sd_read_block(&card_bus, 3U, sec);       /* reserved+fat = 2+1 */
    chk("read root dir", rc, SDW_OK);
    {
        /* 目录项：偏移 20 = 首簇高 16 位，偏移 26 = 首簇低 16 位（FAT32 规范） */
        u32 first = ((u32)(((u32)sec[21] << 8) | sec[20]) << 16) |
                    (u32)(((u32)sec[27] << 8) | sec[26]);
        u32 flen  = (u32)sec[28] | ((u32)sec[29] << 8) |
                    ((u32)sec[30] << 16) | ((u32)sec[31] << 24);
        u32 n = flen;
        u32 h = 5381U;

        xil_printf("  dirent attr=0x%02x clus=%u size=%u name=[", (u32)sec[11], first, flen);
        for (i = 0; i < 11U; i++) { xil_printf("%c", (u32)sec[i]); }
        xil_printf("]\n");
        chk("dirent first_clus", (int)first, (int)(g.root_clus + 1U));
        chk("dirent size", (int)flen, (int)csvlen);

        for (i = 0; (i < 8U) && (n > 0U); i++) {
            u32 k;
            u32 lba = 3U + 1U + i;                /* 数据簇紧接根目录簇 */
            if (sd_read_block(&card_bus, lba, sec2) != SDW_OK) { break; }
            for (k = 0; (k < 512U) && (n > 0U); k++, n--) {
                h = (h << 5) + h + (u32)sec2[k];
            }
        }
        xil_printf("  readback djb2=0x%08x (expect 0x%08x)\n", h, h_ref);
        chk("content match", (h == h_ref) ? 1 : 0, 1);
    }
}

int main(void)
{
    u32 i;
    u32 sctlr;
    u32 crc_bad_after_err;

    port_log_reset();

    /* 串口（波特率已校准） */
    Xil_Out32(UART1_BASE + 0x34U, 6U);
    Xil_Out32(UART1_BASE + 0x18U, 67U);
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);
    port_uart_init();

    __asm__ volatile ("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
    sctlr &= ~(1U << 1);
    __asm__ volatile ("mcr p15, 0, %0, c1, c0, 0" :: "r"(sctlr));
    __asm__ volatile ("isb" ::: "memory");

    xil_printf("\n=== sd_wr block protocol test (fake card, no SD card) ===\n");
    xil_printf("card = 0x%08x, %u sectors (%u KB)\n",
               (u32)CARD_BASE, CARD_SEC, (u32)(CARD_SEC * 512U / 1024U));

    /* 安全检查：.bss + 栈 不能伸进假卡镜像 */
    {
        u32 stk = (u32)_stack_top;
        xil_printf("stack_top = 0x%08x, card = 0x%08x\n", stk, (u32)CARD_BASE);
        if (stk > CARD_BASE) {
            xil_printf("RESULT FAIL_layout (stack overlaps card image)\n");
            for (;;) { usleep(500000UL); }
        }
    }

    for (i = 0; i < CARD_SEC * 512U; i++) {
        ((volatile u8 *)CARD_BASE)[i] = 0U;
    }
    inject_reset();

    t_roundtrip();
    t_edges();
    t_token_search();
    t_errors();
    crc_bad_after_err = fc_wr_crc_bad;
    t_fat32();

    xil_printf("\n--- card-side counters ---\n");
    xil_printf("blocks accepted=%u  crc_bad=%u  range_bad=%u  blocks read=%u  bad_token=%u\n",
               fc_wr_ok, fc_wr_crc_bad, fc_wr_range_bad, fc_rd_ok, fc_badtok);

    /* 卡侧 CRC 错只应该来自 T4 那一次"故意算错"的注入：
     * 如果 sd_wr.c 的 CRC16 算错了，这里会明显变大（T5 至少要写十几个块）。 */
    chk_true("crc injection was live", (crc_bad_after_err == 1U) ? 1 : 0);
    chk_true("no unexpected crc err", (fc_wr_crc_bad == crc_bad_after_err) ? 1 : 0);
    chk_true("no bad write token", (fc_badtok == 0U) ? 1 : 0);

    xil_printf("checks: %u passed, %u failed\n", t_pass, t_fail);
    xil_printf((t_fail == 0U) ? "RESULT PASS\n" : "RESULT FAIL\n");

    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
