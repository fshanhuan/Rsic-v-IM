/* =============================================================================
 * sw/freertos_port/stdlib.h -- 空壳 stdlib 头（给 FreeRTOS 内核编译用）
 * -----------------------------------------------------------------------------
 * 为什么需要：FreeRTOS 的 list.c / queue.c / tasks.c / heap_4.c 都无条件
 *   `#include <stdlib.h>`，而我们**没有 newlib**（工具链只装了 gcc + binutils，
 *   见 sw/env.sh）。这条 include 在内核里实际只用到 malloc/free 的声明，
 *   而内核的分配全走 pvPortMalloc → 我们自己的 heap_4.c，永远不会调到 libc。
 *   所以给一个只含声明的空壳即可，不提供实现（真调到就是链接错误，能立刻发现）。
 *
 * ★ 同一目录下的 string.h / stdio.h 同理。它们只在 -Isw/freertos_port 这一路
 *   生效，不影响工具链自带的头（我们也没装）。
 * ============================================================================= */
#ifndef CM_STDLIB_H
#define CM_STDLIB_H

#include <stddef.h>

void *malloc(size_t n);
void  free(void *p);
void *calloc(size_t n, size_t sz);
void *realloc(void *p, size_t n);
int   abs(int v);

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

#endif /* CM_STDLIB_H */
