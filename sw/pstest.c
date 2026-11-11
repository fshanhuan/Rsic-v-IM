/* =============================================================================
 * sw/pstest.c — 双核协同 第 3 步：RISC-V 侧的"双向中断"搭档
 * -----------------------------------------------------------------------------
 * 它由 PS 装载（PS 把本程序的 .text 灌进 DRAM 0xA000，stage-0 stub 再抄进 IMEM）。
 *
 * 双向握手协议（与 sw/ps/ps_irq_test.c 一一对应）：
 *
 *   ① CPU → PS（PLIC 无关，走 MMIO 0x1000_001C bit1 = irq_ps 电平）
 *        MSG  = 0xDEADBEEF        （DRAM 0x1_2000：给 PS 的载荷）
 *        CTL  = 2                 （irq_ps = 1，等 PS 来收）
 *        ACK  = 0xACED            （等 PS 回执；PS 收到后会写它并清 irq_ps）
 *   ② PS → CPU（AXI 控制寄存器 bit1 → PLIC 源 4 的电平中断）
 *        NIRQ++ 在中断里          （DRAM 0x1_2008：PS 每敲一次就 +1）
 *
 * 判据（LED + 串口）：
 *   ACK 收到了、且 NIRQ >= 1  → LED = 0x2A，串口 "OK"
 *   否则                      → LED = 0x7F，串口 "NG"
 *
 * ★ 为什么用字符立即数而不是字符串常量：本核 lw 走数据口，字符串在 .rodata
 *   （DRAM 0x1_0000）。PS 会灌 .rodata，但保持和 irqtest.c 一样的写法更省事。
 * ★ 为什么最后 for(;;)：main 返回会走停机 magic（写 0x1000_00F0），那个 idx 正好是
 *   LED —— 会把判据冲掉（见 docs/总线化_A1.md §6）。
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define LED      (*(volatile uint32_t *)0x10000010u)
#define IRQPEND  (*(volatile uint32_t *)0x10000020u)
#define IRQEN    (*(volatile uint32_t *)0x10000024u)
#define IRQID    (*(volatile uint32_t *)0x10000028u)
#define CTL      (*(volatile uint32_t *)0x1000001Cu)

/* 共享 DRAM 的约定地址（PS 侧同名宏） */
#define MSG      (*(volatile uint32_t *)0x00012000u)
#define ACK      (*(volatile uint32_t *)0x00012004u)
#define NIRQ     (*(volatile uint32_t *)0x00012008u)

#define MIE_MEIE      (1u << 11)
#define MSTATUS_MIE   (1u << 3)
#define PS_SRC_BIT    (1u << 4)     /* PLIC 源 4 = PS 事件 */

static volatile uint32_t n_irq;
static volatile uint32_t last_id;

static void putc_(char c)
{
    while (TXSTAT & 1u)
        ;
    TXDATA = (uint32_t)(uint8_t)c;
}

__attribute__((interrupt("machine"), aligned(4)))
void trap_entry(void)
{
    uint32_t id = IRQID;              /* claim：当前最高优先级的待处理源 */
    last_id = id;
    n_irq   = n_irq + 1u;
    if (id == 4u)                     /* ★ 必须写进 DRAM：PS 只能通过 AXI 看这块内存。
                                       *   第一版只加了个 .bss 里的计数器，PS 永远读到 0
                                       *   （板上实测：PS 侧 PS_IRQ 拉高、PLIC pending=1，
                                       *    但共享内存里的 NIRQ 一直是 0 → 判 NG）。 */
        NIRQ = NIRQ + 1u;
    if (id != 0u)
        IRQPEND = (1u << (id & 7u));  /* 写 1 清 pending */
}

int main(void)
{
    uint32_t i;
    uint32_t ok;

    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)(uintptr_t)&trap_entry));

    ACK  = 0u;
    NIRQ = 0u;
    n_irq = 0u;

    IRQEN = PS_SRC_BIT;               /* 使能 PLIC 源 4 */
    __asm__ volatile("csrs mie, %0"     ::"r"(MIE_MEIE));
    __asm__ volatile("csrs mstatus, %0" ::"r"(MSTATUS_MIE));

    /* ---- ① 通知 PS：写载荷 + 拉 irq_ps ---- */
    MSG = 0xDEADBEEFu;
    CTL = 0x2u;

    /* PS 收到后会写 ACK=0xACED 并清 irq_ps；这里等回执（约 1 ms 量级） */
    for (i = 0; i < 2000000u && ACK != 0xACEDu; i++)
        ;
    ok = (ACK == 0xACEDu) ? 1u : 0u;

    /* ---- ② 等 PS 敲 PLIC 源 4，中断里累加 NIRQ ---- */
    for (i = 0; i < 2000000u && NIRQ == 0u; i++)
        ;

    __asm__ volatile("csrc mstatus, %0" ::"r"(MSTATUS_MIE));
    IRQEN = 0u;

    ok = ok && (NIRQ >= 1u);

    LED = ok ? 0x2Au : 0x7Fu;

    if (ok) {
        putc_('P'); putc_('S'); putc_('-'); putc_('O'); putc_('K'); putc_('\n');
    } else {
        putc_('P'); putc_('S'); putc_('-'); putc_('N'); putc_('G'); putc_('\n');
    }

    for (;;)
        ;
}
