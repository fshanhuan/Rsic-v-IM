#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_exc_progs.py -- 生成异常体系（C4）专项回归程序。

背景：v9 原来只有 ecall 一种同步异常：
  * 非法指令会被"匹配不上就当加法"执行掉，写坏 rd；
  * 非对齐访存会被静默对齐（LSU 里把 addr[17:16] 强制清零），读到错的字；
  * mtval 是个死寄存器，软件无法定位出错的指令/地址。
C4 修复后，这三类异常都会正确陷入 mtvec，并写 mcause/mepc/mtval。

本脚本生成三个 hex 程序（纯手工汇编，无外部工具链依赖）：

  exc_illegal.hex  : 陷阱处理程序 + 一条非法指令
                     期望 mcause=2, mtval=非法指令编码
  exc_misalign.hex : 陷阱处理程序 + 一条非对齐 lw + 一条非对齐 sw
                     期望 mcause=4(mtval=地址) 然后 mcause=6(mtval=地址)
  exc_jalr.hex     : 陷阱处理程序 + 一条 jal（目标非 2 字节对齐）
                     期望 mcause=0, mtval=目标地址
                     注：jalr 的目标 bit0 被硬件清零，天然对齐，所以用 jal + imm 造。

陷阱处理程序做的事（放在 mtvec，例如 0x100）：
  * 记录 mcause / mepc / mtval 到 x20 / x21 / x22；
  * 计数器 x23 += 1（便于测试台数"陷入了几次"）；
  * 把 mepc 加 4（跳过出错指令）后 mret，程序继续往下走，最后 ecall 收尾。

这样测试台只要检查寄存器快照就能判断异常体系是否正确。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM_DIR = HERE                      # hex 与测试台同目录

# ---------------------------------------------------------------- 汇编小工具
def r(op, f3, f7, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def i(op, f3, rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def s(op, f3, rs1, rs2, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
         | ((imm & 0x1F) << 7) | op

def b(op, f3, rs1, rs2, imm):
    imm &= 0x1FFF
    b12 = (imm >> 12) & 1
    b11 = (imm >> 11) & 1
    b10_5 = (imm >> 5) & 0x3F
    b4_1 = (imm >> 1) & 0xF
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
         | (b4_1 << 8) | (b11 << 7) | op

def u(op, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

def j(op, rd, imm):
    imm &= 0x1FFFFF
    b20 = (imm >> 20) & 1
    b10_1 = (imm >> 1) & 0x3FF
    b11 = (imm >> 11) & 1
    b19_12 = (imm >> 12) & 0xFF
    return (b20 << 31) | (b19_12 << 12) | (b11 << 20) | (b10_1 << 21) | (rd << 7) | op

OP_R, OP_I0, OP_I1, OP_I2 = 0x33, 0x03, 0x13, 0x67
OP_S, OP_B, OP_U0, OP_J, OP_SYS = 0x23, 0x63, 0x37, 0x6F, 0x73

def li(rd, val):
    """小常数加载：addi rd, x0, val（val 在 12 位有符号范围内）。"""
    return [i(OP_I1, 0b000, rd, 0, val)]

def la(rd, addr):
    """把一个 32 位地址装进 rd：lui + addi（低位 12 位按有符号处理）。"""
    hi = (addr + 0x800) >> 12
    lo = addr - (hi << 12)
    return [u(OP_U0, rd, hi), i(OP_I1, 0b000, rd, rd, lo)]

NOP = 0x00000013


def assemble(prog_words):
    """把 (地址: 指令) 列表展开成从 0 开始的连续 hex 数组，未用地址填 0。"""
    n = max(prog_words.keys()) // 4 + 1
    mem = [0] * n
    for addr, w in prog_words.items():
        mem[addr // 4] = w & 0xFFFFFFFF
    return mem


def write_hex(name, mem):
    path = os.path.join(SIM_DIR, name)
    with io.open(path, "w", encoding="ascii", newline="\n") as f:
        for w in mem:
            f.write("%08x\n" % w)
    print("wrote %s (%d words)" % (path, len(mem)))


# =============================================================== 陷阱处理程序
MTVEC = 0x100        # 陷阱入口
ENTRY = 0x000        # 主程序入口


def trap_handler():
    """放在 MTVEC，把 mcause/mepc/mtval 记到 x20/x21/x22，x23 计数，mepc+=4，mret。"""
    w = {}
    a = MTVEC
    w[a + 0x00] = r(OP_R, 0b000, 0, 20, 0, 0)        # csrrs x20, mcause, x0
    a = MTVEC
    # csrrs rd, csr, rs1  → I 型，funct3=010，csr 在 imm[11:0]
    w[MTVEC + 0x00] = i(OP_SYS, 0b010, 20, 0, 0x342)  # csrrs x20, mcause, x0
    w[MTVEC + 0x04] = i(OP_SYS, 0b010, 21, 0, 0x341)  # csrrs x21, mepc, x0
    w[MTVEC + 0x08] = i(OP_SYS, 0b010, 22, 0, 0x343)  # csrrs x22, mtval, x0
    w[MTVEC + 0x0C] = i(OP_I1, 0b000, 23, 23, 1)      # addi x23, x23, 1
    w[MTVEC + 0x10] = i(OP_I1, 0b000, 21, 21, 4)      # addi x21, x21, 4  (跳过出错指令)
    w[MTVEC + 0x14] = i(OP_SYS, 0b001, 0, 21, 0x341)  # csrrw x0, mepc, x21
    w[MTVEC + 0x18] = 0x30200073                      # mret
    return w


def prologue():
    """公共前缀：设 mtvec、清 x20..x23。注意这些指令本身必须合法且对齐。"""
    w = {}
    a = ENTRY
    for ins in la(1, MTVEC):          # lui x1, hi ; addi x1, x1, lo
        w[a] = ins
        a += 4
    w[a] = i(OP_SYS, 0b001, 0, 1, 0x305); a += 4   # csrrw x0, mtvec, x1
    for rd in (20, 21, 22, 23):
        w[a] = i(OP_I1, 0b000, rd, 0, 0); a += 4   # addi xN, x0, 0
    return w, a


def finish(w, a):
    """收尾：x10=1 表示"跑到结尾"，然后 ecall 停机。"""
    w[a] = i(OP_I1, 0b000, 10, 0, 1); a += 4       # addi x10, x0, 1
    w[a] = 0x00000073                              # ecall
    return w, a


# =============================================================== 1) 非法指令
def gen_illegal():
    w = trap_handler()
    w2, a = prologue()
    w.update(w2)
    w[a] = 0x00000000; a += 4          # 全 0 = 非法指令（opcode 0000000 未知）
    w[a] = i(OP_I1, 0b000, 24, 0, 0x55); a += 4    # addi x24, x0, 0x55（证明能恢复）
    w, a = finish(w, a)
    return assemble(w)


# =============================================================== 2) 非对齐访存
def gen_misalign():
    w = trap_handler()
    w2, a = prologue()
    w.update(w2)
    # 先给 x2 一个"奇数"基址：0x400 + 2 → 非对齐的字访问
    for ins in la(2, 0x402):
        w[a] = ins; a += 4
    w[a] = i(OP_I0, 0b010, 25, 2, 0); a += 4       # lw x25, 0(x2)  → 地址 0x402 非对齐 (mcause=4)
    w[a] = i(OP_I1, 0b000, 24, 0, 0x77); a += 4    # addi x24, x0, 0x77（证明能恢复）
    # 再测非对齐 store
    for ins in la(3, 0x403):
        w[a] = ins; a += 4
    w[a] = s(OP_S, 0b010, 3, 24, 0); a += 4        # sw x24, 0(x3)  → 地址 0x403 非对齐 (mcause=6)
    w[a] = i(OP_I1, 0b000, 26, 0, 0x99); a += 4    # addi x26, x0, 0x99
    w, a = finish(w, a)
    return assemble(w)


# =============================================================== 3) 跳转目标非对齐
def gen_jal_misalign():
    w = trap_handler()
    w2, a = prologue()
    w.update(w2)
    # jal x5, +2  → 目标 = 当前 PC + 2，非 4 字节对齐 → mcause=0
    w[a] = j(OP_J, 5, 2); a += 4
    # 正常不该执行到这里；如果异常没生效，x24 会被写脏（测试台据此判 FAIL）
    w[a] = i(OP_I1, 0b000, 24, 0, 0xDE); a += 4
    w, a = finish(w, a)
    return assemble(w)


if __name__ == "__main__":
    write_hex("exc_illegal.hex", gen_illegal())
    write_hex("exc_misalign.hex", gen_misalign())
    write_hex("exc_jal_misalign.hex", gen_jal_misalign())
    print("done. 期望：")
    print("  exc_illegal.hex      x23=1  mcause(x20)=2  mtval(x22)=00000000")
    print("  exc_misalign.hex     x23=2  mcause 先 4 后 6  mtval=00000402 / 00000403")
    print("  exc_jal_misalign.hex x23=1  mcause=0  mtval=00000026")
