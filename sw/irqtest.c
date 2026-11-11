/* =============================================================================
 * sw/irqtest.c — A2 外部中断自测（PLIC-lite → mip.MEIP）
 * -----------------------------------------------------------------------------
 * 改造前：CSR 把 meip 硬连 0，全核只有 mtime 一个中断源（`rtl/CSR.sv:191`）。
 * 现在 PLIC-lite 有 8 个源，这里只测**软件自触发**那一路（源 3），因为它
 * 完全可控、不依赖外部引脚，最适合当回归判据。
 *
 * 流程：
 *   1. mtvec ← trap_entry
 *   2. IRQEN = 1<<3（使能源 3）
 *   3. mie.MEIE = 1，mstatus.MIE = 1
 *   4. 连续写三次 IRQSW → 每次应该进一次陷入
 *   5. 关中断，LED = 中断计数，串口打 "OK" 或 "NG"
 *
 * ★ 为什么用**字符立即数**而不是字符串常量：本核 lw 走数据口，字符串在
 *   .rodata（DRAM 0x1_0000），而板级冒烟测试不预装 DRAM 镜像 —— 读了就是 0。
 *   字符字面量是立即数，不进 .rodata。
 * ★ 为什么最后 `for(;;)` 而不是 return：main 返回会走 crt0 的停机 magic
 *   （写 0x1000_00F0），而那个地址的 mmio_idx = 4 正是 **LED**，会把 LED 覆盖掉
 *   （见 docs/总线化_A1.md §6）。测 LED 的程序不能返回。
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define LED      (*(volatile uint32_t *)0x10000010u)
#define IRQPEND  (*(volatile uint32_t *)0x10000020u)
#define IRQEN    (*(volatile uint32_t *)0x10000024u)
#define IRQID    (*(volatile uint32_t *)0x10000028u)
#define IRQSW    (*(volatile uint32_t *)0x1000002Cu)

#define MIE_MEIE      (1u << 11)
#define MSTATUS_MIE   (1u << 3)
#define SW_SRC_BIT    (1u << 3)

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
    uint32_t id = IRQID;              /* claim：最高优先级的待处理源号 */
    last_id = id;
    n_irq   = n_irq + 1u;
    IRQPEND = (1u << (id & 7u));      /* 写 1 清 pending（处理完） */
}

int main(void)
{
    /* mtvec 必须 4 字节对齐；trap_entry 已 aligned(4) */
    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)(uintptr_t)&trap_entry));

    IRQEN = SW_SRC_BIT;               /* 使能软件源 */
    __asm__ volatile("csrs mie, %0"     ::"r"(MIE_MEIE));
    __asm__ volatile("csrs mstatus, %0" ::"r"(MSTATUS_MIE));

    for (uint32_t i = 0; i < 3u; i++) {
        IRQSW = 1u;                   /* 触发一次软件中断 */
        /* ★ S1 最小复现实验：把空转改成"反复读一个 MMIO 寄存器"，
         *   让中断必然落在一次 MMIO load 在途的时刻（shell 就是这样死的）。 */
        for (volatile int d = 0; d < 200; d++)
            (void)TXSTAT;
    }

    __asm__ volatile("csrc mstatus, %0" ::"r"(MSTATUS_MIE));
    IRQEN = 0u;

    LED = n_irq & 0x7Fu;              /* 期望 3 */

    if ((n_irq == 3u) && (last_id == 3u)) {
        putc_('O'); putc_('K'); putc_('\n');
    } else {
        putc_('N'); putc_('G'); putc_('\n');
    }

    for (;;)
        ;                             /* 不返回：见文件头注释 */
}
