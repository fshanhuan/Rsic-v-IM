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

static const char hexd[] = "0123456789abcdef";

/* ---------------------------------------------------------------- 输出 */
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

/* 非阻塞取一个字节；没有就返回 -1。★ 必须先看 RXSTAT.bit0。
 *
 * ★★ RXDATA 是**幂等读**，弹出要靠写 UART_RXPOP。
 *   为什么不能"读即弹"：一次 `lw 0x1000_0008` 曾经会让 perip_ren 出两个脉冲
 *   （DCache 的 uncacheable 读被重发，v14 已从 RTL 侧修掉，见 DCache.sv 的 2a 段），
 *   "读即弹"于是每读一个字节吃掉两个 —— 现象是 `l 3f` 被解析成 `l3`。
 *   写成 peek + 显式 pop 之后，读重复多少次都无害。
 */
static int getc_nb(void)
{
    int c;
    if ((UART_RXSTAT & 1u) == 0u)
        return -1;
    c = (int)(UART_RX & 0xFFu);
    UART_RXPOP = 1u;              /* 显式弹出（写是单拍的） */
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
    { "r",      c_run,    "r <a>        run code just stored in IROM (a = word addr)" },
    { "run",    c_run,    0 },
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

int main(void)
{
    int len = 0;
    int c;
    int swallow_lf = 0;
    int hi = 0;                     /* 历史游标：0 = 最新（空行） */


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
