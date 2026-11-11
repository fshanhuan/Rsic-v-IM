/* =============================================================================
 * sw/ps/ps_axil_test.c -- PS 侧（Cortex-A9）裸机：通过 AXI 读写 RISC-V 的 DRAM
 * -----------------------------------------------------------------------------
 * 地址：BD 里 assign_bd_address 给本 SoC 分配 **0x4000_0000**（256 KB），
 *   而 SoC 内部 DRAM 的字节地址是 0x0 ~ 0x1_FFFF，所以 PS 侧访问
 *     SOC_BASE + <DRAM 字节地址>      例：RISC-V 的 0x10044 → 0x4001_0044
 *
 * 测什么：
 *   1) 读 RISC-V 写进去的值（PS 观察 RISC-V）；
 *   2) 写一个标记再读回（PS 给 RISC-V 喂数据）。
 * 配合的 RISC-V 程序（sim/tb_axil_dram.sv 里那段手汇编）：
 *     sw a2, 0x44(a0)   # a0 = 0x0001_0000 → [0x10044] = 0x3C
 *
 * ★ 完全 freestanding：不用 xil_printf/newlib，直接写 Zynq UART1 的寄存器
 *   （0xE000_1000，MIO48/49）。因为本机 Vitis 缺 hsi 组件，用不了 BSP/库。
 *
 * ★ 编译（Windows 下，工具链是现成的）：
 *     E:\renases_e2s\toolchains\gcc_arm\13.2.rel1\bin\arm-none-eabi-gcc.exe
 *   见 sw/build_ps_app.ps1
 * ============================================================================= */

typedef unsigned int u32;

#define UART1_BASE   0xE0001000u
#define UART_CR      (*(volatile u32 *)(UART1_BASE + 0x00u))
#define UART_MR      (*(volatile u32 *)(UART1_BASE + 0x04u))
#define UART_BAUDGEN (*(volatile u32 *)(UART1_BASE + 0x18u))
#define UART_SR      (*(volatile u32 *)(UART1_BASE + 0x2Cu))
#define UART_FIFO    (*(volatile u32 *)(UART1_BASE + 0x30u))

#define SOC_BASE    0x40000000u
#define OFF_CPU_W   0x00010044u   /* RISC-V 在这里写 0x3C */
#define OFF_MARK    0x00010040u   /* PS 在这里写标记 */
#define OFF_MARK2   0x00010048u   /* 第二个地址，验证不是只有一个地址能用 */
#define MARK_VAL    0x5150C0DEu

static void uart_putc(char c)
{
    /* SR bit4 = TX FIFO full */
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

/* 板级自测（不依赖 RISC-V 侧是否在跑）：
 *   A) 读 0x4001_0044 —— 信息性：RISC-V 若在跑会写 0x3C，不在跑就是 0；
 *   B) 写 0x4001_0040 = MARK，读回比较 —— 证明 PS→DRAM→PS 的写通路；
 *   C) 再写一个不同地址 0x4001_0048，读回比较 —— 证明不是"只有某个地址能用"。
 * 判据：B、C 都对才算 PASS。
 *
 * ★ 2026-11-11 板上第一次跑时，A（读）通了、B（写）卡死：
 *   根因是 bridge 要求 awvalid 与 wvalid **同拍**，而真实主机先 AW 后 W。
 *   已在 board/axil_slave.sv 修掉（并给 tb_axil 加了 T8 通道分离用例）。 */
int main(void)
{
    u32 v, w1, w2;

    /* UART1：115200 8N1（MIO/波特率由 ps7_init 配好；这里只确保收发使能） */
    UART_CR = (1u << 0) | (1u << 1) | (1u << 2);   /* RXRST | TXRST | TXEN */
    UART_MR = 0x20u;                              /* 8N1, 无校验 */
    UART_CR = (1u << 2) | (1u << 4);              /* TXEN | RXEN */

    uart_puts("\n=== PS -> RISC-V AXI test ===\n");

    v = *(volatile u32 *)(SOC_BASE + OFF_CPU_W);
    uart_puts("A) RISC-V DRAM[0x10044] = ");
    uart_puthex(v);
    uart_puts("   (informational)\n");

    *(volatile u32 *)(SOC_BASE + OFF_MARK) = MARK_VAL;
    w1 = *(volatile u32 *)(SOC_BASE + OFF_MARK);
    uart_puts("B) write/readback 0x10040 = ");
    uart_puthex(w1);
    uart_puts("   (expect 0x5150c0de)\n");

    *(volatile u32 *)(SOC_BASE + OFF_MARK2) = 0x12345678u;
    w2 = *(volatile u32 *)(SOC_BASE + OFF_MARK2);
    uart_puts("C) write/readback 0x10048 = ");
    uart_puthex(w2);
    uart_puts("   (expect 0x12345678)\n");

    if (w1 == MARK_VAL && w2 == 0x12345678u) {
        uart_puts("RESULT: PASS\n");
        return 0;
    }
    uart_puts("RESULT: FAIL\n");
    return 1;
}
