#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tcl_dryrun.py — 在沙箱里"跑"一遍 Tcl 脚本，只验证语法/命令名，不产生副作用。

做法：
    · 把 `file` / `exit` / `exec` 这些会真的动手的内建命令改名后替换成空壳；
    · `unknown` 兜住所有未知命令（create_project、launch_runs…）→ 一律返回空；
    · 然后 eval 整份脚本。
  Tcl 的语法错误（典型的是"注释行丢了 #，`}` 变成顶层命令"）会在 eval 时直接抛
  `invalid command name "}"` —— 这正是 Vivado 报的那个错。

用法：python tools/tcl_dryrun.py build_project_boot.tcl
"""
import io
import sys
import tkinter

SANDBOX = r"""
foreach c {file exit exec open close socket glob cd pwd source} {
    if {[llength [info commands $c]]} { rename $c __orig_$c }
}
proc file {args} { return "" }
proc exit {args} { return "" }
proc exec {args} { return "" }
proc open {args} { return "" }
proc close {args} { return "" }
proc socket {args} { return "" }
proc glob {args} { return "" }
proc cd {args} { return "" }
proc pwd {args} { return "" }
proc source {args} { return "" }
proc unknown {args} {
    set cmd [lindex $args 0]
    # 关键：裸的右花括号/左花括号 在 Tcl 里是"命令名"，说明注释行丢了 #（正是 Vivado 报的错）。
    # ★ 注释里不能出现花括号字面量：proc 体是 braced word，扫描时会把它当成闭合。
    set rb "\}"
    set lb "\{"
    if {$cmd eq $rb || $cmd eq $lb} { error "invalid command name $cmd" }
    return ""
}
"""


def main():
    if len(sys.argv) < 2:
        print("usage: tcl_dryrun.py <script.tcl> [...]")
        return 2
    bad = 0
    for path in sys.argv[1:]:
        src = io.open(path, encoding="utf-8").read()
        tcl = tkinter.Tcl()
        tcl.eval(SANDBOX)
        tcl.setvar("dry_src", src)
        try:
            tcl.eval("eval $dry_src")
            print("%-34s OK" % path)
        except Exception as e:                     # noqa: BLE001
            print("%-34s ERROR: %s" % (path, str(e).strip().splitlines()[0]))
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
