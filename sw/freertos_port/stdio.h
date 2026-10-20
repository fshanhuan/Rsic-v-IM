/* =============================================================================
 * sw/freertos_port/stdio.h -- 空壳 stdio 头
 * -----------------------------------------------------------------------------
 * tasks.c 在 configUSE_STATS_FORMATTING_FUNCTIONS / trace facility 打开时会用
 * snprintf 拼任务状态表。我们全关了，所以只留声明；真被调用就是链接错误。
 * ============================================================================= */
#ifndef CM_STDIO_H
#define CM_STDIO_H

#include <stddef.h>

int snprintf(char *buf, size_t n, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int printf(const char *fmt, ...);

#endif /* CM_STDIO_H */
