#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_mix_prog.py — 生成「一条无冲突主线」的讲解程序 teach_mix.hex

整段程序就 7 条指令（没有准备段），且**没有任何依赖冲突**：
    addi  ->  load  ->  addi（不读 load 的结果）  ->  mul  ->  branch(taken)
    ->  错误路径 addi（应被冲刷）  ->  ecall

与上一版的区别：③ 从 `addi tp,gp,7`（读 ② 的 load 结果，触发 load-use）
改成 `addi tp,zero,7`（不读），**故本程序没有 load-use 气泡**。
（load-use 本身仍然由 figs 02 的 `teach_loaduse` 演示。）

生成：
    teach/teach_mix.hex

用法：
    python3 teach/gen_mix_prog.py
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "..",
                                "BigBird-CPU-Lab-main", "cdp-tests", "tools"))
from rv_asm import Prog   # noqa: E402


def main():
    p = Prog()

    # 整段程序就是这 8 条；没有准备段。
    #   注意：DRAM 上电全 0，所以 lw 读地址 0 拿到 0。
    #         这对演示 load-use 没有影响（冒险是看“寄存器号撞不撞”，不看数值）。
    p.addi(2, 0, 3)            # 0x00  ① addi  x2(sp) = 3
    p.lw(3, 0, 0)              # 0x04  ② load  x3(gp) = mem[0] = 0
    p.addi(4, 0, 7)            # 0x08  ③ addi  x4(tp) = 7     ← **不读 gp，无 load-use**
    p.mul(5, 4, 2)             # 0x0c  ④ mul   x5(t0) = 7 * 3 = 21
    p.bne(5, 0, 8)             # 0x10  ⑤ branch x5 != 0 → 跳，跳过下一条
    p.addi(10, 0, 0xBAD)       # 0x14     错误路径（应被冲刷掉）
    p.ecall()                  # 0x18     结束

    out = os.path.join(_HERE, "teach_mix.hex")
    with open(out, "w") as f:
        for w in p.words:
            f.write("%08x\n" % (w & 0xFFFFFFFF))
    print("wrote %s  (%d 条指令)" % (out, len(p.words)))
    for i, w in enumerate(p.words):
        print("   %#04x: %08x" % (i * 4, w))


if __name__ == "__main__":
    main()
