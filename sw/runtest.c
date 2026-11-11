/* =============================================================================
 * sw/runtest.c — S4：从文件系统加载程序并执行（"换程序不用重新综合"）
 * -----------------------------------------------------------------------------
 * 流程（全部在片内完成，不碰串口）：
 *   ① 在 ramdisk 里建一个文件 "payload"，内容是一小段机器码；
 *   ② 用 fs_read 把它读回来（证明是**从文件系统**取的，不是内嵌在代码里跑）；
 *   ③ 逐字写到 IROM 数据窗口 0x2_0000 + 0x4000；
 *   ④ fence.i 让取指侧看到新指令；
 *   ⑤ 跳过去执行；payload 把 LED 写成 0x5A 然后返回；
 *   ⑥ 回到本程序，检查 LED == 0x5A，再写 0x2A 作为总判据。
 *
 * payload（5 条指令，20 字节）：
 *   lui   a0, 0x10000        ; 0x1000_0000
 *   addi  a0, a0, 0x10       ; → LED 寄存器
 *   addi  a1, zero, 0x5A
 *   sw    a1, 0(a0)          ; LED = 0x5A
 *   jalr  x0, 0(ra)          ; 返回调用者
 *
 * ★ 为什么 payload 用"运行时赋值"的数组而不是 const 数组：const 会进 .rodata，
 *   而 .rodata 在 DRAM 的 0x1_0000 —— 仿真台必须预装 DRAM 镜像才有值（见 S3 的坑）。
 *   这里已经要求 +dram=，但少一个依赖总是好的。
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define LED      (*(volatile uint32_t *)0x10000010u)

#define IROM_WIN   0x00020000u
#define APP_ADDR   0x00004000u

/* ---- 最小 ramdisk FS（与 sw/fstest.c 同一套布局，只留 create/read）---- */
#define BLK_SZ      256u
#define NBLK        256u
#define DIR_ENTRIES 32u
#define NAME_LEN    16u
#define SB_MAGIC    0x53534642u
#define SB_NFILES   1u
#define SB_NEXT     2u

typedef struct { char name[NAME_LEN]; uint16_t start; uint16_t nblk; uint32_t size; } dirent_t;

static volatile uint32_t disk_base = 0u;         /* 见 fstest.c：不能用 (uint8_t*)0 常量 */
#define disk ((uint8_t *)disk_base)
#define sb   ((uint32_t *)disk_base)
#define dir  ((dirent_t *)(disk_base + BLK_SZ))

static void putc_(char c) { while (TXSTAT & 1u) ; TXDATA = (uint32_t)(uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }

static void name_copy(char dst[NAME_LEN], const char *src)
{
    uint32_t i = 0;
    for (; i + 1u < NAME_LEN && src[i]; i++) dst[i] = src[i];
    dst[i] = '\0';
}

static int streq(const char *a, const char *b)
{
    while (*a && (*a == *b)) { a++; b++; }
    return *a == *b;
}

static void fs_init(void)
{
    uint32_t i;
    if (sb[0] != SB_MAGIC) {
        for (i = 0; i < (BLK_SZ / 4u); i++) sb[i] = 0;
        sb[0] = SB_MAGIC;
        sb[SB_NEXT] = 5;
        for (i = 0; i < DIR_ENTRIES; i++) dir[i].name[0] = '\0';
    }
}

static dirent_t *fs_find(const char *name)
{
    uint32_t i;
    for (i = 0; i < DIR_ENTRIES; i++)
        if (dir[i].name[0] && streq(dir[i].name, name)) return &dir[i];
    return (dirent_t *)0;
}

static int fs_create(const char *name, const uint8_t *data, uint32_t size)
{
    uint32_t i;
    dirent_t *e = (dirent_t *)0;
    uint32_t nb = (size + BLK_SZ - 1u) / BLK_SZ;
    uint32_t start;

    if (nb == 0u) nb = 1u;
    if (fs_find(name)) return -1;
    for (i = 0; i < DIR_ENTRIES; i++) if (!dir[i].name[0]) { e = &dir[i]; break; }
    if (!e) return -2;
    start = sb[SB_NEXT];
    if (start + nb > NBLK) return -3;
    sb[SB_NEXT] = start + nb;
    for (i = 0; i < size; i++) disk[start * BLK_SZ + i] = data[i];
    name_copy(e->name, name);
    e->start = (uint16_t)start;
    e->nblk  = (uint16_t)nb;
    e->size  = size;
    return 0;
}

static int fs_read(const char *name, uint8_t *buf, uint32_t cap)
{
    dirent_t *e = fs_find(name);
    uint32_t i;
    if (!e) return -1;
    if (e->size > cap) return -2;
    for (i = 0; i < e->size; i++) buf[i] = disk[e->start * BLK_SZ + i];
    return (int)e->size;
}

/* ---------------------------------------------------------------- 主程序 */
static uint32_t blob[5];
/* ★ 用 uint32_t 数组当字节缓冲，而不是 uint8_t[64]：后者不保证 4 字节对齐，
 *   再强转成 `const uint32_t *` 去读就是**非对齐 load** → 本核会报异常 → 复位重启
 *   （表现是"跳过去之前就先挂了"，第二遍还因为重名失败）。 */
static uint32_t buf32[16];
#define buf ((uint8_t *)buf32)

int main(void)
{
    int ok = 1, n, i;
    volatile uint32_t *win;

    fs_init();

    /* ① 造 payload（运行时赋值，别让编译器放到 .rodata）
     *   ★ 判据不能靠"读回 LED"——LED 是**只写**寄存器，读它恒返回 0
     *     （board_top 的 MMIO 读 mux：TXDATA/LED/BOOTREQ/RXPOP 一律读回 0）。
     *     改成写 DRAM 0x2000，再读回来比对。 */
    blob[0] = 0x00002537u;      /* lui   a0, 0x2            → 0x0000_2000 */
    blob[1] = 0x05A00593u;      /* addi  a1, zero, 0x5A                     */
    blob[2] = 0x00B52023u;      /* sw    a1, 0(a0)          → [0x2000]=0x5A */
    blob[3] = 0x00008067u;      /* jalr  x0, 0(ra)                          */

    ok &= (fs_create("payload", (uint8_t *)blob, 16u) == 0);

    /* ② 从文件系统读回来 */
    n = fs_read("payload", buf, sizeof(buf32));
    ok &= (n == 16);

    if (ok) {
        /* ③ 搬到 IROM 的 0x4000（窗口地址 = 0x2_0000 + 0x4000） */
        win = (volatile uint32_t *)(IROM_WIN + APP_ADDR);
        for (i = 0; i < 4; i++)
            win[i] = buf32[i];

        /* ④ 让取指侧看到新指令 */
        __asm__ volatile(".word 0x0000100f" ::: "memory");

        /* ⑤ 跳过去执行 */
        ((void (*)(void))APP_ADDR)();

        /* ⑥ payload 应该把 DRAM[0x2000] 写成 0x5A */
        ok &= (*(volatile uint32_t *)0x00002000u == 0x5Au);
    }

    LED = ok ? 0x2Au : 0x7Fu;
    puts_(ok ? "RUNTEST-PASS\n" : "RUNTEST-FAIL\n");
    for (;;)
        ;
}
