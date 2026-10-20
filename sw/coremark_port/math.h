/* =============================================================================
 * sw/coremark_port/math.h -- 只有 modf 的"数学头"
 * -----------------------------------------------------------------------------
 * vendor 的 cvt.c（ee_printf 打印 %f 用）只从 <math.h> 里要一个 modf。
 * 本平台没有 libm（也没有 newlib 头），所以：
 *   · 用这个头把 <math.h> 顶掉（-Isw/coremark_port 在系统目录之前）；
 *   · modf 的实现放在 libc_mini.c（软浮点，靠 libgcc 的 __adddf3 等）。
 * ============================================================================= */
#ifndef CM_MATH_H
#define CM_MATH_H

double modf(double x, double *iptr);

#endif /* CM_MATH_H */
