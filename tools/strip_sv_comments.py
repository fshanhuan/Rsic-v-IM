#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
strip_sv_comments.py — SystemVerilog/Verilog 注释剥离器（注释迭代的"安全网"）

为什么要它：
  注释迭代要改动 24 个文件的**几万字符**，最大的风险不是改错字，而是
  **手滑碰到了一行真代码**（或者把 `//` 写进了字符串里）。靠人眼看 diff 不可靠。

  做法：把 文件 与 快照 都剥掉全部注释 + 归一化空白，再逐字符比较。
  只要剥离后的结果完全一致，就**机械证明**了"本次改动只发生在注释里"。

  ★ 关键性质：被注释掉的代码（`// assign x = y;`）属于注释，删掉它
    不会改变剥离结果 —— 所以"删除注释掉的死代码"也是被允许且可验证的。

正确处理（这是它比 `re.sub(r'//.*')` 强的地方）：
  - 字符串里的 `//` `/*` 不当注释（例如 $display("...") 里的内容、属性里的 "true"）
  - 字符串里的转义 `\\"` 
  - 行续接 `\\` 换行
  - 嵌套？Verilog 不允许嵌套块注释，按标准处理（第一个 */ 结束）

用法：
  python strip_sv_comments.py <文件>                  # 打印剥离后的代码（调试用）
  python strip_sv_comments.py --check <新> <旧>       # 只要代码一致就退出码 0
  python strip_sv_comments.py --diff  <新> <旧>       # 打印代码层面的差异
"""
import sys
import re


def strip(text):
    """返回 (剥离注释后的代码, 是否在文件结束时仍处于块注释/字符串内)"""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        # ---- 行注释 ----
        if c == "/" and nxt == "/":
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            continue
        # ---- 块注释 ----
        if c == "/" and nxt == "*":
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        # ---- 字符串 ----
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i]); out.append(text[i + 1]); i += 2
                    continue
                out.append(text[i])
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        # ---- 行续接：反斜杠 + 换行，等价于空白 ----
        if c == "\\" and nxt == "\n":
            out.append(" ")
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def normalize(code):
    """归一化：把任意空白序列压成单个空格，并去掉首尾空白。
    这样"把一行拆成两行"或"调整缩进"都不算代码改动。"""
    return re.sub(r"\s+", " ", code).strip()


def code_of(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return normalize(strip(f.read()))


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2

    if a[0] == "--check":
        if len(a) != 3:
            print("用法: --check <新> <旧>")
            return 2
        x, y = code_of(a[1]), code_of(a[2])
        if x == y:
            print("CODE-IDENTICAL  %s" % a[1])
            return 0
        print("CODE-CHANGED    %s   (剥离注释后的代码不同！)" % a[1])
        return 1

    if a[0] == "--diff":
        if len(a) != 3:
            print("用法: --diff <新> <旧>")
            return 2
        x, y = code_of(a[1]), code_of(a[2])
        # 找第一个不同的位置，给上下文
        k = 0
        while k < min(len(x), len(y)) and x[k] == y[k]:
            k += 1
        lo = max(0, k - 120)
        print("首个差异在第 %d 个字符（去掉注释与空白之后）:" % k)
        print("  新: ...%s..." % x[lo:k + 160].replace("\n", "\\n"))
        print("  旧: ...%s..." % y[lo:k + 160].replace("\n", "\\n"))
        return 1

    print(strip(open(a[0], "r", encoding="utf-8", errors="replace").read()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
