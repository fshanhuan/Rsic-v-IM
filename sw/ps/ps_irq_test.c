/* =============================================================================
 * sw/ps/ps_irq_test.c — 双核协同 第 3 步：PS 侧（Cortex-A9）双向中断 + 装载
 * -----------------------------------------------------------------------------
 * 一条程序做完两件事：
 *   ① 装载并放行 RISC-V（同第 1 步：写 DRAM → HOLD=0 → stub 抄进 IMEM）；
 *   ② 双向中断握手：
 *        CPU → PS ：RISC-V 写 MSG=0xDEADBEEF，拉 irq_ps（MMIO 0x1000_001C bit1）
 *                    → 本程序配好的 GIC 收到 IRQ_F2P[0] → ISR 读 MSG、写 ACK、
 *                      清 irq_ps（CTRL bit3）
 *        PS → CPU ：本程序写 CTRL bit1（PS_IRQ=1）→ RISC-V 的 PLIC 源 4 →
 *                    pstest 的 ISR 给 NIRQ 加一；本程序轮询 NIRQ>=1
 *
 * GIC（Cortex-A9，Zynq-7000）：
 *   GICD 0xF8F0_1000：CTLR / ISENABLER / IPRIORITYR / ITARGETSR
 *   GICC 0xF8F0_0100：CTLR / PMR / IAR / EOIR
 *   ★ Zynq 把 IRQ_F2P[0..7] 映射到 SPI **61..68**，所以这 8 个 ID 全打开，
 *     谁进来就在 ISR 里打印 ID（实测口径，不靠猜）。
 *
 * 判据：MSG 读到 0xDEADBEEF、NIRQ >= 1 → "RESULT: PASS"（COM13）
 * ============================================================================= */

typedef unsigned int u32;
typedef unsigned char u8;

#include "app_image_pstest.h"

/* ---------- UART1（MIO48/49，ps7_init 已配好引脚与波特率） ---------- */
#define UART1_BASE   0xE0001000u
#define UART_CR      (*(volatile u32 *)(UART1_BASE + 0x00u))
#define UART_MR      (*(volatile u32 *)(UART1_BASE + 0x04u))
#define UART_SR      (*(volatile u32 *)(UART1_BASE + 0x2Cu))
#define UART_FIFO    (*(volatile u32 *)(UART1_BASE + 0x30u))

/* ---------- AXI 窗口（BD 里给 256 KB）---------- */
#define SOC_BASE     0x40000000u
#define REG_CTRL     (*(volatile u32 *)(SOC_BASE + 0x00020000u))
#define REG_STATUS   (*(volatile u32 *)(SOC_BASE + 0x00020004u))
#define REG_SCRATCH  (*(volatile u32 *)(SOC_BASE + 0x00020008u))
#define SH_MSG       (*(volatile u32 *)(SOC_BASE + 0x00012000u))
#define SH_ACK       (*(volatile u32 *)(SOC_BASE + 0x00012004u))
#define SH_NIRQ      (*(volatile u32 *)(SOC_BASE + 0x00012008u))

/* ---------- GIC ---------- */
#define GICD        0xF8F01000u
#define GICC        0xF8F00100u
#define GICD_CTLR       (*(volatile u32 *)(GICD + 0x000u))
#define GICD_ISENABLER1 (*(volatile u32 *)(GICD + 0x104u))   /* ID 32..63  */
#define GICD_ISENABLER2 (*(volatile u32 *)(GICD + 0x108u))   /* ID 64..95  */
#define GICC_CTLR       (*(volatile u32 *)(GICC + 0x000u))
#define GICC_PMR        (*(volatile u32 *)(GICC + 0x004u))
#define GICC_IAR        (*(volatile u32 *)(GICC + 0x00Cu))
#define GICC_EOIR       (*(volatile u32 *)(GICC + 0x010u))

static void uart_putc(char c)
{
    while (UART_SR & (1u << 4))
        ;
    UART_FIFO = (u32)(unsigned char)c;
}
static void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}
static void uart_puthex(u32 v)
{
    static const char h[] = "0123456789abcdef";
    int i;
    uart_puts("0x");
    for (i = 7; i >= 0; i--) uart_putc(h[(v >> (i * 4)) & 0xFu]);
}
static void uart_putdec(u32 v)
{
    char b[12];
    int i = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v) { b[i++] = (char)('0' + v % 10u); v /= 10u; }
    while (i--) uart_putc(b[i]);
}

static void uart_init(void)
{
    UART_CR = (1u << 0) | (1u << 1) | (1u << 2);
    UART_MR = 0x20u;
    UART_CR = (1u << 2) | (1u << 4);
}

/* ---------- 中断服务：由 start_ps_irq.S 的 irq_handler 调用 ---------- */
volatile u32 g_irq_count, g_last_id, g_msg;

void gic_irq_handler(void)
{
    u32 id = GICC_IAR & 0x3FFu;          /* 读 IAR = 应答（会抬高优先级） */
    g_irq_count++;
    g_last_id = id;

    if (id >= 61u && id <= 68u) {        /* IRQ_F2P[0..7]：我们的 PL 中断 */
        g_msg = SH_MSG;                  /* RISC-V 写在共享 DRAM 的载荷 */
        SH_ACK = 0xACEDu;                /* 回执：CPU 看到它就往下走 */
        REG_CTRL = 0x8u;                 /* bit3 = 清 irq_ps（电平中断必须清源） */
    }
    GICC_EOIR = id;                      /* 写 EOIR = 结束 */
}

static void gic_init(void)
{
    u32 off;
    /* ★ 必须用 **32 位字访问**：MMU 关闭时所有地址都是 Strongly-ordered，
     *   而 ARMv7 对 SO 内存的 **字节/半字** 访问会直接 Data Abort
     *   （实测：用 volatile u8* 写 GICD_IPRIORITYR 立刻进 data abort 异常，
     *     PC 停在向量表 0x10 的 `b .` 上，串口一个字都打不出来 —— 这个坑踩过）。
     *   一次写 4 个 ID 的优先级/目标，天然字对齐。 */
    for (off = 60u; off <= 68u; off += 4u) {
        *(volatile u32 *)(GICD + 0x400u + off) = 0xA0A0A0A0u;  /* 优先级 */
        *(volatile u32 *)(GICD + 0x800u + off) = 0x01010101u;  /* 目标 CPU0 */
    }
    GICD_ISENABLER1 = 0xE0000000u;       /* 61..63 */
    GICD_ISENABLER2 = 0x0000001Fu;       /* 64..68 */
    GICD_CTLR = 1u;
    GICC_PMR  = 0xF0u;
    GICC_CTLR = 1u;
}

int main(void)
{
    u32 i, st, ok = 1u;

    uart_init();
    uart_puts("\n=== PS IRQ test (step 3) ===\n");

    st = REG_STATUS;
    uart_puts("STATUS = ");
    uart_puthex(st);
    uart_puts("\n");
    if ((st >> 16) != 0xB155u) {
        uart_puts("FATAL: ps_ctrl MAGIC mismatch\nRESULT: FAIL\n");
        return 1;
    }

    /* ---------- 装载 pstest ---------- */
    REG_CTRL = 0x1u;                                  /* HOLD=1，清 ALIVE */
    *(volatile u32 *)(SOC_BASE + RISC_IMG_DRAM) = RISC_IMG_WORDS;
    for (i = 0; i < RISC_IMG_WORDS; i++)
        *(volatile u32 *)(SOC_BASE + RISC_IMG_DRAM + 4u + i * 4u) = risc_img[i];
    for (i = 0; i < RISC_RODATA_WORDS; i++)
        *(volatile u32 *)(SOC_BASE + RISC_RODATA_ADDR + i * 4u) = risc_rodata[i];
    for (i = 0; i < RISC_BSS_WORDS; i++)
        *(volatile u32 *)(SOC_BASE + RISC_BSS_ADDR + i * 4u) = 0u;
    uart_puts("loaded pstest: ");
    uart_putdec(RISC_IMG_WORDS);
    uart_puts(" words\n");

    /* ---------- 先配中断，再放行 CPU（避免第一发 irq_ps 丢在配置前） ---------- */
    gic_init();
    uart_puts("GIC ready (SPI 61..68 enabled)\n");
    __asm__ volatile("cpsie i" ::: "memory");

    REG_CTRL = 0x0u;                                  /* HOLD=0：CPU 开始跑 */
    uart_puts("CPU released, waiting for irq_ps...\n");

    for (i = 0; i < 20000000u; i++)
        if (g_irq_count) break;

    uart_puts("irq_count = ");
    uart_putdec(g_irq_count);
    uart_puts("  id = ");
    uart_putdec(g_last_id);
    uart_puts("  MSG = ");
    uart_puthex(g_msg);
    uart_puts("\n");

    if (g_irq_count == 0u) ok = 0u;
    if (g_msg != 0xDEADBEEFu) ok = 0u;
    if (g_last_id < 61u || g_last_id > 68u) ok = 0u;

    /* PS 收下标记，给调试器留个便条 */
    REG_SCRATCH = ok ? 0x600D0001u : 0xBAD00001u;

    /* ---------- PS → CPU：抬高 PS_IRQ，等 RISC-V 的中断计数 ---------- */
    REG_CTRL = 0x2u;                                  /* bit1 = PS_IRQ */
    for (i = 0; i < 20000000u; i++)
        if (SH_NIRQ) break;
    uart_puts("NIRQ (RISC-V counter) = ");
    uart_putdec(SH_NIRQ);
    uart_puts("\n");
    REG_CTRL = 0x0u;                                  /* 撤掉 PS_IRQ */

    if (SH_NIRQ < 1u) ok = 0u;

    uart_puts(ok ? "RESULT: PASS\n" : "RESULT: FAIL\n");
    return ok ? 0 : 1;
}
