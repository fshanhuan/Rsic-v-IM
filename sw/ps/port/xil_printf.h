/* =============================================================================
 * sw/ps/port/xil_printf.h -- 极简 printf（输出到 PS UART1 @0xE0001000）
 * ============================================================================= */
#ifndef XIL_PRINTF_H
#define XIL_PRINTF_H

#include "xil_types.h"

int  xil_printf(const char *fmt, ...);
void port_uart_init(void);

/* 内存日誌（xil_printf 的内容同步写到这里，JTAG 直接可读） */
void port_log_reset(void);

#endif /* XIL_PRINTF_H */
