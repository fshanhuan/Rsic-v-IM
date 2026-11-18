#!/usr/bin/env python3
"""ila_pixels_to_png.py —— 把 ILA 抓到的 HDMI 像素 CSV 还原成图片 + 统计

输入：Vivado `write_hw_ila_data -csv_file` 导出的 CSV（列里有 hdmi_d/de/hsync/vsync）
输出：
  · sim/build/hdmi_line_preview.png   —— 抓到的若干行拼成的小图（放大 2x）
  · 控制台统计：行数、每行有效像素数、像素取值分布、网格/波形特征

为什么需要：没有显示器时，这是"画面上真是什么"的唯一直接证据。
"""
import csv
import sys
from collections import Counter

def find_col(headers, *keys):
    for h in headers:
        hl = h.strip().lower()
        for k in keys:
            if k in hl:
                return h
    return None

def main():
    if len(sys.argv) < 2:
        print("用法: python ila_pixels_to_png.py <ila_pixels.csv> [输出png]")
        return 2
    path = sys.argv[1]
    out_png = sys.argv[2] if len(sys.argv) > 2 else "sim/build/hdmi_line_preview.png"

    with open(path, newline="", encoding="utf-8", errors="ignore") as f:
        rd = csv.reader(f)
        rows = list(rd)
    if len(rows) < 2:
        print("CSV 行数不足")
        return 1
    headers = rows[0]
    # 第二行是 Radix 说明（Vivado 会把数据列标成 HEX）——必须按它决定进制，
    # 否则 "1080" 会被当成十进制 1080，而不是 0x1080。
    radix = rows[1] if len(rows) > 1 and rows[1] and rows[1][0].lower().startswith("radix") else []
    def base_of(col_name):
        if not radix:
            return 16
        try:
            i = headers.index(col_name)
            return 16 if "hex" in radix[i].strip().lower() else 10
        except (ValueError, IndexError):
            return 16
    c_d = find_col(headers, "hdmi_d", "probe0")
    c_de = find_col(headers, "de", "probe1")
    c_hs = find_col(headers, "hsync", "hs")
    c_vs = find_col(headers, "vsync", "vs")
    print("列映射:", {"data": c_d, "de": c_de, "hsync": c_hs, "vsync": c_vs}, "进制:",
          {k: (16 if v and base_of(v) == 16 else 10) for k, v in
           {"data": c_d, "de": c_de}.items()})
    if c_d is None or c_de is None:
        print("找不到数据/DE 列：", headers)
        return 1
    i_d, i_de = headers.index(c_d), headers.index(c_de)
    i_hs = headers.index(c_hs) if c_hs else None
    i_vs = headers.index(c_vs) if c_vs else None
    b_d = base_of(c_d)
    b_de = base_of(c_de)
    b_hs = base_of(c_hs) if c_hs else 10
    b_vs = base_of(c_vs) if c_vs else 10

    samples = []
    for r in rows[2:] if radix else rows[1:]:
        try:
            d = int(r[i_d], b_d)
            de = int(r[i_de], b_de)
            hs = int(r[i_hs], b_hs) if i_hs is not None else None
            vs = int(r[i_vs], b_vs) if i_vs is not None else None
        except (ValueError, IndexError):
            continue
        samples.append((d, de, hs, vs))
    print(f"样本数 = {len(samples)}")
    if not samples:
        return 1

    # 按 hsync 下降沿（或 de 下降沿）切行
    lines, cur = [], []
    prev_de = 0
    for d, de, hs, vs in samples:
        if de:
            cur.append(d)
        elif prev_de and cur:
            lines.append(cur)
            cur = []
        prev_de = de
    if cur:
        lines.append(cur)

    lens = [len(l) for l in lines]
    print(f"切出 {len(lines)} 行有效像素，行长 = {lens}")
    vals = Counter()
    for l in lines:
        for d in l:
            vals[d] += 1
    print("像素取值 top8:", vals.most_common(8))

    if not lines:
        return 1

    # 画图：每行像素按 16 位颜色转 RGB565
    try:
        from PIL import Image
    except ImportError:
        print("没有 Pillow，跳过 PNG；上面统计已足够")
        return 0

    W = max(len(l) for l in lines)
    H = len(lines)
    SCALE = 2
    img = Image.new("RGB", (W * SCALE, H * SCALE))
    for y, l in enumerate(lines):
        for x, d in enumerate(l):
            r = ((d >> 11) & 0x1F) * 255 // 31
            g = ((d >> 5) & 0x3F) * 255 // 63
            b = (d & 0x1F) * 255 // 31
            for dy in range(SCALE):
                for dx in range(SCALE):
                    img.putpixel((x * SCALE + dx, y * SCALE + dy), (r, g, b))
    img.save(out_png)
    print(f"已保存 {out_png}（{W}×{H}，放大 {SCALE}x）")
    return 0

if __name__ == "__main__":
    sys.exit(main())
