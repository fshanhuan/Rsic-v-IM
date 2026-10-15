#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_extract_coverage.py — 验证"被删掉的注释有没有搬进 extract"

为什么需要：
  风格指南要求"不许删知识，只许搬"（B 类故障战史必须逐字进 extract）。
  但 7 个 agent 并行改写，靠自觉不可靠。这个脚本给一个**可量化**的覆盖率。

原理：
  1. 从"改动前快照"里抽出全部注释文本，切成行（归一化空白）；
  2. 从"改动后文件"里抽出全部注释文本，同样切行；
  3. 找出"改动前有、改动后没有"的行 = **被删掉/被改写的行**；
  4. 对每一行，看它在 extract.md 里有没有足够的**4-gram 覆盖**（≥60% 视为已记录）。
     用 4-gram 而不是子串匹配，是为了容忍合理的改写与重新排版。
  5. 输出每个文件的覆盖率；低于阈值就报出来。

★ 阈值是实测标定的（见 tools/probe_ngram_threshold.py）：
     原文照抄 88.6% / 轻度改写 65.9% / 中度改写 46.5% / **重度改写 20.0%** / 无关 0.0%
   所以：
     - 松阈值 35% = 判定"有没有真的丢"（中度改写能过，重度改写/无关会被抓出来）
     - 严阈值 60% = "原样保留率"，只作抽查参考，不作判定
   两个数都打印，避免单一阈值既误杀改写、又放过真删。

★ 只统计"实质行"（去空白后 ≥ 12 字符），避免把 `//`、`// ---` 这类当知识。

用法：
  python tools/check_extract_coverage.py                 # 全部文件
  python tools/check_extract_coverage.py --min 0.9       # 自定义松阈值
  python tools/check_extract_coverage.py --show IFU.sv   # 打印某文件没被覆盖的行
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

SNAP = os.path.join(ROOT, "_comment_iter", "before")
EXTRACT = os.path.join(ROOT, "_comment_iter", "extract")
CANON = r"E:\share doc\v9"
WORK = r"E:\FPGA\v9_vivado_ila"


def current_path(rel):
    rel = rel.replace("/", os.sep)
    d, name = os.path.split(rel)
    if d == "core":
        return os.path.join(CANON, "rtl", name)
    if d == "board":
        return os.path.join(CANON, "board", name)
    if d == "work":
        # 2026-10 清理：工作目录根那份 board_top_gui.sv 冗余副本已删除，
        # project_src\ 里那份是唯一正本（构建实际编译的就是它）
        return os.path.join(WORK, "project_src", name)
    return None


def comment_text(path):
    """抽出文件里的全部注释内容（不含 // 和 /* */ 标记本身）"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    out = []
    # 块注释
    for m in re.finditer(r"/\*(.*?)\*/", src, re.S):
        out.append(m.group(1))
    # 行注释（先把块注释挖掉，免得块里的 // 被重复统计）
    tmp = re.sub(r"/\*(.*?)\*/", lambda m: "\n" * m.group(1).count("\n"), src, flags=re.S)
    for m in re.finditer(r"//(.*)", tmp):
        out.append(m.group(1))
    # 清掉块注释开头的装饰星号
    txt = "\n".join(out)
    lines = []
    for ln in txt.splitlines():
        ln = re.sub(r"^\s*\*+\s?", "", ln)
        ln = re.sub(r"[\s\-=*_]{2,}", " ", ln).strip()
        lines.append(ln)
    return lines


def ngrams(s, n=4):
    s = re.sub(r"\s+", "", s)
    return set(s[i:i + n] for i in range(max(0, len(s) - n + 1)))


def covered(line, extract_ngrams, thr=0.35):
    """松阈值：这一行在 extract 里有没有"实质被记录"。
    35% 是实测标定值（中度改写约 46%，重度改写约 20%）。"""
    g = ngrams(line)
    if not g:
        return True
    hit = sum(1 for x in g if x in extract_ngrams)
    return hit / len(g) >= thr


def strict_ratio(line, extract_ngrams):
    """严阈值口径的"原样保留率"，只作抽查参考"""
    g = ngrams(line)
    if not g:
        return 1.0
    return sum(1 for x in g if x in extract_ngrams) / len(g)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    args = sys.argv[1:]
    min_cov = 0.90          # 每个文件的"记录率"下限
    main_thr = 0.35         # 单行的松阈值（实测标定：中度改写 46%，重度改写 20%）
    if "--min" in args:
        min_cov = float(args[args.index("--min") + 1])
    if "--thr" in args:
        main_thr = float(args[args.index("--thr") + 1])
    show = None
    if "--show" in args:
        show = args[args.index("--show") + 1]

    man = os.path.join(ROOT, "_comment_iter", "manifest_before.tsv")
    entries = []
    with open(man, "r", encoding="utf-8-sig") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) >= 2:
                entries.append(p[0].lstrip("\ufeff"))

    print("%-34s %7s %7s %7s %8s %8s" % ("文件", "实质行", "被删行", "真丢失", "记录率", "原样率"))
    print("-" * 84)
    worst = []
    tot_removed = tot_missed = 0
    total_strict = 0.0
    n_with_removed = 0
    for rel in entries:
        name = os.path.basename(rel)
        if show and show.lower() not in name.lower():
            continue
        old = os.path.join(SNAP, rel.replace("/", os.sep))
        new = current_path(rel)
        if not os.path.exists(new):
            print("%-34s   (当前文件不存在)" % rel)
            continue
        ext = os.path.join(EXTRACT, name + ".md")
        ext_txt = ""
        if os.path.exists(ext):
            with open(ext, "r", encoding="utf-8", errors="replace") as f:
                ext_txt = f.read()
        ext_g = ngrams(ext_txt)

        old_lines = [l for l in comment_text(old) if len(re.sub(r"\s+", "", l)) >= 12]
        new_set = set(re.sub(r"\s+", "", l) for l in comment_text(new))
        removed = [l for l in old_lines if re.sub(r"\s+", "", l) not in new_set]

        missed = [l for l in removed if not covered(l, ext_g, main_thr)]
        srate = None
        if removed:
            srate = sum(strict_ratio(l, ext_g) for l in removed) / len(removed)
            total_strict += srate
            n_with_removed += 1
        tot_removed += len(removed)
        tot_missed += len(missed)
        cov = 1.0 if not removed else 1.0 - len(missed) / len(removed)
        flag = "" if cov >= min_cov else "   <<<<"
        print("%-34s %7d %7d %7d %7.1f%% %7s%s"
              % (rel, len(old_lines), len(removed), len(missed), cov * 100,
                 "-" if srate is None else "%.0f%%" % (srate * 100), flag))
        if cov < min_cov:
            worst.append((rel, missed))
        if show:
            for l in missed[:40]:
                print("       真丢失: %s" % l[:110])

    print("-" * 84)
    overall = 1.0 if tot_removed == 0 else 1.0 - tot_missed / tot_removed
    print("总体：被删/改写 %d 行，其中 %d 行在 extract 里找不到实质记录 → 记录率 %.1f%%"
          % (tot_removed, tot_missed, overall * 100))
    if n_with_removed:
        print("      平均\"原样保留率\" %.1f%% （严口径 60%%，低于它只表示改写较多，建议抽查）"
              % (total_strict / n_with_removed * 100))
    if worst:
        print("")
        print("低于阈值 %.0f%% 的文件：" % (min_cov * 100))
        for rel, missed in worst:
            print("  %-32s 真丢失 %d 行" % (rel, len(missed)))
        print("→ 用 --show <文件> 看具体是哪几行，补进 extract 或恢复回源码注释。")
    ok = overall >= min_cov
    print("判定：%s" % ("PASS —— 删除的知识都有记录" if ok else "FAIL —— 有知识被删且没搬走"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
