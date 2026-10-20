/* =============================================================================
 * sw/cm_probe_port/core_portme.h -- 对拍用的**主机端口头**（只为 sw/cm_probe.c 服务）
 * -----------------------------------------------------------------------------
 * 为什么不直接用 CoreMark 自带的 linux 端口：那个端口目录里只有 .mak，没有
 * core_portme.h（它复用 barebones 的），而 barebones 把 ee_ptr_int 定成 32 位 ——
 * 在 x86-64 上会截断指针。
 *
 * 这里只提供 coremark.h 需要的**最小集合**：类型 + 配置开关 + portable_init 声明。
 * ★ 关键点：所有类型宽度必须与 rv32 端口一致（ee_s16=16b / ee_u32=32b），
 *   只有 ee_ptr_int 随指针宽度变（64 位），否则 align_mem 会截断。
 * ============================================================================= */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

#define HAS_FLOAT   0
#define HAS_TIME_H  0
#define USE_CLOCK   0
#define HAS_STDIO   0
#define HAS_PRINTF  0

#define MEM_METHOD  MEM_STATIC
#define SEED_METHOD SEED_VOLATILE

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
/* ★ 主机是 64 位指针 */
typedef unsigned long  ee_ptr_int;
typedef ee_u32         ee_size_t;

#ifndef NULL
#define NULL ((void *)0)
#endif

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0
#endif

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 0
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

#ifndef COMPILER_VERSION
#ifdef __GNUC__
#define COMPILER_VERSION "GCC" __VERSION__
#else
#define COMPILER_VERSION "unknown"
#endif
#endif

#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "-O2"
#endif

#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
