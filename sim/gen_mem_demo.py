#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_mem_demo.py — 生成「存储器专题」课堂演示程序 sim/mem_demo.hex

演示目标（每条对应一张波形图）：
  ① store  → DRAM（写直达，perip_wen 单拍脉冲）
  ② load   → DCache miss：发一次 DRAM 读、hold 一拍、回填
  ③ load   → DCache hit ：总线上**没有**第二次读
  ④ load   → IROM 数据窗口 0x0002_0000：数据口能读到取指侧那块 BRAM
  ⑤ store  → IROM 数据窗口（b_wen 单拍；同一拍 DRAM 的 wen 必须为 0）
  ⑥ load   → 回读刚才写进窗口的字（0x12345678）
  ⑦ load   → MMIO TXSTAT（不可缓存，读直通外设）
  ⑧ store  → MMIO TXDATA = 'A'（UART 起始位/整帧）
  ⑨ store  → MMIO LED（外设寄存器，不占存储器）
  ⑩ load   → 地址 0 走数据口 = DRAM[0]（与取指口的 IROM[0] 是两回事）
  ⑪⑫ store → 把两条指令写进 IROM 的 0x1000/0x1004
  ⑬ jalr   → 跳进刚写进去的代码，执行 addi a5,zero,0x7b → a5=0x7b
     （这就是 shell 的 load/run 通路：数据口写代码区，取指口立刻执行）

输出格式：每行一个 32 位字（8 位小写十六进制），与 sim/*.hex 一致。
用法：python3 sim/gen_mem_demo.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "mem_demo.hex")

RN = dict(zero=0, ra=1, sp=2, gp=3, tp=4, t0=5, t1=6, t2=7, s0=8, s1=9,
          a0=10, a1=11, a2=12, a3=13, a4=14, a5=15, a6=16, a7=17,
          s2=18, s3=19, s4=20, s5=21, s6=22, s7=23, s8=24, s9=25, s10=26, s11=27,
          t3=28, t4=29, t5=30, t6=31)
R = lambda n: RN[n] if isinstance(n, str) else n


def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (R(rs2) << 20) | (R(rs1) << 15) | (f3 << 12) | (R(rd) << 7) | op


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (R(rs1) << 15) | (f3 << 12) | (R(rd) << 7) | op


def s_type(imm, rs2, rs1, f3, op):
    i = imm & 0xFFF
    return ((i >> 5) << 25) | (R(rs2) << 20) | (R(rs1) << 15) | (f3 << 12) | ((i & 0x1F) << 7) | op


def b_type(imm, rs2, rs1, f3):
    i = imm & 0x1FFF
    return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (R(rs2) << 20) | (R(rs1) << 15) \
        | (f3 << 12) | (((i >> 1) & 0xF) << 8) | (((i >> 11) & 1) << 7) | 0x63


def u_type(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (R(rd) << 7) | op


lui   = lambda rd, imm20: u_type(imm20, rd, 0x37)
addi  = lambda rd, rs1, imm: i_type(imm, rs1, 0, rd, 0x13)
andi  = lambda rd, rs1, imm: i_type(imm, rs1, 7, rd, 0x13)
lw    = lambda rd, imm, rs1: i_type(imm, rs1, 2, rd, 0x03)
sw    = lambda rs2, imm, rs1: s_type(imm, rs2, rs1, 2, 0x23)
bne   = lambda rs1, rs2, imm: b_type(imm, rs2, rs1, 1)
jalr  = lambda rd, rs1, imm: i_type(imm, rs1, 0, rd, 0x67)
jal   = lambda rd, imm: (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) \
    | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (R(rd) << 7) | 0x6F
nop   = lambda: addi("zero", "zero", 0)

# -----------------------------------------------------------------------------
# 程序：地址 = 代码下标 * 4
# -----------------------------------------------------------------------------
prog = [
    # ---- 基址准备 ----
    lui("t0", 0x10),             # 0x00 t0 = 0x0001_0000  (DRAM 数据区)
    lui("t1", 0x20),             # 0x04 t1 = 0x0002_0000  (IROM 数据窗口)
    lui("t2", 0x10000),          # 0x08 t2 = 0x1000_0000  (MMIO)
    # ---- ① store / ② load miss / ③ load hit ----
    lui("t3", 0x5A5AA),          # 0x0c
    addi("t3", "t3", 0x5A5),     # 0x10 t3 = 0x5A5A_A5A5
    sw("t3", 0, "t0"),           # 0x14 ① sw → DRAM[0x10000]
    lw("t4", 0, "t0"),           # 0x18 ② lw → miss（发一次读 + hold + 回填）
    lw("t5", 0, "t0"),           # 0x1c ③ lw → hit（总线不再发读）
    # ---- ④ IROM 数据窗口读 ----
    lw("t6", 0, "t1"),           # 0x20 ④ lw 0x2_0000 = IROM 第 0 个字（本程序第一条）
    # ---- ⑤ 窗口写 / ⑥ 回读 ----
    lui("s0", 0x12345),          # 0x24
    addi("s0", "s0", 0x678),     # 0x28 s0 = 0x1234_5678
    sw("s0", 0x400, "t1"),       # 0x2c ⑤ sw → IROM[0x100]（窗口写，b_wen 单拍）
    lw("s1", 0x400, "t1"),       # 0x30 ⑥ lw → 0x1234_5678（经 b_rdata 回填）
    # ---- ⑦ MMIO 读 / ⑧ MMIO 写（UART）----
    lw("a0", 4, "t2"),           # 0x34 ⑦ lw TXSTAT（0x1000_0004）
    addi("a1", "zero", 0x41),    # 0x38 a1 = 'A'
    sw("a1", 0, "t2"),           # 0x3c ⑧ sw TXDATA → 起始位
    nop(),                       # 0x40 给 busy 起来留两拍
    nop(),                       # 0x44
    lw("a2", 4, "t2"),           # 0x48 轮询 TXSTAT.busy
    andi("a2", "a2", 1),         # 0x4c
    bne("a2", "zero", -8),       # 0x50 → 0x48
    # ---- ⑨ LED / ⑩ 数据口地址 0 ----
    addi("a3", "zero", 0x2A),    # 0x54
    sw("a3", 0x10, "t2"),        # 0x58 ⑨ LED = 0x010_1010
    lw("a4", 0, "zero"),         # 0x5c ⑩ 数据口 addr=0 → DRAM[0]（≠ 取指口 IROM[0]）
    # ---- ⑪⑫⑬ 自改写：写代码区 → 跳过去执行 ----
    # ★ 踩过的坑（第一次跑就踩了，留着当课堂例子）：
    #   `sw s2, 0x1000(t1)` 看着对，其实 0x1000 = 4096 **超出 S 型立即数范围**（±2048），
    #   汇编器/我的编码器都会把它截成 0 —— 结果写到了 0x2_0000 即 IROM 第 0 个字，
    #   把第一条指令（lui t0,0x10）覆盖成了 addi a5,zero,0x7b。程序没崩，反而"s1 过后
    #   a5 莫名其妙等于 0x7b"，差点被当成 PASS。正确写法：先把 0x2_1000 装进一个基址寄存器。
    lui("s5", 0x21),             # 0x60 s5 = 0x0002_1000 = 0x2_0000 + 0x1000
    lui("s2", 0x07b00),          # 0x64
    addi("s2", "s2", 0x793),     # 0x68 s2 = 0x07B0_0793 = addi a5,zero,0x7b
    sw("s2", 0, "s5"),           # 0x6c ⑪ 写入 IROM 字 [0x400]（取指地址 0x1000）
    addi("s3", "zero", 0x6F),    # 0x70 s3 = 0x0000_006F = jal x0,0
    sw("s3", 4, "s5"),           # 0x74 ⑫ 写入 IROM 字 [0x401]（取指地址 0x1004）
    lw("s6", 0, "s5"),           # 0x78 ⑬ 回读校验：必须读到 0x07B0_0793
    #    ★ 这条回读不只是校验：它把 jalr 往后推了 4 拍，让两次窗口写**一定**先落盘。
    #      没有它，流水线里已经预取过 0x1000/0x1004 的旧内容（全 0），跳过去会先执行到
    #      旧值 —— 这是"改代码区之后必须让预取失效"的真实现象（课堂上正好讲 fence.i）。
    lui("s4", 1),                # 0x7c s4 = 0x0000_1000（目标取指地址）
    jalr("zero", "s4", 0),       # 0x80 ⑭ 跳进刚写进去的代码
    nop(),                       # 0x84
]

# 0x1000 / 0x1004 由程序自己写入；hex 里补 0 只是让 $readmemh 的行号连续
PROG_WORDS = 0x88 // 4 + 1
TAIL_TO = 0x1008 // 4 + 1
words = prog + [0] * (TAIL_TO - PROG_WORDS)

with open(OUT, "w", encoding="ascii", newline="\n") as f:
    for w in words:
        f.write("%08x\n" % (w & 0xFFFFFFFF))

print("wrote %s  (%d words = %d bytes)" % (OUT, len(words), len(words) * 4))
for i, w in enumerate(words[:len(prog)]):
    print("  0x%02x: %08x" % (i * 4, w))
