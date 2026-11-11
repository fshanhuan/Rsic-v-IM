#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_soc_map.py — A4：由 rtl/soc_map.sv **生成** C 头文件与地址表文档。

为什么需要它：
    地址映射原来散落在 5 个地方（board_top 的译码、读 mux、写门控、monitor.c 的宏、
    docs 里的表格）。A1/A2/A3 已经把 RTL 侧收成 `rtl/soc_map.sv` 一处，但**软件和
    文档还是各写一份**。这个脚本让它们从同一个源生成，并提供一个 --check 模式给
    回归用：谁手改了生成物、或者改了 soc_map.sv 忘了重新生成，都会被抓出来。

用法：
    python tools/gen_soc_map.py            # 生成 sw/soc_map.h 与 docs/地址表.md
    python tools/gen_soc_map.py --check    # 只比对，不一致返回 1（回归用）

约定：
    · 只解析**对象式**宏（`define NAME VALUE）；带参数的宏（片选比较）跳过；
    · 数值支持 32'hxxxx / N'dxxx / 纯十进制，下划线会被去掉（C 不认下划线）；
    · 注释里以 0x 开头的第一个十六进制数当作"地址"，用于文档表格排序。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "rtl", "soc_map.sv")
HDR = os.path.join(ROOT, "sw", "soc_map.h")
DOC = os.path.join(ROOT, "docs", "地址表.md")

DEFINE = re.compile(r"^`define\s+([A-Za-z_][A-Za-z0-9_]*)\s+([^/\s]+)\s*(?://(.*))?$")


def parse_value(text):
    """把 SystemVerilog 字面量转成 Python int；不认识就返回 None。"""
    t = text.replace("_", "")
    m = re.fullmatch(r"(\d+)'[hH]([0-9a-fA-F]+)", t)
    if m:
        return int(m.group(2), 16)
    m = re.fullmatch(r"(\d+)'[dD](\d+)", t)
    if m:
        return int(m.group(2), 10)
    if re.fullmatch(r"\d+", t):
        return int(t, 10)
    return None


def parse():
    entries = []
    with open(SRC, "r", encoding="utf-8") as f:
        for line in f:
            m = DEFINE.match(line.rstrip("\n"))
            if not m:
                continue
            name, val, comment = m.group(1), m.group(2), (m.group(3) or "").strip()
            v = parse_value(val)
            if v is None:
                continue          # 带参数/表达式/宏引用的，跳过
            addr = None
            am = re.match(r"0x([0-9A-Fa-f]+)", comment)
            if am:
                addr = int(am.group(1), 16)
            entries.append((name, v, comment, addr, val))
    return entries


def to_c(v):
    if v <= 1:
        return "%d" % v
    if v < 0x10000:
        return "%d" % v
    return "0x%08Xu" % v


def gen_header(entries):
    def group_of(name):
        parts = name.split("_")
        return parts[1] if len(parts) > 1 else ""

    out = []
    out.append("/* =============================================================================")
    out.append(" * sw/soc_map.h — SoC 地址映射（**自动生成，不要手改**）")
    out.append(" * -----------------------------------------------------------------------------")
    out.append(" * 来源：rtl/soc_map.sv")
    out.append(" * 生成：python tools/gen_soc_map.py")
    out.append(" * 校验：python tools/gen_soc_map.py --check  （_diag/regress.ps1 会跑）")
    out.append(" * ============================================================================= */")
    out.append("#ifndef SOC_MAP_H")
    out.append("#define SOC_MAP_H")
    out.append("")
    group = None
    for name, v, comment, addr, raw in sorted(entries, key=lambda e: (group_of(e[0]), e[0])):
        g = group_of(name)
        if g != group:
            group = g
            out.append("/* ---- %s ---- */" % g)
        tail = ("  /* %s */" % comment) if comment else ""
        out.append("#define %-24s %s%s" % (name, to_c(v), tail))
    out.append("")
    out.append("#endif /* SOC_MAP_H */")
    out.append("")
    return "\n".join(out)


def gen_doc(entries):
    out = []
    out.append("# SoC 地址表")
    out.append("")
    out.append("> **自动生成，不要手改。** 来源 `rtl/soc_map.sv`，生成脚本 `tools/gen_soc_map.py`。")
    out.append("> `_diag/regress.ps1` 里的 `socmap` 用例会用 `--check` 比对这份文件与头文件。")
    out.append("")
    out.append("## 数据口地址空间（哈佛：取指口另有一套）")
    out.append("")
    out.append("| 名字 | 值 | 说明 |")
    out.append("|---|---|---|")
    for name, v, comment, addr, raw in entries:
        if not name.startswith("SOC_MMIO_IDX_"):
            out.append("| `%s` | `%s` | %s |" % (name, raw, comment.replace("|", "\\|")))
    out.append("")
    out.append("## MMIO 寄存器（基址 `SOC_MMIO_BASE` + idx×4）")
    out.append("")
    out.append("| 地址 | 名字 | 说明 |")
    out.append("|---|---|---|")
    base = next((v for n, v, c, a, r in entries if n == "SOC_MMIO_BASE"), 0x10000000)
    idx = [(n, v, c) for n, v, c, a, r in entries if n.startswith("SOC_MMIO_IDX_")]
    idx.sort(key=lambda x: x[1])
    for name, v, comment in idx:
        out.append("| `0x%08X` | `%s` | %s |" % (base + v * 4, name, comment.replace("|", "\\|")))
    out.append("")
    return "\n".join(out)


def main():
    entries = parse()
    if not entries:
        print("!! 没解析到任何宏，检查 rtl/soc_map.sv 的格式")
        return 2
    hdr = gen_header(entries)
    doc = gen_doc(entries)

    if "--check" in sys.argv:
        bad = 0
        for path, want in ((HDR, hdr), (DOC, doc)):
            if not os.path.exists(path):
                print("!! 缺文件: %s" % path)
                bad += 1
                continue
            with open(path, "r", encoding="utf-8") as f:
                got = f.read()
            if got != want:
                print("!! 不一致: %s（改过 soc_map.sv 后请重新生成）" % path)
                bad += 1
        print("[SOCMAP] %s (%d 条宏)" % ("OK" if bad == 0 else "DIFF", len(entries)))
        return 0 if bad == 0 else 1

    with open(HDR, "w", encoding="utf-8", newline="\n") as f:
        f.write(hdr)
    with open(DOC, "w", encoding="utf-8", newline="\n") as f:
        f.write(doc)
    print("wrote %s" % HDR)
    print("wrote %s" % DOC)
    print("%d 条宏" % len(entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
