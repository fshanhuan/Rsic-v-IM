#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_all.py — 注释迭代的批量安全校验

用途：每一轮注释改动之后跑一次。对 25 个文件逐个做
      "剥离注释 + 归一化空白" 后的**代码等价性**比较，
      并统计注释行数的变化。

判定：
  CODE-IDENTICAL = 该文件只有注释变了（**允许**）
  CODE-CHANGED   = 真代码/字符串被动了（**不允许**，必须回滚该文件重做）

同时校验"工作目录副本 == 仓库正本"（两边必须字节一致，否则 Vivado 构建或
仿真会用到不同版本）。

用法：
  python tools/check_all.py            # 只校验，不写任何东西
  python tools/check_all.py --stats    # 额外打印每个文件的注释行数 before/after
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from strip_sv_comments import strip, normalize          # noqa: E402

CANON = r"E:\share doc\v9"
WORK = r"E:\FPGA\v9_vivado_ila"
SNAP = os.path.join(ROOT, "_comment_iter", "before")


def current_path(rel):
    """把快照里的相对路径映射成"现在的正本路径" """
    rel = rel.replace("/", os.sep)
    d, name = os.path.split(rel)
    if d == "core":
        # 2026-10 整理：21 个 CPU RTL（含 MDU_pipelined.sv）统一在 rtl\ 下
        return os.path.join(CANON, "rtl", name)
    if d == "board":
        return os.path.join(CANON, "board", name)
    if d == "work":
        # 2026-10 清理：工作目录根那份 board_top_gui.sv 冗余副本已删除，
        # project_src\ 里那份是唯一正本（构建实际编译的就是它）
        return os.path.join(WORK, "project_src", name)
    return None


def work_copy(rel):
    """工作目录里对应的副本（用于两树一致性检查）"""
    rel = rel.replace("/", os.sep)
    d, name = os.path.split(rel)
    if d == "core":
        return os.path.join(WORK, "rtl", name)
    if d == "board":
        return os.path.join(WORK, "board", name)
    if d == "work":
        # project_src 里那一份才是构建实际用的；根目录那份是同一内容的副本
        return os.path.join(WORK, "project_src", name)
    return None


def code_of(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return normalize(strip(f.read()))


def comment_lines(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    n = 0
    for ln in src.splitlines():
        t = ln.strip()
        if t.startswith("//") or t.startswith("/*") or t.startswith("*"):
            n += 1
    return n


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    want_stats = "--stats" in sys.argv

    man = os.path.join(ROOT, "_comment_iter", "manifest_before.tsv")
    entries = []
    # ★ 用 utf-8-sig 读：清单是 PowerShell Set-Content 写的，带 BOM，
    #   不处理的话第一行的路径会以 \ufeff 开头，导致它被判成 MISSING。
    with open(man, "r", encoding="utf-8-sig") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) >= 2:
                entries.append((p[0].lstrip("\ufeff"), int(p[1])))

    n_ok = n_bad = n_missing = n_sync_bad = 0
    c_before = c_after = 0
    rows = []
    for rel, size0 in entries:
        old = os.path.join(SNAP, rel.replace("/", os.sep))
        new = current_path(rel)
        if new is None or not os.path.exists(new):
            rows.append((rel, "MISSING", "", ""))
            n_missing += 1
            continue
        same_code = (code_of(old) == code_of(new))
        wc = work_copy(rel)
        sync = ""
        if wc and os.path.exists(wc):
            with open(new, "rb") as a, open(wc, "rb") as b:
                sync = "两树一致" if a.read() == b.read() else "两树不一致!"
                if sync.endswith("!"):
                    n_sync_bad += 1
        cb, ca = comment_lines(old), comment_lines(new)
        c_before += cb
        c_after += ca
        n_ok += same_code
        n_bad += (not same_code)
        rows.append((rel, "CODE-IDENTICAL" if same_code else "CODE-CHANGED",
                     "%d -> %d" % (cb, ca), sync))

    print("%-38s %-15s %-12s %s" % ("文件", "代码等价性", "注释行数", "两树"))
    print("-" * 88)
    for rel, st, cc, sy in rows:
        flag = "" if st == "CODE-IDENTICAL" else "   <<<<"
        print("%-38s %-15s %-12s %s%s" % (rel, st, cc, sy, flag))

    print("-" * 88)
    print("代码等价: %d 个文件 OK, %d 个被改动(必须回滚), %d 个缺失"
          % (n_ok, n_bad, n_missing))
    if n_sync_bad:
        print("!! 有 %d 个文件工作目录与仓库正本不一致" % n_sync_bad)
    if want_stats:
        print("注释行数合计: %d -> %d  (%+d, %+.1f%%)"
              % (c_before, c_after, c_after - c_before,
                 100.0 * (c_after - c_before) / max(c_before, 1)))
    bad = n_bad + n_missing + n_sync_bad
    print("总判定: %s" % ("PASS —— 只改了注释" if bad == 0 else "FAIL —— 见上面的 <<<<"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
