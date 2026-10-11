#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_teaching_progs.py — 生成一组「上台讲解」用的小程序（文本 hex，供 tb_iverilog 的
$readmemh 载入）。

每个程序只演示一个机制，配 sim/tb_iverilog.sv 的波形探针，用
    python3 sim/vcd2svg.py wave/teach_<name>.vcd figures/讲解/<name>.svg "<标题>" <拍数>
渲染成流水线时序图。

只新增文件，不改任何 RTL。
"""
import os
import sys

# 复用 cdp-tests 自带的编码器（纯标准库）
sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "BigBird-CPU-Lab-main",
                                "cdp-tests", "tools"))
try:
    from rv_asm import Prog
except Exception:
    Prog = None


def write_hex(prog, path):
    """写文本 hex：每行一个 32bit 字（8 位十六进制），与 sim/prog.hex 同格式。"""
    with open(path, "w") as f:
        for w in prog.words:
            f.write("%08x\n" % (w & 0xFFFFFFFF))
    print("wrote %-28s (%d 条指令)" % (path, len(prog.words)))


def build():
    assert Prog is not None, "找不到 rv_asm.py 编码器"
    here = os.path.dirname(os.path.abspath(__file__))

    # 1) 基本 ALU + 数据前递：连续相关指令，不暂停
    p = Prog()
    p.addi(1, 0, 5)            # x1 = 5
    p.addi(2, 0, 7)            # x2 = 7
    p.add(3, 1, 2)             # x3 = 12   （x1/x2 前递，EXU→EXU）
    p.add(4, 3, 1)             # x4 = 17   （x3 前递）
    p.sub(5, 4, 2)             # x5 = 10
    p.ecall()
    write_hex(p, os.path.join(here, "teach_alu.hex"))

    # 2) load-use 冒险：lw 之后紧跟用它的 add → 暂停
    p = Prog()
    p.addi(1, 0, 16)           # x1 = 0x10（基址）
    p.addi(5, 0, 0x123)        # x5 = 0x123（要写进内存的值）
    p.sw(5, 1, 0)              # mem[0x10] = 0x123
    p.lw(6, 1, 0)              # x6 = mem[0x10]
    p.add(7, 6, 5)             # x7 = x6 + x5  ← 立刻用 x6，触发 load-use 暂停
    p.add(8, 7, 6)             # x8 = x7 + x6
    p.ecall()
    write_hex(p, os.path.join(here, "teach_loaduse.hex"))

    # 3) 分支/跳转 + 重定向冲刷
    p = Prog()
    p.addi(1, 0, 1)            # x1 = 1
    p.addi(2, 0, 1)            # x2 = 1
    p.beq(1, 2, 8)             # x1==x2 → 跳，跳过下一条（错路径被冲刷）
    p.addi(3, 0, 0xFF)         # 不应执行
    p.addi(4, 0, 4)            # x4 = 4
    p.jal(5, 8)                # 跳到 +8，跳过下一条
    p.addi(6, 0, 0xFF)         # 不应执行
    p.addi(7, 0, 7)            # x7 = 7
    p.ecall()
    write_hex(p, os.path.join(here, "teach_branch.hex"))

    # 4) mul：单拍出结果，流水不暂停
    p = Prog()
    p.addi(1, 0, 6)            # x1 = 6
    p.addi(2, 0, 7)            # x2 = 7
    p.mul(3, 1, 2)             # x3 = 42
    p.mul(4, 3, 3)             # x4 = 1764
    p.mulh(5, 1, 2)            # x5 = 高 32 位 = 0
    p.ecall()
    write_hex(p, os.path.join(here, "teach_mul.hex"))

    # 5) div：多拍迭代，MDU busy 冻结整条流水
    p = Prog()
    p.addi(1, 0, 100)          # x1 = 100
    p.addi(2, 0, 7)            # x2 = 7
    p.div(3, 1, 2)             # x3 = 14
    p.ecall()
    write_hex(p, os.path.join(here, "teach_div.hex"))

    # 6) 访存全流程：lui/addi 造地址 → sw → lw（含 DCache miss→fill→hit）
    p = Prog()
    p.addi(1, 0, 32)           # x1 = 0x20
    p.addi(2, 0, 0x55)
    p.sw(2, 1, 0)              # mem[0x20] = 0x55
    p.lw(3, 1, 0)              # x3 = mem[0x20]  （D-Cache 访问）
    p.lw(4, 1, 4)              # x4 = mem[0x24]
    p.ecall()
    write_hex(p, os.path.join(here, "teach_mem.hex"))

    # ---- 下面这些是「循环版」：转起来以后 ICache 命中，稳态 1 IPC，
    #      适合讲解流水线重叠 / 前递 / 暂停 / 多拍 M 扩展 ----

    # 7) 循环做加法（稳态 1 IPC + 数据前递）
    p = Prog()
    p.addi(1, 0, 0)            # 0x00  sum = 0
    p.addi(2, 0, 1)            # 0x04  inc = 1
    p.addi(3, 0, 4)            # 0x08  count = 4
    p.add(1, 1, 2)             # 0x0c  loop: sum += inc（依赖上一轮的 sum → 前递）
    p.addi(3, 3, -1)           # 0x10  count--
    p.bne(3, 0, -8)            # 0x14  → 0x0c
    p.ecall()                  # 0x18
    write_hex(p, os.path.join(here, "teach_loop_alu.hex"))

    # 8) 循环 lw → 立即使用（每轮都触发 load-use 暂停）
    p = Prog()
    p.addi(1, 0, 16)           # 0x00  基址 0x10
    p.addi(5, 0, 0x123)        # 0x04
    p.sw(5, 1, 0)              # 0x08  mem[0x10] = 0x123
    p.addi(3, 0, 4)            # 0x0c  count = 4
    p.lw(6, 1, 0)              # 0x10  loop: x6 = mem[0x10]
    p.add(7, 6, 5)             # 0x14  x7 = x6 + x5 ← load-use 暂停
    p.addi(3, 3, -1)           # 0x18
    p.bne(3, 0, -12)           # 0x1c  → 0x10
    p.ecall()                  # 0x20
    write_hex(p, os.path.join(here, "teach_loop_loaduse.hex"))

    # 9) 循环 mul（单拍出结果）
    p = Prog()
    p.addi(1, 0, 1)            # 0x00
    p.addi(2, 0, 3)            # 0x04
    p.addi(3, 0, 4)            # 0x08
    p.mul(1, 1, 2)             # 0x0c  loop: x1 *= 3
    p.addi(3, 3, -1)           # 0x10
    p.bne(3, 0, -8)            # 0x14
    p.ecall()
    write_hex(p, os.path.join(here, "teach_loop_mul.hex"))

    # 10) 循环 div（每次 32 拍迭代，冻结整条流水）
    p = Prog()
    p.addi(1, 0, 1000)         # 0x00
    p.addi(2, 0, 7)            # 0x04
    p.addi(3, 0, 3)            # 0x08
    p.div(4, 1, 2)             # 0x0c  loop: x4 = x1 / x2
    p.addi(3, 3, -1)           # 0x10
    p.bne(3, 0, -8)            # 0x14
    p.ecall()
    write_hex(p, os.path.join(here, "teach_loop_div.hex"))


if __name__ == "__main__":
    build()
