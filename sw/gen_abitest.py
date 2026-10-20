#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/gen_abitest.py -- 寄存器跨函数调用保持性测试（RISC-V ABI）

背景（v13 发现）：CoreMark 在 `lw a5,-1776(s8)` 上陷入，而 s8 本应是
`lui s8,0x11` 得到的 0x11000，实际却是 0x10542（一个 rodata 裸地址）。
它正好在调用 `__ledf2`（软双精度比较）**之后** —— 按 ABI，被调用者不得修改
s0-s11，所以要么是 libgcc 有问题，要么是**寄存器堆/写回通路**有问题。

本生成器造一个纯汇编程序：
  1) 把 x5..x7 / x9..x31 全写成互不相同的常量；
  2) 调一个会压栈/出栈、只用 t 寄存器的函数（模拟真实 callee）；
  3) 回来逐个比对；每个不一致就往 x10 加 1；
  4) 结束：x10 = 出错个数（期望 0）。

tb_mini 直接 `+x10=0` 判定。

用法：
    python3 sw/gen_abitest.py
    vvp sim/build/tb_mini.vvp +prog=sim/abitest.hex +cycles=2000 +x10=0
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ---- RV32I 编码 ----
def I(op, rd, f3, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def S(op, f3, rs1, rs2, imm):
    im = imm & 0xFFF
    return ((im >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((im & 0x1F) << 7) | op

def B(op, f3, rs1, rs2, imm):
    im = imm & 0x1FFF
    return (((im >> 12) & 1) << 31) | (((im >> 5) & 0x3F) << 25) | (rs2 << 20) | \
           (rs1 << 15) | (f3 << 12) | (((im >> 1) & 0xF) << 8) | (((im >> 11) & 1) << 7) | op

def J(op, rd, imm):
    im = imm & 0x1FFFFF
    return (((im >> 20) & 1) << 31) | (((im >> 1) & 0x3FF) << 21) | \
           (((im >> 11) & 1) << 20) | (((im >> 12) & 0xFF) << 12) | (rd << 7) | op

def addi(rd, rs1, imm): return I(0x13, rd, 0, rs1, imm)
def add(rd, rs1, rs2):  return (0 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33
def sw(rs2, rs1, imm):  return S(0x23, 0b010, rs1, rs2, imm)
def lw(rd, rs1, imm):   return I(0x03, rd, 0b010, rs1, imm)
def bne(rs1, rs2, imm): return B(0x63, 0b001, rs1, rs2, imm)
def beq(rs1, rs2, imm): return B(0x63, 0b000, rs1, rs2, imm)
def jal(rd, imm):       return J(0x6F, rd, imm)

# 参与测试的寄存器（跳过 x0/x2(sp)/x3(gp)/x4(tp)/x8(s0)：
#   sp 要留给压栈，gp/tp 不用，x8 在某些 ABI 里是 frame pointer）
REGS = [5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]

# 每个寄存器一个互不相同的常量（12 位立即数能装下，避免 lui 干扰）
VALS = {r: (0x100 + i * 0x11) for i, r in enumerate(REGS)}


def build():
    p: list[int] = []

    # ---- 1) 建立初始值 ----
    for r in REGS:
        p.append(addi(r, 0, VALS[r]))

    # ---- 2) 调用被测函数（会压栈/出栈、只用 t 寄存器） ----
    #   jal ra, func  —— func 紧跟在主体之后
    jal_idx = len(p)
    p.append(jal(1, 0))          # 占位，稍后回填
    after_call = len(p)

    # ---- 3) 逐个比对；不一致就 addi x10, x10, 1 ----
    checks = []
    p.append(addi(10, 0, 0))     # x10 = 0
    for r in REGS:
        p.append(addi(5, 0, VALS[r]))     # x5 = 期望值（t0 可随便用）
        checks.append((len(p), r))
        p.append(bne(r, 5, 0))            # 占位，稍后回填到 skip
        p.append(addi(10, 10, 1))         # 不一致 → 计数
        # 回填：跳过 addi
    # 计算每个 bne 的跳转目标（跳到各自的下一条 addi 之后）
    for i, (pos, r) in enumerate(checks):
        target = pos + 2                    # 跳过 addi(10,10,1)
        p[pos] = bne(r, 5, (target - pos) * 4)

    # ---- 4) 自旋（x10 就是结果，tb 直接查） ----
    p.append(jal(0, 0))

    # ---- 5) 被测函数：压栈 ra、写读一个局部、只碰 t 寄存器 ----
    func_off = (len(p) - after_call) * 4    # 相对 after_call 的字节偏移
    # 注意 jal 的偏移是相对 jal 所在指令
    p[jal_idx] = jal(1, (after_call - jal_idx) * 4)

    # func 本体
    p.append(addi(2, 2, -16))       # sp -= 16
    p.append(sw(1, 2, 12))          # 存 ra
    p.append(addi(5, 0, 0x55))      # t0
    p.append(sw(5, 2, 0))
    p.append(lw(6, 2, 0))           # t1 = 读回
    p.append(lw(1, 2, 12))          # 取回 ra
    p.append(addi(2, 2, 16))        # sp += 16
    p.append(addi(0, 0, 0))         # nop
    p.append(I(0x67, 0, 0, 1, 0))   # jalr x0, 0(ra) = ret
    return p


def main() -> int:
    prog = build()
    out = ROOT / "sim" / "abitest.hex"
    with out.open("w", encoding="ascii", newline="\n") as f:
        for w in prog:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    print(f"wrote {out} ({len(prog)} words)")
    print("expect: +x10=0 （0 = 所有被调用者保存寄存器都完好）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
