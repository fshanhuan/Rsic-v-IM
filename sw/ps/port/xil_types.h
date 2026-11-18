/* =============================================================================
 * sw/ps/port/xil_types.h -- 给 Xilinx xsdps 驱动用的最小类型定义
 * -----------------------------------------------------------------------------
 * 为什么需要这个文件：
 *   Xilinx 的 SD 驱动（sw/ps/sdps/）本来是给 BSP 环境写的，头文件依赖一堆
 *   libxil 的东西。本工程的 PS 程序是**完全 freestanding**（-nostdlib，无 BSP），
 *   所以这里用最少的内容把那些依赖补齐，语义与 Xilinx 原版保持一致。
 * ============================================================================= */
#ifndef XIL_TYPES_H
#define XIL_TYPES_H

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;

typedef signed char        s8;
typedef signed short       s16;
typedef signed int         s32;
typedef signed long long   s64;

typedef char               char8;
typedef unsigned int       uptr;
typedef int                sint32;
typedef unsigned long      UINTPTR;
typedef long               INTPTR;

#ifndef TRUE
#define TRUE  1U
#endif
#ifndef FALSE
#define FALSE 0U
#endif
#ifndef NULL
#define NULL  ((void *)0)
#endif

/* 驱动里用它判断实例是否已经初始化过 */
#define XIL_COMPONENT_IS_READY  0x11111111U

#define ALIGNMENT_CACHELINE     32U
#ifndef INLINE
#define INLINE inline
#endif

#endif /* XIL_TYPES_H */
