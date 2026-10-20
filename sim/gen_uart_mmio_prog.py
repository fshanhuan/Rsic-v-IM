#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_uart_mmio_prog.py -- v12（B）UART MMIO 端到端测试程序

这段程序是给 board/tb_board_top_uart.sv 用的**板级**用例（不是 CPU 单元测试）：
它真正通过 CPU 的 sw/lw 去碰 0x1000_0000 这个外设窗口，验证四件事：

  1. `sw` 到 0x1000_0000 能真的把字节送进 uart_tx（打印 'H' 和 'i'）；
  2. `lw` 0x1000_0004 能读到 busy 位 —— 这是软件做流控的唯一手段，
     读不到的话连续打印就会丢字符；
  3. MMIO 写**不会**同时写掉 DRAM 的第 0 个字（地址译码必须门掉 dram 的 wen，
     否则"打一个字符，栈里的变量莫名其妙变了"）；
  4. 普通 DRAM 读写仍然正常（写 0x40 再读回来）。

程序结尾写 x10 = 0x600D 然后原地自跳：测试台靠"看到 x10 写回 0x600D"取现场，
不会因为程序自己继续跑（或 ecall 跳回 0 重跑）而污染结果。

用法：python3 sim/gen_uart_mmio_prog.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# 复用已有的编码器与汇编小工具（它们本身在 __main__ 保护下，import 不会产生副作用）
from gen_exc_progs import i, s, la, write_hex, NOP          # noqa: E402
from gen_sys_progs import Prog, OP_I0, OP_I1, OP_S, OP_B, OP_J   # noqa: E402

# ---- MMIO 地址（与 board/board_top.sv 的第 4) 段一致）----
UART_BASE   = 0x1000_0000      # TXDATA（写）
UART_STATUS = 0x1000_0004      # STATUS（读，bit0 = busy）

DRAM_WORD0  = 0x0000_0000      # 板级 DRAM 第 0 个字（测试台预置 0xCAFE0000）
DRAM_TEST   = 0x0000_0040      # 普通 DRAM 读写验证地址


def gen():
    p = Prog()

    # ---- 基址 ----
    p.la(1, UART_BASE)                    # x1 = 0x1000_0000

    # ---- 打印 'H' ----
    p.emit(i(OP_I1, 0b000, 2, 0, ord('H')))
    p.emit(s(OP_S, 0b010, 1, 2, 0))       # sw x2, 0(x1)

    # ---- 轮询 STATUS 直到 busy=0（软件流控）----
    poll = p.label()
    p.emit(i(OP_I0, 0b010, 3, 1, 4))       # lw x3, 4(x1)  -> busy?
    p.branch_here(0b001, 3, 0, poll)      # bne x3, x0, poll

    # ---- 打印 'i'（此时第一帧已经发完，第二个字节必定完整）----
    p.emit(i(OP_I1, 0b000, 2, 0, ord('i')))
    p.emit(s(OP_S, 0b010, 1, 2, 0))       # sw x2, 0(x1)

    # ---- MMIO 写之后 DRAM[0] 必须没被改 ----
    p.emit(i(OP_I0, 0b010, 5, 0, 0))      # lw x5, 0(x0)  -> 预置的 0xCAFE0000

    # ---- 普通 DRAM 读写仍然工作 ----
    p.la(6, DRAM_TEST)
    p.la(7, 0x1234)
    p.emit(s(OP_S, 0b010, 6, 7, 0))       # sw x7, 0(x6)
    p.emit(i(OP_I0, 0b010, 8, 6, 0))      # lw x8, 0(x6)  -> 0x1234

    # ---- 结束标记 ----
    p.la(10, 0x600D)
    p.emit(0x0000006F)                    # jal x0, 0 —— 原地自跳，现场冻结
    return p.mem()


if __name__ == "__main__":
    write_hex("uart_mmio.hex", gen())
    print("done. uart_mmio.hex 期望：")
    print("  串口先收到 'H'(0x48)、再收到 'i'(0x69)")
    print("  x5 = 0xCAFE0000（DRAM[0] 没被 MMIO 写覆盖）")
    print("  x8 = 0x1234      （普通 DRAM 读写正常）")
    print("  x10 = 0x600D     （程序走到尾的标记）")
