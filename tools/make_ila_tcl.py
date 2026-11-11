#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_ila_tcl.py — 由 build_project_boot.tcl 生成 build_project_ila.tcl。

为什么需要：两个脚本 99% 相同，只有 4 处实质差别（工程目录、顶层模块、板级顶层源文件、
约束文件）。分别维护两份，改一处忘了另一处就出事故 —— 而且本轮它们同时被
PowerShell 的 GBK 往返损坏过（`#` 被吃掉，`}` 变成顶层命令）。

用法：python tools/make_ila_tcl.py
"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PAIRS = [
    ('set PROJ  "E:/FPGA/v9_vivado_ila/v9_boot"', 'set PROJ  "E:/FPGA/v9_vivado_ila/v9_ila"'),
    ('set TOP        "board_top_gui_boot"',       'set TOP        "board_top_gui"'),
    ('"$WORK/project_src/board_top_gui_boot.sv"', '"$WORK/project_src/board_top_gui.sv"'),
    ("v9_board_boot.xdc",                         "v9_board_ila.xdc"),
]


def main():
    src = os.path.join(ROOT, "build_project_boot.tcl")
    dst = os.path.join(ROOT, "build_project_ila.tcl")
    s = io.open(src, encoding="utf-8").read()
    applied = 0
    for a, b in PAIRS:
        if a not in s:
            print("!! 没找到锚点: %s" % a)
            continue
        s = s.replace(a, b)
        applied += 1
    io.open(dst, "w", encoding="utf-8", newline="\n").write(s)
    print("wrote %s (%d/%d 处替换)" % (dst, applied, len(PAIRS)))
    return 0 if applied == len(PAIRS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
