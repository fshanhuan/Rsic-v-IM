#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_tcl.py — 用 Tcl 自己的 `info complete` 检查脚本的括号/引号是否闭合。

为什么需要：本仓库的 build_project_*.tcl 曾经被 PowerShell 按 GBK 读、
再按 UTF-8 写，导致**注释行里的 `#` 被吃掉**，`}` 变成顶层命令 →
Vivado 报 `invalid command name "}"`。这类破坏只看"大括号数量相等"是查不出来的，
必须让 Tcl 解析器自己说。

用法：python tools/check_tcl.py build_project_boot.tcl [更多文件...]
"""
import io
import sys
import tkinter

tcl = tkinter.Tcl()

bad = 0
for path in sys.argv[1:]:
    src = io.open(path, encoding="utf-8").read()
    tcl.setvar("chk_src", src)
    ok = tcl.eval("info complete $chk_src")
    print("%-32s %s" % (path, "OK" if ok else "INCOMPLETE"))
    if not ok:
        bad += 1
sys.exit(1 if bad else 0)
