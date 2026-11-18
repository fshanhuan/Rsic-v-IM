/* =============================================================================
 * sw/ps/port/xstatus.h -- 最小状态码定义（与 Xilinx 原版数值一致）
 * ============================================================================= */
#ifndef XSTATUS_H
#define XSTATUS_H

#define XST_SUCCESS             0L
#define XST_FAILURE             1L
#define XST_DEVICE_BUSY         3L
#define XST_DEVICE_IS_STARTED   4L
#define XST_DEVICE_NOT_FOUND    5L
#define XST_INVALID_PARAM       20L

#define XIL_COMPONENT_IS_STARTED 0x11111112U

#endif /* XSTATUS_H */
