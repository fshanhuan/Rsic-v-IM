#!/usr/bin/env python3
"""ila_frame_assemble.py —— 把 150 段 ILA 抓取拼成完整一帧 800×600 的 PNG

输入：sim/build/frame/ila_frame_*.csv（每段 4096 拍，含 hdmi_d / de / dbg_line）
输出：sim/build/hdmi_frame.png（800×600，RGB565 还原）

坐标换算（实测）：显示坐标 y = dbg_line - 23，面板 y=16..31 对应 dbg_line 39..54。
x = 该行内第几个 de=1 的像素（0..799）。
"""
import csv
import glob
import os
import sys
from collections import defaultdict

Y_OFFSET = 23
W, H = 800, 600
COLOR_NAMES = {0x1080: "背景", 0x4680: "网格", 0x1880: "文本面板", 0xEB80: "波形/字模"}


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "sim/build/frame"
    out = sys.argv[2] if len(sys.argv) > 2 else "sim/build/hdmi_frame.png"
    files = sorted(glob.glob(os.path.join(d, "ila_frame_*.csv")))
    if not files:
        print("没找到帧片段 CSV")
        return 1
    print(f"片段数 = {len(files)}")

    img = defaultdict(dict)      # img[y][x] = pixel
    cnt = defaultdict(int)
    for p in files:
        with open(p, newline="", encoding="utf-8", errors="ignore") as f:
            rd = list(csv.reader(f))
        if len(rd) < 3:
            continue
        hdr = rd[0]

        def col(*keys):
            for i, h in enumerate(hdr):
                hl = h.strip().lower()
                if all(k in hl for k in keys):
                    return i
            return None
        i_d, i_de, i_ln = col("hdmi_d"), col("hdmi_de"), col("dbg_line")
        if None in (i_d, i_de, i_ln):
            continue
        row_x = defaultdict(int)          # 每行的 x 计数
        for r in rd[2:]:
            try:
                de = int(r[i_de], 16)
                if de != 1:
                    continue
                v = int(r[i_d], 16)
                ln = int(r[i_ln], 16)
            except (ValueError, IndexError):
                continue
            y = ln - Y_OFFSET
            if y < 0 or y >= H:
                continue
            x = row_x[ln]
            row_x[ln] += 1
            if x >= W:
                continue
            if x not in img[y]:        # 先到先得（同一行可能在多个片段里重复出现）
                img[y][x] = v
                cnt[v] += 1

    got_rows = len(img)
    print(f"拼出 {got_rows} 行；像素颜色统计：")
    for k, c in sorted(cnt.items(), key=lambda kv: -kv[1]):
        print(f"  0x{k:04X} ({COLOR_NAMES.get(k, '?')}) : {c}")

    try:
        from PIL import Image
    except ImportError:
        print("没有 Pillow，跳过 PNG")
        return 0

    im = Image.new("RGB", (W, H))
    px = im.load()
    for y in range(H):
        for x in range(W):
            v = img.get(y, {}).get(x, 0x1080)      # 没抓到的默认背景
            r = ((v >> 11) & 0x1F) * 255 // 31
            g = ((v >> 5) & 0x3F) * 255 // 63
            b = (v & 0x1F) * 255 // 31
            px[x, y] = (r, g, b)
    im.save(out)
    print(f"已保存 {out}（{W}×{H}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
