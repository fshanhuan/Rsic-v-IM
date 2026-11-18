/* =============================================================================
 * sw/ps/port/xil_clocking.h -- XCLOCKING 未开启时驱动不会用到，桩掉即可
 * ============================================================================= */
#ifndef XIL_CLOCKING_H
#define XIL_CLOCKING_H

#include "xil_types.h"

static INLINE u32 Xil_ClockEnable(u32 ClockId)  { (void)ClockId; return 0U; }
static INLINE u32 Xil_ClockDisable(u32 ClockId) { (void)ClockId; return 0U; }

#endif /* XIL_CLOCKING_H */
