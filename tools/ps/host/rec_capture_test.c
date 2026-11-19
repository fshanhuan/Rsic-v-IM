/* =============================================================================
 * tools/ps/host/rec_capture_test.c -- 在 PC 上验 sw/ps/rec_capture.h 的取样本逻辑
 * -----------------------------------------------------------------------------
 * 为什么要有这个测试：
 *   2026-11-20 00:30 在板上查出两个真 bug，都在"取样本"那几行里：
 *     1) 读 0x8C **只是窥视队头**，弹出要写 0x98 的 bit2 —— 原来只读不弹，
 *        于是 1024 个样本全是同一个值（实测全 3706）；
 *     2) XADC 结果左对齐，12 位码要 `>>4`，原来 `& 0x0FFF` 取的是低 12 位。
 *   这两个 bug 活了几个月，因为这段代码**只有插了卡才会在板上跑到**，
 *   而主机测试原来只测 fat32/sd_wr，从不碰 MMIO。
 *
 * 这个测试用一个**假的 rec_mmio**（和 board/rec_mmio.sv 同语义：peek 不弹、
 * 写 bit2 才弹）去调**同一份 rec_capture()**，于是协议写错了这里立刻红。
 *
 * 编译（Windows + mingw gcc）：
 *   gcc -O2 -I sw/ps -o sim/build/rec_capture_test.exe tools/ps/host/rec_capture_test.c
 * 运行：
 *   sim/build/rec_capture_test.exe
 * ============================================================================= */
#include <stdio.h>
#include <string.h>
#include "rec_capture.h"

#define FIFO_DEPTH 1024
#define BASE       0x40010000U

static unsigned short fifo[FIFO_DEPTH];
static unsigned int    wp, rp, total_produced, en;
static int             peeks;           /* 累计窥视次数，用来验"窥视不弹" */

/* 被测代码要用到的四个寄存器 */
static unsigned int fake_rd(unsigned int addr)
{
    unsigned int off = addr - BASE;
    if (off == REC_OFF_DATA) { peeks++; return fifo[rp % FIFO_DEPTH]; }
    if (off == REC_OFF_ST)   { return (rp != wp) ? REC_ST_LEVEL_MASK : 0U; }
    if (off == REC_OFF_CTL)  { return en; }
    if (off == REC_OFF_CNT)  { return total_produced; }
    return 0U;
}

static void fake_wr(unsigned int addr, unsigned int val)
{
    unsigned int off = addr - BASE;
    if (off == REC_OFF_CTL) {
        if ((val & REC_CTL_POP) != 0U) {
            if (rp != wp) { rp++; }          /* 弹出：只动读指针 */
        } else {
            en = val & 1U;                   /* bit2=1 时 bit0 被忽略（与 RTL 一致） */
        }
    }
}

static const rec_io_ops fake_ops = { fake_rd, fake_wr, (void (*)(void))0 };

static int fails;
static void chk(const char *what, int got, int exp)
{
    if (got != exp) { printf("FAIL: %s (got %d, exp %d)\n", what, got, exp); fails++; }
    else            { printf("ok  : %s (%d)\n", what, got); }
}

int main(void)
{
    unsigned short buf[FIFO_DEPTH];
    unsigned int n, c0, c1, i, distinct, same_as_expected;

    /* ---- 1. FIFO 里塞满 1024 个"温度"样本（左对齐 16 位，12 位码在 [15:4]）---- */
    for (i = 0U; i < FIFO_DEPTH; i++) {
        unsigned int code12 = 2529U + (i % 15U);        /* 2529..2543，像真温度 */
        fifo[i] = (unsigned short)((code12 << 4) | 0x0U);
    }
    wp = FIFO_DEPTH; rp = 0U; total_produced = FIFO_DEPTH; en = 0U; peeks = 0;

    /* ---- 2. 窥视两次，读指针不能动（这就是原来的 bug 1）---- */
    {
        unsigned int a = fake_rd(BASE + REC_OFF_DATA);
        unsigned int b = fake_rd(BASE + REC_OFF_DATA);
        chk("two peeks return the same head", (int)(a == b), 1);
        chk("peek did not advance rp", (int)rp, 0);
    }

    /* ---- 3. 取全部 1024 个 ---- */
    n = rec_capture(&fake_ops, BASE, buf, FIFO_DEPTH, &c0, &c1);
    chk("captured count", (int)n, FIFO_DEPTH);
    chk("consume advanced rp", (int)rp, FIFO_DEPTH);
    chk("adc_cnt before", (int)c0, FIFO_DEPTH);
    chk("adc_cnt after",  (int)c1, FIFO_DEPTH);

    /* ---- 4. 关键：不能是"同一个值重复 1024 次"（bug 1 的症状）---- */
    distinct = 0U;
    for (i = 0U; i < n; i++) {
        unsigned int j, seen = 0U;
        for (j = 0U; j < i; j++) { if (buf[j] == buf[i]) { seen = 1U; break; } }
        if (!seen) { distinct++; }
    }
    chk("distinct values (must be >1)", (int)(distinct > 1U), 1);
    chk("distinct values == 15", (int)distinct, 15);

    /* ---- 5. 每个值都必须等于对应元素的 raw>>4（bug 2 的症状：取了低 12 位）---- */
    same_as_expected = 0U;
    for (i = 0U; i < n; i++) {
        unsigned int exp = (fifo[i] >> 4) & 0x0FFFU;
        if (buf[i] == (unsigned short)exp) { same_as_expected++; }
    }
    chk("values == raw>>4", (int)same_as_expected, (int)n);
    chk("first value is a temperature code > 2500", (int)(buf[0] > 2500U), 1);

    /* ---- 6. FIFO 空了以后应立刻返回 0，不能死等 ---- */
    n = rec_capture(&fake_ops, BASE, buf, FIFO_DEPTH, &c0, &c1);
    chk("second capture on empty FIFO", (int)n, 0);

    printf("RESULT %s (%d failures)\n", (fails == 0) ? "PASS" : "FAIL", fails);
    return (fails == 0) ? 0 : 1;
}
