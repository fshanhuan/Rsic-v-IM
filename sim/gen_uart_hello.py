#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_uart_hello.py -- v12（B）上板演示程序：UART console 循环打印 "Hi"

为什么不复用 sim/uart_mmio.hex：那个程序打印完就 `jal x0, 0` 停住了。
上板验证时有个**串口独占**的问题 —— 引导加载器（load_uart.ps1）和
console 读取器（read_uart.ps1）抢同一个 COM9，不可能同时跑：
加载的时候读不到，能读的时候程序早就打完了。

所以演示程序必须**周期性地重复打印**：先灌进去，等加载器放开串口，
再起读取器，随时都能收到输出。

顺带这个程序还是"板上量拍数"的最小样本：
  - 延时循环的迭代次数固定（DELAY_ITERS），
  - probe6 = mcycle，两个相邻打印之间的拍数差 / 迭代次数
    = **每条循环指令的真实拍数**（不用改代码、不用插桩）。

用法：python3 sim/gen_uart_hello.py  →  sim/uart_hello.hex
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from gen_exc_progs import i, s, la, write_hex        # noqa: E402
from gen_sys_progs import Prog, OP_I0, OP_I1, OP_S, OP_B, OP_J   # noqa: E402

UART_BASE   = 0x1000_0000     # TXDATA（写）
UART_STATUS = 0x1000_0004     # STATUS（读，bit0 = busy）

# 延时循环的迭代次数：每次迭代 2 条指令，约 1.75 拍/指令 → 3.5 拍
# 200000 次 ≈ 700k 拍 ≈ 14 ms @50MHz。
# ★ 这个数直接决定"两次打印之间有多久"，读取器就是靠它才抓得到。
DELAY_ITERS = 200_000


def gen():
    p = Prog()
    start = p.label()

    p.la(1, UART_BASE)                    # x1 = 0x1000_0000

    # ---- 打印 'H' ----
    p.emit(i(OP_I1, 0b000, 2, 0, ord('H')))
    p.emit(s(OP_S, 0b010, 1, 2, 0))
    poll = p.label()
    p.emit(i(OP_I0, 0b010, 3, 1, 4))      # lw x3, 4(x1)
    p.branch_here(0b001, 3, 0, poll)      # bne x3, x0, poll

    # ---- 打印 'i' ----
    p.emit(i(OP_I1, 0b000, 2, 0, ord('i')))
    p.emit(s(OP_S, 0b010, 1, 2, 0))

    # ---- 等 busy 落，然后延时，再回到开头 ----
    poll2 = p.label()
    p.emit(i(OP_I0, 0b010, 3, 1, 4))      # lw x3, 4(x1)
    p.branch_here(0b001, 3, 0, poll2)     # bne x3, x0, poll2

    p.la(20, DELAY_ITERS)
    delay = p.label()
    p.emit(i(OP_I1, 0b000, 20, 20, -1))   # addi x20, x20, -1
    p.branch_here(0b001, 20, 0, delay)    # bne x20, x0, delay

    p.jal_here(0, start)                  # jal x0, start
    return p.mem()


if __name__ == "__main__":
    write_hex("uart_hello.hex", gen())
    print("done. uart_hello.hex")
    print("  串口会周期性地收到 'H' 'i'（每轮之间延时 %d 次循环 ≈ 14 ms）" % DELAY_ITERS)
    print("  ILA: probe6 = mcycle，两次 'H' 之间的差值 / %d = 每轮延时的拍数" % DELAY_ITERS)
