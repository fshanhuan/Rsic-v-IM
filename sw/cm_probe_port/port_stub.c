/* =============================================================================
 * sw/cm_probe_port/port_stub.c -- 对拍探针的**符号桩**（x86 / rv32 共用）
 * -----------------------------------------------------------------------------
 * core_util.c 的 get_seed_32() 要引用 seed*_volatile，探针的 main 要引用
 * portable_init/fini —— 正常构建里由 core_portme.c 提供。对拍时只要一组固定值
 * （与 CoreMark 的 2K 性能跑一致：seed1=0, seed2=0, seed3=0x66, seed4=ITERATIONS,
 * seed5=0 → execs=ALL_ALGORITHMS_MASK）。
 * ★ 必须两边**完全一致**，否则对拍没有意义。
 * ============================================================================= */
#include "coremark.h"

ee_u32 default_num_contexts = 1;

volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = 1;
volatile ee_s32 seed5_volatile = 0;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

/* ★ ee_printf 由 sw/cm_probe_port/ee_mini.c 提供（两边同一份格式化逻辑） */
