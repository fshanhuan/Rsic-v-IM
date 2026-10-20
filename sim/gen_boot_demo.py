#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_boot_demo.py -- 生成"上板验证串口引导"用的演示程序。

为什么单独做一个程序：
  1. 它必须和 IROM 里固化的 prog.hex **写回序列明显不同**，这样 ILA 一眼就能分辨
     "跑的是刚灌进去的程序"还是"跑的是固化在 bitstream 里的旧程序"：
         prog.hex      : x1=0x1000, x2=5, x3=7, x4=12, x5=35 ...
         prog_boot_demo: x10=42,   x11=99, x12=127   （全是好认的值）
  2. 它必须**循环**：`jal x0, 0` 跳回 0x0，让三条写回周期性重复。
     否则写回只在启动瞬间出现一次，等 ILA 抓的时候早就过去了（第一次做验证时就差点踩这个坑）。
  3. 不写 ecall：mtvec=0，ecall 会让它变成"每轮都陷入"的循环，白白引入 4 拍重填
     （见 docs/BOOT_UART.md 与 docs/IMPLEMENTATION_v11.md 的波形分析）。

用法：
    python sim/gen_boot_demo.py
    # 产物 sim/prog_boot_demo.hex，可用 _diag/load_uart.ps1 直接灌
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from gen_bench_progs import Prog, OP_I1  # noqa: E402
from gen_exc_progs import write_hex      # noqa: E402


def main():
    p = Prog().at(0)
    p.li(10, 42)        # x10 = 42   （a0，测试台的固定观察口也读它）
    p.li(11, 99)        # x11 = 99
    p.li(12, 127)       # x12 = 127
    p.jal_here(0, 0)    # jal x0, 0 → 跳回 0x0，整段做成死循环

    mem = p.mem()
    write_hex("prog_boot_demo.hex", mem)
    print("  期望 ILA 看到：x10=42(0x2a) x11=99(0x63) x12=127(0x7f)，周期重复")


if __name__ == "__main__":
    main()
