/* =============================================================================
 * sw/ps/port/xil_cache.h -- 数据 cache 维护：本程序 MMU/cache 全关，故为空操作
 * -----------------------------------------------------------------------------
 * ★ 这一点很重要：ARM 复位后 MMU 关、D-cache 关（start_ps.S 也没开），
 *   所以 CPU 与 SD 控制器看到的都是同一份物理内存，不需要 flush/invalidate。
 *   如果以后开了 MMU/cache，这些空操作必须换成真正的维护指令。
 * ============================================================================= */
#ifndef XIL_CACHE_H
#define XIL_CACHE_H

#include "xil_types.h"

#define Xil_DCacheFlushRange(Addr, Len)        do { (void)(Addr); (void)(Len); } while (0)
#define Xil_DCacheInvalidateRange(Addr, Len)   do { (void)(Addr); (void)(Len); } while (0)
#define Xil_DCacheFlush()                      do { } while (0)
#define Xil_DCacheInvalidate()                 do { } while (0)
#define Xil_ICacheInvalidateRange(Addr, Len)   do { (void)(Addr); (void)(Len); } while (0)
#define Xil_ICacheEnable()                     do { } while (0)
#define Xil_DCacheEnable()                     do { } while (0)

#endif /* XIL_CACHE_H */
