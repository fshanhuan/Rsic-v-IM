#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/gen_storelw.py -- 量 store→load 同地址冒险窗口的宽度

背景（v13 发现）：FreeRTOS 的 `++uxSchedulerSuspended` 之后紧接一次 load，
读回来是**旧值**（tasks.c:2446 的 configASSERT 挂掉）；独立内存测试里
"写一个地址、立刻读回" 4000 次错 3999 次。怀疑 DCache 的 store 命中合并
（DCache.sv:279 `store_req_r && store2_hit`）与后继 load 的响应拍重叠。

这个生成器造一个程序，在 store 与 load 之间插入 N 个 nop（N = 0..5，
另外还有一个"不同地址"的对照），把结果放进 x5..x10，供 sim/tb_mini.sv 校验：

    x5  N=0  期望 0x1111
    x6  N=1  期望 0x2222
    x7  N=2  期望 0x3333
    x8  N=3  期望 0x4444
    x9  N=4  期望 0x5555
    x10 不同地址对照（写 A 读 B，必须读到 B 的旧值 0x0BAD）

用法：
    python3 sw/gen_storelw.py            # 写出 sim/storelw.hex
    vvp sim/build/tb_mini.vvp +prog=sim/storelw.hex \\
        +x5=4369 +x6=8738 +x7=13107 +x8=17476 +x9=21845 +x10=2989
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ---- 指令编码小工具（RISC-V RV32I） ----
def I(op: int, rd: int, f3: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def S(op: int, f3: int, rs1: int, rs2: int, imm: int) -> int:
    im = imm & 0xFFF
    return ((im >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((im & 0x1F) << 7) | op

def U(op: int, rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

def addi(rd: int, rs1: int, imm: int) -> int:  return I(0x13, rd, 0, rs1, imm)
def lui(rd: int, imm20: int) -> int:           return U(0x37, rd, imm20)
def sw(rs2: int, rs1: int, imm: int) -> int:   return S(0x23, 0b010, rs1, rs2, imm)
def lw(rd: int, rs1: int, imm: int) -> int:    return I(0x03, rd, 0b010, rs1, imm)
def nop() -> int:                               return addi(0, 0, 0)

# x1 = DRAM 基址 0x0000_2000（低 16 位口径，避开设代码区）
BASE = 0x00002000
BASE_HI = (BASE + 0x800) >> 12          # lui 的立即数（带进位校正）


def build() -> list[int]:
    p: list[int] = []
    p.append(lui(1, BASE_HI))           # x1 = 0x2000
    p.append(addi(1, 1, BASE & 0xFFF))

    # 三个"哨兵"值先写进去，保证这些行是**驻留**的（否则第一次 store 是 miss，
    # 走的是"写穿透到 DRAM"，不会触发 store-hit 合并这条路径）
    for off, val in ((0x00, 0x0BAD), (0x40, 0x0BAD), (0x80, 0x0BAD),
                     (0xC0, 0x0BAD), (0x100, 0x0BAD), (0x140, 0x0BAD)):
        p.append(lui(2, (val + 0x800) >> 12))
        p.append(addi(2, 2, val & 0xFFF))
        p.append(sw(2, 1, off))
    # 读一遍，让所有行都变成 hit（真正的冒险只在 hit 路径上）
    for off in (0x00, 0x40, 0x80, 0xC0, 0x100, 0x140):
        p.append(lw(3, 1, off))

    # 主体：store → N 个 nop → load 同地址
    cases = [
        (0x00, 0x1111, 5, 0),   # N=0 → x5
        (0x40, 0x2222, 6, 1),   # N=1 → x6
        (0x80, 0x3333, 7, 2),   # N=2 → x7
        (0xC0, 0x4444, 8, 3),   # N=3 → x8
        (0x100, 0x5555, 9, 4),  # N=4 → x9
    ]
    for off, val, rd, gap in cases:
        p.append(lui(2, (val + 0x800) >> 12))
        p.append(addi(2, 2, val & 0xFFF))
        p.append(sw(2, 1, off))
        for _ in range(gap):
            p.append(nop())
        p.append(lw(rd, 1, off))

    # 对照：写 A、读 B（B 里仍是 0x0BAD），验证"不是所有 load 都错"
    p.append(lui(2, (0x1111 + 0x800) >> 12))
    p.append(addi(2, 2, 0x1111 & 0xFFF))
    p.append(sw(2, 1, 0x00))
    p.append(lw(10, 1, 0x140))

    # ★ 结束方式：`jal x0, 0` 自旋，靠测试台的 +cycles=N 超时把寄存器 dump 出来
    #   （tb_mini 在超时路径上同样会执行 +x5..+x10 的校验）。不用 x10=0x600D 标记，
    #   因为 x10 被上面那条对照 load 占用了。
    p.append(I(0x6F, 0, 0, 0, 0))       # jal x0, 0
    return p


def main() -> int:
    prog = build()
    out = ROOT / "sim" / "storelw.hex"
    with out.open("w", encoding="ascii", newline="\n") as f:
        for w in prog:
            f.write(f"{w:08x}\n")
    print(f"wrote {out}  ({len(prog)} words)")
    print("expect: +x5=4369 +x6=8738 +x7=13107 +x8=17476 +x9=21845 +x10=2989")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
