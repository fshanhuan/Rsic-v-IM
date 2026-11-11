/* =============================================================================
 * sw/fstest.c — S3：ramdisk 文件系统自测（不依赖中断、不依赖 shell）
 * -----------------------------------------------------------------------------
 * 区域：DRAM 0x0000_0000 – 0x0000_FFFF（64 KB）。这块在 link.ld 里**本来就留空**
 *   （0x1_0000 以上才是 .data/.bss/栈），所以拿来当 ramdisk 不占程序空间。
 *
 * 布局（块 256 B，共 256 块）：
 *   块 0        超级块   magic 'BFSS' / nfiles / next_free
 *   块 1..N     目录表   32 项 × 32 B（name[16] + start(u16) + nblk(u16) + size(u32)）
 *   块 N+1..    数据区   连续块（bump 分配，不回收；删文件只标 unused）
 *
 * ★ 为什么用 bump 分配而不是位图：这是教学用最小实现，删掉的文件空间不回收，
 *   但"删了就不能再读到"这个语义是对的。真要做碎片回收再上位图。
 * ★ 为什么目录项定长 32 B：一个块 256 B 正好放 8 项，32 项 = 4 块，算术简单。
 *
 * 判据：三道读写校验全过 → LED=0x2A、串口打 "FSTEST-PASS"；否则 LED=0x7F。
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define LED      (*(volatile uint32_t *)0x10000010u)

#define DISK_BASE   0x00000000u
#define BLK_SZ      256u
#define NBLK        256u
#define DIR_ENTRIES 32u
#define NAME_LEN    16u

#define SB_MAGIC    0x53534642u          /* 'BFSS' 小端 */

typedef struct {
    char     name[NAME_LEN];
    uint16_t start;                      /* 起始块号 */
    uint16_t nblk;                       /* 占用块数 */
    uint32_t size;                       /* 字节数 */
} dirent_t;                              /* 24 B，补齐到 32 B */

/* ★ 不能用 `(uint8_t *)0` 这样的常量指针：在 C 里它就是 NULL，gcc 会认定
 *   "解引用空指针是 UB" 从而**把全部访存优化掉**（实测整个程序只剩 21 个字）。
 *   用一个 volatile 的基址变量，把"0 只是一个数值"藏过优化器。 */
static volatile uint32_t disk_base = DISK_BASE;
#define disk ((uint8_t *)disk_base)
#define sb   ((uint32_t *)disk_base)
#define dir  ((dirent_t *)(disk_base + BLK_SZ))

/* 超级块： [0]=magic [1]=nfiles [2]=next_free_blk */
#define SB_NFILES  1u
#define SB_NEXT    2u

static void putc_(char c) { while (TXSTAT & 1u) ; TXDATA = (uint32_t)(uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }

static int streq(const char *a, const char *b)
{
    while (*a && (*a == *b)) { a++; b++; }
    return *a == *b;
}

static void name_copy(char dst[NAME_LEN], const char *src)
{
    uint32_t i = 0;
    for (; i + 1u < NAME_LEN && src[i]; i++) dst[i] = src[i];
    dst[i] = '\0';
}

static void fs_init(void)
{
    uint32_t i;
    if (sb[0] != SB_MAGIC) {                 /* 首次上电/复位后重建 */
        for (i = 0; i < (BLK_SZ / 4u); i++) sb[i] = 0;
        sb[0] = SB_MAGIC;
        sb[SB_NFILES] = 0;
        sb[SB_NEXT]   = 5;                   /* 0=SB, 1..4=目录 */
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
    if (fs_find(name)) return -1;            /* 重名 */
    for (i = 0; i < DIR_ENTRIES; i++) if (!dir[i].name[0]) { e = &dir[i]; break; }
    if (!e) return -2;                       /* 目录满 */

    start = sb[SB_NEXT];
    if (start + nb > NBLK) return -3;        /* 空间不足 */
    sb[SB_NEXT] = start + nb;

    for (i = 0; i < size; i++) disk[start * BLK_SZ + i] = data[i];

    name_copy(e->name, name);
    e->start = (uint16_t)start;
    e->nblk  = (uint16_t)nb;
    e->size  = size;
    sb[SB_NFILES] = sb[SB_NFILES] + 1u;
    return 0;
}

/* 返回字节数；-1 = 没这个文件；-2 = 缓冲区不够 */
static int fs_read(const char *name, uint8_t *buf, uint32_t cap)
{
    dirent_t *e = fs_find(name);
    uint32_t i;
    if (!e) return -1;
    if (e->size > cap) return -2;
    for (i = 0; i < e->size; i++) buf[i] = disk[e->start * BLK_SZ + i];
    return (int)e->size;
}

static int fs_delete(const char *name)
{
    dirent_t *e = fs_find(name);
    if (!e) return -1;
    e->name[0] = '\0';                       /* 只标失效，块不回收 */
    sb[SB_NFILES] = sb[SB_NFILES] - 1u;
    return 0;
}

static uint32_t fs_free_blocks(void) { return NBLK - sb[SB_NEXT]; }

/* ---------------------------------------------------------------- 自测 */
static uint8_t  buf_a[3000];
static uint8_t  buf_b[3000];
/* ★ 不要写 static uint8_t pattern[8] = {...}：那会进 .data，而本平台的 .data 靠
 *   板级/仿真预装镜像才有值。tb_prog 只载 IROM、不载 DRAM 镜像 ⇒ .data 是 **X**，
 *   X 一路传进 ok，最后 `LED = ok ? …` 得到 X，TB 既看不到 0x2A 也看不到 0x7F → 超时。
 *   （实测就是这么挂的。）改成 .bss（crt0 会清零）+ 运行时填值。 */
static uint8_t  pattern[8];

static int check(int ok) { return ok; }

int main(void)
{
    int i, n, ok = 1;
    uint32_t before, after;

    fs_init();
    before = fs_free_blocks();

    for (i = 0; i < 8; i++) pattern[i] = (uint8_t)(0x11u * (uint32_t)(i + 1));

    /* ① 建三个文件：1 B / 300 B / 3000 B */
    ok &= check(fs_create("tiny", pattern, 1u) == 0);
    for (i = 0; i < 300; i++) buf_a[i] = (uint8_t)i;
    ok &= check(fs_create("mid", buf_a, 300u) == 0);
    for (i = 0; i < 3000; i++) buf_a[i] = (uint8_t)(i * 7 + 3);
    ok &= check(fs_create("big", buf_a, 3000u) == 0);

    /* ② 读回逐字节比对 */
    n = fs_read("big", buf_b, sizeof(buf_b));
    ok &= check(n == 3000);
    if (n == 3000) for (i = 0; i < 3000; i++) ok &= check(buf_b[i] == buf_a[i]);

    n = fs_read("mid", buf_b, sizeof(buf_b));
    ok &= check(n == 300);
    if (n == 300) for (i = 0; i < 300; i++) ok &= check(buf_b[i] == (uint8_t)i);

    n = fs_read("tiny", buf_b, sizeof(buf_b));
    ok &= check(n == 1 && buf_b[0] == 0x11);

    /* ③ 删除 + 重名 + 不存在 */
    ok &= check(fs_delete("mid") == 0);
    ok &= check(fs_read("mid", buf_b, sizeof(buf_b)) == -1);   /* 删了就读不到 */
    ok &= check(fs_create("tiny", pattern, 1u) == -1);         /* 重名被拒 */
    ok &= check(fs_delete("nope") == -1);

    after = fs_free_blocks();
    ok &= check(after < before);                                /* 真的占了块 */

    LED = ok ? 0x2Au : 0x7Fu;
    puts_(ok ? "FSTEST-PASS\n" : "FSTEST-FAIL\n");
    for (;;) ;
}
