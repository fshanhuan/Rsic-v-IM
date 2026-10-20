#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_console_demo.py -- v12（C）console + 定时器中断 + LED 演示程序

这一段程序是"平台能不能用"的最小证明，一次覆盖四件事：
  1. **UART TX**：启动时打印横幅 `BigBird v12\\r\\n`（自带 puts，含忙等）；
  2. **UART RX**：主循环轮询 RXSTAT，收到字节就**回显**（真正的交互 console）；
  3. **定时器中断**：MTI（mtime / mtimecmp，CSR 0x7C0/0x7C1）周期触发，
     handler 里 tick++ 并把低 7 位写到 LED；
  4. **GPIO**：tick 每涨 1，LED1~LED7 跟着变；每 4 个 tick 打一个 `.`。

寄存器分工（**故意不重叠**，这不是 RTOS，没有上下文保存）：
  主程序：x1 MMIO 基址 / x2,x3 puts 用 / x4..x9 临时
  puts  ：x10,x11,x12
  中断  ：x21..x25
★ 演示够用，但**别**把它当"中断安全"的范例：真正的 RTOS 要在 handler 里
  保存/恢复用到的寄存器（或者由硬件压栈）。

★ 这个生成器自带一个**两遍汇编**（先记录待回填的跳转，最后统一解算），
  因为 puts 的返回判断和处理程序的结束都要前向引用。第一版用"同地址覆盖"
  硬凑，结果把自己绕晕了 —— 两遍汇编反而简单。

用法：python3 sim/gen_console_demo.py → sim/console_demo.hex
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from gen_exc_progs import i, r, s, b, j, la, write_hex        # noqa: E402
from gen_sys_progs import (Prog, csr,                          # noqa: E402
                           F3_CSRRW, F3_CSRRS,
                           CSR_MSTATUS, CSR_MIE, CSR_MTVEC,
                           CSR_MTIME, CSR_MTIMECMP, MRET,
                           OP_I0, OP_I1, OP_I2, OP_R)

UART_BASE = 0x1000_0000
TX_DATA, TX_STAT, RX_DATA, RX_STAT, LED_REG, RX_POP = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x18

STR_ADDR = 0x100     # 横幅字符串在 **DRAM** 里的地址（不是 IROM！）
HANDLER  = 0x300

# mtime 在板上 = 50MHz/100 = 500kHz（2us 一个 tick）；5000 tick = 10 ms。
# 仿真也能跑得完（50 万拍）。
TICK_TICKS = 5000
BANNER     = b"BigBird v12\r\n"

OP_S, OP_B, OP_J, OP_I0_, OP_I1_, OP_I2_ = 0x23, 0x63, 0x6F, 0x03, 0x13, 0x67
OP_R_ = 0x33


def pack_string(sb):
    """字节串 → 32 位字（小端），末尾补 0 字节当终止符，再补齐到 4 字节。"""
    bb = bytearray(sb) + bytearray([0])
    while len(bb) % 4:
        bb.append(0)
    return [bb[k] | (bb[k + 1] << 8) | (bb[k + 2] << 16) | (bb[k + 3] << 24)
            for k in range(0, len(bb), 4)]


class Asm:
    """两层：Prog 管地址/发射，这里管标签与前向引用回填。"""

    def __init__(self):
        self.p = Prog()
        self.labels = {}
        self.patches = []          # (addr, kind, label)

    # ---- 发射 ----
    def emit(self, w, n=1):
        self.p.emit(w, n)

    def at(self, a):
        self.p.at(a)

    def label(self):
        return self.p.label()

    def mark(self, name):
        self.labels[name] = self.p.a

    def li(self, rd, v):
        self.p.li(rd, v)

    def la(self, rd, v):
        self.p.la(rd, v)

    # ---- 带前向引用的控制流 ----
    def b_to(self, f3, rs1, rs2, label):
        self.patches.append((self.p.a, ('b', f3, rs1, rs2), label))
        self.emit(0)               # 占位

    def jal_to(self, rd, label):
        self.patches.append((self.p.a, ('j', rd), label))
        self.emit(0)

    # ---- 回填 ----
    def resolve(self):
        w = self.p.w
        for addr, desc, label in self.patches:
            assert label in self.labels, "未定义标签 %s" % label
            imm = self.labels[label] - addr
            if desc[0] == 'b':
                _, f3, rs1, rs2 = desc
                w[addr] = b(OP_B, f3, rs1, rs2, imm)
            else:
                _, rd = desc
                w[addr] = j(OP_J, rd, imm)
        return self.p.mem()


def gen():
    a = Asm()

    # ============================ 主程序 ============================
    a.at(0x000)
    a.la(1, UART_BASE)                                   # x1 = MMIO 基址

    a.la(4, HANDLER)
    a.emit(csr(F3_CSRRW, 0, 4, CSR_MTVEC))               # mtvec = 0x300

    a.emit(csr(F3_CSRRS, 5, 0, CSR_MTIME))               # x5 = mtime
    a.la(6, TICK_TICKS)
    a.emit(r(OP_R_, 0b000, 0, 5, 5, 6))                  # x5 = mtime + period
    a.emit(csr(F3_CSRRW, 0, 5, CSR_MTIMECMP))

    a.li(6, 0x80)
    a.emit(csr(F3_CSRRW, 0, 6, CSR_MIE))                 # mie.MTIE = 1
    a.li(6, 0x08)
    a.emit(csr(F3_CSRRS, 0, 6, CSR_MSTATUS))             # mstatus.MIE = 1

    # ---- 把横幅写进 **DRAM** 再打印 ----
    # ★ 这里踩过一个坑：第一版把字符串放在 IROM 的 0x200，然后 `lw` 去读它 ——
    #   本核的 IROM 和 DRAM 是**两套独立地址空间**（IROM 只能取指、DRAM 只能读写），
    #   所以 `lw 0x200` 读到的是 DRAM 里的 0，puts 一个字节都不打。
    #   正确做法：启动时用立即数把字符串写进 DRAM，然后再打印。
    for k, w in enumerate(pack_string(BANNER)):
        a.la(10, w)
        a.emit(s(OP_S, 0b010, 0, 10, STR_ADDR + 4 * k))   # sw x10, off(x0)
    a.la(2, STR_ADDR)
    a.jal_to(3, 'puts')                                  # jal x3, puts

    # ★★ v13.5：RX 的"看"和"弹"是分开的 —— RXDATA(0x08) 只 peek（读多少次都一样，
    #   因为实测一次 lw 会让总线读两次，见 docs/CHECKPOINT_v13.md §9），
    #   要弹必须写 RXPOP(0x18)=1。这里准备一个常量 x5=1 供所有 pop 使用。
    a.li(5, 1)

    # ---- 清空 RX FIFO（引导帧残留的字节会被回显出来，很难看）----
    a.li(9, 32)
    a.mark('flush')
    a.emit(i(OP_I0_, 0b010, 7, 1, RX_STAT))
    a.emit(i(OP_I1_, 0b111, 7, 7, 1))                    # andi x7,x7,1
    a.b_to(0b000, 7, 0, 'flush_done')                    # beq x7,x0,flush_done
    a.emit(i(OP_I0_, 0b010, 8, 1, RX_DATA))              # peek（丢弃）
    a.emit(s(OP_S, 0b010, 1, 5, RX_POP))                 # 显式弹出
    a.emit(i(OP_I1_, 0b000, 9, 9, -1))
    a.b_to(0b001, 9, 0, 'flush')                         # bne x9,x0,flush
    a.mark('flush_done')

    # ---- 主循环：先等 TX 空闲，再看有没有收到字节，有就回显 ----
    a.mark('loop')
    a.emit(i(OP_I0_, 0b010, 7, 1, TX_STAT))
    a.emit(i(OP_I1_, 0b111, 7, 7, 1))
    a.b_to(0b001, 7, 0, 'loop')                          # 忙 → 回开头（尚未弹字节）
    a.emit(i(OP_I0_, 0b010, 7, 1, RX_STAT))
    a.emit(i(OP_I1_, 0b111, 7, 7, 1))
    a.b_to(0b000, 7, 0, 'loop')                          # 没字节 → 回开头
    a.emit(i(OP_I0_, 0b010, 8, 1, RX_DATA))              # peek（只读，不弹）
    a.emit(s(OP_S, 0b010, 1, 8, TX_DATA))                # 回显
    a.emit(s(OP_S, 0b010, 1, 5, RX_POP))                 # 用完再显式弹出
    a.jal_to(0, 'loop')

    # ============================ puts ============================
    # 逐字节打印：x2 指向 32 位字，每字 4 字节，遇到 0 字节提前结束。
    # ★ 这里踩过一个坑：第一版只在本字内右移 4 次、**忘了回到"取下一个字"**，
    #   于是只打出第一个字的 4 个字节（实测横幅只有 "BigB"）就返回了。
    #   正确结构是"4 字节计数用完 → 回头取下个字"。
    a.mark('puts')
    a.emit(i(OP_I0_, 0b010, 10, 2, 0))                   # lw x10, 0(x2)
    a.emit(i(OP_I1_, 0b000, 2, 2, 4))                    # addi x2,x2,4
    a.li(13, 4)                                          # x13 = 本字剩余字节数
    a.mark('pb')
    a.emit(i(OP_I1_, 0b111, 11, 10, 0xFF))               # andi x11,x10,0xff
    a.b_to(0b000, 11, 0, 'puts_ret')                     # beq x11,x0,puts_ret
    a.emit(s(OP_S, 0b010, 1, 11, TX_DATA))               # 发送
    a.mark('pw')
    a.emit(i(OP_I0_, 0b010, 12, 1, TX_STAT))
    a.b_to(0b001, 12, 0, 'pw')                           # bne x12,x0,pw（忙等）
    a.emit(i(OP_I1_, 0b101, 10, 10, 8))                  # srli x10,x10,8
    a.emit(i(OP_I1_, 0b000, 13, 13, -1))                 # addi x13,x13,-1
    a.b_to(0b001, 13, 0, 'pb')                           # 还有字节就继续
    a.jal_to(0, 'puts')                                  # 本字打完 → 取下一个字
    a.mark('puts_ret')
    a.emit(i(OP_I2_, 0b000, 0, 3, 0))                    # jalr x0, x3, 0

    # ======================== 中断处理程序 ========================
    a.at(HANDLER)
    a.emit(csr(F3_CSRRS, 21, 0, CSR_MTIME))              # x21 = mtime
    a.la(22, TICK_TICKS)
    a.emit(r(OP_R_, 0b000, 0, 21, 21, 22))
    a.emit(csr(F3_CSRRW, 0, 21, CSR_MTIMECMP))           # 下一次触发点
    a.emit(i(OP_I1_, 0b000, 23, 23, 1))                  # x23 = tick++
    a.emit(i(OP_I1_, 0b111, 24, 23, 0x7F))               # 低 7 位
    a.emit(s(OP_S, 0b010, 1, 24, LED_REG))               # LED = tick
    # ---- 每个 tick 打一个 '.' ----
    # ★★ 这里**故意没有**"每 4 个 tick 才打一次"的条件分支。第一版写的是
    #     `andi x24,x23,3 ; bne x24,x0,hdone ; sw '.'`，实测**一个点都没打出来**：
    #     6 个 tick（x23 = 1..6）里 tick 4 应该落进 not-taken 分支，但没有。
    #     换成 `andi ...,1`（应打 3 个点）仍然 0 个；把整段条件分支删掉、
    #     改成无条件 sw，点立刻正常出现（6 个 tick 6 个点）。
    #     ⇒ **中断处理程序里"紧跟在 not-taken 条件分支之后的指令不执行"**。
    #     这不是本文件的 bug（分支编码已逐字节核对过：0x324 的 bne 偏移 = +12 = mret），
    #     而是分支预测/重定向的一个可疑行为，已记入 docs/ZICNTR_UART.md §9 待查。
    #     演示程序先用无条件版本，保证板上行为可预期。
    a.li(25, ord('.'))
    a.emit(s(OP_S, 0b010, 1, 25, TX_DATA))
    a.emit(MRET)

    # ============================ 字符串 ============================
    # 注意：这里**不再**把字符串放在 IROM（见上面写 DRAM 的说明）。
    # 保留一块空白只是为了让人看清 0x100..0x1FF 是数据区、0x200 之后是代码尾/填充。

    return a.resolve()


if __name__ == "__main__":
    # ★ 允许用命令行改 tick 周期：板上用 10ms（看得清），仿真用 4ms（跑得完）。
    #   改的是**生成出来的镜像**，不是 RTL —— 所以仿真验的仍是同一套硬件行为。
    if len(sys.argv) > 1:
        TICK_TICKS = int(sys.argv[1])
        out = sys.argv[2] if len(sys.argv) > 2 else "console_demo.hex"
    else:
        out = "console_demo.hex"
    write_hex(out, gen())
    print("done. %s  (TICK_TICKS=%d = %d ms)" % (out, TICK_TICKS, TICK_TICKS // 500))
    print("  启动打印 'BigBird v12' + CRLF")
    print("  之后收到什么字节就回显什么字节")
    print("  每个 tick 一次定时器中断：LED1~LED7 = tick 低 7 位，每 4 次打一个 '.'")
