/* =============================================================================
 * tools/ps/host/sim/xil_io.h -- 把 Xil_In32/Xil_Out32 重定向到模拟寄存器
 * -----------------------------------------------------------------------------
 * 为什么需要：sw/ps/port/xil_io.h 把 Xil_In32 定义成"直接解引用物理地址"的宏，
 * 在 PC 上一执行就段错误。要让 sd_bit_bus.c（真代码）跑在 PC 上，必须把它换成
 * 一个能被拦截的实现。
 *
 * 用法：编译时把这个目录放在 -I 的最前面，它就会盖住 sw/ps/port/xil_io.h。
 * ============================================================================= */
#ifndef XIL_IO_H
#define XIL_IO_H

#include "xil_types.h"

u32  sim_in32(u32 addr);
void sim_out32(u32 addr, u32 val);

#define Xil_In32(Addr)         sim_in32((u32)(Addr))
#define Xil_Out32(Addr, Val)   sim_out32((u32)(Addr), (u32)(Val))
#define Xil_In16(Addr)         ((u16)sim_in32((u32)(Addr)))
#define Xil_Out16(Addr, Val)   sim_out32((u32)(Addr), (u32)(Val))
#define Xil_In8(Addr)          ((u8)sim_in32((u32)(Addr)))
#define Xil_Out8(Addr, Val)    sim_out32((u32)(Addr), (u32)(Val))

#endif /* XIL_IO_H */
