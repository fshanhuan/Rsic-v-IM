#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
selftest_strip.py — strip_sv_comments.py 的自测（5 个用例）

为什么必须有：如果剥离器"永远返回一致"，那么整条注释迭代的安全网就是假的，
比没有更危险（会给人虚假的信心）。所以先证明它**能识别出代码改动**。

★ 教训（这个自测第一版就踩了）：
  不要用 PowerShell 的 Get-Content / Set-Content 生成或改写这些带中文注释的
  .sv 文件 —— PS 5.1 默认按 ANSI(936) 读，中文注释会变成乱码，而且换行可能被吃掉，
  结果是 `module IFU (` 被粘进上一行的 `//` 注释里，剥离器于是把真代码也剥掉。
  本任务一律用 Python（显式 UTF-8）或 agent 的文件工具处理这些文件。

用法：python tools/selftest_strip.py
"""
import os
import re
import sys
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from strip_sv_comments import strip, normalize  # noqa: E402

SRC = os.path.join(ROOT, "_comment_iter", "before", "core", "IFU.sv")
# 第二个基准文件：它**有块注释**（IFU.sv 没有，只用它测不出块注释处理对不对）
SRC2 = os.path.join(ROOT, "_comment_iter", "before", "board", "sync_mem.sv")
OUT = os.path.join(ROOT, "_comment_iter", "selftest")


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def code(s):
    return normalize(strip(s))


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

def run_cases(tag, src):
    """在一份基准文件上跑全部用例。
    返回 (通过数, 失败数, 块注释用例是否真的改到了东西)"""
    cases = []      # (名字, 新内容, 期望代码一致, 是否真的改到了东西)

    # 1) 只改注释文字 -> 代码必须一致
    newc = src.replace("// 取指级只做一件事", "// 【精简后】取指级只做一件事")
    if newc == src:
        newc = src.replace("\n", "\n// probe\n", 1)
    cases.append(("c1_只改注释文字", newc, True, newc != src))

    # 2) 删掉全部块注释 -> 代码必须一致
    newc = re.sub(r"(?s)/\*.*?\*/", "", src)
    cases.append(("c2_删掉块注释", newc, True, newc != src))

    # 3) 删掉一整段行注释（模拟"精简战史"）-> 代码必须一致
    newc = re.sub(r"(?s)\n(?:[ \t]*//[^\n]*\n)+", "\n", src, count=1)
    cases.append(("c3_删掉行注释段", newc, True, newc != src))

    # 4) 改一行真代码 -> 必须报不同
    newc = src.replace("pc <= snpc;", "pc <= snpc + 4;")
    if newc == src:
        newc = src.replace("endmodule", "", 1)      # 删掉一个真 token
    cases.append(("c4_改真代码", newc, False, newc != src))

    # 5) 改字符串内容（字符串不是注释，改了就是改代码）-> 必须报不同
    newc = src.replace('"para.sv"', '"para//sv"')
    if newc == src:
        newc = src.replace('"timescale', '"Xtimescale', 1)
    cases.append(("c5_改字符串", newc, False, newc != src))

    # 6) 在字符串所在行尾加注释 -> 代码必须一致（测"字符串优先于注释"的解析顺序）
    newc = src.replace('`include "para.sv"', '`include "para.sv" // x')
    cases.append(("c6_字符串后加注释", newc, True, newc != src))

    ok = bad = 0
    touched_block = False
    for name, newc, expect_same, changed in cases:
        p = os.path.join(OUT, "%s__%s.sv" % (tag, name))
        if not changed:
            print("  [%s] %-20s (跳过：基准里没有对应内容)" % (tag, name))
            continue
        write(p, newc)
        same = code(newc) == code(src)
        good = (same == expect_same)
        ok += good
        bad += (not good)
        if name == "c2_删掉块注释":
            touched_block = True
        print("  [%s] %-20s 期望 %-9s 实测 %-9s %s"
              % (tag, name,
                 "IDENTICAL" if expect_same else "CHANGED",
                 "IDENTICAL" if same else "CHANGED",
                 "OK" if good else "<<< 失败"))
    return ok, bad, touched_block


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    total_ok = total_bad = 0
    block_covered = False
    for tag, path in (("IFU", SRC), ("sync_mem", SRC2)):
        if not os.path.exists(path):
            print("跳过（不存在）: %s" % path)
            continue
        src = read(path)
        print("基准文件: %s  (%d 字符)" % (path, len(src)))
        if "module" not in src:
            print("!! 基准文件看起来不像 Verilog，跳过")
            continue
        o, b, tb = run_cases(tag, src)
        total_ok += o
        total_bad += b
        block_covered = block_covered or tb
        print("")

    print("自测结果: %d 通过, %d 失败" % (total_ok, total_bad))
    if not block_covered:
        print("!! 没有任何基准文件含块注释，块注释用例没被真正覆盖")
        total_bad += 1
    if total_bad == 0:
        print("剥离器可信：能识别代码/字符串改动，也不会把注释当代码。")
    return 0 if total_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
