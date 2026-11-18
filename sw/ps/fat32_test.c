/* =============================================================================
 * sw/ps/fat32_test.c -- 不依赖 SD 卡的 FAT32 自测（内存假盘）
 * -----------------------------------------------------------------------------
 * 目的：把"格式化 + 写文件 + 生成 CSV"这套逻辑在**真硬件上**跑起来并留下可验证的证据，
 *       唯一的区别是块设备不是卡，而是 OCM 里一块 64 KB 的内存。
 *
 * 布局（见 link_ps_sd.ld）：
 *   0x1_0000 ~ 0x1_FFFF : 假盘（64 KB = 128 个 512 字节扇区）
 *   0x2_0000 ~           : 数据缓冲（CSV 文本）
 *
 * 产出：内存日志里打印卷参数、文件长度、CSV 校验和、目录项与数据首字节；
 *       之后用 JTAG 把假盘前 4 KB dump 出来，交给 tools/ps/fat32_verify.py
 *       按 FAT32 规范解析并比对内容 —— 这就是"不依赖卡"的实证。
 * ============================================================================= */
#include "fat32.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define DISK_BASE   0x00010000U      /* 64 KB 假盘 */
#define DISK_SECTORS 128U
#define CSV_BUF     0x00020000U
#define UART1_BASE  0xE0001000U

#define NSAMP       100U

/* ---------------------------- 假盘块读写 -------------------------------- */
static int dsk_rd(void *ctx, u32 lba, u8 *buf)
{
    u8 *src;

    (void)ctx;
    if (lba >= DISK_SECTORS) { return -1; }
    src = (u8 *)(DISK_BASE + lba * 512U);
    {
        u32 i;
        for (i = 0; i < 512U; i++) { buf[i] = src[i]; }
    }
    return 0;
}

static int dsk_wr(void *ctx, u32 lba, u8 *buf)
{
    u8 *dst;

    (void)ctx;
    if (lba >= DISK_SECTORS) { return -1; }
    dst = (u8 *)(DISK_BASE + lba * 512U);
    {
        u32 i;
        for (i = 0; i < 512U; i++) { dst[i] = buf[i]; }
    }
    return 0;
}

/* djb2：只为跨平台比对用 */
static u32 djb2(const u8 *p, u32 n)
{
    u32 h = 5381U;
    u32 i;

    for (i = 0; i < n; i++) {
        h = ((h << 5) + h + (u32)p[i]);
    }
    return h;
}

int main(void)
{
    static fat32_io io;
    static fat32_geo g;
    static u16 samp[NSAMP];
    u8 *csv = (u8 *)CSV_BUF;
    u32 csvlen;
    u32 i;
    int rc;

    port_log_reset();

    /* 串口（波特率已校准） */
    Xil_Out32(UART1_BASE + 0x34U, 6U);
    Xil_Out32(UART1_BASE + 0x18U, 67U);
    Xil_Out32(UART1_BASE + 0x04U, 0x20U);
    Xil_Out32(UART1_BASE + 0x00U, 0x17U);
    port_uart_init();

    /* 先确认/打开"允许非对齐访问"：gcc 会把连续的字节写合并成 str，
     * 而 FAT32 引导扇区里到处是奇地址字段。若 SCTLR.A=1，这些 str 会直接
     * 触发对齐异常（实测 DFSR=0x801，PC 落在 memcpy 的向量化代码里）。 */
    {
        u32 sctlr = 0U;

        __asm__ volatile ("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
        xil_printf("\nSCTLR = 0x%08x (A bit = %u)\n", sctlr, (sctlr >> 1) & 1U);
        sctlr &= ~(1U << 1);                       /* A=0：允许非对齐访问 */
        __asm__ volatile ("mcr p15, 0, %0, c1, c0, 0" :: "r"(sctlr));
        __asm__ volatile ("isb" ::: "memory");
        __asm__ volatile ("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
        xil_printf("SCTLR after clear = 0x%08x (A bit = %u)\n",
                   sctlr, (sctlr >> 1) & 1U);
    }

    xil_printf("\n=== FAT32 self-test on RAM disk (no SD card) ===\n");
    xil_printf("disk = 0x%08x, %u sectors (%u KB)\n",
               (u32)DISK_BASE, DISK_SECTORS, (u32)(DISK_SECTORS * 512U / 1024U));

    /* 假盘清零（避免验证时看到上一次的残留） */
    for (i = 0; i < DISK_SECTORS * 512U; i++) {
        ((u8 *)DISK_BASE)[i] = 0U;
    }

    io.ctx   = (void *)0;
    io.read  = dsk_rd;
    io.write = dsk_wr;

    fat32_geo_small(&g, DISK_SECTORS);

    xil_printf("[0] calling format...\n");
    rc = fat32_format(&io, &g);
    xil_printf("[1] format rc=%d\n", rc);
    if (rc != 0) { goto idle; }

    /* 造样本：s[i] = (0x800 + 7*i) & 0xFFF（与主机侧验证脚本同一公式） */
    for (i = 0; i < NSAMP; i++) {
        samp[i] = (u16)((0x800U + 7U * i) & 0xFFFU);
    }
    csvlen = fat32_csv_from_samples(csv, 8192U, samp, NSAMP);
    xil_printf("[2] csv: %u bytes, djb2=0x%08x\n", csvlen, djb2(csv, csvlen));
    {
        int k;
        xil_printf("    first line: ");
        for (k = 0; (k < 20) && (csv[k] != 0U); k++) {
            char c = (char)csv[k];
            xil_printf("%c", (c == '\r') ? ' ' : c);
        }
        xil_printf("\n");
    }

    rc = fat32_write_file(&io, &g, "REC     CSV", csv, csvlen);
    xil_printf("[3] write_file rc=%d\n", rc);
    if (rc != 0) { goto idle; }

    /* 回读：先看根目录项，再比对数据 */
    {
        static u8 sec[512] __attribute__((aligned(4)));
        u8 *p;
        u32 first;
        u32 flen;
        u32 h = 5381U;
        u32 n;

        if (dsk_rd(NULL, 2U + 1U /* root clus lba = reserved+fat = 3 */, sec) != 0) {
            xil_printf("[4] read root failed\n");
            goto idle;
        }
        p = &sec[0];
        xil_printf("[4] dirent name=%.11s attr=0x%02x clus=%u size=%u\n",
                   (const char *)p, (u32)p[11],
                   (u32)(((u32)p[21] << 8) | p[20]) << 16 | (u32)(((u32)p[27] << 8) | p[26]),
                   (u32)((u32)p[28] | ((u32)p[29] << 8) | ((u32)p[30] << 16) | ((u32)p[31] << 24)));

        first = (u32)(((u32)p[27] << 8) | p[26]);
        flen  = (u32)p[28] | ((u32)p[29] << 8) | ((u32)p[30] << 16) | ((u32)p[31] << 24);
        xil_printf("    first_clus=%u len=%u\n", first, flen);

        /* 把文件内容读回来算校验和 */
        n = flen;
        for (i = 0; i < 8U && n > 0U; i++) {
            u32 k;
            if (dsk_rd(NULL, 3U + 1U + i, sec) != 0) { break; }
            for (k = 0; k < 512U && n > 0U; k++, n--) {
                h = (h << 5) + h + (u32)sec[k];
            }
        }
        xil_printf("[5] readback djb2=0x%08x (expect 0x%08x) %s\n",
                   h, djb2(csv, csvlen), (h == djb2(csv, csvlen)) ? "MATCH" : "MISMATCH");
        xil_printf(h == djb2(csv, csvlen) ? "RESULT PASS\n" : "RESULT FAIL\n");
    }

idle:
    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
