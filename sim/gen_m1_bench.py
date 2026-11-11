#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_m1_bench.py — 生成 sim/m1_bench.hex：量 v15「M1 命中前递」到底省不省周期。

思路：让 DCache 里那一行**先驻留**（先 store + 两次 load 把它填实），
然后跑一个 400 次的循环，循环体是教科书式的 load-use：

    loop: lw   t4, 0(t0)      # 命中（行已驻留）→ M1 探测口本拍就能给数据
          add  t5, t5, t4     # 消费者，紧跟其后 → 没有前递就要多停 1 拍
          addi t3, t3, -1
          bne  t3, zero, loop

同一份 hex 配 `sim/tb_mini.sv` 跑两次即可对比：
  A) 原样跑                        → 走 M1 快路
  B) 把 DCache 的 m1_hit 强制 1'b0 → 退回 M2 路径
两者 cyc 之差 / 循环次数 = 每次 load-use 省下的拍数。

结尾 x10 = 0x600D（tb_mini 的停机标记）。
用法：python sim/gen_m1_bench.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "m1_bench.hex")

RN = dict(zero=0, ra=1, sp=2, gp=3, tp=4, t0=5, t1=6, t2=7, s0=8, s1=9,
          a0=10, a1=11, a2=12, a3=13, a4=14, a5=15, a6=16, a7=17,
          s2=18, s3=19, s4=20, s5=21, s6=22, s7=23, s8=24, s9=25, s10=26, s11=27,
          t3=28, t4=29, t5=30, t6=31)
R = lambda n: RN[n] if isinstance(n, str) else n

r_type = lambda f7, rs2, rs1, f3, rd, op: (f7 << 25) | (R(rs2) << 20) | (R(rs1) << 15) | (f3 << 12) | (R(rd) << 7) | op
i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | (R(rs1) << 15) | (f3 << 12) | (R(rd) << 7) | op
s_type = lambda imm, rs2, rs1, f3, op: (((imm & 0xFFF) >> 5) << 25) | (R(rs2) << 20) | (R(rs1) << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op
b_type = lambda imm, rs2, rs1, f3: ((((imm & 0x1FFF) >> 12) & 1) << 31) | ((((imm & 0x1FFF) >> 5) & 0x3F) << 25) | (R(rs2) << 20) | (R(rs1) << 15) | (f3 << 12) | ((((imm & 0x1FFF) >> 1) & 0xF) << 8) | ((((imm & 0x1FFF) >> 11) & 1) << 7) | 0x63
u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | (R(rd) << 7) | op

lui  = lambda rd, imm20: u_type(imm20, rd, 0x37)
addi = lambda rd, rs1, imm: i_type(imm, rs1, 0, rd, 0x13)
lw   = lambda rd, imm, rs1: i_type(imm, rs1, 2, rd, 0x03)
sw   = lambda rs2, imm, rs1: s_type(imm, rs2, rs1, 2, 0x23)
bne  = lambda rs1, rs2, imm: b_type(imm, rs2, rs1, 1)
add  = lambda rd, rs1, rs2: r_type(0, rs2, rs1, 0, rd, 0x33)
nop  = lambda: addi("zero", "zero", 0)
jal0 = lambda: (((0 >> 20) & 1) << 31) | (((0 >> 1) & 0x3FF) << 21) | (((0 >> 11) & 1) << 20) \
    | (((0 >> 12) & 0xFF) << 12) | (0 << 7) | 0x6F

N = 400

prog = [
    lui("t0", 0x10),           # 0x00 t0 = 0x0001_0000
    lui("t1", 0x5A5AA),        # 0x04
    addi("t1", "t1", 0x5A5),   # 0x08 t1 = 0x5A5A_A5A5
    sw("t1", 0, "t0"),         # 0x0c 写直达（不分配）
    lw("t2", 0, "t0"),         # 0x10 未命中 → 发读 + 回填这一行
    lw("t2", 0, "t0"),         # 0x14 命中
    nop(),                     # 0x18 让回填落定
    nop(),                     # 0x1c
    addi("t3", "zero", N),     # 0x20 循环计数
    lw("t4", 0, "t0"),         # 0x24 ← loop：命中，M1 探测口可当拍给数据
    add("t5", "t5", "t4"),     # 0x28 load-use 消费者
    addi("t3", "t3", -1),      # 0x2c
    bne("t3", "zero", -12),    # 0x30 → 0x24
    # ★ 踩坑记录：0x600D 超出 12 位有符号立即数（±2048），`addi a0,zero,0x600D`
    #   会被截成 0x00D（实测 x10 拿到 0x0d、tb_mini 认不出停机标记 → TIMEOUT）。
    #   分成 lui + addi 两步构造。
    lui("a0", 0x6),            # 0x34 a0 = 0x0000_6000
    addi("a0", "a0", 0x00D),   # 0x38 a0 = 0x0000_600D（tb_mini 停机标记）
    nop(),                     # 0x3c
    jal0(),                    # 0x40 走完停在这
]

with open(OUT, "w", encoding="ascii", newline="\n") as f:
    for w in prog:
        f.write("%08x\n" % (w & 0xFFFFFFFF))

print("wrote %s  (%d words)" % (OUT, len(prog)))
for i, w in enumerate(prog):
    print("  0x%02x: %08x" % (i * 4, w))
