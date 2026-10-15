#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""correlate_dcache.py — 找出 dcache_miss / dcache_hit 计数涨在哪个 PC 上"""
import sys, csv

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def load(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rows = list(csv.reader(f))
    header = [h.strip() for h in rows[0]]
    body = [r for r in rows[2:] if len(r) >= len(header)]
    return {h: i for i, h in enumerate(header)}, body


def col(c, n):
    for h, i in c.items():
        if n in h:
            return i
    return None


def hv(s):
    try:
        return int((s or "").strip(), 16)
    except ValueError:
        return None


def run(path, label):
    c, d = load(path)
    ih, im = col(c, "icache_hit"), col(c, "icache_miss")
    dh, dm = col(c, "dcache_hit"), col(c, "dcache_miss")
    wp, wv, we = col(c, "debug_wb_pc"), col(c, "debug_wb_value"), col(c, "debug_wb_ena")
    ip = col(c, "ifu_pc")
    print("=" * 78)
    print("%s  (%s)" % (label, path))
    print("=" * 78)
    for name, idx in (("dcache_miss", dm), ("dcache_hit", dh)):
        vals = [hv(r[idx]) for r in d]
        inc = [k for k in range(1, len(vals)) if vals[k] != vals[k - 1]]
        print("")
        print("---- %s：窗口内变化 %d 次 (首=%s 末=%s) ----"
              % (name, len(inc), vals[0], vals[-1]))
        for k in inc[:12]:
            print("   拍 %4d -> %4d  (+%s)   wb_pc=0x%s ena=%s val=0x%s   ifu_pc=0x%s"
                  % (k - 1, k, vals[k] - vals[k - 1] if vals[k] > vals[k - 1] else "?",
                     d[k][wp], d[k][we], d[k][wv], d[k][ip] if ip else "?"))
    # wb_pc 直方图
    hist = {}
    for r in d:
        p = hv(r[wp])
        hist[p] = hist.get(p, 0) + 1
    print("")
    print("---- wb_pc 直方图（按 PC 统计拍数）----")
    for p in sorted(hist):
        print("   0x%02X : %4d" % (p, hist[p]))


if __name__ == "__main__":
    for i, p in enumerate(sys.argv[1:]):
        run(p, "抓取%d" % (i + 1))
