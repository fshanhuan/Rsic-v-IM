/* =============================================================================
 * sw/coremark_port/core_portme.h -- 本 SoC 的 CoreMark 端口配置
 * -----------------------------------------------------------------------------
 * 做法：**先**定义平台能力宏，**再** #include 原版 barebones/core_portme.h。
 *   原版头里所有配置项都是 `#ifndef XXX / #define XXX` 形式，所以先定义即可覆盖，
 *   不需要改 vendor 源码（升级 CoreMark 时不用重新打补丁）。
 *
 * 与原版 barebones 的差异及原因：
 *   HAS_FLOAT   1  -> 本核无 FPU，但有 libgcc 软浮点；CoreMark 报告要打 %f。
 *   HAS_TIME_H  0  -> 没有 time.h / clock()；计时走 mcycle（见 core_portme.c）。
 *   USE_CLOCK   0  -> 同上。
 *   MEM_STATIC     -> 不用 malloc（没有堆），用 core_main.c 里的 static_memblk。
 * ============================================================================= */
#ifndef CM_CORE_PORTME_WRAP_H
#define CM_CORE_PORTME_WRAP_H

/* vendor 头用 size_t 定义 ee_size_t，但自己不 include <stddef.h>；
 * -ffreestanding 下 gcc 仍自带 stddef.h，先带上即可。 */
#include <stddef.h>

#define HAS_FLOAT   1
#define HAS_TIME_H  0
#define USE_CLOCK   0
#define HAS_STDIO   0
#define HAS_PRINTF  0

#define MEM_METHOD  MEM_STATIC
#define SEED_METHOD SEED_VOLATILE

/* 主频 50 MHz：一个时钟拍 = 一个 mcycle tick，所以每秒计数就是 50e6。
 * ★ 32 位 mcycle 在 50 MHz 下 85.9 s 回绕；CoreMark 要求 >=10 s 的运行时间，
 *   离回绕还有 8 倍余量，安全。 */
#define CLOCKS_PER_SEC 50000000

#ifndef ITERATIONS
#define ITERATIONS 1
#endif

/* 由 vendor 头补全：ee_s16/ee_u32/CORE_TICKS/portable_init/ee_printf 声明等 */
#include "../coremark/barebones/core_portme.h"

#endif /* CM_CORE_PORTME_WRAP_H */
