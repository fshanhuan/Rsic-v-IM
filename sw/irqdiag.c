/* =============================================================================
 * sw/irqdiag.c — 定位"上板一开中断就没输出"到底卡在哪一步
 * -----------------------------------------------------------------------------
 * 输出一串单字符进度，每个字符都在**开启中断之前/之后**的不同位置：
 *
 *   A  程序起来了（还没碰任何 CSR）
 *   B  mtvec / PLIC 使能 / mie / mstatus 都写完（此时 MIE=1）
 *   C  软件中断已触发并**返回**了（能走到这里说明陷入+mret 通）
 *   D  陷入计数 n_irq >= 1
 *   E  第二次触发也回来了
 *
 * 判读：
 *   "A"        → mtvec/CSR 写就把 CPU 弄死了
 *   "AB"       → 中断被接受后回不来（陷入路径或 mret 有问题）
 *   "ABC"      → 第一次能回，第二次不回
 *   "ABCDE"    → 中断通路正常，之前的测试是别的原因
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define IRQPEND  (*(volatile uint32_t *)0x10000020u)
#define IRQEN    (*(volatile uint32_t *)0x10000024u)
#define IRQSW    (*(volatile uint32_t *)0x1000002Cu)

static volatile uint32_t n_irq;

static void putc_(char c) { while (TXSTAT & 1u) ; TXDATA = (uint32_t)(uint8_t)c; }

__attribute__((interrupt("machine"), aligned(4)))
void trap_entry(void)
{
    n_irq = n_irq + 1u;
    IRQPEND = (1u << 3);          /* claim 软件源 */
}

int main(void)
{
    volatile int d;
    uint32_t t0, now;

    /* ★ 先等约 8 秒（mtime 500 kHz → 4e6 tick）再开始打印。
     *   原因：board_run.ps1 是"流完后才打开监听"，一次性打印会被错过
     *   （实测 monitor 因为一直在打提示符才被抓到）。这段等待顺便还验证了
     *   CLINT 的 mtime 在真片上确实在走数。 */
    __asm__ volatile("csrr %0, 0x7C0" : "=r"(t0));
    do {
        __asm__ volatile("csrr %0, 0x7C0" : "=r"(now));
    } while ((uint32_t)(now - t0) < 4000000u);

    putc_('A');

    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)(uintptr_t)&trap_entry));
    IRQEN = (1u << 3);
    __asm__ volatile("csrs mie, %0"     ::"r"(1u << 11));   /* MEIE */
    __asm__ volatile("csrs mstatus, %0" ::"r"(1u << 3));    /* MIE  */

    putc_('B');

    IRQSW = 1u;                   /* 触发第一次 */
    for (d = 0; d < 1000; d++)    /* 给陷入一点时间 */
        ;
    putc_('C');

    if (n_irq >= 1u) putc_('D');

    IRQSW = 1u;                   /* 触发第二次 */
    for (d = 0; d < 1000; d++)
        ;
    if (n_irq >= 2u) putc_('E');

    putc_('\n');
    for (;;)
        ;
}
