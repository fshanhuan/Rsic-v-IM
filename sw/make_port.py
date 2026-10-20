#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/make_port.py -- 从 vendor 的 barebones 复制 ee_printf.c / cvt.c 并打补丁

为什么需要：vendor 的 ee_printf.c 里 uart_send_char() 是 `#error` 占位实现，
必须换成我们自己的（core_portme.c 里轮询 TXSTAT 的那份）。为了不手改 vendor
目录（升级 CoreMark 时能一键重放），用脚本复制 + 定点替换。

用法：
    python3 sw/make_port.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "sw" / "coremark" / "barebones"
DST = ROOT / "sw" / "coremark_port"

# vendor 里的占位函数（函数体中间是一大段注释 + #error）
PLACEHOLDER = re.compile(
    r"void\s*\nuart_send_char\(char c\)\s*\n\{.*?\n\}\n",
    re.DOTALL,
)

REPLACEMENT = """/* ---- 本平台的实现 ---- */
/* uart_send_char 的实体在 core_portme.c（轮询 TXSTAT 后写 TXDATA）。
 * 这里只留声明：vendor 原文件把实现放在这个位置，并且是 `#error` 占位。 */
void uart_send_char(char c);
"""


def patch_ee_printf() -> int:
    src = SRC / "ee_printf.c"
    dst = DST / "ee_printf.c"
    text = src.read_text(encoding="utf-8")
    new, n = PLACEHOLDER.subn(REPLACEMENT, text)
    if n != 1:
        print(f"!! ee_printf.c 里没找到唯一的 uart_send_char 占位实现（匹配 {n} 次）",
              file=sys.stderr)
        return 1
    dst.write_text(new, encoding="utf-8", newline="\n")
    print(f"   ee_printf.c  patched  ({len(text)} -> {len(new)} bytes)")
    return 0


def copy_plain() -> int:
    src = SRC / "cvt.c"
    dst = DST / "cvt.c"
    text = src.read_text(encoding="utf-8")
    dst.write_text(text, encoding="utf-8", newline="\n")
    print(f"   cvt.c        copied   ({len(text)} bytes)")
    return 0


def main() -> int:
    DST.mkdir(parents=True, exist_ok=True)
    rc = patch_ee_printf()
    rc |= copy_plain()
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
