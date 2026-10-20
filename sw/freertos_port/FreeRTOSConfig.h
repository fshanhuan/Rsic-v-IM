/* =============================================================================
 * sw/freertos_port/FreeRTOSConfig.h -- BigBird v13 的 FreeRTOS 配置
 * -----------------------------------------------------------------------------
 * ★ 本核的定时器不是 SiFive CLINT 的 MMIO，而是两条 **CSR**：
 *     mtime    (0x7C0, 只读)  —— 500 kHz 墙钟（50MHz / 100 分频）
 *     mtimecmp (0x7D0, 可写)  —— 写新值即清中断
 *   所以这里把 configMTIME_BASE_ADDRESS / configMTIMECMP_BASE_ADDRESS 都定义成 0
 *   （让 stock 端口里那套 64 位 CLINT 访问整段不编译），再用 make_rtos_port.py
 *   把 vPortSetupTimerInterrupt 和 portUPDATE_MTIMER_COMPARE_REGISTER 换成 CSR 版。
 *
 * ★ configCPU_CLOCK_HZ 与 mtime 的关系：mtime 每 100 个 CPU 拍才 +1（500kHz），
 *   而端口的 tick 重装用的是 "mtime += CPU_CLOCK_HZ / TICK_RATE_HZ"。
 *   如果直接填 50e6/100 = 500000，mtime 是 500kHz，500000 个 tick = 1 s。
 *   所以这里必须按 **mtime 的频率** 算：500000/100 = 5000 个 mtime 单位 = 10 ms。
 *   —— 这就是为什么要单独给 configMTIME_TICKS_PER_SECOND，而不是复用 CPU 频率。
 * ============================================================================= */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configMTIME_BASE_ADDRESS                0
#define configMTIMECMP_BASE_ADDRESS             0

/* mtime 的计数频率（= 50MHz / 100 分频）。★ 不是 CPU 主频！ */
#define configMTIME_TICKS_PER_SECOND            500000
#define configCPU_CLOCK_HZ                      50000000
/* 1 kHz tick（1 ms）：mtime 500kHz → 每 tick 500 个 mtime 计数。
 * ★ 选 1 kHz 而不是 100 Hz 的原因：仿真里 100 Hz 意味着一个 tick 就要 50 万拍，
 *   demo 打印几行就要上亿拍，调试太慢。1 ms 也是嵌入式最常见的 tick。 */
#define configTICK_RATE_HZ                      1000
/* 一 tick 对应多少个 mtime 单位：500000/1000 = 500 */
#define configMTIME_TICKS_PER_TICK \
    ( configMTIME_TICKS_PER_SECOND / configTICK_RATE_HZ )

#define configUSE_PREEMPTION                    1
#define configUSE_TIME_SLICING                  1
#define configUSE_IDLE_HOOK                     0
#define configUSE_TICK_HOOK                     0
#define configUSE_16_BIT_TICKS                  0
#define configMAX_PRIORITIES                    5
#define configMINIMAL_STACK_SIZE                256
#define configTOTAL_HEAP_SIZE                   ( 20 * 1024 )
#define configMAX_TASK_NAME_LEN                 8

#define configUSE_MUTEXES                       1
#define configUSE_RECURSIVE_MUTEXES             0
#define configUSE_COUNTING_SEMAPHORES           0
#define configUSE_QUEUE_SETS                    0
#define configUSE_TASK_NOTIFICATIONS            1
#define configUSE_TRACE_FACILITY                0
#define configUSE_STATS_FORMATTING_FUNCTIONS    0
#define configQUEUE_REGISTRY_SIZE               0
#define configUSE_TIMERS                        0
#define configUSE_CO_ROUTINES                   0
#define configCHECK_FOR_STACK_OVERFLOW          0
#define configUSE_MALLOC_FAILED_HOOK            0
#define configUSE_IDLE_SLEEP                    0
#define configGENERATE_RUN_TIME_STATS           0

/* RISC-V 端口：中断用一个**独立的** ISR 栈（每个任务栈之外） */
#define configISR_STACK_SIZE_WORDS              256

/* ★ 这些 INCLUDE_xxx 必须显式给：内核里全是 `#if ( INCLUDE_vTaskDelay == 1 )`，
 *   未定义时按 0 处理 → 相关函数**静默不编译**，链接期才报 undefined reference。 */
#define INCLUDE_vTaskPrioritySet                1
#define INCLUDE_uxTaskPriorityGet               1
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_vTaskDelayUntil                 1
#define INCLUDE_vTaskDelay                      1
#define INCLUDE_xTaskGetSchedulerState          1
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#define INCLUDE_xTaskGetIdleTaskHandle          1
#define INCLUDE_xTaskGetTickCount               1

#define configASSERT( x ) \
    if( ( x ) == 0 ) { vAssertCalled( __FILE__, __LINE__ ); }

void vAssertCalled( const char *pcFile, unsigned long ulLine );

/* ---- 中断优先级：M 模式单核不需要，端口只要求这两个宏存在 ---- */
#define configMAX_SYSCALL_INTERRUPT_PRIORITY    0
#define configKERNEL_INTERRUPT_PRIORITY         0

#endif /* FREERTOS_CONFIG_H */
