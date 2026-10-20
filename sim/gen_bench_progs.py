#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_bench_progs.py -- 生成 v11 的 3 个**性能基准**（不是功能用例）。

为什么需要它们（v11 优化的前提）：
  优化前全工程只有 24 个程序，最大的 200 字（800 B），IROM 4 096 字里只用掉 4.9%。
  "改完之后快了多少"在这类 hello-world 级别的程序上测不出来 —— 例如 D-Cache 从
  64 行扩到 256 行，7 个老程序的周期数**一个都没变**（工作集本就装得下）。
  所以先有三个有代表性工作集的基准，再谈优化。

三个基准各自打一类结构：
  bench_call : 函数调用密集 —— 两个**不同调用点**调用同一个函数，使 BTB 的
               "上次返回地址"在两点之间来回猜错，专门用来量 RAS（返回地址栈）的收益。
  bench_mem  : 字节访存密集 —— lbu 紧跟 add（强制 load-use 相关）+ sb 写回，
               64 字节连续工作集，用来量 load-use 前递与 D-Cache 容量。
  bench_div  : 十进制格式化 —— `q = x/10; r = x%10;` 同源配对 + 若干独立除法，
               用来量 v11 的 div/rem 配对缓存与除零/|a|<|b| 快路径。

约定（与 sim/gen_sys_progs.py 一致）：
  - 从 0x000 开始，收尾 `ecall`；
  - 不留 mtvec（=0），ecall 后 pc 回 0，测试台在 ecall 到达 ID 后 DRAIN 拍取现场；
  - 这些程序**不配期望值表**（tb_iverilog 的 prog_id 落到 default → NO_EXPECTATION），
    只报周期数/计数器实测值。功能正确性由既有 23 项回归保证。

用法：
    python3 sim/gen_bench_progs.py
    vvp sim/build/tb_iverilog.vvp +prog=sim/bench_call.hex +prog_id=99 +max=20000
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from gen_exc_progs import i, b, j, u, li, assemble, write_hex, NOP, SIM_DIR  # noqa: E402

OP_R, OP_I0, OP_I1, OP_I2 = 0x33, 0x03, 0x13, 0x67
OP_S, OP_B, OP_U0, OP_U1, OP_J, OP_SYS = 0x23, 0x63, 0x37, 0x17, 0x6F, 0x73

ECALL = 0x00000073
F3_BNE = 0b001

# ★ 循环回边之后、ecall 之前必须垫 ≥12 条 NOP（RETURN_GUARD）。
#   原因：sim/tb_iverilog.sv:904 用 `u_cpu.IDU_ecall_flag` 判"程序结束"，**不检查这条 ecall
#   是不是投机取到的**。回边紧挨着 ecall 时，第一次迭代分支还没在 EX 解析，取指已经把
#   ecall 送进 ID → 测试台立刻停表（实测 bench_call 只跑了 44 拍就"结束"）。
#   垫 12 条 NOP 后，分支在 EX 的误预测重定向（≈3 拍后）早已把这条路径冲掉；而"真出口"
#   那次分支不跳，NOP 顺序执行完才到 ecall —— 多花的 12 拍是常数，不影响对比。
RETURN_GUARD = 12

F7_M = 0b0000001          # RV32M 的 funct7
F3_DIV, F3_DIVU, F3_REM, F3_REMU = 0b100, 0b101, 0b110, 0b111


def r_alu(f3, rd, rs1, rs2, f7=0):
    """R 型整数/M 扩展（用 gen_exc_progs 的 r() 需要 op 参数）。"""
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_R


class Prog:
    def __init__(self):
        self.w = {}
        self.a = 0

    def at(self, addr):
        self.a = addr
        return self

    def emit(self, ins, n=1):
        for _ in range(n):
            self.w[self.a] = ins
            self.a += 4
        return self

    def li(self, rd, val):
        for ins in li(rd, val):
            self.emit(ins)

    def la(self, rd, addr):
        for ins in (u(OP_U0, rd, (addr + 0x800) >> 12),
                    i(OP_I1, 0b000, rd, rd, addr - (((addr + 0x800) >> 12) << 12))):
            self.emit(ins)

    def nops(self, n):
        """填 NOP。★ 必须放在回边之后、ecall 之前，见 RETURN_GUARD 说明。"""
        for _ in range(n):
            self.emit(NOP)

    def label(self):
        return self.a

    def branch_here(self, f3, rs1, rs2, target):
        self.emit(b(OP_B, f3, rs1, rs2, target - self.a))

    def jal_here(self, rd, target):
        self.emit(j(OP_J, rd, target - self.a))

    def mem(self):
        return assemble(self.w)


# =====================================================================
# bench_call：两个调用点 → 一个函数
# =====================================================================
def gen_call():
    p = Prog().at(0)
    FUNC_CALLS = 20

    p.li(2, 0)                                   # x2 = 累加器
    p.li(3, FUNC_CALLS)                          # x3 = 外层循环次数
    top = p.label()
    p.jal_here(1, 0x7FFF_FFFF)                   # 占位：调用点 A（地址回填见下）
    offA = p.a - 4
    p.jal_here(1, 0x7FFF_FFFF)                   # 占位：调用点 B
    offB = p.a - 4
    p.emit(i(OP_I1, 0b000, 3, 3, -1))            # addi x3, x3, -1
    p.branch_here(F3_BNE, 3, 0, top)             # bne x3, x0, top
    p.nops(RETURN_GUARD)
    p.emit(ECALL)

    fn = p.label()
    p.emit(i(OP_I1, 0b000, 2, 2, 1))             # addi x2, x2, 1
    p.emit(i(OP_I1, 0b000, 2, 2, 2))             # addi x2, x2, 2
    # ★ 函数体故意做成 8 条指令（不是 3 条）：RAS 的压栈发生在 EX（比取指晚约 4 拍），
    #   只有函数体比"取指领先量"长时，取指到 ret 那一刻栈里才已经有返回地址。
    #   3 条指令的函数是**退化极端**（实测那种情况 RAS 帮不上，见 docs/优化_v11_进度.md）。
    p.emit(i(OP_I1, 0b000, 2, 2, 1))
    p.emit(i(OP_I1, 0b000, 2, 2, 1))
    p.emit(i(OP_I1, 0b000, 2, 2, 1))
    p.emit(i(OP_I1, 0b000, 2, 2, 1))
    p.emit(i(OP_I1, 0b000, 2, 2, 1))
    p.emit(i(OP_I1, 0b000, 2, 2, 1))
    p.emit(i(OP_I2, 0b000, 0, 1, 0))             # jalr x0, x1, 0   ← ret

    # 回填两个 jal 的偏移（j() 的 imm 是字节相对偏移）
    for off in (offA, offB):
        p.w[off] = j(OP_J, 1, fn - off)

    return p.mem()


# =====================================================================
# bench_mem：字节 copy + 累加（load-use 相关 + 写回）
# =====================================================================
def gen_mem():
    p = Prog().at(0)
    N = 64

    p.la(1, 0x1000)                              # 源（★ 必须 la：li 只支持 12 位立即数）
    p.la(4, 0x1100)                              # 目的
    p.li(3, N)                                   # 计数
    p.li(5, 0)                                   # 校验和
    p.li(6, 0)                                   # 临时
    top = p.label()
    p.emit(i(OP_I0, 0b100, 6, 1, 0))             # lbu  x6, 0(x1)
    p.emit(i(OP_I1, 0b000, 5, 5, 0))             # addi x5, x5, 0   ← 强制"load 后立刻用"
    p.emit(r_alu(0b000, 5, 5, 6))                # add  x5, x5, x6
    p.emit(i(OP_I0, 0b000, 6, 4, 0))             # lb  x6, 0(x4)    ← 另一个 load
    p.emit(i(OP_I1, 0b000, 5, 5, 1))             # addi x5, x5, 1   ← 紧跟使用
    p.emit(i(OP_S, 0b000, 6, 1, 0))              # sb   x6, 0(x1)   ← 写回（字节）
    p.emit(i(OP_I1, 0b000, 1, 1, 1))             # addi x1, x1, 1
    p.emit(i(OP_I1, 0b000, 4, 4, 1))             # addi x4, x4, 1
    p.emit(i(OP_I1, 0b000, 3, 3, -1))            # addi x3, x3, -1
    p.branch_here(F3_BNE, 3, 0, top)             # bne  x3, x0, top
    p.nops(RETURN_GUARD)
    p.emit(ECALL)
    return p.mem()


# =====================================================================
# bench_div：十进制格式化（div/rem 同源配对 + 独立除法 + 除零）
# =====================================================================
def gen_div():
    p = Prog().at(0)
    DIGITS = 8

    p.la(1, 123456789)                           # x1 = 被除数（★ la，不是 li）
    p.li(2, 10)                                  # x2 = 10
    p.li(3, DIGITS)                              # x3 = 位数
    p.li(4, 0)                                   # x4 = 余数累加
    p.li(5, 0)                                   # x5 = 独立除法结果
    top = p.label()
    # ---- 同源配对：GCC 对 "q = x/10; r = x%10;" 就是这两条相邻 ----
    p.emit(r_alu(F3_DIV, 6, 1, 2, F7_M))         # div x6, x1, x2
    p.emit(r_alu(F3_REM, 7, 1, 2, F7_M))         # rem x7, x1, x2   ← 命中配对缓存
    p.emit(r_alu(0b000, 4, 4, 7))                # add x4, x4, x7
    p.emit(r_alu(0b000, 1, 6, 0))                # add x1, x6, x0    (x1 = q)
    p.emit(i(OP_I1, 0b000, 3, 3, -1))            # addi x3, x3, -1
    p.branch_here(F3_BNE, 3, 0, top)
    # ---- 独立除法（缓存被上面最后一条覆盖 → 这条必须真迭代） ----
    p.emit(r_alu(F3_DIVU, 5, 1, 2, F7_M))        # divu x5, x1, x2
    # ---- 除零快路径（结果：商全 1 / 余数=被除数） ----
    p.emit(r_alu(F3_DIV, 8, 1, 0, F7_M))         # div  x8, x1, x0
    p.emit(r_alu(F3_REM, 9, 1, 0, F7_M))         # rem  x9, x1, x0
    p.nops(RETURN_GUARD)
    p.emit(ECALL)
    return p.mem()


def main():
    for name, fn in (("bench_call.hex", gen_call),
                     ("bench_mem.hex", gen_mem),
                     ("bench_div.hex", gen_div)):
        write_hex(name, fn())


if __name__ == "__main__":
    main()
