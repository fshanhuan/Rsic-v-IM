/* =============================================================================
 * sw/ps/port/xil_io.h -- MMIO 读写（直接 volatile 指针，不开 MMU 也就是物理地址）
 * ============================================================================= */
#ifndef XIL_IO_H
#define XIL_IO_H

#include "xil_types.h"

#define Xil_In32(Addr)        (*(volatile u32 *)(uptr)(Addr))
#define Xil_Out32(Addr, Val)  (*(volatile u32 *)(uptr)(Addr) = (u32)(Val))
#define Xil_In16(Addr)        (*(volatile u16 *)(uptr)(Addr))
#define Xil_Out16(Addr, Val)  (*(volatile u16 *)(uptr)(Addr) = (u16)(Val))
#define Xil_In8(Addr)         (*(volatile u8 *)(uptr)(Addr))
#define Xil_Out8(Addr, Val)   (*(volatile u8 *)(uptr)(Addr) = (u8)(Val))

#endif /* XIL_IO_H */
