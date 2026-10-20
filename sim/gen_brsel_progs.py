#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_brsel_progs.py -- 分支/条件执行的最小探针程序（查"not-taken 后不执行"）

背景：v12（C）的 console 演示程序里，中断处理程序中
    andi x24, x23, 3
    bne  x24, x0, hdone
    <两条指令：li + sw>
  hdone: mret
"两条指令"从来没执行过。为了分清是"handler 特有"还是"核心分支路径"，这里做
**同一个动态模式的两个版本**：

  brsel_a.hex  普通代码里，ALU → bne（1 条间隔）→ 条件执行一条 addi
               期望 x6 = 10（20 次迭代里偶数 10 次）
  brsel_b.hex  同上，但 andi 和 bne 之间插一条 nop
  brsel_c.hex  同上，但条件执行的是一条 **store**（写到 DRAM 0x40），
               模拟 handler 里 sw 的情形；最后把 DRAM[0x40] 读回 x7

三个都自带 `li x10,0x600D` 结束标记，配合 sim/tb_mini.sv 用。

另外给一个**handler 版本**（brsel_h.hex）：定时器中断里做同样的事，
把"偶数次 tick 的计数"写进 x6，用来验证问题是否只在中断上下文里出现。

用法：python3 sim/gen_brsel_progs.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from gen_exc_progs import i, r, s, b, j, la, write_hex, NOP       # noqa: E402
from gen_sys_progs import (Prog, csr, F3_CSRRW, F3_CSRRS,          # noqa: E402
                           CSR_MSTATUS, CSR_MIE, CSR_MTVEC,
                           CSR_MTIME, CSR_MTIMECMP, MRET,
                           OP_I0, OP_I1, OP_I2, OP_R)

OP_S, OP_B, OP_J = 0x23, 0x63, 0x6F
UART_BASE = 0x1000_0000


class Asm:
    def __init__(self):
        self.p = Prog(); self.labels = {}; self.patches = []

    def emit(self, w, n=1): self.p.emit(w, n)
    def at(self, a): self.p.at(a)
    def label(self): return self.p.label()
    def mark(self, n): self.labels[n] = self.p.a
    def li(self, rd, v): self.p.li(rd, v)
    def la(self, rd, v): self.p.la(rd, v)

    def b_to(self, f3, rs1, rs2, label):
        self.patches.append((self.p.a, ('b', f3, rs1, rs2), label)); self.emit(0)

    def jal_to(self, rd, label):
        self.patches.append((self.p.a, ('j', rd), label)); self.emit(0)

    def resolve(self):
        w = self.p.w
        for addr, desc, label in self.patches:
            imm = self.labels[label] - addr
            w[addr] = b(OP_B, desc[1], desc[2], desc[3], imm) if desc[0] == 'b' \
                else j(OP_J, desc[1], imm)
        return self.p.mem()


def body(mode):
    """mode: 'alu' | 'nop' | 'store'"""
    a = Asm()
    a.at(0x000)
    a.li(5, 0)                 # x5 = i
    a.li(6, 0)                 # x6 = 偶数次计数
    a.li(7, 20)                # 迭代上限
    a.li(9, 0x40)              # DRAM 地址（store 版用）

    a.mark('loop')
    a.emit(i(OP_I1, 0b000, 5, 5, 1))          # addi x5, x5, 1
    a.emit(i(OP_I1, 0b111, 8, 5, 1))          # andi x8, x5, 1
    if mode == 'nop':
        a.emit(NOP)
    a.b_to(0b001, 8, 0, 'skip')               # bne x8, x0, skip
    if mode == 'store':
        a.emit(s(OP_S, 0b010, 9, 6, 0))       # sw x6, 0(x9)  —— 模拟 MMIO sw
        a.emit(i(OP_I1, 0b000, 6, 6, 1))      # 计数（store 之后再看能否执行）
    else:
        a.emit(i(OP_I1, 0b000, 6, 6, 1))      # addi x6, x6, 1
    a.mark('skip')
    a.b_to(0b100, 5, 7, 'loop')               # blt x5, x7, loop

    if mode == 'store':
        a.emit(i(OP_I0, 0b010, 7, 9, 0))      # lw x7, 0(x9) -> 最后一次写的值
    a.la(10, 0x600D)
    a.emit(0x0000006F)                        # jal x0, 0
    return a.resolve()


def handler_version():
    """handler 里做同一件事：偶数次 tick 才把 x6 加 1。

    期望：跑够 6 个 tick（tick 2/4/6）→ x6 = 3。
    """
    a = Asm()
    a.at(0x000)
    a.la(1, UART_BASE)
    a.la(4, 0x300)
    a.emit(csr(F3_CSRRW, 0, 4, CSR_MTVEC))
    a.emit(csr(F3_CSRRS, 5, 0, CSR_MTIME))
    a.la(6, 500)
    a.emit(r(OP_R, 0b000, 0, 5, 5, 6))
    a.emit(csr(F3_CSRRW, 0, 5, CSR_MTIMECMP))
    a.li(6, 0x80)
    a.emit(csr(F3_CSRRW, 0, 6, CSR_MIE))
    a.li(6, 0x08)
    a.emit(csr(F3_CSRRS, 0, 6, CSR_MSTATUS))
    a.mark('wait')
    a.emit(i(OP_I1, 0b000, 30, 30, 1))        # x30 每拍 +1（当"时钟"用）
    a.b_to(0b001, 30, 0, 'wait')              # 无限循环（bne x30,x0,wait）

    a.at(0x300)
    a.emit(csr(F3_CSRRS, 21, 0, CSR_MTIME))
    a.la(22, 500)
    a.emit(r(OP_R, 0b000, 0, 21, 21, 22))
    a.emit(csr(F3_CSRRW, 0, 21, CSR_MTIMECMP))
    a.emit(i(OP_I1, 0b000, 23, 23, 1))        # tick++
    a.emit(i(OP_I1, 0b111, 24, 23, 1))        # andi x24, x23, 1
    a.b_to(0b001, 24, 0, 'hx')                # bne x24,x0,hx —— 奇数跳过
    a.emit(i(OP_I1, 0b000, 6, 6, 1))          # x6++  ← 关键：这条到底执行没
    a.mark('hx')
    a.emit(MRET)
    return a.resolve()


if __name__ == "__main__":
    write_hex("brsel_a.hex", body('alu'))
    write_hex("brsel_b.hex", body('nop'))
    write_hex("brsel_c.hex", body('store'))
    write_hex("brsel_h.hex", handler_version())
    print("done.")
    print("  brsel_a/b/c: 20 次迭代里偶数 10 次 → x6 期望 10")
    print("  brsel_c     : 另外 x7 = 最后一次写入 DRAM[0x40] 的值（=9）")
    print("  brsel_h     : tick 2/4/6 各加一次 → x6 期望 3")
