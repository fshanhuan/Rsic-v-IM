/* =============================================================================
 * sw/app/hello_app.c -- 从 shell 加载并运行的 C 应用（演示/验收）
 * -----------------------------------------------------------------------------
 * 它不是一个独立程序（没有 crt0、没有 _start）：入口就是 main()，由 shell 的
 * `r <addr>` 用 jalr 调进来，sp 沿用 shell 的栈；`return` 就回到 shell。
 *
 * 这条通路上被验证的东西：
 *   · 代码真的被 `L 3000` 写进了 IROM（否则第一条指令就非法）
 *   · 字符串常量真的被 `D 10000` 写进了 DRAM（否则 lw 读到 0）
 *   · 应用能写 MMIO（UART TX）、能读自己的 .rodata、能返回
 *
 * 输出：HELLO-APP <3 个数字>，用来顺便验证 .data 段的读写。
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)

static const char msg[] = "HELLO-APP from IROM 0x4000\n";

static void putc_(char c)
{
    while (UART_TXSTAT & 1u)
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
}

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static void putdec_(unsigned int v)
{
    char b[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v && i < 11) { b[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i--) putc_(b[i]);
}

/* .data 里的可写变量：证明数据段也灌进来了 */
static volatile unsigned int acc = 0;

/* ★ .bss 由应用自己清零：shell 只负责把 .rodata/.data 灌进 DRAM，
 *   不会替应用清 .bss（它也不知道多大）。link_app.ld 提供了这两个符号。 */
extern char __bss_start[], __bss_end[];

int main(void)
{
    unsigned int i;
    char *p;

    for (p = __bss_start; p < __bss_end; p++)
        *p = 0;

    puts_(msg);                      /* .rodata 在 DRAM，靠 D 10000 灌 */

    for (i = 1; i <= 5; i++)
        acc += i;

    puts_("acc=");
    putdec_(acc);                    /* 期望 15 */
    putc_('\n');

    return (acc == 15u) ? 0 : 1;     /* 返回值回到 shell 看不到，但 acc 打印能看出来 */
}
