/* =============================================================================
 * sw/ps/port/xil_assert.h -- 断言：默认只做求值，不打日志（裸机没有异常框架）
 * -----------------------------------------------------------------------------
 * Xilinx 原版在断言失败时会打印并（可选）死循环。这里改成"求值即返回"，
 * 因为驱动里断言只用来挡 NULL 指针/未初始化实例，出错时后面的代码自己会返回
 * XST_FAILURE，比在裸机上挂死更好定位。
 * ============================================================================= */
#ifndef XIL_ASSERT_H
#define XIL_ASSERT_H

#include "xil_types.h"
#include "xstatus.h"

#define Xil_AssertNonvoid(Expr)   do { (void)(Expr); } while (0)
#define Xil_AssertVoid(Expr)      do { (void)(Expr); } while (0)
#define Xil_AssertNonvoidAlways() do { } while (0)
#define Xil_AssertVoidAlways()    do { } while (0)
#define Xil_AssertSetCallback(cb) do { (void)(cb); } while (0)

#endif /* XIL_ASSERT_H */
