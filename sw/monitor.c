/* =============================================================================
 * sw/monitor.c -- 板级串口 shell（P3 → v14 轻量 shell）
 * -----------------------------------------------------------------------------
 * 为什么需要它：改一个程序原来只有两条路 —— 重烧 bitstream（冷启动 53~57 s，
 *   ILA 还得重新 arm），或者伸手按 S1 复位键。有了这个 shell，串口上敲一条命令
 *   就能：看内存/看 CSR、改内存、点灯、算校验和、以及**重新进入引导器**（然后
 *   宿主直接灌新镜像，几秒完成，不需要重配 FPGA）。
 *
 * v14 相对 v13.5 的变化（"monitor" → "shell"）：
 *   · 命令表驱动（名字可长短两种写法），代替原来"只看首字符"的 switch；
 *   · 行编辑：退格、^U 删整行、^C 取消、↑/↓ 历史（4 条）；
 *   · 参数支持 0x 十六进制 / 0d 十进制，缺省仍是十六进制（与旧脚本兼容）；
 *   · 新命令：echo / fill / cmp / uptime / cksum / info；
 *   · CR 后紧跟的 LF 被吞掉（宿主发 CRLF 时不再多打一个空提示符）。
 *
 * 命令一览（不区分大小写）：
 *   h | help             帮助
 *   d | dump   <a> [n]   从 a 起 dump n 个字（默认 8，每行 8 个）
 *   p | peek   <a>       读一个字
 *   w | poke   <a> <v>   写一个字（外设寄存器也走这条）
 *   c | csr              dump 关键 CSR
 *   l | led    <v>       写 LED（低 7 位）
 *   f | fill   <a> <n> <v>  填 n 个字
 *   m | cmp    <a> <b> <n>  比较两块内存
 *   k | cksum  <a> [n]   djb2 校验和（默认 64 字）—— `k 20000` 就是"读自己的代码"
 *   u | uptime           开机时长（mtime，500 kHz）
 *   i | info             硬件/镜像信息
 *   e | echo   <text>    回显（拿来测链路）
 *   b | boot             重新进入引导器（宿主随后灌镜像）
 *
 * ★ 不变量（都是硬件契约，改程序时别破坏）：
 *   - RXDATA 是**幂等读**（peek），弹出靠写 RXPOP。读之前必须先看 RXSTAT.bit0。
 *     FIFO 只有 8 深，主循环里不能长时间不读。
 *   - TXDATA 忙时要等 TXSTAT.bit0 == 0（115200 下一个字节 86.8 us）。
 *   - MMIO 区不可 cache（地址 >= 0x1000_0000 由 DCache 的 UNCACHE_MASK 保证）。
 *   - 0x0002_0000..0x0002_FFFF 是 **IROM 的数据窗口**（v14 双读口），只读：
 *     cksum/dump 读它就能看到自己的代码。写它无效（DRAM 写使能被挡掉）。
 *   - 本程序只用 DRAM 里的静态缓冲，不建堆。
 * ============================================================================= */
#include <stdint.h>

#define UART_TX     (*(volatile uint32_t *)0x10000000u)
#define UART_TXSTAT (*(volatile uint32_t *)0x10000004u)
#define UART_RX     (*(volatile uint32_t *)0x10000008u)
#define UART_RXSTAT (*(volatile uint32_t *)0x1000000Cu)
#define LED_REG     (*(volatile uint32_t *)0x10000010u)
#define BOOT_REQ    (*(volatile uint32_t *)0x10000014u)   /* bit0 -> 重新引导 */
#define UART_RXPOP  (*(volatile uint32_t *)0x10000018u)   /* 写 1 -> 弹一个字节 */

#define LINE_MAX   128
#define HIST_MAX   4
#define ARGV_MAX   6

/* IROM 数据窗口基址（与 board_top 的 irom_win_sel 一致） */
#define IROM_WIN   0x00020000u
#define DRAM_BASE  0x00010000u

/* ★ v16：shell 自己代码区的结束地址（link.ld 的 `_etext`）。向上取 4KB 对齐之后，
 *   才是可以安全 `load` 应用的下界 —— 硬编码 0x3000 踩过坑：加了 load/run 两条
 *   命令之后 text 涨到 13 836 B（> 0x3000），load 会覆盖 shell 自己。 */
extern char _etext[];
#define IROM_APP_MIN ((uint32_t)((((uint32_t)_etext) + 0xFFFu) & ~0xFFFu))

/* ★ A4：地址映射的单一来源是 rtl/soc_map.sv，由 tools/gen_soc_map.py 生成
 *   sw/soc_map.h。这里做**编译期**一致性检查 —— 手写常量漂了，编译就报错，
 *   而不是等上板才发现"读错地址"。 */
#include "soc_map.h"
_Static_assert(IROM_WIN == SOC_CODEWIN_BASE,
               "IROM_WIN 与 soc_map.h 的 SOC_CODEWIN_BASE 不一致（请重跑 tools/gen_soc_map.py）");
_Static_assert(DRAM_BASE == 0x00010000u,
               "DRAM_BASE 必须仍是 0x1_0000（0x0_0000~0x0_FFFF 留给 ramdisk 空洞）");

static const char hexd[] = "0123456789abcdef";

/* ---------------------------------------------------------------- 输出 */
static void rxq_push(uint8_t b);
static void rxq_drain(void);
static int  rxq_get(void);

static void putc_(char c)
{
    while (UART_TXSTAT & 1u)
        ;
    UART_TX = (uint32_t)(unsigned char)c;
}

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static void puthex_(uint32_t v, int ndig)
{
    int i;
    for (i = ndig - 1; i >= 0; i--)
        putc_(hexd[(v >> (i * 4)) & 0xF]);
}

static void puthex8(uint32_t v) { puthex_(v, 8); }

static void putdec_(uint32_t v)
{
    char b[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v && i < 11) { b[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i--) putc_(b[i]);
}

/* ---------------------------------------------------------------- 输入 */
static uint32_t rd_mtime(void)
{
    uint32_t v;
    __asm volatile("csrr %0, 0x7c0" : "=r"(v));
    return v;
}

/* ------------------------------------------------------------ A2/S1：串口中断
 * 改造前：只靠 getc_nb() 轮询 RXSTAT。RX FIFO 只有 **8 深** —— 115200 下 8 字节
 *   只有 694 us 的余量，主循环在别处待久了（一次串口打印就是 52 ms）必然丢字节。
 * 改造后：PLIC 源 0（RX FIFO 非空，**电平**）→ CSR.mip.MEIP → 本 ISR 把字节搬进
 *   64 字节环形缓冲；getc_nb() 先取环，环空再退回轮询（两条路并存，向后兼容）。
 *
 * ★ 不变量 1：ISR 必须**一直抽到 FIFO 空**。源 0 是电平信号，只要还有字节没抽走，
 *   退出 ISR 会立刻再进一次 —— 那不是"丢字节"，是中断风暴。
 * ★ 不变量 2：环满时仍然要 pop（丢这个字节），否则 FIFO 永远非空、永远在中断。
 * ★ 不变量 3：claim 要写 IRQPEND 的 bit0（写 1 清位），不是抽完就完事。
 */
#define UART_IRQPEND (*(volatile uint32_t *)0x10000020u)   /* A2：PLIC 待处理 / claim */
#define UART_IRQEN   (*(volatile uint32_t *)0x10000024u)   /* A2：PLIC 使能位图      */

#define RXQ_SIZE 64
static volatile int      rx_irq_on;         /* 1 = 中断模式（getc_nb 不许碰 FIFO） */
static volatile uint8_t  rxq[RXQ_SIZE];
static volatile uint32_t rxq_w, rxq_r;      /* 写/读游标，自由增长，取模访问 */

static void rxq_push(uint8_t b)
{
    uint32_t w = rxq_w;
    if ((w - rxq_r) >= RXQ_SIZE)
        return;                             /* 满：丢弃（FIFO 那边已经 pop 过了） */
    rxq[w % RXQ_SIZE] = b;
    rxq_w = w + 1u;
}

static int rxq_get(void)
{
    uint32_t r = rxq_r;
    if (r == rxq_w)
        return -1;
    rxq_r = r + 1u;
    return (int)rxq[r % RXQ_SIZE];
}

/* 把 RX FIFO 里现有的字节全部搬进环形缓冲（最多 32 个，防止在中断/打印里死循环） */
static void rxq_drain(void)
{
    int n = 0;
    while ((UART_RXSTAT & 1u) && (n++ < 32)) {
        rxq_push((uint8_t)(UART_RX & 0xFFu));
        UART_RXPOP = 1u;
    }
}

/* ---------------- S2：软件断点（用 ebreak 打补丁，不需要改 RTL）----------------
 * 思路（老式 debugger 的做法）：把目标地址那条指令换成 `ebreak`（0x00100073），
 * 执行到那里就陷入；ISR 打印现场、把原指令写回去、mepc+=4 跳过错位，再返回。
 *
 * 约束（写清楚，免得误用）：
 *   · 只能打在**可写的代码区**（IROM 窗口 0x2_xxxx，即 addr >= 0x4000 的应用区）；
 *   · 只支持**一个**断点（够用，且省掉链表/数组的边界问题）；
 *   · 打断点期间那一行不能被执行第二次（已还原；要重复命中就重新 bk 一次）。
 */
#define EBREAK_INSN 0x00100073u
static uint32_t bk_addr;      /* 0 = 无断点 */
static uint32_t bk_orig;

/* 最近一次**同步异常**的现场（中断不算）。`i` 命令会打出来 —— 跑飞之后不用再猜。 */
static volatile uint32_t exc_last_cause, exc_last_pc, exc_n;

__attribute__((interrupt("machine"), aligned(4)))
void trap_entry(void)
{
    uint32_t cause, epc;

    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    __asm__ volatile("csrr %0, mepc"   : "=r"(epc));

    /* ★★ P0-1（S1 的最后一个洞）：**中断绝不能改 mepc**。
     *
     *   原来这里对所有陷入都做 `mepc += 4`，于是每一次串口接收中断都把"被打断的
     *   那条指令"跳了过去。后果分两种：
     *     · 真片上：偶尔少执行一条指令，命令解析时好时坏（一直以为"没规律"）；
     *     · 仿真里：被跳过的是 `sw` 时，之后 `lw` 读到的是**从未写过的槽**；
     *       tb 只清了 DRAM 低 16 K 字，高半段是 X → X 顺着寄存器流进地址/控制，
     *       于是 debug_status 的低两位（dcache_hold / IFU_stall）变 X。
     *       这就是"开 MIE 后停顿网络出现未定义值"的真正来源：不是 RTL 的 X，
     *       是**软件跳了一条指令**之后读到了仿真未初始化的存储。
     *
     *   规范（特权手册 3.1.15）：中断的 mepc 指向被打断、之后要**续执行**的那条，
     *   只有同步异常的 mepc 才是出错指令本身。所以中断分支直接返回。 */
    if ((cause & 0x80000000u) != 0u) {
        if ((cause & 0x1Fu) == 11u) {       /* MEI：PLIC 电平源必须 claim，否则立刻重入 */
            while (UART_RXSTAT & 1u) {      /* 一直抽到 FIFO 空（不变量 1） */
                rxq_push((uint8_t)(UART_RX & 0xFFu));
                UART_RXPOP = 1u;
            }
            UART_IRQPEND = (1u << 0);       /* claim：清 pending（不变量 3） */
        }
        /* MTI(7) / MSI(0)：电平由 CLINT / 软件源自己维护，这里不 claim */
        return;                             /* gcc 的 interrupt 属性会补 mret */
    }

    if (cause == 3u && bk_addr != 0u && epc == bk_addr) {
        /* 断点命中：还原指令、跳过它，然后继续 */
        *(volatile uint32_t *)(IROM_WIN + bk_addr) = bk_orig;
        bk_addr = 0u;
        __asm__ volatile("csrw mepc, %0" ::"r"(epc + 4u));
        return;
    }

    /* 其它同步异常：记现场 + 跳过一条，避免死在原地 */
    exc_last_cause = cause;
    exc_last_pc    = epc;
    exc_n          = exc_n + 1u;
    __asm__ volatile("csrw mepc, %0" ::"r"(epc + 4u));
}

static void rx_flush(void)
{
    int n = 0;
    while ((UART_RXSTAT & 1u) && (n++ < 128)) {
        (void)UART_RX;
        UART_RXPOP = 1u;
    }
    rxq_r = 0;
    rxq_w = 0;
}

static void rx_irq_init(void)
{
    /* ★ 先把 FIFO 里**引导期残留的字节**冲掉，再开中断。
     *   实测（真片）：不冲的话，第一条命令会变成 "k0 20000" —— 那个 '0' 是串口灌
     *   镜像时 console 接收器吃进去的字节（引导期间 console FIFO 一直在监听同一条线），
     *   开机后被 ISR 搬进环形缓冲，插在用户输入中间，命令就解析失败了。
     *   冲洗放在开 MIE 之前，纯轮询做完，不需要中断参与。 */
    {
        int n = 0;
        while ((UART_RXSTAT & 1u) && (n++ < 64)) {
            (void)UART_RX;
            UART_RXPOP = 1u;
        }
        rxq_r = 0;
        rxq_w = 0;
    }

    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)(uintptr_t)&trap_entry));
    rx_irq_on = 1;                          /* ★ 之后 getc_nb 只吃环形缓冲 */
    UART_IRQEN = (1u << 0);                 /* 使能源 0：RX FIFO 非空 */
    __asm__ volatile("csrs mie, %0"     ::"r"(1u << 11));   /* MEIE */
    __asm__ volatile("csrs mstatus, %0" ::"r"(1u << 3));    /* MIE  */
}

/* 非阻塞取一个字节；没有就返回 -1。
 *
 * ★★ RXDATA 是**幂等读**，弹出要靠写 UART_RXPOP。
 *   为什么不能"读即弹"：一次 `lw 0x1000_0008` 曾经会让 perip_ren 出两个脉冲
 *   （DCache 的 uncacheable 读被重发，v14 已从 RTL 侧修掉，见 DCache.sv 的 2a 段），
 *   "读即弹"于是每读一个字节吃掉两个 —— 现象是 `l 3f` 被解析成 `l3`。
 *   写成 peek + 显式 pop 之后，读重复多少次都无害。
 *
 * ★ S1 关键修复：开了中断之后，**这个函数不许再碰 FIFO**。
 *   真片实测症状是字节重复（`i` 变成 `i0`）和丢失（`l 3f` 里 `l` 没了）——
 *   因为 ISR 在把 FIFO 往环形缓冲搬，而这里的"轮询回退"也在 peek+pop，
 *   同一个 FIFO 有了**两个消费者**，互相抢字节。开中断时这里只吃环形缓冲。
 */
static int getc_nb(void)
{
    int c = rxq_get();                      /* 先吃中断搬进来的那批 */
    if (c >= 0)
        return c;
    if (rx_irq_on)
        return -1;                          /* ★ 中断模式下绝不去碰 FIFO */
    /* 未开中断：退回轮询（老镜像/单元测试） */
    if ((UART_RXSTAT & 1u) == 0u)
        return -1;
    c = (int)(UART_RX & 0xFFu);
    UART_RXPOP = 1u;                        /* 显式弹出（写是单拍的） */
    return c;
}

/* 阻塞取一个字节（带 mtime 超时，避免主循环永远卡住） */
static int getc_to(uint32_t to)
{
    uint32_t t0 = rd_mtime();
    int c;
    for (;;) {
        c = getc_nb();
        if (c >= 0)
            return c;
        if ((rd_mtime() - t0) > to)
            return -1;
    }
}

/* ---------------------------------------------------------------- 解析 */
static int hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static char *skip_ws(char *p)
{
    while (*p == ' ' || *p == '\t')
        p++;
    return p;
}

/* 解析一个数：0x.. 十六进制 / 0d.. 十进制 / 其它按**十六进制**（与旧脚本兼容）。
 * 返回 1 成功、0 没有数字。 */
static int parse_num(char **pp, uint32_t *out)
{
    char *p = skip_ws(*pp);
    uint32_t v = 0;
    int d, any = 0, dec = 0;

    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        p += 2;
    } else if (p[0] == '0' && (p[1] == 'd' || p[1] == 'D')) {
        p += 2;
        dec = 1;
    }
    for (;;) {
        if (dec) {
            if (*p < '0' || *p > '9') break;
            d = *p - '0';
        } else {
            d = hexval((unsigned char)*p);
            if (d < 0) break;
        }
        v = dec ? (v * 10u + (uint32_t)d) : ((v << 4) | (uint32_t)d);
        p++;
        any = 1;
    }
    if (!any)
        return 0;
    *out = v;
    *pp  = p;
    return 1;
}

static int streq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static int tokenize(char *s, char *argv[])
{
    int argc = 0;
    for (;;) {
        s = skip_ws(s);
        if (!*s)
            break;
        if (argc >= ARGV_MAX)
            break;
        argv[argc++] = s;
        while (*s && *s != ' ' && *s != '\t')
            s++;
        if (*s)
            *s++ = '\0';
    }
    return argc;
}

/* ---------------------------------------------------------------- 命令 */
static void c_help(int argc, char **argv);
static void c_dump(int argc, char **argv);
static void c_peek(int argc, char **argv);
static void c_poke(int argc, char **argv);
static void c_csr(int argc, char **argv);
static void c_led(int argc, char **argv);
static void c_fill(int argc, char **argv);
static void c_cmp(int argc, char **argv);
static void c_cksum(int argc, char **argv);
static void c_uptime(int argc, char **argv);
static void c_info(int argc, char **argv);
static void c_echo(int argc, char **argv);
static void c_boot(int argc, char **argv);
static void c_run(int argc, char **argv);
static void c_bk(int argc, char **argv);
static void c_bd(int argc, char **argv);
static void c_bl(int argc, char **argv);
static void c_ls(int argc, char **argv);
static void c_df(int argc, char **argv);
static void c_sa(int argc, char **argv);
static void c_rm(int argc, char **argv);
static void c_runf(int argc, char **argv);
static void c_load(int argc, char **argv);
static void c_data(int argc, char **argv);

typedef struct {
    const char *name;
    void (*fn)(int argc, char **argv);
    const char *help;
} cmd_t;

static const cmd_t cmds[] = {
    { "h",      c_help,   "h            this help" },
    { "help",   c_help,   0 },
    { "d",      c_dump,   "d <a> [n]    dump n words (def 8)" },
    { "dump",   c_dump,   0 },
    { "p",      c_peek,   "p <a>        peek one word" },
    { "peek",   c_peek,   0 },
    { "w",      c_poke,   "w <a> <v>    poke one word" },
    { "poke",   c_poke,   0 },
    { "c",      c_csr,    "c            dump CSRs" },
    { "csr",    c_csr,    0 },
    { "l",      c_led,    "l <v>        write LED (low 7 bits)" },
    { "led",    c_led,    0 },
    { "f",      c_fill,   "f <a> <n> <v> fill n words" },
    { "fill",   c_fill,   0 },
    { "m",      c_cmp,    "m <a> <b> <n> compare two regions" },
    { "cmp",    c_cmp,    0 },
    { "k",      c_cksum,  "k <a> [n]    djb2 checksum (def 64 words)" },
    { "cksum",  c_cksum,  0 },
    { "u",      c_uptime, "u            uptime (mtime @500kHz)" },
    { "uptime", c_uptime, 0 },
    { "i",      c_info,   "i            hardware / image info" },
    { "info",   c_info,   0 },
    { "e",      c_echo,   "e <text>     echo (link test)" },
    { "echo",   c_echo,   0 },
    { "b",      c_boot,   "b            re-enter boot loader" },
    { "boot",   c_boot,   0 },
    { "r",      c_run,    "r <a>        run raw code at irom addr (a = word addr)" },
    { "bk",     c_bk,     "bk <a>       set breakpoint at irom addr (>= IROM_APP_MIN)" },
    { "bd",     c_bd,     "bd           delete the breakpoint" },
    { "bl",     c_bl,     "bl           list the breakpoint" },
    { "ls",     c_ls,     "ls           list ramdisk files" },
    { "df",     c_df,     "df           free space on the ramdisk" },
    { "sa",     c_sa,     "sa <n> <a> <l>  save memory[a..a+l) as file n" },
    { "rm",     c_rm,     "rm <n>       delete file n" },
    { "run",    c_runf,   "run <n>      load file n to 0x4000 and execute" },
    { "L",      c_load,   "L <a>        load hex words into IROM window from UART" },
    { "load",   c_load,   0 },
    { "D",      c_data,   "D <a>        load hex words to DRAM/RAM (8 hex/word)" },
    { "data",   c_data,   0 },
};
#define NCMDS ((int)(sizeof(cmds) / sizeof(cmds[0])))

static void c_help(int argc, char **argv)
{
    int i;
    (void)argc; (void)argv;
    puts_("\ncommands (numbers: hex by default, 0x=hex, 0d=dec):\n");
    for (i = 0; i < NCMDS; i++)
        if (cmds[i].help) {
            puts_("  "); puts_(cmds[i].help); putc_('\n');
        }
}

static void c_csr(int argc, char **argv)
{
    uint32_t ms, mi, mp, mc, me, mtv, mcy, mret, mtime, mtc;
    (void)argc; (void)argv;
    __asm volatile("csrr %0, 0x300" : "=r"(ms));
    __asm volatile("csrr %0, 0x304" : "=r"(mi));
    __asm volatile("csrr %0, 0x344" : "=r"(mp));
    __asm volatile("csrr %0, 0x342" : "=r"(mc));
    __asm volatile("csrr %0, 0x341" : "=r"(me));
    __asm volatile("csrr %0, 0x343" : "=r"(mtv));
    __asm volatile("csrr %0, 0xb00" : "=r"(mcy));
    __asm volatile("csrr %0, 0xb02" : "=r"(mret));
    __asm volatile("csrr %0, 0x7c0" : "=r"(mtime));
    __asm volatile("csrr %0, 0x7c1" : "=r"(mtc));
    puts_("\n mstatus   = 0x"); puthex8(ms);   puts_("   (MIE bit3, MPIE bit7)\n");
    puts_(" mie       = 0x"); puthex8(mi);     puts_("   (MTIE bit7)\n");
    puts_(" mip       = 0x"); puthex8(mp);     puts_("   (MTIP bit7)\n");
    puts_(" mcause    = 0x"); puthex8(mc);     puts_("\n");
    puts_(" mepc      = 0x"); puthex8(me);     puts_("\n");
    puts_(" mtvec     = 0x"); puthex8(mtv);    puts_("\n");
    puts_(" mcycle    =  "); putdec_(mcy);     puts_("\n");
    puts_(" minstret  =  "); putdec_(mret);    puts_("\n");
    puts_(" mtime     =  "); putdec_(mtime);   puts_("  (500 kHz)\n");
    puts_(" mtimecmp  =  "); putdec_(mtc);     puts_("\n");
}

static void c_dump(int argc, char **argv)
{
    uint32_t a, n, i;
    char *p;
    if (argc < 2) { puts_("usage: d <addr> [n]\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &a)) { puts_("usage: d <addr> [n]\n"); return; }
    n = 8u;
    if (argc >= 3) { p = argv[2]; if (!parse_num(&p, &n)) n = 8u; }
    if (n > 256u) n = 256u;                     /* 别让一条命令刷屏太久 */
    for (i = 0; i < n; i++) {
        uint32_t addr = a + i * 4u;
        if ((i & 7u) == 0u) {
            putc_('\n'); putc_(' '); puthex8(addr); puts_(":");
        }
        putc_(' ');
        puthex8(*(volatile uint32_t *)addr);
    }
    putc_('\n');
}

static void c_peek(int argc, char **argv)
{
    uint32_t a;
    char *p;
    if (argc < 2) { puts_("usage: p <addr>\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &a)) { puts_("usage: p <addr>\n"); return; }
    puts_(" ["); puthex8(a); puts_("] = 0x"); puthex8(*(volatile uint32_t *)a); putc_('\n');
}

static void c_poke(int argc, char **argv)
{
    uint32_t a, v;
    char *p;
    if (argc < 3) { puts_("usage: w <addr> <val>\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &a)) { puts_("usage: w <addr> <val>\n"); return; }
    p = argv[2];
    if (!parse_num(&p, &v)) { puts_("usage: w <addr> <val>\n"); return; }
    *(volatile uint32_t *)a = v;
    puts_(" ["); puthex8(a); puts_("] <- 0x"); puthex8(v);
    puts_("  (readback 0x"); puthex8(*(volatile uint32_t *)a); puts_(")\n");
}

static void c_led(int argc, char **argv)
{
    uint32_t v;
    char *p;
    if (argc < 2) { puts_("usage: l <val>\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &v)) { puts_("usage: l <val>\n"); return; }
    LED_REG = v & 0x7Fu;
    puts_(" LED <- 0x"); puthex8(v & 0x7Fu); putc_('\n');
}

static void c_fill(int argc, char **argv)
{
    uint32_t a, n, v, i;
    char *p;
    if (argc < 4) { puts_("usage: f <addr> <n> <val>\n"); return; }
    p = argv[1]; if (!parse_num(&p, &a)) { puts_("usage: f <addr> <n> <val>\n"); return; }
    p = argv[2]; if (!parse_num(&p, &n)) { puts_("usage: f <addr> <n> <val>\n"); return; }
    p = argv[3]; if (!parse_num(&p, &v)) { puts_("usage: f <addr> <n> <val>\n"); return; }
    if (n > 65536u) n = 65536u;
    for (i = 0; i < n; i++)
        *(volatile uint32_t *)(a + i * 4u) = v;
    puts_(" filled "); putdec_(n); puts_(" words @0x"); puthex8(a); putc_('\n');
}

static void c_cmp(int argc, char **argv)
{
    uint32_t a, b, n, i;
    char *p;
    if (argc < 4) { puts_("usage: m <a> <b> <n>\n"); return; }
    p = argv[1]; if (!parse_num(&p, &a)) { puts_("usage: m <a> <b> <n>\n"); return; }
    p = argv[2]; if (!parse_num(&p, &b)) { puts_("usage: m <a> <b> <n>\n"); return; }
    p = argv[3]; if (!parse_num(&p, &n)) { puts_("usage: m <a> <b> <n>\n"); return; }
    if (n > 65536u) n = 65536u;
    for (i = 0; i < n; i++) {
        uint32_t x = *(volatile uint32_t *)(a + i * 4u);
        uint32_t y = *(volatile uint32_t *)(b + i * 4u);
        if (x != y) {
            puts_(" differ @+0x"); puthex_(i * 4u, 4);
            puts_("  a=0x"); puthex8(x);
            puts_("  b=0x"); puthex8(y); putc_('\n');
            return;
        }
    }
    puts_(" identical ("); putdec_(n); puts_(" words)\n");
}

/* djb2：与 sw/dptest.c、sw/build_dptest.sh 的实现必须逐位一致 */
static void c_cksum(int argc, char **argv)
{
    uint32_t a, n = 64u, i, ck = 5381u;
    char *p;
    if (argc < 2) { puts_("usage: k <addr> [n]\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &a)) { puts_("usage: k <addr> [n]\n"); return; }
    if (argc >= 3) { p = argv[2]; if (!parse_num(&p, &n)) n = 64u; }
    if (n > 65536u) n = 65536u;
    for (i = 0; i < n; i++)
        ck = (ck << 5) - ck + *(volatile uint32_t *)(a + i * 4u);
    puts_(" cksum 0x"); puthex8(ck);
    puts_("  ("); putdec_(n); puts_(" words @0x"); puthex8(a); puts_(")\n");
}

static void c_uptime(int argc, char **argv)
{
    uint32_t t = rd_mtime();
    uint32_t sec = t / 500000u;
    uint32_t ms  = (t % 500000u) / 500u;     /* 0..999 */
    (void)argc; (void)argv;
    puts_(" mtime="); putdec_(t);
    puts_("  = "); putdec_(sec); putc_('.');
    putc_((char)('0' + (ms / 100u) % 10u));
    putc_((char)('0' + (ms / 10u) % 10u));
    putc_((char)('0' + ms % 10u));
    puts_(" s\n");
}

static void c_info(int argc, char **argv)
{
    (void)argc; (void)argv;
    puts_("\n BigBird RV32 (v14)  RV32IM+Zicsr+Zicntr  single-issue in-order\n");
    puts_("  clk=50MHz  IROM=64KB@0x0 (fetch only, +data window @0x20000)\n");
    puts_("  DRAM=128KB@0x0  .text@IROM  .data/.stack@0x1_0000\n");
    puts_("  MMIO @0x1000_0000: tx/rx/led/bootreq/rxpop\n");
    puts_("  D-cache 256x1w  BTB/PHT 256  GHR 8  RAS 8\n");
    /* P0-1：中断已默认开启，顺手把"最近一次同步异常"的现场打出来 */
    puts_("  rx irq ");
    puts_(rx_irq_on ? "ON" : "off(poll)");
    puts_("   exc n="); putdec_(exc_n);
    puts_(" last="); puthex8(exc_last_cause);
    puts_(" @0x"); puthex8(exc_last_pc); putc_('\n');
}

static void c_echo(int argc, char **argv)
{
    int i;
    putc_(' ');
    for (i = 1; i < argc; i++) {
        if (i > 1) putc_(' ');
        puts_(argv[i]);
    }
    putc_('\n');
}

/* ★ 重新进入引导器。写完这条命令 CPU 会在几拍内被复位，所以先把话说清楚。
 *   注意：这个写操作本身必须走完（store 是写直达，函数返回前已经到 MMIO）。 */
static void c_boot(int argc, char **argv)
{
    (void)argc; (void)argv;
    puts_(" re-arming boot loader, CPU will be held in reset ...\n");
    puts_(" (host: _diag\\board_run.ps1 -SkipProgram -PreCmd b ...)\n");
    BOOT_REQ = 1u;
    for (;;)                        /* 正常情况下永远到不了这里（CPU 已被复位） */
        ;
}

/* ---------------------------------------------------------------- load / run
 * ★ v16：`load` 把 ASCII 十六进制行写进 **IROM 数据窗口**（0x2_0000 + addr），
 *   `run` 再跳到**取指地址**（= 同一个字地址，因为窗口 0x2_xxxx 与取指 0xxxx 是
 *   同一块 IROM）。也就是说：软件第一次能"写自己的代码区、然后执行它"。
 *   两个命令必须成对用，且**不能覆盖 monitor 自己**（monitor 在 IROM 低 11KB，
 *   从 0x3000（= 窗口 0x2_3000）以上才安全）。
 *
 *   `load` 的协议（字符流，行尾 CR/LF 均认）：
 *     每行 8 个十六进制数字（一个 32 位字），写一个到 addr、addr += 4；
 *     收到单独一行 "."（或空行）结束；写满 4KB 也结束。
 *   为什么用 ASCII 而不是二进制：`_diag/mon_cmd.ps1` 只能发文本，ASCII 还能人手敲。
 */
#define LOAD_MAX_WORDS 1024u    /* 4KB：够一个演示程序，也不至于刷屏太久 */

static void c_load(int argc, char **argv)
{
    uint32_t base, n = 0, got, v;
    char *p;
    int c, i;

    if (argc < 2) { puts_("usage: L <irom_addr>\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &base)) { puts_("usage: L <irom_addr>\n"); return; }
    if ((base & 3u) != 0u) { puts_(" irom addr must be word-aligned\n"); return; }
    if (base < IROM_APP_MIN) {
        puts_(" refuse: below shell text end; use >= 0x"); puthex8(IROM_APP_MIN); putc_('\n');
        return;
    }
    /* ★ 提示必须**短**：RX FIFO 只有 8 深，宿主（脚本）在提示还没打完时就会开始
     *   灌字节；长提示会把 FIFO 灌满并丢掉行尾的 CR —— 实测就是"两行粘成 16 个
     *   十六进制数字"然后报错。所以只回一行 14 字符，而且下面的解析**不依赖换行**。 */
    puts_("hex8, '.'=end\n");

    /* 解析：连续十六进制数字流，每 8 位 = 一个字；CR/LF/空格一律忽略；
     * '.' 结束。这样即使宿主把两行粘在一起、或者丢了 CR，也能正确切分。 */
    got = 0;
    v = 0;
    for (;;) {
        c = getc_to(2000000u);              /* 4 s @500kHz：一路灌下来不会等这么久 */
        if (c < 0) { puts_("\n timeout\n"); break; }
        if (c == '.') { puts_("\n done\n"); break; }
        i = hexval(c);
        if (i < 0) continue;                /* CR/LF/空格/杂字符：跳过，不打断 */
        v = (v << 4) | (uint32_t)i;
        got++;
        if (got == 8u) {
            *(volatile uint32_t *)(IROM_WIN + base + n * 4u) = v;
            n++;
            got = 0;
            v = 0;
            putc_('.');                     /* 每写一个字回一个点，宿主可以数 */
            if (n >= LOAD_MAX_WORDS) { puts_("\n limit\n"); break; }
        }
    }
    if (got != 0u)
        puts_(" (odd digit count ignored)\n");
fin:
    puts_(" loaded "); putdec_(n * 4u); puts_(" bytes @irom 0x"); puthex8(base);
    puts_("  (run 0x"); puthex8(base); puts_(")\n");
    /* ★ fence.i：写完代码区后必须让取指端的队列失效，否则 `r` 可能取到旧字。
     *   本核没有 I-Cache，但 IFU 有 4 项取指队列 —— 对"刚写、从没取过"的区域本来
     *   也安全，插上它是为了让"覆盖一段已经执行过的代码"（热补丁）也正确。
     * ★ v16 更正：早先那句"fence.i 会让 CPU 停住"是**误判**，真凶是测试台在 shell
     *   还在打印时就把命令发完了（RX FIFO 8 深，行尾 CR 被挤掉）。单测见
     *   `sw/fenceitest.c`：裸 fence.i / store 后紧跟 / 循环里连续，全部正常。 */
    __asm volatile(".word 0x0000100f" ::: "memory");   /* fence.i */
}

/* ★ v17：`D <addr>` —— 和 `L` 同一套"连续十六进制流"解析，但**直接写目标地址**
 *   （DRAM 0x0~0x1_FFFF / MMIO）。用途：把 C 应用的 `.rodata/.data` 灌进 DRAM，
 *   这样带字符串常量的 C 程序也能 load-and-run（`.text` 走 `L`，`.data` 走 `D`）。
 *   ★ 边界：不许写 IROM 窗口（0x2_xxxx）——那是 `L` 的活，混着用会让人算不清地址。 */
#define DATA_MAX_WORDS 2048u      /* 8KB */

static void c_data(int argc, char **argv)
{
    uint32_t base, n = 0, got, v;
    char *p;
    int c, i;

    if (argc < 2) { puts_("usage: D <addr>\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &base)) { puts_("usage: D <addr>\n"); return; }
    if ((base & 3u) != 0u) { puts_(" addr must be word-aligned\n"); return; }
    if ((base & 0xFFFE0000u) == 0x00020000u) {
        puts_(" refuse: 0x2_xxxx is the IROM window, use L instead\n");
        return;
    }
    if (base >= 0x10000000u && base < 0x10000100u) {
        /* 允许写 MMIO（调试用），但先提示一句，免得手滑把 TXDATA 当内存灌 */
        puts_(" note: writing MMIO space\n");
    }
    puts_("hex8, '.'=end\n");

    got = 0;
    v = 0;
    for (;;) {
        c = getc_to(2000000u);
        if (c < 0) { puts_("\n timeout\n"); break; }
        if (c == '.') { puts_("\n done\n"); break; }
        i = hexval(c);
        if (i < 0) continue;
        v = (v << 4) | (uint32_t)i;
        got++;
        if (got == 8u) {
            *(volatile uint32_t *)(base + n * 4u) = v;
            n++;
            got = 0;
            v = 0;
            putc_('.');
            if (n >= DATA_MAX_WORDS) { puts_("\n limit\n"); break; }
        }
    }
    if (got != 0u)
        puts_(" (odd digit count ignored)\n");
    puts_(" stored "); putdec_(n * 4u); puts_(" bytes @0x"); puthex8(base); putc_('\n');
}

static void c_run(int argc, char **argv)
{
    uint32_t a;
    char *p;
    void (*fn)(void);

    if (argc < 2) { puts_("usage: r <irom_word_addr>   (e.g. r 3000)\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &a)) { puts_("usage: r <irom_word_addr>\n"); return; }
    if ((a & 3u) != 0u) { puts_(" irom addr must be word-aligned\n"); return; }
    if (a < IROM_APP_MIN) {
        puts_(" refuse: below shell text end; use >= 0x"); puthex8(IROM_APP_MIN); putc_('\n');
        return;
    }
    /* 取指地址与窗口地址是同一块 IROM 的同一个字 ⇒ 直接把 a 当函数指针。
     * ★ fence.i：让取指看到刚写进来的那几行（本核无 I-Cache，但取指队列是 4 项，
     *   刚写完就跳过去时要保证队列里不是旧字）。
     * ★ v16 更正：早先以为"fence.i 会让 CPU 停住"是**误判** —— 真凶是测试台把命令
     *   发在 shell 还在打印的时候（RX FIFO 只有 8 深，行尾 CR 被挤掉 → 命令永远收不到
     *   回车）。`sw/fenceitest.c` 单独测过：裸 fence.i、store 后紧跟 fence.i、循环里
     *   连续 fence.i 全部正常（F1..F4 + FENCEITEST-PASS）。 */
    puts_(" jump to irom 0x"); puthex8(a); puts_(", running...\n");
    __asm volatile(".word 0x0000100f" ::: "memory");   /* fence.i */
    /* ★ 等发送器**真的空**再跳：putc_ 只在写之前等 busy，最后一个 '\n' 还在移位寄存器里
     *   （115200 下 87 us）。应用第一件事往往就是往 TXDATA 写字符，uart_tx 忙时**丢弃**，
     *   实测就是"应用跑了、但它的第一个字符不见了"。 */
    while (UART_TXSTAT & 1u)
        ;
    fn = (void (*)(void))a;
    fn();                                   /* 返回时继续（应用自己决定是否返回） */
    puts_(" returned to shell\n");
}

/* ---------------------------------------------------------------- 主循环 */
static char line[LINE_MAX];
static char hist[HIST_MAX][LINE_MAX];
static int  hist_n;                     /* 已存条数 */
static int  hist_head;                  /* 下一条写入位置 */

static void hist_add(const char *s)
{
    int i;
    char *d = hist[hist_head];
    if (!*s)
        return;
    /* 与最近一条相同就不重复存 */
    if (hist_n > 0) {
        int prev = (hist_head + HIST_MAX - 1) % HIST_MAX;
        if (streq(hist[prev], s))
            return;
    }
    for (i = 0; i < LINE_MAX - 1 && s[i]; i++)
        d[i] = s[i];
    d[i] = '\0';
    hist_head = (hist_head + 1) % HIST_MAX;
    if (hist_n < HIST_MAX)
        hist_n++;
}

static void print_prompt(void)
{
    puts_("> ");
}

/* ------------------------------------------------------------ P1：ramdisk FS
 * 区域：DRAM 0x0000_0000 – 0x0000_9FFF（40 KB）。`link.ld` 里本来就留空
 *   （0x1_0000 以上才是 shell 的 .data/.bss/栈），所以拿来做 ramdisk 不占程序空间。
 *
 * ★ DRAM 三段划分（128 KB 全用上，见 sw/app/link_app.ld，**两边必须一致**）：
 *   0x0_0000 – 0x0_9FFF  文件系统 40 KB（160 块 × 256 B）      ← 本文件
 *   0x0_A000 – 0x0_FFFF  应用数据区 24 KB（.rodata/.data/.bss + 应用私有栈）
 *   0x1_0000 – 0x1_FFFF  shell 自己的 .rodata/.data/.bss/栈
 *   应用要是把自己的变量放到 0x1_0000，写的就是 shell 的命令表 —— 所以 `run`
 *   只允许把数据装进 0xA000~0xFFFF，越界直接拒绝（初版不检查，正是 P1-1 失败的
 *   原因之一）。
 *
 * 布局（块 256 B × 160 块）：
 *   块 0     超级块：magic 'BFSS' / nfiles
 *   块 1..3  目录表：48 项 × 16 B？→ 这里用 32 项 × 24 B = 768 B，正好 3 块
 *   块 4     位图：256 位 = 32 B
 *   块 5..   数据区（**位图分配，可回收**）
 *
 * 与 sw/fstest.c 的区别：那里是 bump 分配（删了不回收），这里是位图 + 连续分配，
 * `rm` 之后 `df` 会真的变多 —— 这就是 P1-2 要的空间回收。
 */
#define FS_BLK    256u
#define FS_NBLK   160u          /* 160 × 256 B = 40 KB = DRAM 0x0~0x9FFF */
#define FS_DIRMAX 32u
#define FS_MAGIC  0x53534642u

typedef struct {
    char     name[16];
    uint16_t start;
    uint16_t nblk;
    uint32_t size;
} fent_t;                       /* 24 B */

static volatile uint32_t fs_base = 0u;      /* 不能用 (uint8_t*)0 常量，见 fstest.c */
#define fsdisk ((uint8_t *)fs_base)
#define fssb   ((uint32_t *)fs_base)
#define fsdir  ((fent_t *)(fs_base + FS_BLK))
#define fsmap  ((uint8_t *)(fs_base + 4u * FS_BLK))

static int  fs_up;                          /* 1 = 已挂载 */

static void fs_mount(void)
{
    uint32_t i;
    if (fssb[0] != FS_MAGIC) {
        for (i = 0; i < (FS_BLK / 4u); i++) fssb[i] = 0;
        fssb[0] = FS_MAGIC;
        fssb[1] = 0;                        /* nfiles */
        for (i = 0; i < 32u; i++) fsmap[i] = 0;
        for (i = 0; i < FS_DIRMAX; i++) fsdir[i].name[0] = '\0';
        /* 0..4 已被元数据占用 */
        for (i = 0; i < 5u; i++) fsmap[i >> 3] |= (uint8_t)(1u << (i & 7u));
    }
    fs_up = 1;
}

static int fs_used(uint32_t b) { return (fsmap[b >> 3] >> (b & 7u)) & 1u; }
static void fs_mark(uint32_t b, int v)
{
    if (v) fsmap[b >> 3] |=  (uint8_t)(1u << (b & 7u));
    else   fsmap[b >> 3] &= (uint8_t)~(1u << (b & 7u));
}

static uint32_t fs_free_blocks(void)
{
    uint32_t b, n = 0;
    for (b = 5u; b < FS_NBLK; b++) if (!fs_used(b)) n++;
    return n;
}

/* 找 n 个连续空闲块；成功则标记占用并返回起始块，失败返回 0 */
static uint32_t fs_alloc(uint32_t n)
{
    uint32_t b, run = 0, st = 0;
    for (b = 5u; b < FS_NBLK; b++) {
        if (!fs_used(b)) {
            if (run == 0u) st = b;
            run++;
            if (run == n) {
                for (; st <= b; st++) fs_mark(st, 1);
                return b - n + 1u;
            }
        } else {
            run = 0u;
        }
    }
    return 0u;
}

static fent_t *fs_find(const char *name)
{
    uint32_t i;
    for (i = 0; i < FS_DIRMAX; i++)
        if (fsdir[i].name[0] && streq(fsdir[i].name, name)) return &fsdir[i];
    return (fent_t *)0;
}

static int fs_create(const char *name, const uint8_t *data, uint32_t size)
{
    uint32_t i, nb, st;
    fent_t *e = (fent_t *)0;

    if (!fs_up) fs_mount();
    if (size == 0u) return -4;
    if (fs_find(name)) return -1;                 /* 重名 */
    for (i = 0; i < FS_DIRMAX; i++) if (!fsdir[i].name[0]) { e = &fsdir[i]; break; }
    if (!e) return -2;                            /* 目录满 */
    nb = (size + FS_BLK - 1u) / FS_BLK;
    st = fs_alloc(nb);
    if (st == 0u) return -3;                      /* 空间不足 */
    for (i = 0; i < size; i++) fsdisk[st * FS_BLK + i] = data[i];
    for (i = 0; i < 15u && name[i]; i++) e->name[i] = name[i];
    e->name[i] = '\0';
    e->start = (uint16_t)st;
    e->nblk  = (uint16_t)nb;
    e->size  = size;
    fssb[1] = fssb[1] + 1u;
    return 0;
}

static int fs_remove(const char *name)
{
    fent_t *e = fs_find(name);
    uint32_t b;
    if (!e) return -1;
    for (b = e->start; b < (uint32_t)e->start + e->nblk; b++) fs_mark(b, 0);
    e->name[0] = '\0';
    fssb[1] = fssb[1] - 1u;
    return 0;
}


static void c_bk(int argc, char **argv)
{
    uint32_t a;
    char *p;
    if (argc < 2) { puts_("usage: bk <irom_addr>\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &a)) { puts_("usage: bk <irom_addr>\n"); return; }
    if ((a & 3u) != 0u) { puts_(" must be word-aligned\n"); return; }
    if (a < IROM_APP_MIN) { puts_(" refuse: below shell text end\n"); return; }
    if (bk_addr != 0u) *(volatile uint32_t *)(IROM_WIN + bk_addr) = bk_orig;
    bk_orig = *(volatile uint32_t *)(IROM_WIN + a);
    *(volatile uint32_t *)(IROM_WIN + a) = EBREAK_INSN;
    __asm__ volatile(".word 0x0000100f" ::: "memory");
    bk_addr = a;
    puts_(" breakpoint @0x"); puthex8(a); puts_("  (was 0x"); puthex8(bk_orig); puts_(")\n");
}

static void c_bd(int argc, char **argv)
{
    (void)argc; (void)argv;
    if (bk_addr == 0u) { puts_(" no breakpoint\n"); return; }
    *(volatile uint32_t *)(IROM_WIN + bk_addr) = bk_orig;
    __asm__ volatile(".word 0x0000100f" ::: "memory");
    puts_(" cleared 0x"); puthex8(bk_addr); putc_('\n');
    bk_addr = 0u;
}

static void c_bl(int argc, char **argv)
{
    (void)argc; (void)argv;
    if (bk_addr == 0u) { puts_(" no breakpoint\n"); return; }
    puts_(" 0x"); puthex8(bk_addr);
    puts_("  orig=0x"); puthex8(bk_orig); putc_('\n');
}

/* ------------------------------------------------------------ P1：FS 命令 */

static void c_ls(int argc, char **argv)
{
    uint32_t i, n = 0;
    (void)argc; (void)argv;
    if (!fs_up) fs_mount();
    for (i = 0; i < FS_DIRMAX; i++) {
        if (!fsdir[i].name[0]) continue;
        puts_("  "); puts_(fsdir[i].name);
        puts_("   "); putdec_(fsdir[i].size); puts_(" B");
        puts_("  @blk "); putdec_(fsdir[i].start); putc_('\n');
        n++;
    }
    puts_(" "); putdec_(n); puts_(" file(s), ");
    putdec_(fs_free_blocks()); puts_(" free blocks (256 B each)\n");
}

static void c_df(int argc, char **argv)
{
    (void)argc; (void)argv;
    if (!fs_up) fs_mount();
    puts_(" free "); putdec_(fs_free_blocks()); puts_(" / "); putdec_(FS_NBLK);
    puts_(" blocks = "); putdec_(fs_free_blocks() * FS_BLK / 1024u); puts_(" KB\n");
}

/* sa <name> <addr> <bytes> —— 把内存里的一段存成文件 */
static void c_sa(int argc, char **argv)
{
    uint32_t a, n;
    char *p;
    int r;
    if (argc < 4) { puts_("usage: sa <name> <addr> <bytes>\n"); return; }
    p = argv[2]; if (!parse_num(&p, &a)) { puts_(" bad addr\n"); return; }
    p = argv[3]; if (!parse_num(&p, &n)) { puts_(" bad len\n"); return; }
    if (!fs_up) fs_mount();
    r = fs_create(argv[1], (const uint8_t *)a, n);
    if (r == 0)            { puts_(" saved "); putdec_(n); puts_(" B as "); puts_(argv[1]); putc_('\n'); }
    else if (r == -1)      puts_(" refuse: name exists\n");
    else if (r == -2)      puts_(" refuse: directory full\n");
    else if (r == -3)      puts_(" refuse: no space\n");
    else                   puts_(" refuse: bad length\n");
}

static void c_rm(int argc, char **argv)
{
    if (argc < 2) { puts_("usage: rm <name>\n"); return; }
    if (!fs_up) fs_mount();
    if (fs_remove(argv[1]) == 0) puts_(" removed\n");
    else                        puts_(" no such file\n");
}

/* ------------------------------------------------------------ P1-1：run
 * run <name> [entry] —— 从文件系统把应用装进板子并执行
 *
 * 两种镜像都认：
 *   ① **容器**（sw/mkapp.py 生成；推荐）：32 B 头 + 代码 + 数据
 *        0  magic 'BAPP'  4 irom_base  8 irom_len  12 dram_base
 *        16 dram_len      20 entry     24 sum      28 hdr_words(=8)
 *      一条命令完成"装代码 + 装数据 + 跳入口"，而且带校验和 —— 串口丢一个字节
 *      会当场报错，而不是跑飞之后让人猜。
 *   ② 裸镜像（没有头）：整段当代码装到 APP_EXEC，兼容老用法 `L`+`sa`。
 *
 * ★ 为什么数据必须落在 0xA000~0xFFFF：0x1_0000 以上是 shell 自己的 .data/.bss，
 *   应用写进去就是破坏 shell 的命令表（P1-1 第一次上板失败的直接原因）。
 * ★ 为什么用**字**拷贝而不是逐字节：IROM 窗口的写通路是整套字的写使能，
 *   逐字节 store 会变成"读-改-写整字"，容易踩到没有意义的中间值。
 */
#define APP_EXEC  0x00006000u           /* 代码基址（= shell text 端 4KB 对齐） */
#define APP_DATA  0x0000A000u           /* 应用数据区基址（见 link_app.ld） */
#define APP_MAGIC 0x50504142u           /* 'BAPP' */

static uint32_t ld32(const volatile uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* 从 src 取一个字；不足 4 字节的部分补 0（只有镜像尾巴会用到） */
static uint32_t getw(const volatile uint8_t *src, uint32_t avail)
{
    uint32_t w = 0u, k;
    for (k = 0; k < 4u; k++)
        if (k < avail) w |= (uint32_t)src[k] << (8u * k);
    return w;
}

/* 把 n 字节按字写到绝对地址 dst（dst 必须 4 对齐） */
static void copy_words(uint32_t dst, const volatile uint8_t *src, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i += 4u)
        *(volatile uint32_t *)(dst + i) = getw(src + i, n - i);
}

static void c_runf(int argc, char **argv)
{
    fent_t *e;
    uint32_t i, cbase, clen, dbase = 0u, dlen = 0u, ent, sum, bad;
    const volatile uint8_t *img;

    if (argc < 2) { puts_("usage: run <name> [entry]\n"); return; }
    if (!fs_up) fs_mount();
    e = fs_find(argv[1]);
    if (!e) { puts_(" no such file\n"); return; }
    if (e->size < 8u) { puts_(" bad size\n"); return; }
    img = (const volatile uint8_t *)(fsdisk + e->start * FS_BLK);

    if (ld32(img) == APP_MAGIC) {
        if (ld32(img + 28) != 8u) { puts_(" bad container header\n"); return; }
        cbase = ld32(img + 4);
        clen  = ld32(img + 8);
        dbase = ld32(img + 12);
        dlen  = ld32(img + 16);
        ent   = ld32(img + 20);
        sum   = ld32(img + 24);
        if (32u + clen + dlen > e->size) { puts_(" container truncated\n"); return; }
        if (cbase < IROM_APP_MIN || cbase >= 0x00010000u ||
            clen > (0x00010000u - cbase)) {
            puts_(" refuse: code must land in 0x"); puthex8(IROM_APP_MIN);
            puts_("..0xFFFF\n"); return;
        }
        if (dlen != 0u &&
            (dbase < APP_DATA || dbase >= 0x00010000u ||
             dlen > (0x00010000u - dbase))) {
            puts_(" refuse: data must land in 0x"); puthex8(APP_DATA);
            puts_("..0xFFFF\n"); return;
        }
        bad = 0u;
        for (i = 0; i < clen + dlen; i++) bad += img[32u + i];
        if (bad != sum) {
            puts_(" checksum 0x"); puthex8(bad);
            puts_(" != 0x"); puthex8(sum); puts_(" (re-send the file)\n");
            return;
        }
        copy_words(IROM_WIN + cbase, img + 32u, clen);
        if (dlen != 0u) copy_words(dbase, img + 32u + clen, dlen);
    } else {
        cbase = APP_EXEC;
        clen  = e->size;
        ent   = APP_EXEC;
        if (cbase < IROM_APP_MIN) {
            puts_(" refuse: app base below shell text end\n"); return;
        }
        if (clen > (0x00010000u - cbase)) { puts_(" bad size\n"); return; }
        copy_words(IROM_WIN + cbase, img, clen);
        puts_(" (raw image, no header)\n");
    }

    __asm__ volatile(".word 0x0000100f" ::: "memory");     /* fence.i */

    if (argc >= 3) { char *q = argv[2]; if (parse_num(&q, &ent)) { } }
    puts_(" run "); puts_(e->name); puts_(" @0x"); puthex8(ent);
    puts_("  code "); putdec_(clen);
    if (dlen != 0u) { puts_("B + data "); putdec_(dlen); }
    puts_("B\n");
    ((void (*)(void))ent)();                               /* 应用返回后继续 */
    puts_(" returned to shell\n");
}

int main(void)
{
    int len = 0;
    int c;
    int swallow_lf = 0;
    int hi = 0;                     /* 历史游标：0 = 最新（空行） */

    /* ★★ P0-1：串口接收**默认走中断**了（2026-11-10）。
     *
     *   "开 MIE 后命令解析全坏 / debug_status 低两位变 X" 的两个真实原因，都修了：
     *     ① 两个消费者抢同一个 RX FIFO（isr 在搬、getc_nb 又在 peek+pop）
     *        → 中断模式下 getc_nb 只吃环形缓冲（见它的注释）；
     *     ② 陷入处理对**中断**也做 mepc+=4（见 trap_entry 的注释）
     *        → 每次接收中断都会跳过一条被打断的指令，栈上的 sw 被跳过之后 lw 就读到
     *          仿真里未初始化的 X，看起来像"停顿网络出现 X"。
     *
     *   现在中断是默认路径；要退回纯轮询（排查用）就编译时加 -DRX_IRQ_DISABLE。 */

    /* ★ P0-3：清掉引导期残留的接收字节 —— 必须在**横幅之前、开中断之前**。
     *   残留来源：灌镜像时 console 的 uart_rx 一直在监听同一条线，把引导帧的字节
     *   也收进了自己的 FIFO；开机后它们会插在用户输入中间（`i` 变 `i0`、`k 20000`
     *   变 `k0 20000`）。
     *   ★ 为什么不再放在横幅之后：横幅要打 10 ms，这期间到达的字节是**用户输入**
     *     （或测试台提前发的命令），冲掉它就会丢第一条命令。仿真里 tb_monitor 正是
     *     在 1 ms 就把 `l 3f` 塞进 FIFO 的 —— 以前能过只是因为那时根本没调这个函数。 */
    rx_flush();

#ifndef RX_IRQ_DISABLE
    rx_irq_init();
#endif



    /* 启动横幅：只打"这是新程序 + 跑了多久 + 怎么求助"三行。
     * ★ 刻意**不**在启动时打整张帮助表：一是串口每字符 87 us，600 字符就是 52 ms，
     *   二是 sim/tb_monitor.sv 要等这段输出跑完才发命令 —— 帮助表会把仿真时间
     *   从几毫秒推到 68 ms（iverilog 下要十几分钟）。按 h 再看即可。 */
    puts_("\n=== BigBird RV32 shell (v14) ===\n");
    puts_(" mtime="); putdec_(rd_mtime()); puts_("  DRAM=0x10000  IROM-win=0x20000\n");
    /* v14：开机自检 IROM 数据窗口 —— 复位向量那条指令低 2 位必须是 2'b11。
     *   这条不只是一行字：它证明"第二个读口 + 0x2_0000 译码"在**板上**真的通了
     *   （严格的逐字比对在 sw/dptest.c）。tb_monitor 会检查 "code-win OK"。 */
    {
        uint32_t w0 = *(volatile uint32_t *)IROM_WIN;
        puts_(" code-win ");
        puts_(((w0 & 3u) == 3u) ? "OK" : "FAIL");
        puts_("  w0="); puthex8(w0); putc_('\n');
    }
    puts_(" h = help\n> ");

    for (;;) {
        c = getc_to(15000000u);     /* 30 s @500kHz 无输入 -> 重打提示符 */
        if (c < 0) {
            puts_("(idle)\n> ");
            len = 0;
            continue;
        }
        if (c == '\n' && swallow_lf) {   /* 宿主发 CRLF：第二个字节忽略 */
            swallow_lf = 0;
            continue;
        }
        swallow_lf = 0;

        if (c == '\r' || c == '\n') {
            line[len] = '\0';
            putc_('\n');
            if (c == '\r')
                swallow_lf = 1;
            if (len > 0) {
                char *argv[ARGV_MAX];
                int argc, i, found = 0;
                hist_add(line);
                hi = 0;
                argc = tokenize(line, argv);
                for (i = 0; i < NCMDS && argc > 0; i++) {
                    if (streq(argv[0], cmds[i].name)) {
                        found = 1;
                        cmds[i].fn(argc, argv);
                        break;
                    }
                }
                if (!found)
                    puts_(" unknown command (h for help)\n");
            }
            len = 0;
            print_prompt();
            continue;
        }
        if (c == 3) {                   /* ^C：取消当前行 */
            puts_("\n^C");
            len = 0;
            print_prompt();
            continue;
        }
        if (c == 21) {                  /* ^U：删整行 */
            while (len > 0) { len--; puts_("\b \b"); }
            continue;
        }
        if (c == 8 || c == 127) {       /* 退格 */
            if (len > 0) { len--; puts_("\b \b"); }
            continue;
        }
        if (c == 27) {                  /* ESC [ A/B：上下翻历史 */
            int c1 = getc_to(5000u);
            int c2 = (c1 == '[') ? getc_to(5000u) : -1;
            if (c2 == 'A' || c2 == 'B') {
                int i;
                if (c2 == 'A') { if (hi < hist_n) hi++; }
                else           { if (hi > 0)      hi--; }
                /* 清行 */
                while (len > 0) { len--; puts_("\b \b"); }
                if (hi > 0) {
                    int idx = (hist_head + HIST_MAX - hi) % HIST_MAX;
                    for (i = 0; i < LINE_MAX - 1 && hist[idx][i]; i++) {
                        line[i] = hist[idx][i];
                        putc_(line[i]);
                    }
                    len = i;
                }
            }
            continue;
        }
        if (c < 32 && c != '\t')
            continue;
        if (len < LINE_MAX - 1) {
            line[len++] = (char)c;
            putc_((char)c);                /* 本地回显 */
        }
    }
    return 0;
}
