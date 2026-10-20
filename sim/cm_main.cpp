// =============================================================================
// sim/cm_main.cpp -- tb_cm 的 Verilator 主循环
// -----------------------------------------------------------------------------
// 为什么自己写 main 而不用 `--binary --main`：
//   1) 需要在 C++ 侧精确控制"每个循环 = 一个时钟周期"，并统计拍数；
//   2) 需要设一个拍数上限（CoreMark 要跑几亿拍，卡死时能自己退出）；
//   3) 避免 --timing（Verilator 的定时模式会显著变慢）。
//
// 编译（由 sw/run_coremark.sh 调用）：
//   verilator --cc --exe --build -O3 -Irtl --top-module tb_cm \
//             rtl/*.sv board/sync_mem.sv sim/tb_cm.sv sim/cm_main.cpp
// =============================================================================
#include "Vtb_cm.h"
#include "verilated.h"

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void tick(Vtb_cm *tb)
{
    tb->clk = 1;
    tb->eval();
    tb->clk = 0;
    tb->eval();
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);

    vluint64_t max_cycles = 1500000000ull; /* 50 MHz 下 30 s，够 3 倍余量 */
    for (int i = 1; i < argc; i++)
        if (std::strncmp(argv[i], "+max=", 5) == 0)
            max_cycles = std::strtoull(argv[i] + 5, nullptr, 0);

    Vtb_cm *tb = new Vtb_cm;

    tb->clk = 0;
    tb->eval();

    vluint64_t cyc = 0;
    int last_pct = -1;
    while (!tb->done && cyc < max_cycles)
    {
        tick(tb);
        cyc++;

        /* 每 10% 打到 stderr（stdout 留给程序输出，避免混在一起） */
        int pct = (int)((cyc * 10ull) / max_cycles);
        if (pct != last_pct && pct >= 1)
        {
            last_pct = pct;
            std::fprintf(stderr, "[sim] %llu cycles (%d%%)\n",
                         (unsigned long long)cyc, pct * 10);
        }
    }

    bool finished = tb->done;
    /* done 之后再多跑几拍：tb 里的收尾诊断（比如 [MEM] DRAM 头部 dump）挂在
     * `if (done)` 的时序块上，提前退出会让它一次都不执行。 */
    for (int i = 0; i < 4; i++)
        tick(tb);
    std::fprintf(stderr, "\n[sim] done=%d  cycles=%llu\n",
                 (int)finished, (unsigned long long)cyc);
    if (!finished)
        std::fprintf(stderr, "[sim] !! 撞到拍数上限 %llu，程序没跑完\n",
                     (unsigned long long)max_cycles);

    tb->final();
    delete tb;
    return finished ? 0 : 2;
}
