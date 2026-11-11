#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tie_optional_ports.py — 给"直接例化 myCPU / DCache"的测试台补上可选端口。

背景（2026-11-11 双核协同第 2 步）：
    DCache 新增了 `inval`（整表无效），myCPU 把它透传成 `dcache_inval`。
    板级 TB 走 board_top，board_top 会驱动它；但 `tb_mini / tb_sys / tb_exc /
    tb_cm / tb_wave / tb_iverilog / tb_msim / tb_dcache_unit` 是**直接例化**内核的，
    端口悬空 = Z ⇒ `~inval` 是 X ⇒ 所有命中判定变 X（表现为"永远 miss"，
    更糟的是 store 合并被吞掉，tb_mini 的 write-once 断言就炸了）。

    这些台子不测一致性，统一钉 0。

用法：python tools/tie_optional_ports.py [--check]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CPU_FILES = ["tb_cm.sv", "tb_exc.sv", "tb_iverilog.sv", "tb_mini.sv",
             "tb_msim.sv", "tb_sys.sv", "tb_wave.sv"]
DCACHE_FILES = ["tb_dcache_unit.sv"]

CPU_LINE = "        .dcache_inval          (1'b0),   // 本台子不测一致性：钉 0（见 tools/tie_optional_ports.py）\n"
DC_LINE = "        .inval     (1'b0),   // 本台子不测一致性：钉 0（见 tools/tie_optional_ports.py）\n"


def insert_after(text, marker, line):
    """在包含 marker 的那一行后面插入 line（若已经存在 dcache_inval / inval 就跳过）。"""
    if ".dcache_inval" in text or ".inval" in text:
        return text, False
    lines = text.split("\n")
    for i, l in enumerate(lines):
        if marker in l:
            lines.insert(i + 1, line.rstrip("\n"))
            return "\n".join(lines), True
    return text, False


def main():
    check = "--check" in sys.argv
    n = 0
    for name in CPU_FILES:
        p = os.path.join(ROOT, "sim", name)
        t = open(p, encoding="utf-8").read()
        t2, ok = insert_after(t, ".cpu_rst", CPU_LINE)
        if ok:
            n += 1
            print("%s: + .dcache_inval(1'b0)" % name)
            if not check:
                open(p, "w", encoding="utf-8", newline="\n").write(t2)
    for name in DCACHE_FILES:
        p = os.path.join(ROOT, "sim", name)
        t = open(p, encoding="utf-8").read()
        t2, ok = insert_after(t, ".req_seq", DC_LINE)
        if ok:
            n += 1
            print("%s: + .inval(1'b0)" % name)
            if not check:
                open(p, "w", encoding="utf-8", newline="\n").write(t2)
    print("patched %d file(s)" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
