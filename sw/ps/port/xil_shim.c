/* =============================================================================
 * sw/ps/port/xil_shim.c -- 裸机运行时（内存日志 / UART / 延时 / 字符串函数）
 * -----------------------------------------------------------------------------
 * 目标：让 Xilinx 的 xsdps 驱动在**没有 BSP、没有 libc** 的 Cortex-A9 上编译运行。
 *   · xil_printf  -> 同时写【内存日志】和 PS UART1（内存日志走 JTAG 读，见下）
 *   · usleep      -> 纯忙等循环（不依赖 PMU/定时器，见下）
 *   · memcpy 等   -> 自己实现（-nostdlib 下没有 libc，gcc 仍可能生成这些调用）
 *
 * ★ 内存日志（2026-11-18 加）：这块板 PS UART1 的波特率和 ps7_init 的假设对不上
 *   （实测 UART 时钟 = IO PLL/16 = 62.5 MHz，而 ps7_init 按 86.4 MHz 算），
 *   串口读回来全是乱码。所以把 xil_printf 的内容同步写进 OCM：
 *       0x2_4000 : 长度，0x2_4004 起 : 文本（见 link_ps_sd.ld）
 *   JTAG 直接读出来解码，得到的是逐字节相同的文本，不依赖串口。
 *
 * ★ 延时为什么不用 PMU：一开始用 Cortex-A9 的 PMCCNTR 做超时，实测它不涨，
 *   导致驱动里所有"等某位清零"的循环永不超时（表现为卡死在 SD 初始化）。
 *   改成纯循环计数后行为可预期。
 * ============================================================================= */
#include <stdarg.h>

#include "xil_types.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "sleep.h"

/* ------------------------------- UART1 ----------------------------------- */
#define UART1_BASE   0xE0001000U
#define UART_CR      (*(volatile u32 *)(UART1_BASE + 0x00U))
#define UART_MR      (*(volatile u32 *)(UART1_BASE + 0x04U))
#define UART_SR      (*(volatile u32 *)(UART1_BASE + 0x2CU))
#define UART_FIFO    (*(volatile u32 *)(UART1_BASE + 0x30U))

void port_uart_init(void)
{
    UART_CR = (1U << 0) | (1U << 1) | (1U << 2);  /* RXRST | TXRST | TXEN */
    UART_MR = 0x20U;                              /* 8N1 */
    UART_CR = (1U << 2) | (1U << 4);              /* TXEN | RXEN  */
}

/* ------------------------------- 内存日志 -------------------------------- */
/* 链接脚本 link_ps_sd.ld 里定义的绝对符号（符号的值就是地址） */
extern u32 _log_len_addr;
extern u32 _log_buf_addr;
extern u32 _log_buf_size;

static u32 *log_len(void)  { return (u32 *)(uptr)&_log_len_addr; }
static char *log_buf(void) { return (char *)(uptr)&_log_buf_addr; }

void port_log_reset(void)
{
    *log_len() = 0U;
}

static void log_putc(char c)
{
    u32 *len = log_len();
    u32  cap = (u32)(uptr)&_log_buf_size;

    if (*len < cap) {
        log_buf()[*len] = c;
        *len = *len + 1U;
    }
}

static void putc_raw(char c)
{
    int n = 0;

    log_putc(c);                                  /* 内存日志：JTAG 可读 */

    /* 波特率已按**实测** UART 时钟 62.5 MHz 重算（BAUDGEN=89 -> 115740），
     * 所以串口现在是可读的；但仍然给 TX FIFO 等待加次数上限，
     * 防止外设异常时把整个程序挂在打印上。 */
    while ((UART_SR & (1U << 4)) != 0U) {
        if (++n > 50000) { break; }
    }
    UART_FIFO = (u32)(u8)c;
}

static void puts_raw(const char *s)
{
    while (*s != '\0') {
        putc_raw(*s++);
    }
}

/* ------------------------------- 延时（纯忙等） --------------------------- */
/* 1 µs ≈ 60 次空循环（667 MHz 下偏保守；精度不重要，只要能退出来） */
static void busy(u32 loops)
{
    volatile u32 i;

    for (i = 0; i < loops; i++) {
        ;
    }
}

void usleep(unsigned long useconds)
{
    u64 loops = (u64)useconds * 60ULL;

    if (loops > 0x7FFFFFFFULL) {
        loops = 0x7FFFFFFFULL;
    }
    busy((u32)loops);
}

void sleep(unsigned int seconds)
{
    while (seconds-- > 0U) {
        usleep(1000000UL);
    }
}

/* ------------------------------- printf --------------------------------- */
static void put_udec(u32 v)
{
    char buf[12];
    int i = 0;

    if (v == 0U) { putc_raw('0'); return; }
    while ((v != 0U) && (i < (int)sizeof(buf))) {
        buf[i++] = (char)('0' + (v % 10U));
        v /= 10U;
    }
    while (i > 0) { putc_raw(buf[--i]); }
}

static void put_sdec(s32 v)
{
    if (v < 0) { putc_raw('-'); put_udec((u32)(-(v + 1)) + 1U); }
    else       { put_udec((u32)v); }
}

static void put_hex(u32 v, int upper, int width, char pad)
{
    static const char lo[] = "0123456789abcdef";
    static const char up[] = "0123456789ABCDEF";
    const char *hx = upper ? up : lo;
    char buf[16];
    int i = 0;

    if (v == 0U) { buf[i++] = '0'; }
    while ((v != 0U) && (i < (int)sizeof(buf))) {
        buf[i++] = hx[v & 0xFU];
        v >>= 4;
    }
    while (i < width) { buf[i++] = pad; }
    while (i > 0) { putc_raw(buf[--i]); }
}

int xil_printf(const char *fmt, ...)
{
    va_list ap;
    int n = 0;

    va_start(ap, fmt);
    while (*fmt != '\0') {
        if (*fmt != '%') {
            if (*fmt == '\n') { putc_raw('\r'); }
            putc_raw(*fmt++);
            n++;
            continue;
        }

        fmt++;                            /* 跳过 '%' */
        {
            int  lmod = 0;                /* 0=32bit, 1=long */
            int  width = 0;
            char pad = ' ';

            if (*fmt == '0') { pad = '0'; fmt++; }
            while ((*fmt >= '0') && (*fmt <= '9')) {
                width = width * 10 + (int)(*fmt - '0');
                fmt++;
            }
            if (*fmt == 'l') { lmod = 1; fmt++; }

            switch (*fmt) {
            case 'c':
                putc_raw((char)va_arg(ap, int));
                fmt++; n++;
                break;
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (s == NULL) { s = "(null)"; }
                puts_raw(s);
                fmt++; n++;
                break;
            }
            case 'd': case 'i':
                if (lmod) { put_sdec((s32)va_arg(ap, long)); }
                else      { put_sdec(va_arg(ap, int)); }
                fmt++; n++;
                break;
            case 'u':
                if (lmod) { put_udec((u32)va_arg(ap, unsigned long)); }
                else      { put_udec(va_arg(ap, unsigned int)); }
                fmt++; n++;
                break;
            case 'x':
            case 'X':
                if (lmod) { put_hex((u32)va_arg(ap, unsigned long), (*fmt == 'X'), width, pad); }
                else      { put_hex(va_arg(ap, unsigned int), (*fmt == 'X'), width, pad); }
                fmt++; n++;
                break;
            case 'p':
                put_hex((u32)va_arg(ap, void *), 0, 8, '0');
                fmt++; n++;
                break;
            case '%':
                putc_raw('%');
                fmt++; n++;
                break;
            default:
                putc_raw('%');
                fmt++;
                break;
            }
        }
    }
    va_end(ap);
    return n;
}


/* ------------------------------- 异常处理 -------------------------------- */
/* 由 start_ps_sd.S 的向量表调用：把异常类型 / DFSR / DFAR 记进内存日志。
 * type: 1=未定义指令 2=预取中止 3=数据中止 */
void port_fault(unsigned int type, unsigned int dfsr, unsigned int dfar,
                unsigned int pc)
{
    xil_printf("\n*** CPU FAULT type=%u DFSR=0x%08x DFAR=0x%08x PC=0x%08x ***\n",
               type, dfsr, dfar, pc);
}

/* ------------------------------- 字符串（-nostdlib 下必须自备）------------- */
void *memcpy(void *dst, const void *src, unsigned int n)
{
    u8 *d = (u8 *)dst;
    const u8 *s = (const u8 *)src;

    while (n-- > 0U) { *d++ = *s++; }
    return dst;
}

void *memset(void *dst, int c, unsigned int n)
{
    u8 *d = (u8 *)dst;

    while (n-- > 0U) { *d++ = (u8)c; }
    return dst;
}

void *memmove(void *dst, const void *src, unsigned int n)
{
    u8 *d = (u8 *)dst;
    const u8 *s = (const u8 *)src;

    if (d < s) {
        while (n-- > 0U) { *d++ = *s++; }
    } else {
        d += n; s += n;
        while (n-- > 0U) { *--d = *--s; }
    }
    return dst;
}

int memcmp(const void *a, const void *b, unsigned int n)
{
    const u8 *x = (const u8 *)a;
    const u8 *y = (const u8 *)b;

    while (n-- > 0U) {
        if (*x != *y) { return (int)*x - (int)*y; }
        x++; y++;
    }
    return 0;
}

unsigned int strlen(const char *s)
{
    unsigned int n = 0;

    while (*s++ != '\0') { n++; }
    return n;
}

int strcmp(const char *a, const char *b)
{
    while ((*a != '\0') && (*a == *b)) { a++; b++; }
    return (int)(u8)*a - (int)(u8)*b;
}

int strncmp(const char *a, const char *b, unsigned int n)
{
    while ((n-- > 0U) && (*a != '\0') && (*a == *b)) { a++; b++; }
    if (n == 0xFFFFFFFFU) { return 0; }
    return (int)(u8)*a - (int)(u8)*b;
}

char *strcpy(char *dst, const char *src)
{
    char *d = dst;

    while ((*d++ = *src++) != '\0') { ; }
    return dst;
}
