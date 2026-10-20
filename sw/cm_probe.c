/* =============================================================================
 * sw/cm_probe.c -- CoreMark 中间量"双向对拍"探针
 * -----------------------------------------------------------------------------
 * 目的：CoreMark 在我们核上算出来的 crclist 与官方值（0xe714）不符，而乘/除/移位/
 *   访存自检都是对的。这个探针把 CoreMark 自己的算法代码（core_list_join.c 等）
 *   直接链进来，在**同一份源码**上打印同一批中间量：
 *
 *       SIZE / PER_ITEM / 前 6 个链表节点的 idx 与 data16 / 矩阵维数 N / crclist
 *
 *   然后把 x86 版和 rv32 版的输出逐行 diff —— 第一个不同的那一行，就是 CPU 算错
 *   的起点，比盯着 CRC 猜要快得多。
 *
 * 两个平台共用本文件，靠 CM_HOST 切换输出通道（x86 用 putchar，rv32 用 UART MMIO）。
 * ============================================================================= */
#include "coremark.h"

#ifdef CM_HOST
#include <stdio.h>
static void emit(char c)
{
    putchar(c);
}
#else
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define DONE_FLAG   (*(volatile unsigned int *)0x100000f0u)
static void emit(char c)
{
    while (UART_TXSTAT & 1u)
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
}
#endif

static void ps(const char *s)
{
    while (*s)
        emit(*s++);
}

static void pd(unsigned int v)
{
    char b[12];
    int i = 0;
    if (v == 0)
    {
        emit('0');
        return;
    }
    while (v > 0)
    {
        b[i++] = (char)('0' + v % 10u);
        v /= 10u;
    }
    while (i > 0)
        emit(b[--i]);
}

static void px(unsigned int v)
{
    const char *d = "0123456789abcdef";
    int i;
    ps("0x");
    for (i = 7; i >= 0; i--)
        emit(d[(v >> (i * 4)) & 0xF]);
}

static ee_u8        blk[TOTAL_DATA_SIZE];
static core_results res;

/* 对链表做一次与平台无关的摘要：节点数 + 滚动哈希（只用 32 位运算） */
static void dump_list(const char *tag, list_head *l)
{
    unsigned int n = 0;
    unsigned int h = 0;
    while (l != 0 && n < 128)
    {
        h = h * 31u + (unsigned int)l->info->idx;
        h = h * 31u + (unsigned int)(unsigned short)l->info->data16;
        n++;
        l = l->next;
    }
    ps(tag);
    ps(" n="); pd(n);
    ps(" h="); px(h);
    ps("\n");
}

/* 对矩阵区做摘要：覆盖 A/B/C 三块（用 MATDAT/MATRES 逐个累加） */
static void dump_mat(const char *tag, mat_params *p)
{
    unsigned int i, n;
    unsigned int h = 0;
    n = p->N * p->N;
    for (i = 0; i < n && i < 4096u; i++)
    {
        h = h * 31u + (unsigned int)(unsigned short)p->A[i];
        h = h * 31u + (unsigned int)(unsigned short)p->B[i];
        h = h * 31u + (unsigned int)(unsigned short)p->C[i];
    }
    ps(tag);
    ps(" N="); pd(p->N);
    ps(" h="); px(h);
    ps("\n");
}

int main(void)
{
    core_portable p;
    int           argc = 1;
    char         *argv[2];

    argv[0] = (char *)"probe";
    argv[1] = 0;
    portable_init(&p, &argc, argv);

    res.size        = TOTAL_DATA_SIZE / 3;
    res.seed1       = 0;
    res.seed2       = 0;
    res.seed3       = 0x66;
    res.execs       = ALL_ALGORITHMS_MASK;
    res.memblock[0] = blk;
    res.memblock[1] = blk;
    res.memblock[2] = blk + res.size;
    res.memblock[3] = blk + 2 * res.size;
    res.crc         = 0;

    ps("SIZE=");     pd(res.size);
    ps(" PER=");     pd(16 + (unsigned)sizeof(struct list_data_s));
    ps(" LISTH=");   pd((unsigned)sizeof(struct list_head_s));
    ps(" DATASZ=");  pd((unsigned)sizeof(struct list_data_s));
    ps("\n");

    res.list = core_list_init(res.size, (list_head *)res.memblock[1], (ee_s16)res.seed1);
    {
        list_head *n = res.list;
        int        k;
        for (k = 0; k < 6 && n != 0; k++, n = n->next)
        {
            ps("N"); pd((unsigned)k);
            ps(" idx="); px((unsigned)n->info->idx);
            ps(" d16="); px((unsigned)(unsigned short)n->info->data16);
            ps("\n");
        }
    }

    core_init_matrix(res.size, res.memblock[2], (ee_s32)res.seed1, &res.mat);
    core_init_state(res.size, res.seed1, res.memblock[3]);
    dump_list("L0", res.list);
    dump_mat("M0", &res.mat);

    {
        ee_u16 c1, c2;
        c1      = core_bench_list(&res, 1);
        res.crc = crcu16(c1, res.crc);
        ps("C1="); px((unsigned)c1); ps("\n");
        dump_list("L1", res.list);
        dump_mat("M1", &res.mat);

        c2      = core_bench_list(&res, -1);
        res.crc = crcu16(c2, res.crc);
        ps("C2="); px((unsigned)c2); ps("\n");
        dump_list("L2", res.list);
        dump_mat("M2", &res.mat);

        ps("CRC=");  px((unsigned)res.crc);  ps("\n");
        ps("CM=");   px((unsigned)res.crcmatrix);
        ps(" CS=");  px((unsigned)res.crcstate);  ps("\n");
    }

#ifndef CM_HOST
    DONE_FLAG = 0x5A5A5A5A;
#endif
    return 0;
}
