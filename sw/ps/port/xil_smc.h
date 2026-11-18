/* =============================================================================
 * sw/ps/port/xil_smc.h -- Xil_Smc 桩（只有 aarch64/EL1 的 tap-delay 路径会用到，
 *                         ARM32 上驱动根本不会调；这里只为通过编译）
 * ============================================================================= */
#ifndef XIL_SMC_H
#define XIL_SMC_H

#include "xil_types.h"

#define MMIO_WRITE_SMC_FID 0xC4000020U

static INLINE u32 Xil_Smc(u32 Fid, u64 Arg1, u64 Arg2, u64 Arg3,
                          u64 Arg4, u64 Arg5, u64 Arg6, u64 Arg7)
{
    (void)Fid; (void)Arg1; (void)Arg2; (void)Arg3;
    (void)Arg4; (void)Arg5; (void)Arg6; (void)Arg7;
    return 0U;
}

#endif /* XIL_SMC_H */
