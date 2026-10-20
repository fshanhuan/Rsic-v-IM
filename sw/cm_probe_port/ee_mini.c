/* =============================================================================
 * sw/cm_probe_port/ee_mini.c -- 对拍用的最小 printf（x86 / rv32 共用同一份格式逻辑）
 * -----------------------------------------------------------------------------
 * 为什么不用各平台的 printf：x86 用 newlib/glibc 的 printf、rv32 用 barebones 的
 * ee_printf，两者对宽度/填充/有符号的处理不完全一致。对拍中间量时，格式化差异会
 * 伪装成"数据差异"，非常难查。
 *
 * 这里只实现 CoreMark CORE_DEBUG 用到的那几种：%d %u %x %c %s，
 * 以及带 0 填充的宽度（如 %04x）。两种平台走**同一份代码**，只换 emit 通道。
 * ============================================================================= */
#include <stdarg.h>

#ifdef CM_HOST
#include <stdio.h>
static void emit(char c) { putchar(c); }
#else
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
static void emit(char c)
{
    while (UART_TXSTAT & 1u)
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
}
#endif

static void out_str(const char *s)
{
    while (*s)
        emit(*s++);
}

/* v 按 base 输出，width 用 '0' 左填充；neg 时先补 '-' */
static void out_num(unsigned int v, int base, int width, int neg, int upper)
{
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char buf[36];
    int  n = 0;
    if (v == 0)
        buf[n++] = '0';
    while (v > 0)
    {
        buf[n++] = dig[v % (unsigned int)base];
        v /= (unsigned int)base;
    }
    if (neg)
        emit('-');
    while (n < width)
    {
        emit('0');
        width--;
    }
    while (n > 0)
        emit(buf[--n]);
}

int ee_printf(const char *fmt, ...)
{
    va_list ap;
    int     count = 0;

    va_start(ap, fmt);
    while (*fmt)
    {
        if (*fmt != '%')
        {
            emit(*fmt++);
            count++;
            continue;
        }
        fmt++;
        {
            int zero = 0, width = 0, neg = 0;
            unsigned int v;
            if (*fmt == '0') { zero = 1; fmt++; }
            while (*fmt >= '0' && *fmt <= '9')
                width = width * 10 + (*fmt++ - '0');
            (void)zero;
            switch (*fmt)
            {
                case 'd':
                {
                    int s = va_arg(ap, int);
                    if (s < 0) { neg = 1; v = (unsigned int)(-s); }
                    else        { v = (unsigned int)s; }
                    out_num(v, 10, width, neg, 0);
                    break;
                }
                case 'u':
                    out_num(va_arg(ap, unsigned int), 10, width, 0, 0);
                    break;
                case 'x':
                    out_num(va_arg(ap, unsigned int), 16, width, 0, 0);
                    break;
                case 'X':
                    out_num(va_arg(ap, unsigned int), 16, width, 0, 1);
                    break;
                case 'c':
                    emit((char)va_arg(ap, int));
                    break;
                case 's':
                    out_str(va_arg(ap, const char *));
                    break;
                case '%':
                    emit('%');
                    break;
                default:
                    emit('%');
                    emit(*fmt);
                    break;
            }
            fmt++;
        }
    }
    va_end(ap);
    return count;
}
