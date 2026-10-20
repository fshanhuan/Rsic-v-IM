/* =============================================================================
 * sw/rtos_demo.c -- FreeRTOS 在本核上的最小可验证 demo
 * -----------------------------------------------------------------------------
 * 验证什么：
 *   1) 调度器能起来（xPortStartFirstTask 恢复第一个任务上下文 + mret）；
 *   2) **定时器中断**能进（mtimecmp CSR → mcause 0x80000007 → 端口 trap handler）；
 *   3) 抢占式切换真的发生（两个同优先级任务靠 time slicing 交替，打印交叉）；
 *   4) vTaskDelay 的阻塞/唤醒正确（打印节奏不同，不是轮流刷屏）。
 *
 * 三个任务：
 *   blink  : 每 20 tick（200 ms）打印一个 'B'，翻转 LED 低位
 *   count  : 每 50 tick（500 ms）打印 'C' + 计数
 *   idle   : 空闲钩子用不上，直接交给 FreeRTOS 的空闲任务
 *
 * 结束条件：打印够 24 行后写 magic 到 0x1000_00F0，仿真台据此停机（板上无副作用）。
 * ============================================================================= */
#include "FreeRTOS.h"
#include "task.h"

/* ---------------------------------------------------------------- 板级 IO */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)
#define LED_REG     (*(volatile unsigned int *)0x10000010u)
#define DONE_FLAG   (*(volatile unsigned int *)0x100000f0u)

extern void freertos_risc_v_trap_handler(void);

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
    char buf[12];
    int i = 0;
    if (v == 0)
    {
        putc_('0');
        return;
    }
    while (v > 0)
    {
        buf[i++] = (char)('0' + (v % 10u));
        v /= 10u;
    }
    while (i > 0)
        putc_(buf[--i]);
}

/* 断言失败：打印位置后停住（仿真里能直接看出是哪一行） */
void vAssertCalled(const char *pcFile, unsigned long ulLine)
{
    (void)pcFile;
    puts_("\n[ASSERT] line=");
    putdec_((unsigned int)ulLine);
    puts_("\n");
    for (;;)
        ;
}

static volatile unsigned int g_lines = 0;
static volatile unsigned int g_led = 0;

static void puthex_(unsigned int v)
{
    const char *d = "0123456789abcdef";
    int         i;
    puts_("0x");
    for (i = 7; i >= 0; i--)
        putc_(d[(v >> (i * 4)) & 0xF]);
}

/* 一次性把中断使能状态打出来（排查"调度器起来了但 tick 不来"）：
 *   mstatus.MIE(bit3) 必须为 1、mie.MTIE(bit7) 必须为 1、mip.MTIP(bit7) 会周期置位 */
static void dump_irq_state(const char *tag)
{
    unsigned int ms, mi, mp, mc, mtc;
    __asm volatile("csrr %0, 0x300" : "=r"(ms));
    __asm volatile("csrr %0, 0x304" : "=r"(mi));
    __asm volatile("csrr %0, 0x344" : "=r"(mp));
    __asm volatile("csrr %0, 0x342" : "=r"(mc));
    __asm volatile("csrr %0, 0x7c1" : "=r"(mtc));
    puts_(tag);
    puts_(" mstatus="); puthex_(ms);
    puts_(" mie=");     puthex_(mi);
    puts_(" mip=");     puthex_(mp);
    puts_(" mcause=");  puthex_(mc);
    puts_(" mtc=");     puthex_(mtc);
    puts_("\n");
}

static void tick_line(const char *tag, unsigned int n)
{
    puts_(tag);
    putdec_(n);
    puts_("\n");
    g_lines++;
    if (g_lines >= 24)
    {
        puts_("RTOS-DONE\n");
        DONE_FLAG = 0x5A5A5A5A;
        for (;;)
            ;   /* 不再返回：仿真台会停机；板上停在这里等看门狗 */
    }
}

/* ---------------------------------------------------------------- 任务 */
static void vBlinkTask(void *pv)
{
    unsigned int n = 0;
    int          first = 1;
    (void)pv;
    dump_irq_state("[IRQ]task");
    for (;;)
    {
        g_led ^= 0x1u;
        LED_REG = g_led;
        tick_line("B", n++);
        if (first)
        {
            /* 关键观测点：vTaskDelay 会走 portYIELD（ecall）。看它**调用之前**的
             * mstatus.MIE 是不是 1 —— 如果是 1 而返回后变 0，那问题在陷入/返回路径
             * （CPU 侧）；如果调用前就已经是 0，那是端口/内核用法的问题。 */
            dump_irq_state("[IRQ]pre-delay");
            first = 0;
        }
        vTaskDelay(20 / portTICK_PERIOD_MS);
        dump_irq_state("[IRQ]post-delay");
    }
}

static void vCountTask(void *pv)
{
    unsigned int n = 0;
    (void)pv;
    for (;;)
    {
        tick_line("C", n++);
        vTaskDelay(50 / portTICK_PERIOD_MS);
    }
}

/* ---------------------------------------------------------------- main */
int main(void)
{
    /* ★ 必须由应用设置 mtvec：端口的陷入入口 freertos_risc_v_trap_handler */
    __asm volatile("csrw mtvec, %0" ::"r"((unsigned int)freertos_risc_v_trap_handler));

    puts_("RTOS-BOOT\n");

    if (xTaskCreate(vBlinkTask, "blink", configMINIMAL_STACK_SIZE, NULL, 1, NULL) != pdPASS)
        puts_("ERR task1\n");
    if (xTaskCreate(vCountTask, "count", configMINIMAL_STACK_SIZE, NULL, 1, NULL) != pdPASS)
        puts_("ERR task2\n");

    vTaskStartScheduler();   /* 正常情况下不返回 */

    puts_("ERR scheduler returned\n");
    for (;;)
        ;
    return 0;
}
