/* =============================================================================
 * sw/freertos_port/string.h -- 空壳 string 头（声明与 libc_mini.c 的实现对应）
 * -----------------------------------------------------------------------------
 * FreeRTOS 内核用 memcpy/memset/memcmp/strlen，这些在 sw/coremark_port/libc_mini.c
 * 里有实现（单字节循环版）。这里只给声明，避免再引一套 string.h。
 * ============================================================================= */
#ifndef CM_STRING_H
#define CM_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int   memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int   strcmp(const char *a, const char *b);

#endif /* CM_STRING_H */
