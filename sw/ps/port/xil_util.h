/* =============================================================================
 * sw/ps/port/xil_util.h -- Xil_WaitForEvent / Xil_WaitForEvents
 * -----------------------------------------------------------------------------
 * 语义对齐 Xilinx libxil：
 *   Xil_WaitForEvent (RegAddr, Mask, Value, Timeout)
 *       —— 轮询到 ((reg & Mask) == Value) 或超时
 *   Xil_WaitForEvents(RegAddr, MaskOn, MaskOff, Timeout, *Value)
 *       —— 轮询到 ((reg & MaskOn) == MaskOn) 或 ((reg & MaskOff) != 0) 或超时
 *
 * ★ 2026-11-18 的重要教训：一开始用 Cortex-A9 的 PMU 周期计数器做超时，
 *   结果 PMCCNTR 读出来不涨（PMU 在这块板上没真的跑起来），于是所有
 *   "等到某位清零"的循环**永远不会超时**，程序看起来像"卡死在 SD 初始化里"。
 *   排查花了不少时间。现在改成**纯轮询计数**：不依赖任何定时器，
 *   一定能退出。Timeout 按 Xilinx 约定是微秒，这里按 1 µs ≈ 20 次轮询折算
 *   （够保守：宁可多等，绝不死等）。
 * ============================================================================= */
#ifndef XIL_UTIL_H
#define XIL_UTIL_H

#include "xil_types.h"
#include "xil_io.h"
#include "xstatus.h"
#include "sleep.h"

/* Timeout(µs) -> 轮询次数。最少给足 20000 次，避免驱动里 Timeout=1 的
 * "立刻查一次"语义在慢外设上误判。 */
static INLINE u32 port_poll_budget(u32 timeout_us)
{
    u32 n = timeout_us * 20U;
    if (n < 20000U) {
        n = 20000U;
    }
    return n;
}

static INLINE u32 Xil_WaitForEvent(u32 RegAddr, u32 Mask, u32 Value, u32 Timeout)
{
    u32 n = port_poll_budget(Timeout);

    while (n-- > 0U) {
        if ((Xil_In32(RegAddr) & Mask) == Value) {
            return XST_SUCCESS;
        }
    }
    return XST_FAILURE;
}

static INLINE u32 Xil_WaitForEvents(u32 RegAddr, u32 MaskOn, u32 MaskOff,
                                    u32 Timeout, u32 *Value)
{
    u32 n = port_poll_budget(Timeout);

    while (n-- > 0U) {
        u32 v = Xil_In32(RegAddr);
        if (((v & MaskOn) == MaskOn) || ((v & MaskOff) != 0U)) {
            if (Value != NULL) { *Value = v; }
            return XST_SUCCESS;
        }
    }
    if (Value != NULL) { *Value = 0U; }
    return XST_FAILURE;
}

#endif /* XIL_UTIL_H */
