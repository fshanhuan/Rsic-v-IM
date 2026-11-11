#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_bus_smoke.py — 生成 sim/bus_smoke.hex：A1 总线化的板级冒烟测试程序。

为什么要专门写一个：
  改了 board_top 的译码结构（A1 把散落的 mux 收进 board/soc_bus.sv），必须有
  一个**不依赖 C 工具链**的板级程序去踩三条通路，否则只能用 CPU 回归（那条
  路径根本不经过 board_top）。

它踩的四件事（每件都对应总线的一处改动）：
  ① DRAM 写 + 读回      → we_dram / re_dram / 默认从设备
  ② 代码窗口读回指令字   → 读 mux 的 hit_code 分支（**必须用 hit_*，不能用 sel_*：
                            数据在请求的下一拍才有效，那时 ren 已撤）
  ③ 代码窗口写           → we_code（TB 直接查 BRAM 数组验证，绕开 DCache 歧义）
  ④ MMIO 写 LED + 读 TXSTAT + 写 TXDATA → we_mmio / hit_mmio / mmio_idx

判据（由 sim/tb_bus.sv 检查）：
  · UART 收到 "OK"
  · led == 7'h2A
  · DRAM 字 0x1000 == 0xCAFE0123
  · IMEM 字 0x100   == 0xBEEF0456      （0x100 字 = 0x400 字节 = 窗口 0x2_0400）

用法：
  python sim/gen_bus_smoke.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "bus_smoke.hex")

RN = dict(zero=0, ra=1, sp=2, gp=3, tp=4, t0=5, t1=6, t2=7, s0=8, s1=9,
          a0=10, a1=11, a2=12, a3=13, a4=14, a5=15, a6=16, a7=17,
          s2=18, s3=19, s4=20, s5=21, s6=22, s7=23, s8=24, s9=25, s10=26, s11=27,
          t3=28, t4=29, t5=30, t6=31)
R = lambda n: RN[n] if isinstance(n, str) else n


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (R(rs1) << 15) | (f3 << 12) | (R(rd) << 7) | op


def s_type(imm, rs2, rs1, f3, op):
    return (((imm & 0xFFF) >> 5) << 25) | (R(rs2) << 20) | (R(rs1) << 15) | \
           (f3 << 12) | ((imm & 0x1F) << 7) | op


def b_type(imm, rs2, rs1, f3, op=0x63):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (R(rs2) << 20) | (R(rs1) << 15) | (f3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op


def u_type(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (R(rd) << 7) | op


def j_type(imm, rd, op=0x6F):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (R(rd) << 7) | op


lui = lambda rd, imm20: u_type(imm20, rd, 0x37)
addi = lambda rd, rs1, imm: i_type(imm, rs1, 0, rd, 0x13)
andi = lambda rd, rs1, imm: i_type(imm, rs1, 7, rd, 0x13)
lw = lambda rd, imm, rs1: i_type(imm, rs1, 2, rd, 0x03)
sw = lambda rs2, imm, rs1: s_type(imm, rs2, rs1, 2, 0x23)
bne = lambda rs1, rs2, label: ("bne", rs1, rs2, label)
j = lambda label: ("j", label)


def imm20_lo(v):
    """把 32 位常量拆成 (lui 的 imm20, addi 的 12 位有符号) 两半。"""
    lo = v & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
        hi = ((v + 0x1000) >> 12) & 0xFFFFF
    else:
        hi = (v >> 12) & 0xFFFFF
    return hi, lo


# ---------------------------------------------------------------- 常量
# ★ 必须与下面 prog 的**第 0 个字**一致：第 0 条是 `lui t6, 0x10000`。
#   早先这里误写成 lui t0,0x10，程序读回第 0 个字后比不过，直接跳 fail ——
#   仿真里表现为"DRAM 写成功、代码窗口读也成功，却报 FAIL"，很难一眼看出。
W0 = u_type(0x10000, 31, 0x37)      # = 0x10000FB7
DRAM_VAL = 0xCAFE0123
CODE_VAL = 0xBEEF0456

# ---------------------------------------------------------------- 程序（带标签）
prog = []
lbl = {}


def L(name):
    lbl[name] = len(prog)


prog += [
    lui("t6", 0x10000),             # 0x00 t6 = 0x1000_0000（先备好，fail 也能用）
    lui("t0", 0x10),                # 0x04 t0 = 0x0001_0000（DRAM 数据区）
]
hi, lo = imm20_lo(DRAM_VAL)
prog += [
    lui("t1", hi),                  # 0x08
    addi("t1", "t1", lo),           # 0x0c t1 = 0xCAFE_0123
    sw("t1", 0, "t0"),              # 0x10 ① DRAM 写
    lw("t2", 0, "t0"),              # 0x14 ① DRAM 读回
    bne("t1", "t2", "fail"),        # 0x18
    lui("t3", 0x20),                # 0x1c t3 = 0x0002_0000（代码窗口）
    lw("t4", 0, "t3"),              # 0x20 ② 读 IMEM 第 0 个字（应等于 W0）
]
hi, lo = imm20_lo(W0)
prog += [
    lui("t5", hi),                  # 0x24
    addi("t5", "t5", lo),           # 0x28
    bne("t4", "t5", "fail"),        # 0x2c
]
hi, lo = imm20_lo(CODE_VAL)
prog += [
    lui("a4", hi),                  # 0x30
    addi("a4", "a4", lo),           # 0x34 a4 = 0xBEEF_0456
    sw("a4", 0x400, "t3"),          # 0x38 ③ 写窗口 0x2_0400（TB 查 BRAM 数组）
    addi("a1", "zero", 0x2A),       # 0x3c
    sw("a1", 0x10, "t6"),           # 0x40 ④ LED = 0x2A
]

# ---- 打印 'O' 与 'K'：读 TXSTAT 等 busy 清零再写，否则 uart_tx 忙时会丢字符 ----
# ★ 每个字符占 86.8 us（115200），轮询大约 4340 拍 —— 这是正常的，不是性能问题。
#   早期把 $time 的单位当成 ns 读（其实是精度单位 ps），误以为"轮询花了 87 ms"，
#   于是改成固定延时，反而踩了 addi 立即数只有 12 位有符号的坑（2500 → -1596）。
#   结论：$time 打印的是**精度单位**（本 TB 是 1ps），别拿它当 ns 用。
prog += []
L("po")
prog += [
    lw("a3", 4, "t6"),              # 读 TXSTAT
    andi("a3", "a3", 1),
    bne("a3", "zero", "po"),
    addi("a2", "zero", 0x4F),       # 'O'
    sw("a2", 0, "t6"),
]
L("pk")
prog += [
    lw("a3", 4, "t6"),
    andi("a3", "a3", 1),
    bne("a3", "zero", "pk"),
    addi("a2", "zero", 0x4B),       # 'K'
    sw("a2", 0, "t6"),
    j("done"),
]

L("fail")
prog += [
    addi("a1", "zero", 0x7F),
    sw("a1", 0x10, "t6"),           # LED = 0x7F
]

L("done")
# ★ 停机 magic 写 0x1000_0100 而不是 0x1000_00F0：
#   0xF0 的 mmio_idx = addr[4:2] & 7 = 4 → **撞上 LED**，会把 LED 写成 0x5A。
#   mmio_idx 只有 3 位是已知缺陷（见 rtl/soc_map.sv 的注释），0x1000_0100 的
#   addr[15]=1，不落 MMIO，落到 DRAM，没有副作用。
hi, lo = imm20_lo(0x5A5A5A5A)
prog += [
    lui("a6", hi),
    addi("a6", "a6", lo),
    sw("a6", 0x100, "t6"),          # 停机 magic（不碰 MMIO 寄存器）
]

L("halt")
prog += [j("halt")]

# ---------------------------------------------------------------- 两遍：解析标签
out = []
for i, ins in enumerate(prog):
    if isinstance(ins, tuple):
        kind = ins[0]
        if kind == "bne":
            _, rs1, rs2, label = ins
            off = (lbl[label] - i) * 4
            out.append(b_type(off, rs2, rs1, 0b001))
        elif kind == "j":
            _, label = ins
            off = (lbl[label] - i) * 4
            out.append(j_type(off, 0))
        else:
            raise SystemExit("bad pseudo: %r" % (ins,))
    else:
        out.append(ins)

words = out
pad = (-len(words)) % 4
words += [0x00000013] * pad       # nop 填充到 16B 对齐

with open(OUT, "w", encoding="ascii", newline="\n") as f:
    for w in words:
        f.write("%08x\n" % (w & 0xFFFFFFFF))

print("wrote %s : %d words (%d bytes)" % (OUT, len(words), len(words) * 4))
for i, w in enumerate(words):
    print("  %04x: %08x" % (i * 4, w))
