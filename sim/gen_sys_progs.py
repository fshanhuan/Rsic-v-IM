#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sim/gen_sys_progs.py -- 生成 v10.2 系统指令专项回归程序。

覆盖 v10.2 修掉/补全的四块（原来是**完全没人跑过**的指令区）：
  1) CSR 指令全子集：csrrw / csrrs / csrrc / csrrwi / csrrsi / csrrci
     —— 原来 011（csrrc）算成 rs1+csr_addr、读写数据取错、立即数形式直接判非法；
        并且 csrrc 的"rs1=x0 的纯读"会把 CSR 清 0；
  2) CSR 读的 RAW 前递：`csrw` 紧跟 `csrr`（中间只隔一条）必须读到新值；
  3) 中断（机器软件中断 MSI + 机器定时器中断 MTI）：mcause=0x8000_0000 / 0x8000_0007，
     mepc 必须指向**还没执行**的那条指令（mret 回去要重执行，不能跳过）；
  4) fence.i：必须"清 I-Cache 后顺序继续"，原来它落到了 dnpc 的 mtvec 分支 → 直接跑飞；
  5) ebreak：mcause=3、mtval=mepc=ebreak 自己的 PC（原来被当合法空操作静默放过）。

程序布局统一为：主程序 0x000 起，异常/中断处理程序 0x300 起（MTVEC）。
收尾统一是 `addi x10,x0,1` + 自跳转（`jal x0,0`）—— 测试台在**看到 x10 写回 1 的那一拍**
取寄存器现场，因此不受"之后还会不会进 handler"影响。

用法：
    python3 sim/gen_sys_progs.py            # 生成 4 个 .hex
期望值见文件末尾的打印，以及 sim/tb_sys.sv 里的判据。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# 复用 exc 程序生成器的汇编小工具（那边 __main__ 有 guard，import 无副作用）
from gen_exc_progs import r, i, s, b, u, j, la, li, assemble, write_hex, NOP  # noqa: E402

OP_R, OP_I0, OP_I1, OP_I2 = 0x33, 0x03, 0x13, 0x67
OP_S, OP_B, OP_U0, OP_J, OP_SYS, OP_MISC = 0x23, 0x63, 0x37, 0x6F, 0x73, 0x0F

F3_CSRRW, F3_CSRRS, F3_CSRRC = 0b001, 0b010, 0b011
F3_CSRRWI, F3_CSRRSI, F3_CSRRCI = 0b101, 0b110, 0b111

CSR_MSTATUS, CSR_MTVEC, CSR_MSCRATCH = 0x300, 0x305, 0x340
CSR_MISA = 0x301
CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP = 0x341, 0x342, 0x343, 0x344
CSR_MIE, CSR_MVENDORID, CSR_MARCHID = 0x304, 0xF11, 0xF12
CSR_MHARTID = 0xF14
CSR_MIMPID, CSR_MCONFIGPTR = 0xF13, 0xF15
CSR_MTIME, CSR_MTIMECMP = 0x7C0, 0x7C1

# ---- v12（B）Zicntr：标准计数器（para.sv 的 `CSR_mcycle ... 同名）----
CSR_MCYCLE,   CSR_MINSTRET   = 0xB00, 0xB02
CSR_MCYCLEH,  CSR_MINSTRETH  = 0xB80, 0xB82
CSR_CYCLE,    CSR_TIME       = 0xC00, 0xC01
CSR_INSTRET,  CSR_CYCLEH     = 0xC02, 0xC80
CSR_TIMEH,    CSR_INSTRETH   = 0xC81, 0xC82

MRET = 0x30200073
EBREAK = 0x00100073
FENCE_I = 0x0000100F
ECALL = 0x00000073
JAL_X0_0 = 0x0000006F          # jal x0, 0  → 原地自跳（收尾后原地停住）

MTVEC = 0x300

M_STATUS_MPP_MIE = 0x1808      # MPP=M(0x1800) | MIE(bit3)
M_STATUS_MPP = 0x1800


def csr(f3, rd, rs1_or_uimm, addr):
    """CSR 指令编码：f3 决定 是 rw/rs/rc 与 寄存器/立即数 形式。"""
    return i(OP_SYS, f3, rd, rs1_or_uimm, addr)


class Prog:
    """带地址推进的极简汇编器（写起来比手工算偏移清楚）。"""

    def __init__(self):
        self.w = {}
        self.a = 0

    def at(self, addr):
        self.a = addr
        return self

    def emit(self, ins, n=1):
        for k in range(n):
            self.w[self.a] = ins
            self.a += 4
        return self

    def li(self, rd, val):
        for ins in li(rd, val):
            self.emit(ins)

    def la(self, rd, addr):
        for ins in la(rd, addr):
            self.emit(ins)

    def label(self):
        return self.a

    def branch_here(self, f3, rs1, rs2, target):
        """向 target 分支（相对位移 = target - 本条地址）。"""
        self.emit(b(OP_B, f3, rs1, rs2, target - self.a))

    def jal_here(self, rd, target):
        self.emit(j(OP_J, rd, target - self.a))

    def mem(self):
        return assemble(self.w)


# =====================================================================
# 公共：异常处理程序（skip4=True 表示"跳过出错指令"，即 mepc+=4）
# =====================================================================
def trap_handler(p, skip4=True, clr_msi=False, clr_mtip=False):
    """放在 MTVEC 的异常/中断处理程序。

    记录 mcause→x20 / mepc→x21 / mtval→x22，计数 x23，mstatus→x24（陷入时的现场）。
    skip4=True  ：mepc += 4 后 mret（同步异常/断点：跳过出错指令继续）
    skip4=False ：直接 mret（**中断**语义：回到还没执行的那条，重执行）
    clr_msi     ：csrrw x0, mip, x0        清 MSIP（否则软件中断会一直挂着）
    clr_mtip    ：csrrw x0, mtimecmp, x27 写 0xFFFFFFFF 清 MTIP
    """
    p.at(MTVEC)
    p.emit(csr(F3_CSRRS, 20, 0, CSR_MCAUSE))
    p.emit(csr(F3_CSRRS, 21, 0, CSR_MEPC))
    p.emit(csr(F3_CSRRS, 22, 0, CSR_MTVAL))
    p.emit(i(OP_I1, 0b000, 23, 23, 1))                 # addi x23, x23, 1
    if clr_msi:
        p.emit(csr(F3_CSRRW, 0, 0, CSR_MIP))           # csrrw x0, mip, x0
    if clr_mtip:
        p.li(27, -1)                                   # addi x27, x0, -1  → 0xFFFFFFFF
        p.emit(csr(F3_CSRRW, 0, 27, CSR_MTIMECMP))     # csrrw x0, mtimecmp, x27
    p.emit(csr(F3_CSRRS, 24, 0, CSR_MSTATUS))          # 记陷入时的 mstatus
    if skip4:
        p.emit(i(OP_I1, 0b000, 21, 21, 4))             # mepc += 4
        p.emit(csr(F3_CSRRW, 0, 21, CSR_MEPC))
    p.emit(MRET)
    return p


def prologue(p, mtvec=MTVEC, clear_regs=(20, 21, 22, 23, 24)):
    """设 mtvec + 清现场寄存器。第 1 条之前必须先 at(0)。"""
    p.at(0x000)
    p.la(1, mtvec)
    p.emit(csr(F3_CSRRW, 0, 1, CSR_MTVEC))
    for rd in clear_regs:
        p.emit(i(OP_I1, 0b000, rd, 0, 0))
    return p


def finish(p):
    """x10=1 表示"跑到结尾"，然后原地自跳（测试台看 x10 的写回事件取现场）。"""
    p.emit(i(OP_I1, 0b000, 10, 0, 1))
    p.emit(JAL_X0_0)
    return p


# =====================================================================
# 1) CSR 指令全子集 + 读后写 / 写后读（RAW 前递）
# =====================================================================
def gen_csr():
    p = Prog()
    trap_handler(p, skip4=True)          # 本程序不期望陷入，留着只为兜底
    prologue(p)

    p.la(1, 0x12345678)
    p.emit(csr(F3_CSRRW, 5, 1, CSR_MSCRATCH))      # x5 = 旧值(0)，mscratch = 0x12345678
    p.emit(i(OP_I1, 0b000, 6, 0, 1))               # 空一条
    # ★ 只隔一条指令就读：读在 ID、写在 WB，必须靠影子链前递才对
    p.emit(csr(F3_CSRRS, 7, 0, CSR_MSCRATCH))      # x7 = 0x12345678（RAW 前递）
    p.la(2, 0x0000F000)
    p.emit(csr(F3_CSRRS, 8, 2, CSR_MSCRATCH))      # x8 = 旧 0x12345678；mscratch |= 0xF000
    p.emit(csr(F3_CSRRS, 9, 0, CSR_MSCRATCH))      # x9 = 0x1234F678
    p.la(3, 0x0000F000)
    p.emit(csr(F3_CSRRC, 11, 3, CSR_MSCRATCH))     # x11 = 0x1234F678；mscratch &= ~0xF000
    # ★ rs1=x0 的 csrrc 是**纯读**：原实现会把 mscratch 清成 0
    p.emit(csr(F3_CSRRC, 12, 0, CSR_MSCRATCH))     # x12 = 0x12340678，mscratch 不变
    p.emit(csr(F3_CSRRS, 13, 0, CSR_MSCRATCH))     # x13 = 0x12340678
    # 立即数形式（原来直接判非法 → 陷入 → 被测程序早就跑飞了）
    p.emit(csr(F3_CSRRWI, 14, 0x1F, CSR_MSCRATCH))  # x14 = 0x12340678；mscratch = 31
    p.emit(csr(F3_CSRRSI, 15, 0x01, CSR_MSCRATCH))  # x15 = 31；mscratch = 31
    p.emit(csr(F3_CSRRCI, 16, 0x02, CSR_MSCRATCH))  # x16 = 31；mscratch = 29
    p.emit(csr(F3_CSRRS, 17, 0, CSR_MSCRATCH))      # x17 = 29
    # 只读 CSR 的**纯读**（rs1=x0）：这是"|csr_wen 判 CSR 指令"最坏的场合 —— 读的是
    #   只读寄存器，`|csr_wen` 仍然被 bit8 标记置位，rd 必须是**读值**而不是 ALU 新值。
    #   ★ v10.3 起这一条必须写 rs1=x0：带非零 rs1 的读是**写尝试**，规范要求它陷入非法指令
    #     （原来这里是 rs1=x4=0x7EF，v10.3 加了只读地址检查后它就会陷入 —— 那是正确行为，
    #      所以用例本身改成纯读；"写只读要陷入"由 sys_zicsr.hex 专门覆盖）。
    p.emit(csr(F3_CSRRS, 18, 0, CSR_MVENDORID))     # x18 = 0x79737978
    p.emit(csr(F3_CSRRS, 19, 0, CSR_MARCHID))       # x19 = 0x016FBCBD
    p.emit(csr(F3_CSRRS, 25, 0, CSR_MTIMECMP))      # x25 = 0xFFFFFFFF（复位值，只读观察）
    p.emit(csr(F3_CSRRS, 26, 0, CSR_MSTATUS))       # x26 = 0x00001800（MPP=M, MIE=0）
    finish(p)
    return p.mem()


# =====================================================================
# 2) 中断：MSI 一次 + MTI 一次
# =====================================================================
def gen_intr():
    p = Prog()
    trap_handler(p, skip4=False, clr_msi=True, clr_mtip=True)
    prologue(p, clear_regs=(20, 21, 22, 23, 24, 5, 6, 26, 27))

    # ---- 第 1 次：机器软件中断（mie[0]=1, mip[0]=1）----
    p.emit(i(OP_I1, 0b000, 2, 0, 1))
    p.emit(csr(F3_CSRRW, 0, 2, CSR_MIE))            # mie = MSI
    p.emit(csr(F3_CSRRW, 0, 2, CSR_MIP))            # mip.MSIP = 1（此时 MIE=0，不触发）
    p.la(3, M_STATUS_MPP_MIE)
    p.emit(csr(F3_CSRRW, 0, 3, CSR_MSTATUS))        # MIE=1 → 中断立刻会被接收
    # ★ 这段累加和是"中断精确性"的判据：中断必须回到**没执行过**的那条指令，
    #   少执行一条 → x5 != 55。mepc 若错指向下一条，跳过的那条就永久丢了。
    for k in range(1, 11):
        p.emit(i(OP_I1, 0b000, 5, 5, k))            # x5 += k  (1..10 → 55)
    # ---- 第 2 次：机器定时器中断 ----
    p.emit(i(OP_I1, 0b000, 4, 0, 0x80))
    p.emit(csr(F3_CSRRW, 0, 4, CSR_MIE))            # 只留 MTI（MSI 已在 handler 里清掉）
    p.emit(csr(F3_CSRRW, 0, 0, CSR_MTIMECMP))       # mtimecmp = 0 → mtime >= 0 恒成立 → MTIP
    for k in range(3, 8):
        p.emit(i(OP_I1, 0b000, 6, 6, k))            # x6 += 3..7 → 25（同样被中断打断）
    p.emit(i(OP_I1, 0b000, 26, 0, 0x5A))            # 走完到这里 = 两次中断都返回了
    finish(p)
    return p.mem()


# =====================================================================
# 3) fence.i：清 I-Cache 后**顺序继续**（不许跳 mtvec）
# =====================================================================
def gen_fencei():
    p = Prog()
    trap_handler(p, skip4=True)
    prologue(p, clear_regs=(20, 21, 22, 23, 24, 5, 6, 7))

    p.emit(i(OP_I1, 0b000, 5, 5, 1))                # x5 = 1
    p.emit(FENCE_I)                                 # 第 1 条 fence.i
    p.emit(i(OP_I1, 0b000, 6, 5, 2))                # x6 = x5+2 = 3（证明往下走了）
    # 循环里再放 fence.i：让"每次循环都清一次 I-Cache"也跑一遍
    p.emit(i(OP_I1, 0b000, 7, 0, 3))                # x7 = 3 (上限)
    loop = p.label()
    p.emit(i(OP_I1, 0b000, 5, 5, 1))                # x5 += 1
    p.emit(FENCE_I)                                 # 第 2/3/4 条 fence.i
    p.branch_here(0b100, 5, 7, loop)                # blt x5, x7, loop   (x5<x7 → 0x100=f3=100)
    p.emit(i(OP_I1, 0b000, 6, 6, 4))                # x6 = 3+4 = 7
    finish(p)
    return p.mem()


# =====================================================================
# 4) ebreak：mcause=3, mepc=mtval=ebreak 自己的 PC
# =====================================================================
def gen_ebreak():
    p = Prog()
    trap_handler(p, skip4=True)
    prologue(p, clear_regs=(20, 21, 22, 23, 24, 5))
    p.emit(i(OP_I1, 0b000, 5, 0, 7))                # x5 = 7
    ebk = p.label()
    p.emit(EBREAK)                                  # ← 期望 mepc == mtval == 这个地址
    p.emit(i(OP_I1, 0b000, 5, 5, 1))                # x5 = 8（handler 跳回 ebreak+4 才会执行）
    p.emit(i(OP_I1, 0b000, 26, 0, 0x33))            # x26 = 0x33（证明恢复了）
    finish(p)
    return p.mem(), ebk


# =====================================================================
# 5) Zicsr 一致性专项（v10.3）：非法 CSR 访问的陷入 + 可写性 + WARL
# =====================================================================
# 判据全部围绕规范原文（Zicsr §5.1.1 + 特权规范 §1.1）：
#   · "Attempts to write a read-only register raise illegal-instruction exceptions."
#     → 只读段（csr[11:10]=11）的**写尝试**必须陷入；纯读（rs1=x0 / uimm=0）不许陷入。
#       "写尝试"的判据就是同一个 csr_wr：CSRRW/CSRRWI 恒算写，CSRRS/C 只有源非零才算。
#   · "Instructions that access a non-existent CSR are reserved."
#     → 本核按惯例报非法指令（0x7C2 这种落在自定义 R/W 段但没实现的地址也算不存在）。
#   · 陷入必须**零副作用**：rd 不许被写、CSR 不许被改（这是 illegal_flag→no_side_effect 的判据）。
#   · 可写性：mtval(0x343) 是 MRW、mtime(0x7C0) 属 Custom read/write → 写了必须能读回来。
#   · WARL：misa 写入被忽略；mip 只有 MSIP 可写；mstatus 的 MPP 恒 3（见 tb 检查项）。
def gen_zicsr():
    p = Prog()
    trap_handler(p, skip4=True)
    prologue(p, clear_regs=(20, 21, 22, 23, 24, 28))

    # ---- T1 只读 CSR 纯读：合法 ----
    p.emit(csr(F3_CSRRS, 5, 0, CSR_MVENDORID))      # x5 = 0x79737978

    # ---- T2 csrrw 写只读地址（rs1=x0 也算写）→ 陷入；rd 与 CSR 都不得被改 ----
    p.emit(csr(F3_CSRRW, 6, 0, CSR_MVENDORID))      # 陷入；x6 必须还是 0
    p.emit(csr(F3_CSRRS, 19, 0, CSR_MVENDORID))     # x19 = 0x79737978（写入被陷入挡掉）

    # ---- T3 csrrs 带非零 rs1 写只读地址 → 同样陷入 ----
    p.li(1, 1)
    p.emit(csr(F3_CSRRS, 7, 1, CSR_MVENDORID))      # 陷入；x7 必须还是 0

    # ---- T4 立即数 uimm=0 的纯读：合法 ----
    p.emit(csr(F3_CSRRSI, 8, 0, CSR_MARCHID))       # x8 = 0x016FBCBD
    # ---- T5 立即数 uimm!=0 写只读地址 → 陷入 ----
    p.emit(csr(F3_CSRRCI, 9, 3, CSR_MARCHID))       # 陷入；x9 必须还是 0

    # ---- T6/T7 不存在的 CSR：读也陷入、写也陷入 ----
    p.emit(csr(F3_CSRRS, 11, 0, 0x7C2))             # 陷入；x11 必须还是 0
    p.emit(csr(F3_CSRRW, 0, 1, 0x7C3))              # 陷入

    # ---- T8 misa：可读；地址属 R/W 段所以写不陷入，但写入被忽略（WARL） ----
    p.emit(csr(F3_CSRRS, 12, 0, CSR_MISA))          # x12 = 0x40001100
    p.emit(csr(F3_CSRRW, 13, 1, CSR_MISA))          # x13 = 0x40001100（旧值）；写入丢弃
    p.emit(csr(F3_CSRRS, 14, 0, CSR_MISA))          # x14 = 0x40001100（确认没被改）
    # ---- T8b mhartid：单 hart 常量 0，且**不许陷入**（先塞非零值证明真的读到了 0）----
    p.la(27, 0x1234)
    p.emit(csr(F3_CSRRS, 27, 0, CSR_MHARTID))       # x27 = 0
    # ---- T8c mimpid / mconfigptr：规范要求 mimpid "must be readable in any implementation"
    #      （读 0 表示未实现）→ **可读、读 0、不陷入**。v10.3 让它们陷入是错的，v10.3b 修掉。
    p.la(30, 0x12345)
    p.emit(csr(F3_CSRRS, 30, 0, CSR_MIMPID))        # x30 = 0
    p.la(31, 0x23456)
    p.emit(csr(F3_CSRRS, 31, 0, CSR_MCONFIGPTR))    # x31 = 0

    # ---- T9 mtval 软件可写（v10.3 才补的写位）----
    # ★ 这里故意隔 6 条 NOP 再读：CSR 读口有 4 深前递链（EX + sh[0..3]，覆盖前 5 条在途写），
    #   隔得不够远的话读到的是**前递值**而不是寄存器本体 —— 那样"写位根本没接上"这种
    #   变异（zicsr_mtval_ro）会被前递掩盖成 PASS。实测 5 条距离仍在窗口内，6 条才落到窗口外。
    p.la(2, 0xDEADBEEF)
    p.emit(csr(F3_CSRRW, 0, 2, CSR_MTVAL))          # mtval = 0xDEADBEEF
    p.emit(NOP, 6)
    p.emit(csr(F3_CSRRS, 15, 0, CSR_MTVAL))         # x15 = 0xDEADBEEF（真从寄存器读）

    # ---- T10 rd=x0 的 csrrw 仍然要写寄存器 ----
    p.la(3, 0x55AA55AA)
    p.emit(csr(F3_CSRRW, 0, 3, CSR_MSCRATCH))       # mscratch = 0x55AA55AA
    p.emit(NOP, 6)
    p.emit(csr(F3_CSRRS, 16, 0, CSR_MSCRATCH))      # x16 = 0x55AA55AA

    # ---- T11 mtime 软件可写（0x7C0 属 Custom read/write 段）----
    p.la(4, 0x1000)
    p.emit(csr(F3_CSRRW, 0, 4, CSR_MTIME))          # mtime = 0x1000（分频计数器同时清零）
    p.emit(NOP, 6)
    p.emit(csr(F3_CSRRS, 17, 0, CSR_MTIME))         # x17 = 0x1000

    # ---- T12 mip 的 WARL：只有 MSIP 可写，其余位读回 0 ----
    #   这里要读**两次、走两条不同的路**：
    #     · 距离 5（4 条 NOP）→ 读到的是前递值，验证"前递也过 WARL 掩码"
    #       （不加掩码就会读到 ALU 原值 0xFFFFFFFF —— v10.3 自己踩过的 bug）
    #     · 距离 7（再 6 条 NOP）→ 读到的是寄存器本体，验证"寄存器里真的只存了 1"
    p.li(4, -1)
    p.emit(csr(F3_CSRRW, 0, 4, CSR_MIP))            # 写 0xFFFFFFFF
    p.emit(NOP, 4)
    p.emit(csr(F3_CSRRS, 18, 0, CSR_MIP))           # x18 = 0x1（前递路径）
    p.emit(NOP, 6)
    p.emit(csr(F3_CSRRS, 26, 0, CSR_MIP))           # x26 = 0x1（寄存器路径）

    # ---- T13 SYSTEM funct3=100（保留）→ 非法指令，mtval = 指令编码 ----
    p.li(28, p.label() + 4)                         # x28 = 下面那条非法指令的地址
    p.emit(csr(0b100, 0, 0, CSR_MSCRATCH))          # 0x3400_4073
    # ★ 用 la 而不是 li：li() 只有一条 addi（12 位有符号立即数），0x600D 会被截成 0x00D
    p.la(25, 0x600D)                                # x25 = 0x600D（证明恢复了）
    finish(p)
    return p.mem()


# =====================================================================
# 5) v12（B）Zicntr：mcycle / minstret（64 位，拆低高两个 CSR）
# ---------------------------------------------------------------------
# 这个用例要证的四件事，每一件都对应一处"容易做成假实现"的地方：
#   Z1  minstret **每条指令 +1**：直线代码 8 条 addi 夹在两次 csrr 之间，
#       差值必须**恰好 9**（8 条在中间 + 收尾那条自己）。差 1 或差几十都说明
#       计数口径错了（比如把停顿拍数也数进去、或按 WB 电平数成多拍）。
#   Z2  mcycle 可写 + **读口 RAW 前递**：`csrw mcycle, x0` 紧跟 `csrr` 必须读回 0。
#       这条专门证新加的 bit11~bit14 三个位图（写使能 / 读选择 / 影子链）都接上了
#       —— 少了读选择位，读到的会是旧计数（几拍），不是 0。
#   Z3  只读影子 `cycle/cycleh/instret` 可读（不陷入），且 `instret` 与 `minstret`
#       指向**同一个**计数器（不是两份状态）。
#   Z4  写只读影子 `cycle` → 非法指令（mcause=2），且 rd 不被写（零副作用）；
#       陷入之后计数器**继续走**（handler 里也执行了指令）。
def gen_zicntr():
    p = Prog()
    trap_handler(p, skip4=True)
    prologue(p, clear_regs=(20, 21, 22, 23, 24,
                            5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19))

    # ---- Z1：minstret 直线代码里每条 +1 ----
    p.emit(csr(F3_CSRRS, 5, 0, CSR_MINSTRET))      # x5 = minstret（采样点 A）
    for _ in range(8):
        p.emit(i(OP_I1, 0b000, 18, 18, 1))         # 8 条 addi x18,x18,1
    p.emit(csr(F3_CSRRS, 6, 0, CSR_MINSTRET))      # x6 = minstret（采样点 B）
    p.emit(r(OP_R, 0b000, 0x20, 7, 6, 5))          # x7 = x6 - x5  → 必须是 9

    # ---- Z2：mcycle/mcycleh 可写 + 前递（d=1，靠 RAW 前递读到 0）----
    p.emit(csr(F3_CSRRW, 0, 0, CSR_MCYCLE))        # csrw mcycle, x0（清零低半）
    p.emit(csr(F3_CSRRS, 8, 0, CSR_MCYCLE))        # x8 = 0（前递；没前递会读到几十拍）
    p.emit(csr(F3_CSRRW, 0, 0, CSR_MCYCLEH))       # csrw mcycleh, x0（清高高半）
    p.emit(csr(F3_CSRRS, 9, 0, CSR_MCYCLEH))       # x9 = 0（前递）

    # ---- Z2b：**寄存器本体**确实被清零（不能只靠前递证明）----
    #   前递窗口只有 5 个指令槽（EX + 4 深影子链），所以插 6 条 NOP 让窗口过期，
    #   之后的 csrr 只能读寄存器。此时 mcycle = 从清零那拍起数的几拍，必须很小；
    #   没有清零的话这里是程序已经跑了 ~50 拍的计数，一眼就能区分。
    #   ★ 这一条踩过坑：一开始没插 NOP，读到的是**清零前**的 41，因为 ID→WB 有 5 拍，
    #     而当时 `cycle` 别名在 csr_onehot 里没有位 → 绕过前递直接读到了旧寄存器值。
    p.emit(csr(F3_CSRRW, 0, 0, CSR_MCYCLE))        # 再清一次（这次要验寄存器）
    p.emit(NOP, 6)
    p.emit(csr(F3_CSRRS, 11, 0, CSR_CYCLE))        # x11 = 很小的数（证明寄存器真的清了）
    p.emit(csr(F3_CSRRS, 12, 0, CSR_CYCLEH))       # x12 = 0

    # ---- Z3：只读影子 ----
    p.emit(csr(F3_CSRRS, 13, 0, CSR_INSTRET))      # x13 = instret
    p.emit(csr(F3_CSRRS, 14, 0, CSR_MINSTRET))     # x14 = minstret（同一个计数器，x14>=x13）
    p.emit(csr(F3_CSRRS, 15, 0, CSR_TIME))         # x15 = time（= mtime，1MHz 墙钟，很小）
    p.emit(csr(F3_CSRRS, 16, 0, CSR_TIMEH))        # x16 = 0（mtime 只有 32 位，高位读 0）

    # ---- Z4：写只读影子 → 非法指令；陷入后计数器继续走 ----
    p.emit(csr(F3_CSRRW, 17, 0, CSR_CYCLE))        # 陷阱（mcause=2），x17 保持 0
    p.emit(csr(F3_CSRRS, 18, 0, CSR_MINSTRET))     # x18 = 陷阱之后的 minstret
    p.emit(r(OP_R, 0b000, 0x20, 19, 18, 14))       # x19 = x18 - x14 > 0（handler 也执行了指令）

    p.la(25, 0x600D)                               # 走到尾的标记
    finish(p)
    return p.mem()


if __name__ == "__main__":
    write_hex("sys_csr.hex", gen_csr())
    intr_mem = gen_intr()
    write_hex("sys_intr.hex", intr_mem)
    write_hex("sys_fencei.hex", gen_fencei())
    ebk_mem, ebk_addr = gen_ebreak()
    write_hex("sys_ebreak.hex", ebk_mem)
    write_hex("sys_zicsr.hex", gen_zicsr())
    write_hex("sys_zicntr.hex", gen_zicntr())
    print("done. 期望：")
    print("  sys_csr.hex    x5=0 x7=x8=0x12345678 x9=x11=0x1234F678 x12=x13=0x12340678")
    print("                 x14=0x12340678 x15=x16=31 x17=29 x18=0x79737978 x19=0x016FBCBD")
    print("                 x25=0xFFFFFFFF x26=0x1800  x23=0(无陷入)")
    print("  sys_intr.hex   x5=55 x6=25 x23=2 x20=0x80000007 x24=0x1880 x26=0x5A")
    print("  sys_fencei.hex x5=3 x6=7 x23=0(不许跳 mtvec) icache_clr 3 次（循环体跑 2 遍 + 循环前 1 条）")
    print("  sys_ebreak.hex x5=8 x23=1 x20=3 x21=x22=0x%08X" % ebk_addr)
    print("  sys_zicsr.hex  x5=0x79737978 x6=x7=x9=x11=0 x8=0x016FBCBD x19=0x79737978")
    print("                 x12=x13=x14=0x40001100 x15=0xDEADBEEF x16=0x55AA55AA x17=0x1000")
    print("                 x18=1 x25=0x600D x23=6(6 次非法指令陷入) x20=2 x22=0x34004073")
    print("                 x26=1（mip 从寄存器路径再读一次）x27=0（mhartid，先塞 0x1234 再读）")
    print("                 x30=0（mimpid，先塞 0x12345）x31=0（mconfigptr，先塞 0x23456）")
    print("                 x28 == x21-4（mepc 精确指向非法指令本身）")
