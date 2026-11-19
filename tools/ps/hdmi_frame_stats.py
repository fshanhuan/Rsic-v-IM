#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hdmi_frame_stats.py -- 判一张 HDMI 抓帧里"有没有我们的画面"

为什么需要它
------------
采集卡抓到的不一定是画面：没信号时它会自己叠一个 "No Signal" OSD。
肉眼一看就知道，但验收判据必须是**脚本能判**的一行 RESULT。

三个判据（都是可算的，不靠眼睛）：
  1. 近黑像素占比      —— 采集卡的 OSD 是"几乎全黑 + 中间一行字"
  2. 绿色像素占比      —— 我们的画面有绿色网格（80×50）和波形亮线
  3. 网格周期          —— 在列/行亮度投影上找峰，峰间距应 ≈ 80 像素

用法：
    python tools/ps/hdmi_frame_stats.py _diag/hdmi_cap_800x600.png
    python tools/ps/hdmi_frame_stats.py sim/build/hdmi_frame.png     # S3 的已知好帧
    加 --quiet 只打印最后一行 RESULT

判定：
    NO_SIGNAL          近黑 > 90% 且 绿色 < 0.1%          （采集卡 OSD）
    GRID_<N>           找到周期网格，N = 中位间距
    FRAME_NO_GRID      有画面但没找到 80 像素网格

标定（2026-11-19）：拿 S3 逐行 ILA 重建出来的整帧跑，得 GRID_80、
列峰 80.0（x=80..720）、行峰 50.0（y=50..550），且四个颜色的像素数
与文档 §34 记的 460472 / 14632 / 3860 / 1036 逐项相同。
"""
import sys
import numpy as np
from PIL import Image


def load(p):
    im = Image.open(p).convert("RGB")
    return np.asarray(im).astype(np.int16)


def peaks(proj, thr_ratio=0.45):
    """在一维投影上找峰，返回峰值位置（局部最大 + 高于阈值）"""
    if proj.max() <= 0:
        return []
    thr = proj.max() * thr_ratio
    idx = []
    for i in range(1, len(proj) - 1):
        if proj[i] >= thr and proj[i] >= proj[i - 1] and proj[i] >= proj[i + 1]:
            if idx and i - idx[-1] <= 2:      # 合并相邻峰（一条线可能占 2 列）
                if proj[i] > proj[idx[-1]]:
                    idx[-1] = i
            else:
                idx.append(i)
    return idx


def median_spacing(pos):
    if len(pos) < 3:
        return None
    d = np.diff(pos)
    d = d[d > 2]
    if len(d) == 0:
        return None
    return float(np.median(d))


def main(argv):
    quiet = "--quiet" in argv
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print("usage: hdmi_frame_stats.py <png>")
        return 2
    p = args[0]
    a = load(p)
    h, w, _ = a.shape
    R, G, B = a[:, :, 0], a[:, :, 1], a[:, :, 2]

    total = float(h * w)
    nearblack = float(np.count_nonzero((R < 24) & (G < 24) & (B < 24)) / total) * 100.0
    green = float(np.count_nonzero((G > 80) & (G > R + 40) & (G > B + 40)) / total) * 100.0

    # 网格：只看绿色分量，列/行各做一次投影
    g = np.where((G > 80) & (G > R + 40) & (G > B + 40), G, 0)
    colproj = g.sum(axis=0)
    rowproj = g.sum(axis=1)
    cp = peaks(colproj)
    rp = peaks(rowproj)
    csp = median_spacing(cp)
    rsp = median_spacing(rp)

    # 主要颜色
    flat = (a[:, :, 0].astype(np.int32) << 16) | (a[:, :, 1].astype(np.int32) << 8) | a[:, :, 2].astype(np.int32)
    vals, cnts = np.unique(flat, return_counts=True)
    order = np.argsort(cnts)[::-1][:6]

    if nearblack > 90.0 and green < 0.1:
        verdict = "NO_SIGNAL"
    elif csp is not None and 70 <= csp <= 90:
        verdict = "GRID_%d" % int(round(csp))
    elif rsp is not None and 70 <= rsp <= 90:
        verdict = "GRID_%d" % int(round(rsp))
    else:
        verdict = "FRAME_NO_GRID"

    if not quiet:
        print("frame: %s  %dx%d" % (p, w, h))
        print("near-black : %6.2f %%" % nearblack)
        print("green      : %6.3f %%" % green)
        print("colors     : %d distinct" % len(vals))
        print("top colors :")
        for i in order:
            v = int(vals[i])
            print("   #%06X  %8d px  %6.2f %%" % (v, cnts[i], 100.0 * cnts[i] / total))
        print("col peaks  : %d  spacing=%s" % (len(cp), "n/a" if csp is None else "%.1f" % csp))
        print("row peaks  : %d  spacing=%s" % (len(rp), "n/a" if rsp is None else "%.1f" % rsp))
        if csp:
            print("col peak xs: %s" % cp[:12])
        if rsp:
            print("row peak ys: %s" % rp[:12])

    print("RESULT frame_stats verdict=%s size=%dx%d nearblack=%.2f green=%.3f colspacing=%s rowspacing=%s"
          % (verdict, w, h, nearblack, green,
             "n/a" if csp is None else "%.1f" % csp,
             "n/a" if rsp is None else "%.1f" % rsp))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
