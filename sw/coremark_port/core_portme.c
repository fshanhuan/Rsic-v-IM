/* =============================================================================
 * sw/coremark_port/core_portme.c -- 平台相关实现（计时 + 串口 + 初始化）
 * -----------------------------------------------------------------------------
 * 计时口径（这是 CoreMark 分数唯一依赖的平台决定）：
 *   barebones_clock() 直接读 **mcycle**（CSR 0xB00，本核 v12 实现的 32 位低半），
 *   于是 CORE_TICKS 就是**时钟拍数**，CLOCKS_PER_SEC = 50e6。
 *   好处：分数 = ITERATIONS * 50e6 / 拍数，不受串口/中断抖动影响，且与仿真逐拍一致。
 *
 * 串口：115200 8N1，MMIO
 *   +0x00 TXDATA（低 8 位）   +0x04 TXSTAT（bit0 = busy，忙时写会丢弃）
 *   所以发一个字节前必须轮询 TXSTAT。仿真台里 TXSTAT 恒 0。
 * ============================================================================= */
#include "coremark.h"
#include "core_portme.h"

/* ---- 种子：PERFORMANCE_RUN 用 0/0/0x66（与 CoreMark 官方口径一致） ---- */
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* ---- MMIO ---- */
#define UART_TXDATA (*(volatile ee_u32 *)0x10000000u)
#define UART_TXSTAT (*(volatile ee_u32 *)0x10000004u)

void uart_send_char(char c)
{
    while (UART_TXSTAT & 1u)
        ;                       /* 等发送器空闲（忙时写会被硬件丢弃） */
    UART_TXDATA = (ee_u32)(ee_u8)c;
}

/* ---- 计时 ---- */
static inline ee_u32 cm_rd_mcycle(void)
{
    ee_u32 v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

CORETIMETYPE
barebones_clock(void)
{
    return (CORETIMETYPE)cm_rd_mcycle();
}

#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))   /* 模 2^32 差，回绕也正确 */
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC           (CLOCKS_PER_SEC / TIMER_RES_DIVIDER)

static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void)
{
    GETMYTIME(&start_time_val);
}

void stop_time(void)
{
    GETMYTIME(&stop_time_val);
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! ee_ptr_int 放不下指针\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! ee_u32 不是 32 位\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
