#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix_tb_split.py — 一次性修复：把"被吃掉的换行"重新拆开。

背景：2026-11-11 批量替换层次化路径时用错了编码（见 tools/fix_tb_headers.py 的说明），
    除了丢字，还会**丢掉换行**：GBK 解码时把 '\n' 当成上一字符的第二个字节吃掉，
    于是 `// 注释\n    wire x = ...;` 变成 `// 注释    wire x = ...;` ——
    **一行代码被并进注释里，等于被删除**。这种损坏不会报语法错，只会报"未声明"。

本脚本的判据（保守，宁可少拆）：
    一行里 /**/ 或 // 之后，还存在"连续 >=4 个空格 + 代码起始 token"，
    且这一段不是紧跟在注释符后面（那样是注释的缩进，不是代码）。

用法：python tools/fix_tb_split.py [--dry]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["tb_prog.sv", "tb_bus.sv", "tb_mem.sv", "tb_console.sv",
         "tb_board_top_uart.sv", "tb_monitor.sv", "tb_runapp.sv", "tb_axil_dram.sv"]

CODE_START = re.compile(
    r"^(wire|logic|reg|assign|initial|always|wait|if\b|else|for\b|case\b|begin\b|end\b|"
    r"default\b|`|//|/\*|task\b|localparam|integer|string|genvar|generate|"
    r"#|@|\$)"
    r"|^[A-Za-z_]\w*\s*<="
    r"|^[A-Za-z_]\w*\s*=\s*[^=]"
    r"|^\d+\s*:"
    r"|^\.[A-Za-z_]\w*"
    r"|^[A-Za-z_]\w*\("
)


def find_split(line):
    """返回拆分位置（代码起点），找不到返回 -1。

    只有在**这一行确实有注释**、注释里有正文、且正文后面跟着 >=4 空格 + 代码时
    才拆 —— 否则会把普通缩进代码也拆开。
    """
    slash = line.find("//")
    if slash < 0:
        return -1
    comment_text = line[slash + 2:]
    if not comment_text.strip():
        return -1
    best = -1
    for m in re.finditer(r"\s{4,}", line):
        start, end = m.start(), m.end()
        if start <= slash + 2:
            continue                      # 注释符后的缩进，不是代码
        head_text = line[slash + 2:start].strip()
        if not head_text:
            continue                      # 注释还没写任何东西，不算
        tail = line[end:]
        if not tail.strip():
            continue
        if CODE_START.match(tail):
            best = end
    return best


def main():
    dry = "--dry" in sys.argv
    total = 0
    for name in FILES:
        path = os.path.join(ROOT, "sim", name)
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().split("\n")
        out, n = [], 0
        for ln in lines:
            p = find_split(ln)
            if p > 0:
                head = ln[:p].rstrip()
                tail = ln[p:]
                indent = re.match(r"^(\s*)", tail).group(1) or "    "
                tail_body = tail.lstrip()
                # 代码行按原缩进补回（4 空格或原来更长的缩进）
                out.append(head)
                out.append(("    " if len(indent) < 4 else indent) + tail_body)
                n += 1
            else:
                out.append(ln)
        if n:
            print("%s: split %d merged line(s)" % (name, n))
            total += n
            if not dry:
                with open(path, "w", encoding="utf-8", newline="\n") as f:
                    f.write("\n".join(out))
    print("total split: %d" % total)


if __name__ == "__main__":
    main()
