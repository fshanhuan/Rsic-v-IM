#!/usr/bin/env python3
"""ila_text_decode.py —— 从 ILA 抓到的 HDMI 像素里**把屏幕上的文字读出来**

原理：`scope_display` 的文本层是 5×7 点阵（`board/font5x7.sv`），字符单元 8×8，
面板在 (x=16..271, y=16..31)，等于 32 列 × 2 行。ILA 每次抓 4 行，抓 4 次覆盖 16 行后，
按 (行, 列) 把像素拼回 32×16 的位图，再逐 5×7 块与字模表比对，就能还原字符串。

用法：
  python tools/ps/ila_text_decode.py sim/build/ila_line_39.csv sim/build/ila_line_43.csv \
      sim/build/ila_line_47.csv sim/build/ila_line_51.csv
"""
import csv
import re
import sys

FONT_SV = "board/font5x7.sv"
PANEL_X0, PANEL_X1 = 16, 272
TEXT_COLOR = 0xEB80
PANEL_COLOR = 0x1880


def parse_font(path):
    """从 font5x7.sv 里抠出 {索引: (字符, [7 行 5 位])}。"""
    txt = open(path, encoding="utf-8", errors="ignore").read()
    font = {}
    for m in re.finditer(r"5'd(\d+):\s*case\s*\(r\)(.*?)endcase\s*//\s*'(.)'", txt, re.S):
        idx = int(m.group(1))
        body, ch = m.group(2), m.group(3)
        rows = {}
        for rm in re.finditer(r"3'd(\d+):\s*frow\s*=\s*5'b([01]{5})", body):
            rows[int(rm.group(1))] = rm.group(2)
        if len(rows) == 7:
            font[idx] = (ch, [rows[i] for i in range(7)])
    return font


def read_captures(paths):
    """返回 {dbg_line: {x_index: pixel}}；x_index = 该行第几个有效像素。"""
    img = {}
    for p in paths:
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
        i_d = col("hdmi_d")
        i_de = col("hdmi_de")
        i_ln = col("dbg_line")
        if None in (i_d, i_de, i_ln):
            print("跳过（列不全）:", p, hdr)
            continue
        for r in rd[2:]:
            try:
                d = int(r[i_d], 16)
                de = int(r[i_de], 16)
                ln = int(r[i_ln], 16)
            except (ValueError, IndexError):
                continue
            if de != 1:
                continue
            row = img.setdefault(ln, {})
            row[len(row)] = d
    return img


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    font = parse_font(FONT_SV)
    inv = {}
    for idx, (ch, rows) in font.items():
        inv.setdefault(tuple(rows), ch)
    print(f"字模表：{len(font)} 个字符，{len(inv)} 个不同图案")

    img = read_captures(sys.argv[1:])
    if not img:
        print("没有有效样本")
        return 1
    lines = sorted(img)
    print(f"抓到 {len(lines)} 行：{lines[0]}..{lines[-1]}，每行有效像素 {len(img[lines[0]])}")

    base = 39                     # 实测：面板第一行 = dbg_line 39
    for trow in range(2):
        chars = []
        for ccol in range(32):
            bits = []
            for gy in range(7):
                probe_bits = ""
                for gx in range(5):
                    y = base + trow * 8 + gy
                    x = PANEL_X0 + ccol * 8 + gx
                    px = img.get(y, {}).get(x, None)
                    probe_bits += "1" if px == TEXT_COLOR else "0"
                bits.append(probe_bits)
            ch = inv.get(tuple(bits))
            chars.append(ch if ch else ('?' if any('1' in b for b in bits) else '.'))
        s = "".join(chars)
        print(f"文本行 {trow}（32 格全打，'.' = 空白格，'?' = 字模不匹配）：\"{s}\"")
    # 顺带统计面板底色像素，确认面板确实在这几行
    n_panel = sum(1 for ln in lines for v in img[ln].values() if v == PANEL_COLOR)
    print(f"面板底色像素 {n_panel} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
