/* =============================================================================
 * tools/ps/host/sd_bit_sim_test.c -- 在 PC 上跑**真的** sd_bit_bus.c（位翻转驱动）
 * -----------------------------------------------------------------------------
 * 解决什么问题
 * ------------
 * `sw/ps/sd_bit_bus.c` 是整个 SD 通路里唯一**从来没和任何"会应答的东西"说过话**的
 * 一层：它只在真板上对着空卡槽跑过，结果永远是"CMD8 超时"。
 * 于是帧格式、位序、CRC7、CMD 线换向、48 位响应解析、数据阶段 —— 全都只是"看着对"。
 *
 * 这里在 PC 上给 GPIO 寄存器做一层拦截（tools/ps/host/sim/xil_io.h），接一个
 * **按位应答的 SD 卡模型**，然后原封不动地跑：
 *
 *     sd_bit_init() -> sd_bit_powerup() -> sd_bit_card_init()
 *       -> sd_read_block() / sd_write_block()          （sd_wr.c）
 *       -> sd_record_to_card()                          （sd_record.c，产品路径）
 *       -> fat32_format() / fat32_write_file()          （fat32.c）
 *
 * 也就是说：**除了"电平上升沿要等多久"这一件事，整条链路都真的执行了。**
 * 真卡插上那天，剩下的未知就只有电气时序。
 *
 * 卡模型按 SD 物理层规范（1-bit 模式）实现：
 *   · 命令 48 位：0 | 1 | cmd[5:0] | arg[31:0] | crc7 | 1；模型自己重算 CRC7 并比对
 *   · 总线空闲时 CMD 是高的（全 1），**只在看到起始位 0 时才开始收命令**（和真卡一样）
 *   · 响应：R1/R3/R6/R7 = 48 位，R2 = 136 位，CMD0 无响应
 *   · CMD17：R1 之后发 2 个 0xFF + 0xFE + 512 字节 + CRC16（练"搜令牌"）
 *   · CMD24：R1 之后收 0xFE + 512 字节 + CRC16，模型**重算 CRC16**，错了回 0x0B
 *   · 数据响应令牌 0x05，之后忙 16 个时钟
 *
 * 编译/运行：powershell -NoProfile -File tools\ps\host\build_sim.ps1
 * ============================================================================= */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "sd_bit.h"      /* 会带进 sd_wr.h */
#include "sd_crc.h"
#include "fat32.h"
#include "sd_record.h"

/* ------------------------------------------------------------------ 串口垫片 */
void port_uart_init(void) { }
void port_log_reset(void) { }
void usleep(unsigned long useconds) { (void)useconds; }
void sleep(unsigned int seconds) { (void)seconds; }

int xil_printf(const char *fmt, ...)
{
    va_list ap;
    int r;

    va_start(ap, fmt);
    r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}

/* ------------------------------------------------------------------ 寄存器垫片 */
#define A_DATA_RO   0xE000A064U
#define A_MASK_LSW  0xE000A008U
#define A_DIRM1     0xE000A244U
#define A_TRI1      0xF8000834U

#define B_CLK       8U
#define B_CMD       9U

static u32 g_pins_out;      /* MIO40..45 输出锁存（bit0 = MIO40） */
static u32 g_dirm1;
static u32 g_tri1;
static u32 g_card_out;      /* 卡在 CMD 线上驱动的那一位 */

/* 其余寄存器：小表存着（MIO_PIN / SLCR / UART 都是写进去就该读得回来） */
#define MAX_REG 96
static u32 reg_a[MAX_REG];
static u32 reg_v[MAX_REG];
static int reg_n;

static int reg_find(u32 a)
{
    int i;

    for (i = 0; i < reg_n; i++) {
        if (reg_a[i] == a) { return i; }
    }
    return -1;
}

static void reg_put(u32 a, u32 v)
{
    int i = reg_find(a);

    if (i >= 0) { reg_v[i] = v; return; }
    if (reg_n < MAX_REG) {
        reg_a[reg_n] = a;
        reg_v[reg_n] = v;
        reg_n++;
    }
}

static u32 reg_get(u32 a)
{
    int i = reg_find(a);

    return (i >= 0) ? reg_v[i] : 0U;
}

/* ------------------------------------------------------------------ 卡模型 */
static u32   card_rca = 0x1234U;
static u8   *card_disk;
static u32   card_nsec = 131072U;      /* 64 MB */

static u8    q[1200];                  /* 卡待发的字节队列 */
static u32   qlen, qbit;

static u64   cmd_val;      /* 48 位帧，必须用 64 位装 */
static u32   cmd_cnt;
static u32   data_expect;
static u32   data_bits, data_byte, data_cnt;
static u8    wbuf[512];
static u8    wcrc[2];
static u32   write_lba;

/* 统计（这是证据，不是日志装饰） */
static u32 st_cmd_seen[64];
static u32 st_cmd_total;
static u32 st_cmd_crc_bad;
static u32 st_wr_ok;
static u32 st_wr_crc_bad;
static u32 st_rd_ok;
static u32 st_badtok;

static void q_reset(void) { qlen = 0U; qbit = 0U; }

static void q_byte(u8 b)
{
    if (qlen < sizeof(q)) { q[qlen++] = b; }
}

static void q_frame(const u8 *d, u32 n)
{
    while (n-- > 0U) { q_byte(*d++); }
}

/* 取一位（高位先）；队列空了就当总线空闲（全 1） */
static u32 card_bit(void)
{
    u32 i, b;

    if (qbit >= qlen * 8U) { return 1U; }
    i = qbit >> 3;
    b = (u32)((q[i] >> (7U - (qbit & 7U))) & 1U);
    qbit++;
    return b;
}

static void push_frame48(u8 b0, u32 content)
{
    u8 f[6];

    f[0] = b0;
    f[1] = (u8)(content >> 24);
    f[2] = (u8)(content >> 16);
    f[3] = (u8)(content >> 8);
    f[4] = (u8)content;
    f[5] = (u8)((sd_crc7(f, 5U) << 1) | 0x01U);
    q_frame(f, 6U);
}

static void push_r2(void)
{
    u8 f[17];
    u32 i;

    f[0] = 0x3FU;
    for (i = 1U; i < 16U; i++) { f[i] = (u8)(0xA0U + i); }
    f[16] = 0xFFU;
    q_frame(f, 17U);
}

static void push_read_data(u32 lba)
{
    static const u8 pad[2] = { 0xFFU, 0xFFU };
    u8 tmp[512];
    u8 d[2];
    u16 c;
    u32 i;

    q_frame(pad, 2U);                   /* 令牌前的填充 */
    q_byte(0xFEU);

    for (i = 0U; i < 512U; i++) {
        tmp[i] = (lba < card_nsec) ? card_disk[(size_t)lba * 512U + i] : 0x00U;
    }
    q_frame(tmp, 512U);

    c = sd_crc16(tmp, 512U);
    d[0] = (u8)(c >> 8);
    d[1] = (u8)c;
    q_frame(d, 2U);
    st_rd_ok++;
}

static void finish_write(void)
{
    u16 want = sd_crc16(wbuf, 512U);
    u16 got = (u16)(((u16)wcrc[0] << 8) | (u16)wcrc[1]);
    u32 i;

    if (want != got) {
        st_wr_crc_bad++;
        q_byte(0x0BU);                  /* CRC 错令牌 */
        return;
    }
    if (write_lba < card_nsec) {
        for (i = 0U; i < 512U; i++) {
            card_disk[(size_t)write_lba * 512U + i] = wbuf[i];
        }
    }
    st_wr_ok++;
    q_byte(0x05U);                      /* 接受 */
    q_byte(0x00U);                      /* 忙 16 个时钟 */
    q_byte(0x00U);
}

static void handle_cmd(void)
{
    u8 frame[5];
    u32 idx = (u32)((cmd_val >> 40) & 0x3FU);
    u32 arg = (u32)((cmd_val >> 8) & 0xFFFFFFFFU);
    u32 crc = (u32)((cmd_val >> 1) & 0x7FU);

    frame[0] = (u8)((cmd_val >> 40) & 0xFFU);
    frame[1] = (u8)((cmd_val >> 32) & 0xFFU);
    frame[2] = (u8)((cmd_val >> 24) & 0xFFU);
    frame[3] = (u8)((cmd_val >> 16) & 0xFFU);
    frame[4] = (u8)((cmd_val >> 8) & 0xFFU);

    st_cmd_seen[idx & 0x3FU]++;
    st_cmd_total++;
    if (sd_crc7(frame, 5U) != crc) {
        st_cmd_crc_bad++;
    }

    switch (idx) {
    case 0U:                            /* CMD0：无响应 */
        q_reset();
        break;
    case 2U:                            /* CMD2：R2 = 136 位 */
        q_reset();
        push_r2();
        break;
    case 3U:                            /* CMD3：R6，回 RCA */
        q_reset();
        push_frame48(0x03U, card_rca << 16);
        break;
    case 8U:                            /* CMD8：R7，回 0x1AA */
        q_reset();
        push_frame48(0x08U, 0x000001AAU);
        break;
    case 41U:                           /* ACMD41：R3，busy 位已清 */
        q_reset();
        push_frame48(0x3FU, 0xC0FF8000U);
        break;
    case 17U:                           /* 读单块 */
        q_reset();
        push_frame48(0x11U, 0U);
        push_read_data(arg);
        break;
    case 24U:                           /* 写单块 */
        q_reset();
        push_frame48(0x18U, 0U);
        write_lba = arg;
        data_expect = 1U;
        data_bits = 0U;
        data_byte = 0U;
        data_cnt = 0U;
        break;
    default:                            /* CMD55/7/16 等：R1 全 0 */
        q_reset();
        push_frame48(idx & 0x3FU, 0U);
        break;
    }
}

static int host_drives_cmd(void)
{
    return ((g_dirm1 & (1U << B_CMD)) != 0U) && ((g_tri1 & (1U << B_CMD)) == 0U);
}

/* CLK 上升沿：卡在这一刻采样（主机发）或发出（卡发）一位 */
static void on_rising_edge(void)
{
    u32 bit;

    if (host_drives_cmd()) {
        bit = (g_pins_out >> B_CMD) & 1U;

        if (data_expect != 0U) {
            data_byte = (data_byte << 1) | bit;
            data_bits++;
            if ((data_bits & 7U) == 0U) {
                u8 b = (u8)data_byte;

                if (data_cnt == 0U) {
                    if (b != 0xFEU) { st_badtok++; }
                } else if (data_cnt <= 512U) {
                    wbuf[data_cnt - 1U] = b;
                } else {
                    wcrc[data_cnt - 513U] = b;
                }
                data_cnt++;
                if (data_cnt >= 515U) {
                    data_expect = 0U;
                    cmd_cnt = 0U;
                    finish_write();
                }
            }
            return;
        }

        /* 命令帧：**只在看到起始位 0 时开始**，这样空闲的全 1 时钟不会把窗口打歪
         * （真卡就是这么做的） */
        if (cmd_cnt == 0U) {
            if (bit != 0U) { return; }
            cmd_val = 0ULL;
            cmd_cnt = 1U;
            return;
        }
        cmd_val = (cmd_val << 1) | (u64)bit;
        cmd_cnt++;
        if (cmd_cnt >= 48U) {
            handle_cmd();
            cmd_cnt = 0U;
        }
    } else {
        g_card_out = card_bit();
    }
}

/* ------------------------------------------------------------------ 仿真寄存器 */
u32 sim_in32(u32 a)
{
    if (a == A_DATA_RO) {
        u32 v = g_pins_out & 0x3FFFU;

        if (!host_drives_cmd()) {
            v = (v & ~(1U << B_CMD)) | ((g_card_out != 0U) ? (1U << B_CMD) : 0U);
        }
        return v;
    }
    if (a == A_DIRM1) { return g_dirm1; }
    if (a == A_TRI1)  { return g_tri1; }
    return reg_get(a);
}

void sim_out32(u32 a, u32 v)
{
    u32 old_clk, new_pins, mask, data, i;

    if (a == A_MASK_LSW) {
        mask = (v >> 16) & 0x3FFFU;
        data = v & 0x3FFFU;
        old_clk = (g_pins_out >> B_CLK) & 1U;
        new_pins = g_pins_out;
        for (i = 0U; i < 14U; i++) {
            if ((mask & (1U << i)) != 0U) {
                if ((data & (1U << i)) != 0U) { new_pins |=  (1U << i); }
                else                         { new_pins &= ~(1U << i); }
            }
        }
        g_pins_out = new_pins;
        if ((old_clk == 0U) && (((new_pins >> B_CLK) & 1U) == 1U)) {
            on_rising_edge();
        }
        return;
    }
    if (a == A_DIRM1) { g_dirm1 = v; return; }
    if (a == A_TRI1)  { g_tri1 = v; return; }
    reg_put(a, v);
}

/* ------------------------------------------------------------------ 测试框架 */
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

static int save(const char *path, const u8 *p, u32 n)
{
    FILE *f = fopen(path, "wb");

    if (f == 0) { return -1; }
    fwrite(p, 1U, n, f);
    fclose(f);
    printf("  saved %s (%u bytes)\n", path, n);
    return 0;
}

#define NSAMP 1000U

int main(void)
{
    static u8 blk[512], blk2[512];
    static u8 csv[16384];
    static u16 samp[NSAMP];
    static fat32_geo g;
    static sd_record_stat rst;
    u32 rca = 0U;
    u32 i, diffs;
    int rc;

    printf("=== bit-level SD simulation: real sd_bit_bus.c driving a bit-level card ===\n");

    card_nsec = 131072U;                        /* 64 MB */
    card_disk = (u8 *)calloc((size_t)card_nsec, 512U);
    if (card_disk == 0) { printf("calloc failed\n"); return 1; }
    for (i = 0U; i < 512U; i++) {
        card_disk[i] = (u8)((i * 7U + 3U) & 0xFFU);   /* LBA0 预置图案 */
    }

    chk("sd_bit_init", sd_bit_init(), 0);       /* 内部会自检 CLK 跟随 */
    sd_bit_set_half(1U);                        /* 别让 dly() 空转 */
    cmd_cnt = 0U;                               /* 让模型从字节边界开始对齐 */
    cmd_val = 0ULL;
    data_expect = 0U;
    sd_bit_powerup();

    rc = sd_bit_card_init(&rca);
    chk("card_init rc", rc, 0);
    chk("rca", (int)rca, 0x1234);
    chk("cmd0 seen", (int)st_cmd_seen[0], 1);
    chk("cmd8 seen", (int)st_cmd_seen[8], 1);
    chk("acmd41 seen", (int)st_cmd_seen[41], 1);
    chk("cmd2 seen", (int)st_cmd_seen[2], 1);
    chk("cmd3 seen", (int)st_cmd_seen[3], 1);
    chk("cmd7 seen", (int)st_cmd_seen[7], 1);
    chk("cmd16 seen", (int)st_cmd_seen[16], 1);
    chk("commands with bad crc7", (int)st_cmd_crc_bad, 0);

    /* --- 读 LBA0：和预置图案逐字节比 --- */
    rc = sd_read_block(sd_bit_bus(), 0U, blk);
    chk("read lba0 rc", rc, 0);
    diffs = 0U;
    for (i = 0U; i < 512U; i++) {
        if (blk[i] != (u8)((i * 7U + 3U) & 0xFFU)) { diffs++; }
    }
    chk("read lba0 diffs", (int)diffs, 0);

    /* --- 写 / 读回环 --- */
    for (i = 0U; i < 512U; i++) { blk[i] = (u8)(0xFFU - i); }
    chk("write lba7 rc", sd_write_block(sd_bit_bus(), 7U, blk), 0);
    memset(blk2, 0, sizeof(blk2));
    chk("read lba7 rc", sd_read_block(sd_bit_bus(), 7U, blk2), 0);
    diffs = 0U;
    for (i = 0U; i < 512U; i++) {
        if (blk2[i] != blk[i]) { diffs++; }
    }
    chk("lba7 diffs", (int)diffs, 0);

    /* --- 产品路径：整卷格式化 + 1000 样本 CSV，全程走位翻转 --- */
    printf("\n--- product path through the bit-banged bus ---\n");
    fat32_geo_default(&g);
    for (i = 0U; i < NSAMP; i++) {
        samp[i] = (u16)((0x800U + 7U * i) & 0xFFFU);
    }
    rc = sd_record_to_card(sd_bit_bus(), &g, samp, NSAMP, csv, (u32)sizeof(csv),
                           blk, &rst);
    chk("sd_record rc", rc, 0);
    chk("bytes diff", (int)rst.bytes_diff, 0);
    chk("compared == csv bytes", (int)rst.bytes_compared, (int)rst.csv_bytes);
    chk("card wr crc bad", (int)st_wr_crc_bad, 0);
    chk("card bad data token", (int)st_badtok, 0);

    printf("\n--- card side counters ---\n");
    printf("commands=%u  crc7_bad=%u  writes_ok=%u  wr_crc_bad=%u  reads=%u  bad_token=%u\n",
           st_cmd_total, st_cmd_crc_bad, st_wr_ok, st_wr_crc_bad, st_rd_ok, st_badtok);
    printf("cmd counts: 0=%u 2=%u 3=%u 7=%u 8=%u 16=%u 17=%u 24=%u 41=%u 55=%u\n",
           st_cmd_seen[0], st_cmd_seen[2], st_cmd_seen[3], st_cmd_seen[7],
           st_cmd_seen[8], st_cmd_seen[16], st_cmd_seen[17], st_cmd_seen[24],
           st_cmd_seen[41], st_cmd_seen[55]);

    save("sim/build/sd/sim_card.img", card_disk, card_nsec * 512U);

    printf("\nchecks: %u passed, %u failed\n", t_pass, t_fail);
    printf((t_fail == 0U) ? "RESULT PASS\n" : "RESULT FAIL\n");
    free(card_disk);
    return (t_fail == 0U) ? 0 : 1;
}
