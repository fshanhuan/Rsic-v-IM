#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
sync_trees.py — 把仓库正本的 25 个文件同步到工作目录（并核对哈希）

为什么需要单独一个脚本：
  本次注释迭代里，**所有 agent 只改仓库正本 `E:\\share doc\\v9\\`**
  （刻意不碰工作目录，免得并行撞车）。而：
    - iverilog 回归跑的是**工作目录**根下的 .sv；
    - `build_project_ila.tcl` 每次构建也会先用正本覆盖工作目录。
  所以收尾必须把正本同步过去，否则仿真/综合用的还是旧注释。

映射（与 tools/check_all.py 的 current_path/work_copy 保持一致）：
  core/<f>            -> <WORK>/rtl/<f>           （2026-10 整理：CPU RTL 统一在 rtl/ 下）
  board/<f>           -> <WORK>/board/<f>
  work/board_top_gui.sv -> 唯一正本就在 <WORK>/project_src/board_top_gui.sv（构建实际编译它），
                           无需同步

用法：
  python tools/sync_trees.py             # 同步 + 核对
  python tools/sync_trees.py --dry-run   # 只看要做什么，不写
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CANON = r"E:\share doc\v9"
WORK = ROOT
SNAP = os.path.join(ROOT, "_comment_iter", "before")


def plan():
    """返回 [(源, 目标, 说明), ...]"""
    out = []
    man = os.path.join(ROOT, "_comment_iter", "manifest_before.tsv")
    entries = []
    with open(man, "r", encoding="utf-8-sig") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) >= 2:
                entries.append(p[0].lstrip("\ufeff"))
    for rel in entries:
        rel = rel.replace("/", os.sep)
        d, name = os.path.split(rel)
        if d == "core":
            out.append((os.path.join(CANON, "rtl", name),
                        os.path.join(WORK, "rtl", name), rel))
        elif d == "board":
            out.append((os.path.join(CANON, "board", name),
                        os.path.join(WORK, "board", name), rel))
        elif d == "work":
            # 2026-10 清理：根目录那份 board_top_gui.sv 冗余副本已删除，
            # project_src\ 里那份是唯一正本 —— 源=目标，无需同步。
            p = os.path.join(WORK, "project_src", name)
            out.append((p, p, rel))
    return out


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    dry = "--dry-run" in sys.argv

    items = plan()
    print("待同步 %d 个文件%s" % (len(items), "（--dry-run，不写盘）" if dry else ""))
    print("-" * 78)

    n_same = n_copied = n_fail = 0
    for src, dst, rel in items:
        if not os.path.exists(src):
            print("  !! 源不存在: %s" % src)
            n_fail += 1
            continue
        same = False
        if os.path.exists(dst):
            with open(src, "rb") as a, open(dst, "rb") as b:
                same = (a.read() == b.read())
        if same:
            n_same += 1
            continue
        if dry:
            print("  将覆盖  %-34s -> %s" % (rel, dst))
            n_copied += 1
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        with open(src, "rb") as a, open(dst, "rb") as b:
            ok = (a.read() == b.read())
        n_copied += 1
        n_fail += (not ok)
        print("  %s  %-34s" % ("已同步" if ok else "!! 校验失败", rel))

    print("-" * 78)
    print("本来就一致 %d 个，本次同步 %d 个，失败 %d 个" % (n_same, n_copied, n_fail))
    if not dry and n_fail == 0:
        print("两树现在字节一致。接着跑：python tools/acceptance_report.py")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
