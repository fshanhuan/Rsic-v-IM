#!/usr/bin/env python3
"""ARM/A32 最小反汇编器 —— 只覆盖 tools/ps/*.tcl 里迷你汇编器会产生的那几条指令。

用途：在没有 ARM 工具链的机器上，对"手写/自动生成的机器码"做离线自检：
  · 每条字能否解码成预期指令；
  · 分支的目标地址是否落在预期位置（例如循环回跳到"等 FIFO"那一条）。

用法：
  $env:DRAIN_DUMP_ONLY='1'  → xsdb 跑 tools/ps/arm_drain.tcl，把 WORD|i|hex 行筛出来
  python tools/ps/arm_a32_disasm.py <dump.txt> [代码基址]

约定：只支持 MOVW/MOVT/MOV(imm8)/LDR/STR/ADD(imm)/SUB(imm)/CMP(reg|imm)/B/BEQ/BNE。
其余编码一律报 UNKNOWN（不猜）。
"""

import re
import sys

COND = {
    0x0: "eq", 0x1: "ne", 0x2: "cs", 0x3: "cc", 0x4: "mi", 0x5: "pl",
    0x6: "vs", 0x7: "vc", 0x8: "hi", 0x9: "ls", 0xA: "ge", 0xB: "lt",
    0xC: "gt", 0xD: "le", 0xE: "", 0xF: "nv",
}


def decode(w, addr, base):
    """返回 (助记符文本, 是否分支, 目标地址)。"""
    cond = (w >> 28) & 0xF
    cs = COND.get(cond, "?")
    top = (w >> 20) & 0xFF

    # MOVW / MOVT
    if (w & 0x0FF00000) == 0x03000000:
        imm16 = ((w >> 16) & 0xF) << 12 | (w & 0xFFF)
        rd = (w >> 12) & 0xF
        return (f"movw{cs} r{rd}, #0x{imm16:04X}", False, None)
    if (w & 0x0FF00000) == 0x03400000:
        imm16 = ((w >> 16) & 0xF) << 12 | (w & 0xFFF)
        rd = (w >> 12) & 0xF
        return (f"movt{cs} r{rd}, #0x{imm16:04X}", False, None)

    # MOV rd, #imm8
    if (w & 0x0FF00000) == 0x03A00000:
        rd = (w >> 12) & 0xF
        imm = w & 0xFF
        return (f"mov{cs} r{rd}, #0x{imm:02X}", False, None)

    # CMP rn, #imm12
    if (w & 0x0FF00000) == 0x03500000:
        rn = (w >> 16) & 0xF
        imm = w & 0xFFF
        return (f"cmp{cs} r{rn}, #0x{imm:X}", False, None)

    # CMP rn, rm
    if (w & 0x0FF00FF0) == 0x01500000:
        rn = (w >> 16) & 0xF
        rm = w & 0xF
        return (f"cmp{cs} r{rn}, r{rm}", False, None)

    # AND rd, rn, #imm12
    if (w & 0x0FE00000) == 0x02000000:
        rn = (w >> 16) & 0xF
        rd = (w >> 12) & 0xF
        imm = w & 0xFFF
        return (f"and{cs} r{rd}, r{rn}, #0x{imm:X}", False, None)

    # ADD rd, rn, #imm12   (S=0)
    if (w & 0x0FE00000) == 0x02800000:
        rn = (w >> 16) & 0xF
        rd = (w >> 12) & 0xF
        imm = w & 0xFFF
        return (f"add{cs} r{rd}, r{rn}, #0x{imm:X}", False, None)

    # SUB rd, rn, #imm12
    if (w & 0x0FE00000) == 0x02400000:
        rn = (w >> 16) & 0xF
        rd = (w >> 12) & 0xF
        imm = w & 0xFFF
        return (f"sub{cs} r{rd}, r{rn}, #0x{imm:X}", False, None)

    # LDR rd, [rn, #imm12]（U=1, P=1, W=0, B=0）
    if (w & 0x0F300000) == 0x05100000:
        rn = (w >> 16) & 0xF
        rd = (w >> 12) & 0xF
        imm = w & 0xFFF
        return (f"ldr{cs} r{rd}, [r{rn}, #0x{imm:X}]", False, None)

    # STR rd, [rn, #imm12]
    if (w & 0x0F300000) == 0x05000000:
        rn = (w >> 16) & 0xF
        rd = (w >> 12) & 0xF
        imm = w & 0xFFF
        return (f"str{cs} r{rd}, [r{rn}, #0x{imm:X}]", False, None)

    # DSB SY（数据同步屏障，ARMv7 无条件编码）
    if w == 0xF57FF04F:
        return ("dsb sy", False, None)

    # B / BL（cond != 0xF）
    if (w & 0x0E000000) == 0x0A000000:
        off = w & 0xFFFFFF
        if off & 0x800000:
            off -= 0x1000000
        target = addr + 8 + off * 4
        return (f"b{cs} 0x{target:08X}", True, target)

    return (f"UNKNOWN 0x{w:08X}", False, None)


def main():
    if len(sys.argv) < 2:
        print("用法: python arm_a32_disasm.py <dump.txt> [代码基址hex]")
        return 2
    base = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0xFFFFA000
    words = []
    for line in open(sys.argv[1], encoding="utf-8", errors="ignore"):
        m = re.search(r"WORD\|(\d+)\|([0-9A-Fa-f]{8})", line)
        if m:
            words.append(int(m.group(2), 16))
    if not words:
        print("没找到 WORD|i|hex 行")
        return 1

    print(f"=== 反汇编 {len(words)} 条，基址 0x{base:08X} ===")
    labels = {}
    rows = []
    for i, w in enumerate(words):
        addr = base + i * 4
        text, is_branch, target = decode(w, addr, base)
        rows.append((i, addr, w, text, target))
        if is_branch:
            labels.setdefault(target, f"L{len(labels)}")
    for i, addr, w, text, target in rows:
        lab = labels.get(addr, "")
        print(f"  {i:3d} 0x{addr:08X} 0x{w:08X}  {lab+': ' if lab else '      '}{text}")

    print("\n=== 分支目标检查 ===")
    ok = True
    for i, addr, w, text, target in rows:
        if target is None:
            continue
        hit = target - base
        if hit % 4 != 0 or hit < 0 or hit >= len(words) * 4:
            print(f"  [FAIL] 第 {i} 条 {text} 目标越界")
            ok = False
        else:
            idx = hit // 4
            print(f"  [OK]   第 {i} 条 {text} -> 第 {idx} 条 "
                  f"({decode(words[idx], base + idx * 4, base)[0]})")
    print("\n[ARM-DISASM] status=" + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
