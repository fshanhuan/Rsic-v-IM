#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/gen_mrettest.py -- 验证 `csrw mstatus, x` 紧跟 `mret` 的语义

背景（v13）：FreeRTOS 端口在返回前会
    csrw mstatus, <保存值>     ; 恢复任务的中断使能位
    mret
而实测第一次 yield（ecall）之后 mstatus 变成 0x1800（MIE=0、MPIE=0），
中断就此永久关闭。嫌疑：`csrw mstatus` 在 WB 才落盘（4~5 拍），而 `mret`
在 ID 就执行了它自己的 mstatus 更新（MIE<=MPIE、MPIE<=1）—— 两者顺序颠倒。

本程序把这条序列单独做出来（纯汇编，handler 里只碰 t 寄存器，不破坏现场）：

    _start: mtvec=handler; mstatus.MIE=1; ecall
    handler: li t0,0x1880 (MIE=0,MPIE=1,MPP=3); csrw mstatus,t0; mret
    回来之后: x10 = mstatus

期望 x10 = 0x00001888（MIE=MPIE=1）。
若 x10 = 0x00001800 → csrw 覆盖了 mret 的结果（MIE 丢失）；
若 x10 = 0x00001880 → mret 先执行、csrw 后落盘（同样丢掉 MIE）。

用法：
    python3 sw/gen_mrettest.py
    vvp sim/build/tb_mini.vvp +prog=sim/mrettest.hex +cycles=400 +x10=6280
    （6280 = 0x1888）
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ---------------- RV32I 编码 ----------------
def I(op, rd, f3, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def U(op, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

def J(op, rd, imm):
    im = imm & 0x1FFFFF
    return (((im >> 20) & 1) << 31) | (((im >> 1) & 0x3FF) << 21) | \
           (((im >> 11) & 1) << 20) | (((im >> 12) & 0xFF) << 12) | (rd << 7) | op

def addi(rd, rs1, imm): return I(0x13, rd, 0, rs1, imm)
def lui(rd, imm20):     return U(0x37, rd, imm20)
def csrrw(rd, csr, rs1): return I(0x73, rd, 1, rs1, csr)
def csrrs(rd, csr, rs1): return I(0x73, rd, 2, rs1, csr)
def csrr(rd, csr):       return csrrs(rd, csr, 0)
def csrw(csr, rs1):      return csrrw(0, csr, rs1)
def ecall():             return 0x00000073
def mret():              return 0x30200073
def mv(rd, rs):          return addi(rd, rs, 0)


def build():
    p = []

    # ---- _start ----
    p.append(lui(2, 0x20))              # sp = 0x20000（本测试不压栈，仅占位）
    la_idx = len(p)
    p.append(U(0x17, 5, 0))             # auipc t0, <hi>   （占位，稍后回填）
    p.append(addi(5, 5, 0))             # addi  t0, t0, <lo>
    p.append(csrw(0x305, 5))            # mtvec = handler
    p.append(addi(5, 0, 0x8))
    p.append(csrrs(0, 0x300, 5))        # mstatus.MIE = 1
    p.append(addi(5, 0, 0x80))
    p.append(csrrs(0, 0x300, 5))        # mstatus.MPIE = 1（模拟正常现场）
    p.append(ecall())                   # 触发陷入（mcause=11, MIE<=MPIE 由硬件做）
    p.append(csrr(10, 0x300))           # 回来之后：x10 = mstatus
    p.append(J(0x6F, 0, 0))             # 自旋

    # ---- handler：csrw mstatus 紧跟 mret ----
    handler = len(p)
    p.append(lui(5, 0x2))               # t0 = 0x2000
    p.append(addi(5, 5, -0x780))        # t0 = 0x1880 (MIE=0, MPIE=1, MPP=3)
    p.append(csrw(0x300, 5))            # mstatus = 0x1880
    # ★ ecall 的 mepc 指向 ecall 本身，必须 +4 才能跳过它
    p.append(csrr(6, 0x341))            # t1 = mepc
    p.append(addi(6, 6, 4))
    p.append(csrw(0x341, 6))            # mepc += 4
    p.append(mret())

    # 回填 la t0, handler（相对 auipc 那条指令的字节偏移）
    off = (handler - la_idx) * 4
    hi  = (off + 0x800) >> 12
    lo  = off - hi * 4096
    p[la_idx]     = U(0x17, 5, hi & 0xFFFFF)
    p[la_idx + 1] = addi(5, 5, lo & 0xFFF)
    return p


def main() -> int:
    prog = build()
    out = ROOT / "sim" / "mrettest.hex"
    with out.open("w", encoding="ascii", newline="\n") as f:
        for w in prog:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    print(f"wrote {out} ({len(prog)} words)")
    print("expect: +x10=6280  (0x1888 = MIE|MPIE|MPP)")
    print("  若 x10=6144 (0x1800) 或 6272 (0x1880) → csrw 与 mret 的顺序有问题")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
