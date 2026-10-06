"""为差分测试生成 RV32IM 程序：两遍汇编器 + 定向用例 + 随机用例。

输出到目标目录：
  tests/<name>.hex    $readmemh 文本（每行一个 32 位字）
  tests/<name>.exp    JSON：参考模型的终态（32 个 GPR + 非零内存字）
  tests/manifest.txt  用例名列表
"""

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32 import (RefISS, enc_b, enc_i, enc_j, enc_r, enc_s, enc_u, sext, u32, s32)

M32 = 0xFFFFFFFF

RTYPE = {
    'add': (0x00, 0b000), 'sub': (0x20, 0b000), 'sll': (0x00, 0b001),
    'slt': (0x00, 0b010), 'sltu': (0x00, 0b011), 'xor': (0x00, 0b100),
    'srl': (0x00, 0b101), 'sra': (0x20, 0b101), 'or': (0x00, 0b110),
    'and': (0x00, 0b111),
    'mul': (0x01, 0b000), 'mulh': (0x01, 0b001), 'mulhsu': (0x01, 0b010),
    'mulhu': (0x01, 0b011), 'div': (0x01, 0b100), 'divu': (0x01, 0b101),
    'rem': (0x01, 0b110), 'remu': (0x01, 0b111),
}
ITYPE_ALU = {'addi': 0b000, 'slti': 0b010, 'sltiu': 0b011, 'xori': 0b100,
             'ori': 0b110, 'andi': 0b111, 'slli': 0b001, 'srli': 0b101, 'srai': 0b101}
LOADS = {'lb': 0b000, 'lh': 0b001, 'lw': 0b010, 'lbu': 0b100, 'lhu': 0b101}
STORES = {'sb': 0b000, 'sh': 0b001, 'sw': 0b010}
BRANCHES = {'beq': 0b000, 'bne': 0b001, 'blt': 0b100, 'bge': 0b101,
            'bltu': 0b110, 'bgeu': 0b111}

MAGIC_ADDR = 0x3FFC
MAGIC_VAL = 0x123


def li_words(rd, imm):
    imm = u32(imm)
    if imm < 0x800 or (imm >= 0xFFFFF800):
        return [enc_i(sext(imm, 12) if imm >= 0xFFFFF800 else imm, 0, 0b000, rd)]
    hi = ((imm + 0x800) >> 12) & 0xFFFFF
    lo = sext(imm & 0xFFF, 12)
    return [enc_u(hi, rd, 0x37), enc_i(lo, rd, 0b000, rd)]


class Asm:
    """两遍汇编器。跳转目标用「操作序号」表示（0 基）。"""

    def __init__(self):
        self.ops = []

    def emit(self, mn, *a):
        self.ops.append([mn, list(a)])
        return len(self.ops) - 1

    def here(self):
        return len(self.ops)

    def width(self, mn, a):
        if mn == 'jabs':
            return 3
        if mn == 'li':
            return len(li_words(a[0], a[1]))
        return 1

    def assemble(self):
        addr = []
        acc = 0
        for mn, a in self.ops:
            addr.append(acc)
            acc += self.width(mn, a)
        total = acc

        def taddr(t):
            return (addr[t] if t < len(addr) else total) * 4

        out = []
        for i, (mn, a) in enumerate(self.ops):
            if mn in RTYPE:
                f7, f3 = RTYPE[mn]
                rd, rs1, rs2 = a
                out.append(enc_r(f7, rs2, rs1, f3, rd))
            elif mn in ITYPE_ALU:
                rd, rs1, imm = a
                f3 = ITYPE_ALU[mn]
                if mn in ('slli', 'srli'):
                    imm = imm & 0x1F
                elif mn == 'srai':
                    imm = 0x400 | (imm & 0x1F)
                out.append(enc_i(imm, rs1, f3, rd))
            elif mn in LOADS:
                rd, imm, rs1 = a
                out.append(enc_i(imm, rs1, LOADS[mn], rd, op=0x03))
            elif mn in STORES:
                rs2, imm, rs1 = a
                out.append(enc_s(imm, rs2, rs1, STORES[mn]))
            elif mn in BRANCHES:
                rs1, rs2, t = a
                out.append(enc_b(taddr(t) - addr[i] * 4, rs2, rs1, BRANCHES[mn]))
            elif mn == 'jal':
                rd, t = a
                out.append(enc_j(taddr(t) - addr[i] * 4, rd))
            elif mn == 'jalr':
                rd, rs1, imm = a
                out.append(enc_i(imm, rs1, 0b000, rd, op=0x67))
            elif mn == 'jabs':
                # jabs rd, tmp, target [, extra]：tmp = 目标地址 - extra，jalr 再补 extra
                rd, tmp, t = a[0], a[1], a[2]
                extra = a[3] if len(a) > 3 else 0
                ta = taddr(t) - extra
                hi = (ta + 0x800) >> 12
                lo = ta - (hi << 12)
                out.append(enc_u(hi, tmp, 0x37))
                out.append(enc_i(lo, tmp, 0b000, tmp))
                out.append(enc_i(extra, tmp, 0b000, rd, op=0x67))
            elif mn == 'li':
                out += li_words(a[0], a[1])
            elif mn == 'lui':
                out.append(enc_u(a[1], a[0], 0x37))
            elif mn == 'auipc':
                out.append(enc_u(a[1], a[0], 0x17))
            else:
                raise ValueError('unknown mnemonic ' + mn)
        return out


def with_terminator(body_words):
    """追加结束标记（magic store）+ 自跳循环（只写 x0，不再改变架构状态）。"""
    t = list(body_words)
    t += li_words(31, MAGIC_ADDR)
    t += li_words(30, MAGIC_VAL)
    t.append(enc_s(0, 30, 31, 0b010))       # sw x30, 0(x31)
    t.append(enc_j(0, 0))                   # jal x0, 0  -> 自跳
    return t


# --------------------------------------------------------------------------
# 定向用例
# --------------------------------------------------------------------------
def d_lane():
    a = Asm()
    a.emit('li', 1, 0x2000)
    a.emit('li', 2, 0xDDCCBBAA)
    a.emit('sb', 2, 0, 1)
    a.emit('srli', 3, 2, 8)
    a.emit('sb', 3, 1, 1)
    a.emit('srli', 4, 2, 16)
    a.emit('sb', 4, 2, 1)
    a.emit('srli', 5, 2, 24)
    a.emit('sb', 5, 3, 1)
    a.emit('lw', 6, 0, 1)
    a.emit('lb', 7, 0, 1)
    a.emit('lbu', 8, 0, 1)
    a.emit('lh', 9, 2, 1)
    a.emit('lhu', 10, 2, 1)
    a.emit('lb', 11, 3, 1)
    a.emit('sh', 2, 4, 1)
    a.emit('lhu', 12, 4, 1)
    a.emit('sb', 0, 5, 1)
    a.emit('lhu', 13, 4, 1)
    a.emit('lw', 14, 4, 1)
    a.emit('li', 15, 0x2100)
    a.emit('sw', 2, -4, 15)
    a.emit('lw', 16, -4, 15)
    a.emit('lbu', 17, -1, 15)
    a.emit('lh', 18, -2, 15)
    a.emit('sh', 2, 6, 15)      # 半字按 2 字节对齐（非对齐访问本核不保证语义，参考模型按字节算，故不进用例）
    a.emit('lhu', 19, 6, 15)
    return a


def d_div_edge():
    a = Asm()
    a.emit('li', 1, 0)
    a.emit('li', 2, 1)
    a.emit('li', 3, -1)
    a.emit('li', 4, 0x80000000)
    a.emit('li', 5, 0x7FFFFFFF)
    a.emit('li', 6, 7)
    a.emit('li', 7, -7)
    a.emit('div', 8, 4, 3)
    a.emit('rem', 9, 4, 3)
    a.emit('div', 10, 1, 1)
    a.emit('rem', 11, 1, 1)
    a.emit('div', 12, 6, 1)
    a.emit('rem', 13, 6, 1)
    a.emit('divu', 14, 6, 1)
    a.emit('remu', 15, 6, 1)
    a.emit('div', 16, 7, 6)
    a.emit('rem', 17, 7, 6)
    a.emit('divu', 18, 5, 2)
    a.emit('mul', 19, 4, 3)
    a.emit('mulh', 20, 5, 5)
    a.emit('mulhu', 21, 3, 3)
    a.emit('mulhsu', 22, 7, 5)
    a.emit('mulh', 23, 4, 4)
    a.emit('mulhsu', 24, 4, 5)
    a.emit('divu', 25, 4, 3)
    a.emit('remu', 26, 4, 3)
    a.emit('mul', 27, 1, 5)
    a.emit('div', 28, 5, 7)
    a.emit('rem', 29, 5, 7)
    return a


def d_loaduse():
    a = Asm()
    a.emit('li', 1, 0x2400)
    a.emit('li', 2, 0x11223344)
    a.emit('sw', 2, 0, 1)
    a.emit('lw', 3, 0, 1)          # load
    a.emit('add', 4, 3, 2)         # 立即依赖（load-use 冒险）
    a.emit('sub', 5, 4, 3)
    a.emit('lbu', 6, 0, 1)
    a.emit('and', 7, 6, 3)
    a.emit('lh', 8, 2, 1)
    a.emit('or', 9, 8, 7)
    a.emit('lw', 10, 0, 1)
    a.emit('beq', 10, 2, a.here() + 3)   # 用刚 load 的值做分支条件
    a.emit('li', 11, 0xBAD)
    a.emit('li', 12, 0xBAD)
    a.emit('li', 11, 0x600D)
    a.emit('lw', 13, 0, 1)
    a.emit('sw', 13, 8, 1)         # store 刚 load 的值
    a.emit('lw', 14, 8, 1)
    a.emit('add', 15, 14, 13)
    return a


def d_mulchain():
    a = Asm()
    a.emit('li', 1, 3)
    for i in range(2, 12):
        a.emit('mul', i, i - 1, 1)
    a.emit('li', 12, 0xFFFF)
    a.emit('mulh', 13, 12, 12)
    a.emit('mulhu', 14, 13, 12)
    a.emit('mulhsu', 15, 14, 13)
    a.emit('mul', 16, 15, 14)
    return a


def d_loop():
    a = Asm()
    a.emit('li', 1, 0)          # i
    a.emit('li', 2, 0)          # acc
    a.emit('li', 3, 10)         # n
    top = a.here()
    a.emit('addi', 1, 1, 1)
    a.emit('add', 2, 2, 1)
    a.emit('blt', 1, 3, top)    # 后向分支（循环，压预测器）
    a.emit('li', 4, 0x2800)
    a.emit('li', 5, 0)
    a.emit('li', 6, 5)
    top2 = a.here()
    a.emit('sw', 2, 0, 4)       # 循环里做 store（cache 命中/写直达）
    a.emit('lw', 7, 0, 4)
    a.emit('add', 5, 5, 7)
    a.emit('addi', 4, 4, 4)
    a.emit('addi', 6, 6, -1)
    a.emit('bne', 6, 0, top2)   # 后向分支 2
    a.emit('li', 8, 0)          # acc2
    a.emit('li', 9, 4)
    top3 = a.here()
    a.emit('add', 8, 8, 2)
    a.emit('addi', 9, 9, -1)
    a.emit('bge', 9, 0, top3)
    a.emit('lw', 10, 0, 4)
    return a


def d_x0():
    a = Asm()
    a.emit('addi', 0, 0, 5)
    a.emit('lui', 0, 0x12345)
    a.emit('li', 1, 7)
    a.emit('add', 0, 1, 1)
    a.emit('jal', 0, a.here() + 1)   # 写 x0 = pc+4
    a.emit('addi', 2, 0, 3)
    a.emit('add', 3, 0, 0)           # 读 x0
    a.emit('li', 4, 0x2900)
    a.emit('sw', 0, 0, 4)            # store x0
    a.emit('lw', 5, 0, 4)
    a.emit('mul', 0, 1, 1)
    a.emit('div', 0, 1, 1)
    a.emit('add', 6, 0, 5)
    return a


def d_storeload():
    a = Asm()
    a.emit('li', 1, 0x2A00)
    a.emit('li', 2, 0x11223344)
    a.emit('sw', 2, 0, 1)
    a.emit('lw', 3, 0, 1)
    a.emit('sb', 2, 1, 1)       # 部分覆盖
    a.emit('lw', 4, 0, 1)
    a.emit('sh', 2, 2, 1)
    a.emit('lw', 5, 0, 1)
    a.emit('sw', 2, 0, 1)
    a.emit('sw', 2, 0, 1)       # 连续两次同地址 store
    a.emit('lw', 6, 0, 1)
    a.emit('lw', 7, 0, 1)       # 连续两次同地址 load（第二次必命中）
    a.emit('add', 8, 6, 7)
    a.emit('sw', 2, 4, 1)
    a.emit('lw', 9, 4, 1)
    a.emit('lw', 10, -4, 1)     # 跨行访问
    a.emit('add', 11, 9, 10)
    return a


def d_branchmix():
    a = Asm()
    a.emit('li', 1, 0)
    a.emit('li', 2, 3)
    a.emit('li', 3, 0x400)
    t0 = a.here()
    a.emit('addi', 1, 1, 1)
    a.emit('blt', 1, 2, t0)
    a.emit('bge', 1, 2, a.here() + 2)
    a.emit('li', 4, 0xAA)
    a.emit('li', 4, 0xBB)
    a.emit('bne', 4, 2, a.here() + 2)
    a.emit('li', 5, 0xCC)
    a.emit('li', 5, 0xDD)
    a.emit('bltu', 5, 2, a.here() + 2)
    a.emit('li', 6, 0xEE)
    a.emit('li', 6, 0xFF)
    a.emit('bgeu', 6, 2, a.here() + 2)
    a.emit('li', 7, 1)
    a.emit('li', 7, 2)
    a.emit('beq', 7, 5, a.here() + 2)
    a.emit('li', 8, 9)
    a.emit('li', 8, 10)
    t1 = a.here()
    a.emit('addi', 3, 3, -1)
    a.emit('bne', 3, 0, t1)
    return a


def d_jumpmix():
    a = Asm()
    # 只用「程序内部真实指令地址」做跳转目标，避免跳到数据区造成取指错位
    a.emit('jal', 2, a.here() + 1)        # 跳过下一条
    a.emit('li', 3, 0xBAD)
    a.emit('add', 4, 2, 2)                # 用 link（x2 = 上一条 jal 的 pc+4）
    a.emit('jabs', 6, 7, a.here() + 2)    # lui+addi+jalr 绝对跳转
    a.emit('li', 5, 0xBAD)
    a.emit('add', 8, 4, 6)                # 目标
    a.emit('jabs', 9, 10, a.here() + 2, 8)  # jalr 带非零立即数（extra=8）
    a.emit('li', 11, 0xBAD)
    a.emit('add', 12, 8, 9)
    a.emit('jal', 13, a.here() + 2)       # 跳过一条
    a.emit('li', 14, 0xBAD)
    a.emit('add', 15, 13, 12)
    a.emit('jal', 0, a.here() + 2)        # 写 x0
    a.emit('li', 16, 0xBAD)
    a.emit('add', 17, 15, 12)
    # 用 jalr 做循环回边：地址由 auipc 现算（不依赖发射时的地址），有计数器保证终止
    a.emit('li', 18, 3)
    a.emit('add', 21, 17, 0)
    loop = a.here()
    a.emit('addi', 18, 18, -1)            # loop
    done = a.here() + 4                   # beq 后面还有 auipc/addi/jalr 三条
    a.emit('beq', 18, 0, done)            # 计数到 0 退出
    a.emit('auipc', 19, 0)                # x19 = 本条 auipc 的地址
    a.emit('addi', 19, 19, -8)            # x19 = auipc-8 = loop
    a.emit('jalr', 0, 19, 0)              # jalr 回边
    a.emit('add', 21, 21, 18)             # done
    return a


def d_auipc():
    a = Asm()
    a.emit('auipc', 1, 0)
    a.emit('auipc', 2, 1)
    a.emit('auipc', 3, 0xFFFFF)
    a.emit('add', 4, 1, 2)
    a.emit('sub', 5, 3, 1)
    a.emit('li', 6, -1)
    a.emit('xor', 7, 3, 6)
    return a


def d_shift():
    a = Asm()
    a.emit('li', 1, 0x80000001)
    a.emit('li', 2, 0x7FFFFFFF)
    for sh in (0, 1, 15, 31):
        a.emit('slli', 3, 1, sh)
        a.emit('srli', 4, 1, sh)
        a.emit('srai', 5, 1, sh)
        a.emit('sll', 6, 1, 2)
        a.emit('srl', 7, 1, 2)
        a.emit('sra', 8, 1, 2)
        a.emit('add', 9, 3, 4)
        a.emit('add', 10, 9, 5)
        a.emit('add', 11, 10, 6)
        a.emit('add', 12, 11, 7)
        a.emit('add', 13, 12, 8)
    return a


def d_lane_min():
    """最小化：单字写入后，各种宽度/偏移的读（隔离取字节/半字逻辑）。"""
    a = Asm()
    a.emit('li', 1, 0x2000)
    a.emit('li', 2, 0xDDCCBBAA)
    a.emit('sw', 2, 0, 1)
    a.emit('lb', 3, 0, 1)       # 0xFFFFFFAA
    a.emit('lb', 4, 1, 1)       # 0xFFFFFFBB
    a.emit('lb', 5, 2, 1)       # 0xFFFFFFCC
    a.emit('lb', 6, 3, 1)       # 0xFFFFFFDD
    a.emit('lbu', 7, 3, 1)      # 0x000000DD
    a.emit('lbu', 8, 1, 1)      # 0x000000BB
    a.emit('lh', 9, 0, 1)       # 0xFFFFBBAA
    a.emit('lh', 10, 2, 1)      # 0xFFFFDDCC
    a.emit('lhu', 11, 2, 1)     # 0x0000DDCC
    a.emit('lhu', 12, 0, 1)     # 0x0000BBAA
    a.emit('lw', 13, 0, 1)      # 0xDDCCBBAA
    return a


def d_storelane():
    """最小化：只写一个字节/半字，再整字读回（隔离写掩码/字节通道）。"""
    a = Asm()
    a.emit('li', 1, 0x2000)
    a.emit('li', 2, 0xDDCCBBAA)
    a.emit('sw', 2, 0, 1)
    a.emit('sb', 0, 0, 1)
    a.emit('lw', 3, 0, 1)       # 0xDDCCBB00
    a.emit('sw', 2, 0, 1)
    a.emit('sb', 0, 1, 1)
    a.emit('lw', 4, 0, 1)       # 0xDDCC00AA
    a.emit('sw', 2, 0, 1)
    a.emit('sh', 0, 2, 1)
    a.emit('lw', 5, 0, 1)       # 0x0000BBAA
    a.emit('sw', 2, 0, 1)
    a.emit('sh', 0, 0, 1)
    a.emit('lw', 6, 0, 1)       # 0xDDCC0000
    a.emit('li', 7, 0x11)
    a.emit('sb', 7, 3, 1)
    a.emit('lw', 8, 0, 1)       # 0x11CC0000
    return a


def d_div_min():
    """最小化：同一操作连续两次，看结果是否错位一拍。"""
    a = Asm()
    a.emit('li', 1, 0x64)       # 100
    a.emit('li', 2, 7)
    a.emit('div', 3, 1, 2)      # 14
    a.emit('div', 4, 1, 2)      # 14
    a.emit('rem', 5, 1, 2)      # 2
    a.emit('divu', 6, 1, 2)     # 14
    a.emit('mul', 7, 1, 2)      # 700
    a.emit('div', 8, 1, 0)      # 除零 -> 0xFFFFFFFF
    a.emit('rem', 9, 1, 0)      # 100
    a.emit('mul', 10, 9, 5)     # 200
    return a


def d_loop_min():
    """最小化：纯 ALU 计数循环（无访存、无 M 扩展），只测后向分支。"""
    a = Asm()
    a.emit('li', 1, 0)          # i
    a.emit('li', 2, 0)          # acc
    a.emit('li', 3, 10)         # n
    top = a.here()
    a.emit('addi', 1, 1, 1)
    a.emit('add', 2, 2, 1)
    a.emit('blt', 1, 3, top)
    a.emit('add', 4, 1, 2)
    return a


def d_loop_bne():
    """最小化：bne 倒计数循环（无访存）。"""
    a = Asm()
    a.emit('li', 1, 10)         # 计数器
    a.emit('li', 2, 0)
    top = a.here()
    a.emit('add', 2, 2, 1)
    a.emit('addi', 1, 1, -1)
    a.emit('bne', 1, 0, top)
    a.emit('add', 3, 1, 2)
    return a


def d_fwd_branch():
    """最小化：前向分支（不循环），检查是否同样异常。"""
    a = Asm()
    a.emit('li', 1, 0)
    a.emit('li', 2, 10)
    a.emit('blt', 1, 2, a.here() + 2)    # 0 < 10 -> 跳
    a.emit('li', 3, 0xBAD)
    a.emit('addi', 4, 0, 7)
    a.emit('beq', 1, 1, a.here() + 2)    # 0 == 0 -> 跳
    a.emit('li', 5, 0xBAD)
    a.emit('addi', 6, 0, 9)
    a.emit('bge', 1, 2, a.here() + 2)    # 0 >= 10 假 -> 不跳
    a.emit('addi', 7, 0, 3)
    a.emit('addi', 8, 0, 4)
    return a


def d_div_single():
    """对照 A：一条 div 后面全是非 M 指令（隔离“背靠背”这个变量）。"""
    a = Asm()
    a.emit('li', 1, 100)
    a.emit('li', 2, 7)
    a.emit('div', 3, 1, 2)      # 14
    a.emit('add', 4, 0, 3)      # 用 div 结果
    a.emit('sub', 5, 4, 3)
    a.emit('add', 6, 5, 3)
    return a


def d_div_pair():
    """对照 B：两条背靠背 div，操作数与结果都不同。"""
    a = Asm()
    a.emit('li', 1, 100)
    a.emit('li', 2, 7)
    a.emit('div', 3, 1, 2)      # 14
    a.emit('div', 4, 2, 2)      # 1
    a.emit('add', 5, 4, 3)      # 15
    a.emit('rem', 6, 1, 2)      # 2
    a.emit('add', 7, 6, 5)      # 17
    return a


def d_store_dep_load():
    """最小化：store 的数据操作数来自紧邻的前一条 load（load-use 冒险落在 store 上）。"""
    a = Asm()
    a.emit('li', 1, 0x2500)
    a.emit('li', 2, 0xAABBCCDD)
    a.emit('sw', 2, 0, 1)
    a.emit('lw', 3, 0, 1)       # x3 = 0xAABBCCDD
    a.emit('sw', 3, 4, 1)       # 用刚 load 的值做 store 数据
    a.emit('lw', 4, 4, 1)       # 应读回 0xAABBCCDD
    a.emit('add', 5, 4, 3)
    return a


DIRECTED = [
    ('lane', d_lane), ('div_edge', d_div_edge), ('loaduse', d_loaduse),
    ('mulchain', d_mulchain), ('loop', d_loop), ('x0', d_x0),
    ('storeload', d_storeload), ('branchmix', d_branchmix),
    ('jumpmix', d_jumpmix), ('auipc', d_auipc), ('shift', d_shift),
    ('lane_min', d_lane_min), ('storelane', d_storelane), ('div_min', d_div_min),
    ('loop_min', d_loop_min), ('loop_bne', d_loop_bne), ('fwd_branch', d_fwd_branch),
    ('div_single', d_div_single), ('div_pair', d_div_pair),
    ('store_dep_load', d_store_dep_load),
]


# --------------------------------------------------------------------------
# 随机用例
# --------------------------------------------------------------------------
PTRS = list(range(20, 28))
PTR_BASE = [0x2000 + 0x100 * k for k in range(8)]
GREG = [r for r in range(1, 20)] + [28, 29, 30, 31]


def gen_random(seed, n_items):
    rnd = random.Random(seed)
    a = Asm()
    for k, p in enumerate(PTRS):
        a.emit('li', p, PTR_BASE[k])
    recent = []

    def src():
        if recent and rnd.random() < 0.55:
            return rnd.choice(recent[-8:])
        return rnd.choice(GREG + [0, 0])

    def dst():
        return rnd.choice(GREG)

    branchy = []          # 需要回填目标的操作序号

    while len(a.ops) < n_items:
        c = rnd.random()
        if c < 0.30:
            mn = rnd.choice(list(RTYPE))
            r = dst()
            a.emit(mn, r, src(), src())
            recent.append(r)
        elif c < 0.45:
            mn = rnd.choice(['addi', 'slti', 'sltiu', 'xori', 'ori', 'andi',
                             'slli', 'srli', 'srai'])
            r = dst()
            if mn in ('slli', 'srli', 'srai'):
                a.emit(mn, r, src(), rnd.randint(0, 31))
            else:
                a.emit(mn, r, src(), rnd.randint(-2048, 2047))
            recent.append(r)
        elif c < 0.60:
            mn = rnd.choice(list(LOADS))
            r = dst()
            base = rnd.choice(PTRS)
            if mn in ('lw',):
                imm = 4 * rnd.randint(-256, 255)
            elif mn in ('lh', 'lhu'):
                imm = 2 * rnd.randint(-512, 511)
            else:
                imm = rnd.randint(-1024, 1023)
            a.emit(mn, r, imm, base)
            recent.append(r)
        elif c < 0.70:
            mn = rnd.choice(list(STORES))
            base = rnd.choice(PTRS)
            if mn == 'sw':
                imm = 4 * rnd.randint(-256, 255)
            elif mn == 'sh':
                imm = 2 * rnd.randint(-512, 511)
            else:
                imm = rnd.randint(-1024, 1023)
            a.emit(mn, src(), imm, base)
        elif c < 0.80:
            mn = rnd.choice(list(BRANCHES))
            i = a.emit(mn, src(), src(), 0)
            branchy.append(i)
        elif c < 0.87:
            r = dst()
            i = a.emit('jal', r, 0)
            branchy.append(i)
            recent.append(r)
        elif c < 0.93:
            r, tmp = dst(), dst()
            i = a.emit('jabs', r, tmp, 0)
            branchy.append(i)
            recent.append(r)
            recent.append(tmp)
        else:
            r = dst()
            if rnd.random() < 0.5:
                a.emit('lui', r, rnd.randint(0, 0xFFFFF))
            else:
                a.emit('auipc', r, rnd.randint(0, 0xFFFF))
            recent.append(r)

    # 只允许前向跳转 => 必然终止（且必然走到结束标记）
    n = len(a.ops)
    for i in branchy:
        a.ops[i][1][-1] = rnd.randint(i + 1, n)
    return a


# --------------------------------------------------------------------------
NOP = 0x00000013
ECALL = 0x00000073


def with_ecall(body_words, pad=24):
    """交叉验证用变体：正文 + 一批 NOP + ecall，供工程自带 tb_iverilog.sv 收尾。

    末尾补足 NOP 是为了让正文指令在 ecall 到达译码级之前全部提交，
    从而绕开自带测试台「ecall 进 ID 后再等 8 拍」的排空窗口不确定性。
    """
    return list(body_words) + [NOP] * pad + [ECALL]


def write_test(outdir, name, words, ref):
    regs, mem = ref.snapshot()
    with open(os.path.join(outdir, name + '.hex'), 'w') as f:
        for w in words:
            f.write('%08x\n' % w)
    with open(os.path.join(outdir, name + '.exp'), 'w') as f:
        json.dump({'regs': regs, 'mem': {str(k): v for k, v in mem.items()},
                   'steps': ref.steps, 'ninstr': len(words)}, f)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else 'tests'
    n_rand = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    os.makedirs(outdir, exist_ok=True)
    names = []

    for name, fn in DIRECTED:
        body = fn().assemble()
        words = with_terminator(body)
        write_test(outdir, name, words, _run_ref(words))
        with open(os.path.join(outdir, name + '_ecall.hex'), 'w') as f:
            for w in with_ecall(body):
                f.write('%08x\n' % w)
        names.append(name)

    for k in range(n_rand):
        seed = 1000 + k
        n_items = random.Random(seed).randint(60, 160)
        body = gen_random(seed, n_items).assemble()
        words = with_terminator(body)
        write_test(outdir, 'rnd%03d' % k, words, _run_ref(words))
        with open(os.path.join(outdir, 'rnd%03d_ecall.hex' % k), 'w') as f:
            for w in with_ecall(body):
                f.write('%08x\n' % w)
        names.append('rnd%03d' % k)

    with open(os.path.join(outdir, 'manifest.txt'), 'w') as f:
        f.write('\n'.join(names) + '\n')
    print('generated %d tests into %s' % (len(names), outdir))


def _run_ref(words):
    """用参考模型执行给定的字序列（程序装载到地址 0）。"""
    ref = RefISS()
    ref.code_bytes = 4 * len(words)
    for i, w in enumerate(words):
        ref.mem[4 * i] = w & 0xFF
        ref.mem[4 * i + 1] = (w >> 8) & 0xFF
        ref.mem[4 * i + 2] = (w >> 16) & 0xFF
        ref.mem[4 * i + 3] = (w >> 24) & 0xFF
    ref.run()
    return ref


if __name__ == '__main__':
    main()
