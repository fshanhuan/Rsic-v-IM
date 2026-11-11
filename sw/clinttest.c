/* =============================================================================
 * sw/clinttest.c — A3 判据：mtime/mtimecmp 只有**一个**计数源
 * -----------------------------------------------------------------------------
 * 核心判据（前 5 条）：CSR 路径（0x7C0/0x7C1）与总线路径（0x1000_0030/0x38）
 * 读写的必须是同一份状态。任何一条不成立，说明又变回"两套计数器"了。
 *
 *   bit0  csrw mtime,0 之后 lw 0x30 读到 0
 *   bit1  隔一段空转再读 0x30，值必须变大（真的在计数）
 *   bit2  **CSR 写 → 总线读**：csrw mtime,0xABCD0000 之后 lw 0x30 == 0xABCD0000
 *   bit3  **总线写 → CSR 读**：sw 0x30,0x13570000 之后 csrr mtime == 0x13570000
 *   bit4  **CSR 写 → 总线读**（mtimecmp）：csrw 0x7C1,0x12345678 之后 lw 0x38 相同
 *   bit5  定时器中断真的来了一次（mie.MTIE + mtimecmp）
 *   bit6  高半字恒 0（0x34/0x3C）
 *
 * 结果写 LED：全过 = 0x7F；否则哪位失败就缺哪位。串口打 "OK"/"NG"。
 * ★ 不返回：main 返回会走 crt0 的停机 magic（0x1000_00F0 的 idx 是 4 = LED）。
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define LED      (*(volatile uint32_t *)0x10000010u)
#define MTIME    (*(volatile uint32_t *)0x10000030u)
#define MTIMEH   (*(volatile uint32_t *)0x10000034u)
#define MTIMECMP (*(volatile uint32_t *)0x10000038u)
#define MTIMECMPH (*(volatile uint32_t *)0x1000003Cu)

static inline uint32_t rd_csr_mtime(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, 0x7C0" : "=r"(v));
    return v;
}
static inline void wr_csr_mtime(uint32_t v)
{
    __asm__ volatile("csrw 0x7C0, %0" ::"r"(v));
}
static inline uint32_t rd_csr_mtimecmp(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, 0x7C1" : "=r"(v));
    return v;
}
static inline void wr_csr_mtimecmp(uint32_t v)
{
    __asm__ volatile("csrw 0x7C1, %0" ::"r"(v));
}

static volatile uint32_t n_timer;

static void putc_(char c)
{
    while (TXSTAT & 1u)
        ;
    TXDATA = (uint32_t)(uint8_t)c;
}

__attribute__((interrupt("machine"), aligned(4)))
void trap_entry(void)
{
    n_timer = n_timer + 1u;
    wr_csr_mtimecmp(0xFFFFFFFFu);   /* 关掉这一次的 MTIP */
}

int main(void)
{
    uint32_t ok = 0;
    uint32_t a, b;
    int i;

    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)(uintptr_t)&trap_entry));

    /* ---- bit0 ---- */
    wr_csr_mtime(0u);
    if (MTIME == 0u) ok |= 1u;

    /* ---- bit1：真的在走 ---- */
    a = MTIME;
    for (i = 0; i < 5000; i++)
        __asm__ volatile("" ::: "memory");
    b = MTIME;
    if (b > a) ok |= 2u;

    /* ---- bit2：CSR 写 → 总线读 ---- */
    wr_csr_mtime(0xABCD0000u);
    if (MTIME == 0xABCD0000u) ok |= 4u;

    /* ---- bit3：总线写 → CSR 读 ----
     * ★ 不能"写完立刻读 CSR"就判定：store 要到 M 级才发到总线，而紧跟的 CSR 读
     *   在 ID 级就取样了 —— 那一拍读到的是**写之前**的值（这是流水线顺序，不是
     *   两套计数器）。所以这里改成"写 0 再轮询变小时刻"：先前 mtime 是 0xABCD_xxxx
     *   （很大），只有 MMIO 写真的落到同一个计数器上，它才会掉到 0 附近。 */
    MTIME = 0x00000000u;
    {
        uint32_t v = 0xFFFFFFFFu;
        for (i = 0; i < 1000; i++) {
            v = rd_csr_mtime();
            if (v < 0x1000u) break;
        }
        if (v < 0x1000u) ok |= 8u;
    }

    /* ---- bit4：mtimecmp 双向 ---- */
    wr_csr_mtimecmp(0x12345678u);
    if (MTIMECMP == 0x12345678u) ok |= 16u;

    /* ---- bit6：高半恒 0 ---- */
    if ((MTIMEH == 0u) && (MTIMECMPH == 0u)) ok |= 64u;

    /* ---- bit5：一次定时器中断 ---- */
    wr_csr_mtime(0u);
    wr_csr_mtimecmp(50u);                        /* 再过 50 tick（100 us）到期 */
    __asm__ volatile("csrs mie, %0"     ::"r"(1u << 7));   /* MTIE */
    __asm__ volatile("csrs mstatus, %0" ::"r"(1u << 3));   /* MIE  */
    for (i = 0; i < 200000 && (n_timer == 0u); i++)
        __asm__ volatile("" ::: "memory");
    __asm__ volatile("csrc mstatus, %0" ::"r"(1u << 3));
    if (n_timer >= 1u) ok |= 32u;

    LED = ok & 0x7Fu;

    if (ok == 0x7Fu) {
        putc_('O'); putc_('K'); putc_('\n');
    } else {
        putc_('N'); putc_('G'); putc_('\n');
    }

    for (;;)
        ;
}
