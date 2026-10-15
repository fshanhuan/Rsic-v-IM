#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
assemble_fix_history.py — 把 _comment_iter/extract/*.md 汇编成 syn/修复史_全量.md

背景：注释迭代（保守精简）会把散落在 RTL 里的"故障战史 / 实测现象 / 方案沿革"
从源码注释里压缩成 2~5 行，原文明细搬进 extract 片段。本脚本把这些片段
装订成一份可检索的文档，并生成编号索引，供 RTL 注释里的
`见 syn/修复史_全量.md §<锚点>` 指过去。

★ 双向一致：同时写入仓库正本 `E:\\share doc\\v9\\syn\\` 与工作目录
  `E:\\FPGA\\v9_vivado_ila\\syn\\`，并核对字节一致。

用法：
  python tools/assemble_fix_history.py            # 汇编（缺片段会告警）
  python tools/assemble_fix_history.py --strict   # 有文件缺片段就返回非 0
"""
import os
import re
import sys
import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXTRACT = os.path.join(ROOT, "_comment_iter", "extract")
CANON_SYN = r"E:\share doc\v9\syn"
WORK_SYN = os.path.join(ROOT, "syn")

# 阅读顺序：按流水线从前到后，最后是顶层与板级
ORDER = [
    ("一、取指与前端", ["IFU.sv", "ICache.sv", "Branch_Predictor.sv"]),
    ("二、译码与寄存器堆", ["IDU.sv", "Reg_Stack.sv", "RegisterFile.sv", "Reg.sv"]),
    ("三、执行与运算", ["EXU.sv", "MDU_pipelined.sv", "ALU.sv", "add.sv", "sext.sv"]),
    ("四、访存与写回", ["LSU.sv", "DCache.sv", "WBU.sv"]),
    ("五、流水控制与异常", ["Control.sv", "Data_hazard.sv", "CSR.sv"]),
    ("六、顶层与公共定义", ["myCPU.sv", "para.sv"]),
    ("七、板级与工程顶层", ["board_top.sv", "board_top_ila.sv", "sync_mem.sv",
                            "reset_sync.sv", "board_top_gui.sv"]),
]


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    strict = "--strict" in sys.argv

    have = {}
    if os.path.isdir(EXTRACT):
        for fn in os.listdir(EXTRACT):
            if fn.endswith(".md"):
                have[fn[:-3]] = os.path.join(EXTRACT, fn)
    print("找到 %d 个 extract 片段" % len(have))

    all_names = [n for _, group in ORDER for n in group]
    missing = [n for n in all_names if n not in have]
    extra = [n for n in have if n not in all_names]

    out = []
    A = out.append
    A("# v9 修复史 · 全量（注释迭代的抽取归档）")
    A("")
    A("> **这份文档的定位**：它不是新的分析，而是**归档**。")
    A("> 在 v9 的注释迭代（保守精简）中，RTL 里那些\"当时怎么发现、试了几版、实测数字是多少\"")
    A("> 的长篇叙述被压缩成了 2~5 行的 `★ 不变量 + 原因`，**原文逐字搬到了这里**。")
    A("> RTL 注释里的 `见 syn/修复史_全量.md §<锚点>` 就是指向本文件。")
    A("")
    A("> **为什么这样拆**：源码注释要回答的是\"**改这里会坏什么**\"，")
    A("> 而\"当初是怎么踩到的\"属于史料 —— 两种读者、两种篇幅。")
    A("> 但史料**一个字都不能丢**：本文件的存在，就是为了让精简变成\"搬家\"而不是\"删除\"。")
    A("")
    A("**生成时间**：%s" % datetime.date.today().isoformat())
    A("")
    A("**相关文档**（这些是分析，不是归档）：")
    A("")
    A("| 文档 | 讲什么 |")
    A("|---|---|")
    A("| [`上板改造说明.md`](上板改造说明.md) | 上板障碍清单 P0~P5、改造前后对照、6 个 RTL 缺陷的根因 |")
    A("| [`修复进度_C系列.md`](修复进度_C系列.md) | C 系列（异常体系）修复的逐步记录 |")
    A("| [`ecall重定向故障_根因与修复.md`](ecall重定向故障_根因与修复.md) | B9：ecall 重定向失效的完整定位与板上确认 |")
    A("| [`上板验证判据.md`](上板验证判据.md) | 上板时怎么判定\"正常工作\" |")
    A("| [`ila_使用说明.md`](ila_使用说明.md) | ILA 探针分配、触发姿势、时序资源实测 |")
    A("")
    A("---")
    A("")
    A("## 索引")
    A("")
    A("| 模块 | 锚点前缀 | 主题数 |")
    A("|---|---|---|")

    # 统计每个文件的主题数（按 "## " 二级标题计数）
    counts = {}
    for name, path in have.items():
        counts[name] = len(re.findall(r"^##\s+", read(path), re.M))
    for _, group in ORDER:
        for n in group:
            if n in have:
                A("| `%s` | `%s-*` | %d |"
                  % (n, os.path.splitext(n)[0].upper().replace("_", ""), counts.get(n, 0)))
    A("")
    if missing:
        A("> ⚠️ 以下文件本次没有产出 extract 片段（可能该文件确实没有 B 类内容，")
        A("> 也可能是漏了）。用 `python tools/check_extract_coverage.py` 可以定量核对：")
        A(">")
        for n in missing:
            A("> - `%s`" % n)
        A("")
    A("---")
    A("")

    for title, group in ORDER:
        A("## %s" % title)
        A("")
        for n in group:
            if n not in have:
                continue
            A("### %s" % n)
            A("")
            body = read(have[n]).strip()
            # 片段自带一级标题时降级，避免文档里出现两个 H1
            body = re.sub(r"^#\s+.*\n", "", body, count=1).strip()
            A(body)
            A("")
            A("---")
            A("")

    text = "\n".join(out).rstrip() + "\n"

    written = []
    for d in (CANON_SYN, WORK_SYN):
        if not os.path.isdir(d):
            print("跳过（目录不存在）: %s" % d)
            continue
        p = os.path.join(d, "修复史_全量.md")
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        written.append(p)
        print("已写入 %s (%d 字节)" % (p, os.path.getsize(p)))

    if len(written) == 2:
        a, b = (read(p) for p in written)
        print("两树一致: %s" % ("OK" if a == b else "!! MISMATCH"))

    if extra:
        print("警告：extract 目录里有不属于清单的片段: %s" % extra)
    print("缺失片段 %d 个；主题总数 %d" % (len(missing), sum(counts.values())))
    return 1 if (strict and missing) else 0


if __name__ == "__main__":
    sys.exit(main())
