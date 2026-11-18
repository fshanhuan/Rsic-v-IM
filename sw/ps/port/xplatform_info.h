/* =============================================================================
 * sw/ps/port/xplatform_info.h -- 平台判定：本工程只跑 Cortex-A9（Zynq-7000）
 * ============================================================================= */
#ifndef XPLATFORM_INFO_H
#define XPLATFORM_INFO_H

#include "xil_types.h"

#define XPLAT_PS   0U

static INLINE u32 XGetPlatform_Info(void) { return XPLAT_PS; }

#endif /* XPLATFORM_INFO_H */
