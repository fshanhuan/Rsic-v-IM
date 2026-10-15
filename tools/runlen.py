#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""runlen.py — 看某个 1bit 探针的翻转次数 / 最长低电平连拍（判断是不是采样混叠）"""
import sys, csv

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def load(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rows = list(csv.reader(f))
    h = [x.strip() for x in rows[0]]
    return {k: i for i, k in enumerate(h)}, [r for r in rows[2:] if len(r) >= len(h)]


COL = "debug_ready"
for path in sys.argv[1:]:
    c, d = load(path)
    i = [v for k, v in c.items() if COL in k][0]
    v = [int(r[i].strip(), 16) for r in d]
    trans = sum(1 for k in range(1, len(v)) if v[k] != v[k - 1])
    hi = sum(v)
    # 最长连续低/高
    best_lo = best_hi = cur = 1
    lo = hi_ = 0
    for k in range(1, len(v)):
        if v[k] == v[k - 1]:
            cur += 1
        else:
            if v[k - 1] == 0:
                best_lo = max(best_lo, cur)
            else:
                best_hi = max(best_hi, cur)
            cur = 1
    if v[-1] == 0:
        best_lo = max(best_lo, cur)
    else:
        best_hi = max(best_hi, cur)
    print("%-46s %s=1 %4d/%d (%.1f%%)  翻转 %4d 次  最长低 %3d 拍  最长高 %3d 拍"
          % (path.split("\\")[-1], COL, hi, len(v), hi * 100.0 / len(v), trans, best_lo, best_hi))
