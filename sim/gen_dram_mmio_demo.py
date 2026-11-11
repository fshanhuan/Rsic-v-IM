#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_dram_mmio_demo.py — 生成 sim/dram_mmio.hex：专给 W3(DRAM)/W4(MMIO) 两张波形图用。

和 mem_demo.hex 的区别：这份**只**做两件事，且都做得更全 ——
  DRAM：sw / sb / sh 三种宽度写同一个字（mask=10/00/01），再 lw 读回、再 lw 命中
  MMIO：读 TXSTAT → 写 TXDATA（拉高 busy）→ 再读 TXSTAT → 写 LED
这样两张图各自在 15~20 拍内把"所有端口都动一遍"演完，不用截长窗口。

用法（配 sim/tb_mem.sv，它会覆盖 IROM 镜像、另存 CSV）：
  python sim/gen_dram_mmio_demo.py
  vvp sim/build/tb_mem.vvp +prog=sim/dram_mmio.hex \
      +csv=sim/build/mem_trace_io.csv +stop=240 +nochk
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "dram_mmio.hex")

RN = dict(zero=0, ra=1, sp=2, gp=3, tp=4, t0=5, t1=6, t2=7, s0=8, s1=9,
          a0=10, a1=11, a2=12, a3=13, a4=14, a5=15, a6=16, a7=17,
          s2=18, s3=19, s4=20, s5=21, s6=22, s7=23, s8=24, s9=25, s10=26, s11=27,
          t3=28, t4=29, t5=30, t6=31)
R = lambda n: RN[n] if isinstance(n, str) else n

i_type = lambda imm, rs1, f3, rd, op: ((imm & 0xFFF) << 20) | (R(rs1) << 15) | (f3 << 12) | (R(rd) << 7) | op
s_type = lambda imm, rs2, rs1, f3, op: (((imm & 0xFFF) >> 5) << 25) | (R(rs2) << 20) | (R(rs1) << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op
u_type = lambda imm20, rd, op: ((imm20 & 0xFFFFF) << 12) | (R(rd) << 7) | op

lui  = lambda rd, imm20: u_type(imm20, rd, 0x37)
addi = lambda rd, rs1, imm: i_type(imm, rs1, 0, rd, 0x13)
lw   = lambda rd, imm, rs1: i_type(imm, rs1, 2, rd, 0x03)
sw   = lambda rs2, imm, rs1: s_type(imm, rs2, rs1, 2, 0x23)
sb   = lambda rs2, imm, rs1: s_type(imm, rs2, rs1, 0, 0x23)
sh   = lambda rs2, imm, rs1: s_type(imm, rs2, rs1, 1, 0x23)
nop  = lambda: addi("zero", "zero", 0)
jal0 = lambda: 0x0000006F

prog = [
    # ---------------- DRAM：三种宽度的写 ----------------
    lui("t0", 0x10),            # 0x00 t0 = 0x0001_0000
    lui("t1", 0x12345),         # 0x04
    addi("t1", "t1", 0x678),    # 0x08 t1 = 0x1234_5678
    sw("t1", 0, "t0"),          # 0x0c ① sw：mask=2'b10，整字写
    addi("t5", "zero", 0xAA),   # 0x10
    sb("t5", 1, "t0"),          # 0x14 ② sb：mask=2'b00，addr[1:0]=1 → 改 bits[15:8]
    lui("t6", 0x55555),         # 0x18
    addi("t6", "t6", 0x555),    # 0x1c t6 = 0x5555_5555
    sh("t6", 2, "t0"),          # 0x20 ③ sh：mask=2'b01，addr[1]=1 → 改高半字
    lw("t2", 0, "t0"),          # 0x24 ④ 回读 0x5555_AA78（miss → 发读 → 回填）
    lw("t3", 0, "t0"),          # 0x28 ⑤ 再读（hit：总线零动作）
    # ---------------- MMIO ----------------
    lui("t4", 0x10000),         # 0x2c t4 = 0x1000_0000
    lw("a0", 4, "t4"),          # 0x30 ⑥ 读 TXSTAT（busy=0）
    addi("a1", "zero", 0x41),   # 0x34 a1 = 'A'
    sw("a1", 0, "t4"),          # 0x38 ⑦ 写 TXDATA → uart_tx 起始位，busy 拉高
    lw("a0", 4, "t4"),          # 0x3c ⑧ 再读 TXSTAT（busy=1）
    addi("a2", "zero", 0x2A),   # 0x40
    sw("a2", 0x10, "t4"),       # 0x44 ⑨ 写 LED = 0x2A
    # ---------------- 停机标记（tb 只认 x10=0x600D） ----------------
    lui("a0", 0x6),             # 0x48
    addi("a0", "a0", 0x00D),    # 0x4c x10 = 0x0000_600D
    nop(),                      # 0x50
    jal0(),                     # 0x54
]

with open(OUT, "w", encoding="ascii", newline="\n") as f:
    for w in prog:
        f.write("%08x\n" % (w & 0xFFFFFFFF))

print("wrote %s  (%d words)" % (OUT, len(prog)))
for i, w in enumerate(prog):
    print("  0x%02x: %08x" % (i * 4, w))
