/* =============================================================================
 * sw/ps/riscv_loader.c — PS 当宿主：把 RISC-V 镜像灌进 DRAM，然后放行 CPU
 * -----------------------------------------------------------------------------
 * 这是"双核协同 第 1 步"的 PS 侧（Cortex-A9，裸机，不用 BSP）。
 *
 * 上电时序（与 board/ps_ctrl.sv、sw/ps/stub.S 严格对应）：
 *   1. FPGA 配好 → ps_ctrl 的 CTRL.HOLD 复位值是 **1** → RISC-V 被按在复位里；
 *   2. 本程序：清 ALIVE → 写 DRAM 镜像 → 写 .rodata → 清 .bss；
 *   3. 写 CTRL.HOLD = 0 放行；
 *   4. CPU 的 stage-0 stub 把 DRAM[0xA000..] 抄进 IMEM 代码窗口 0x2_0000，
 *      fence.i，跳过去跑 monitor；最后 stub 会写 ALIVE=1；
 *   5. 本程序轮询 STATUS.ALIVE，报 PASS/FAIL。
 *
 * 为什么镜像能放在 DRAM 0xA000：
 *   那是"应用数据区"（shell 的 run 装载区），上电时 shell 还没用到它，
 *   而 shell 自己的 .rodata/.bss/栈在 0x1_0000 以上，不冲突。
 *
 * 寄存器（见 board/ps_ctrl.sv）：CTRL bit0=HOLD bit1=PS_IRQ bit2=CLR_ALIVE
 *   bit3=CLR_IRQ_PS；STATUS bit0=HOLD bit2=irq_ps bit6=ALIVE [31:16]=MAGIC 0xB155
 *
 * 编译：sw/build_ps_app.ps1 loader
 * ============================================================================= */

typedef unsigned int u32;

#include "app_image.h"

#define UART1_BASE   0xE0001000u
#define UART_CR      (*(volatile u32 *)(UART1_BASE + 0x00u))
#define UART_MR      (*(volatile u32 *)(UART1_BASE + 0x04u))
#define UART_SR      (*(volatile u32 *)(UART1_BASE + 0x2Cu))
#define UART_FIFO    (*(volatile u32 *)(UART1_BASE + 0x30u))

#define SOC_BASE     0x40000000u
#define REG_CTRL     (*(volatile u32 *)(SOC_BASE + 0x00020000u))
#define REG_STATUS   (*(volatile u32 *)(SOC_BASE + 0x00020004u))
#define REG_SCRATCH  (*(volatile u32 *)(SOC_BASE + 0x00020008u))

/* DRAM 字访问：RISC-V 的字节地址直接当偏移 */
static inline void dram_wr(u32 byte_addr, u32 v)
{
    *(volatile u32 *)(SOC_BASE + byte_addr) = v;
}
static inline u32 dram_rd(u32 byte_addr)
{
    return *(volatile u32 *)(SOC_BASE + byte_addr);
}

static void uart_putc(char c)
{
    while (UART_SR & (1u << 4))      /* TX FIFO full */
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
    UART_CR = (1u << 0) | (1u << 1) | (1u << 2);   /* RXRST | TXRST | TXEN */
    UART_MR = 0x20u;                               /* 8N1 */
    UART_CR = (1u << 2) | (1u << 4);               /* TXEN | RXEN */
}

int main(void)
{
    u32 i, st, t;
    int ok = 1;

    uart_init();
    uart_puts("\n=== PS loader -> RISC-V (step 1) ===\n");

    /* ---- 0) 控制窗口在位？ ---- */
    st = REG_STATUS;
    uart_puts("STATUS = ");
    uart_puthex(st);
    uart_puts("\n");
    if ((st >> 16) != 0xB155u) {
        uart_puts("FATAL: ps_ctrl MAGIC mismatch (bitstream too old?)\n");
        uart_puts("RESULT: FAIL\n");
        return 1;
    }

    /* ---- 1) 按住 CPU、清 ALIVE ---- */
    REG_CTRL = 0x1u;                  /* HOLD=1, PS_IRQ=0, CLR_ALIVE=1 */
    uart_puts("1) CPU held, alive cleared\n");

    /* ---- 2) 灌数据：.text 到 0xA000（stub 的搬运源）、.rodata 回链接地址、.bss 清零 ---- */
    dram_wr(RISC_IMG_DRAM, RISC_IMG_WORDS);
    for (i = 0; i < RISC_IMG_WORDS; i++)
        dram_wr(RISC_IMG_DRAM + 4u + i * 4u, risc_img[i]);
    for (i = 0; i < RISC_RODATA_WORDS; i++)
        dram_wr(RISC_RODATA_ADDR + i * 4u, risc_rodata[i]);
    for (i = 0; i < RISC_BSS_WORDS; i++)
        dram_wr(RISC_BSS_ADDR + i * 4u, 0u);

    uart_puts("2) loaded text=");
    uart_putdec(RISC_IMG_WORDS);
    uart_puts(" words @0x");
    uart_puthex(RISC_IMG_DRAM);
    uart_puts("  rodata=");
    uart_putdec(RISC_RODATA_WORDS);
    uart_puts(" @0x");
    uart_puthex(RISC_RODATA_ADDR);
    uart_puts("  bss=");
    uart_putdec(RISC_BSS_WORDS);
    uart_puts("\n");

    /* ---- 3) 回读校验（首/中/尾 + 描述符）---- */
    {
        u32 n  = dram_rd(RISC_IMG_DRAM);
        u32 w0 = dram_rd(RISC_IMG_DRAM + 4u);
        u32 wm = dram_rd(RISC_IMG_DRAM + 4u + (RISC_IMG_WORDS / 2u) * 4u);
        u32 wl = dram_rd(RISC_IMG_DRAM + RISC_IMG_WORDS * 4u);
        uart_puts("3) verify n=");
        uart_puthex(n);
        uart_puts(" first=");
        uart_puthex(w0);
        uart_puts(" last=");
        uart_puthex(wl);
        uart_puts("\n");
        if (n != RISC_IMG_WORDS || w0 != risc_img[0] ||
            wm != risc_img[RISC_IMG_WORDS / 2u] ||
            wl != risc_img[RISC_IMG_WORDS - 1u]) {
            uart_puts("   VERIFY FAILED\n");
            ok = 0;
        }
    }

    REG_SCRATCH = 0x10AD0001u;        /* 给调试器留的便条（mrd 0x40020008 可看） */

    /* ---- 4) 放行 CPU ---- */
    REG_CTRL = 0x0u;
    uart_puts("4) HOLD=0, waiting for ALIVE...\n");

    /* ---- 5) 等 stub 报平安（~50 ms 足够：它只抄 20 KB）---- */
    for (t = 0; t < 500000u; t++) {
        if (REG_STATUS & (1u << 6))
            break;
    }
    st = REG_STATUS;
    uart_puts("5) STATUS = ");
    uart_puthex(st);
    uart_puts("  (ALIVE=");
    uart_putc((st & (1u << 6)) ? '1' : '0');
    uart_puts(")\n");

    if (!(st & (1u << 6))) ok = 0;

    uart_puts(ok ? "RESULT: PASS\n" : "RESULT: FAIL\n");
    return ok ? 0 : 1;
}
