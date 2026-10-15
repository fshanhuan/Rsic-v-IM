#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""probe_census.py — 逐列统计一次 ILA 抓取里每个 1bit/多bit 探针的取值分布"""
import sys, csv
from collections import Counter

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def load(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rows = list(csv.reader(f))
    header = [h.strip() for h in rows[0]]
    return header, [r for r in rows[2:] if len(r) >= len(header)]


for path in sys.argv[1:]:
    header, d = load(path)
    print("=" * 78)
    print(path)
    print("=" * 78)
    for i, h in enumerate(header):
        vals = [r[i].strip() for r in d]
        c = Counter(vals)
        uniq = len(c)
        if uniq <= 6:
            s = "  ".join("%s x%d" % (k, v) for k, v in c.most_common())
        else:
            nums = []
            for k in c:
                try:
                    nums.append(int(k, 16))
                except ValueError:
                    pass
            s = "不同取值 %d 个，范围 0x%X..0x%X" % (uniq, min(nums), max(nums))
        ones = c.get("1", 0) + c.get("01", 0) + c.get("1'b1", 0)
        print("  %-34s %s%s" % (h, s, ("   [=1 的拍数 %d]" % ones) if ones and uniq <= 6 else ""))
    print("")
