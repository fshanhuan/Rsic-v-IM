# -*- coding: utf-8 -*-
"""Generate the three product-report figures with Pillow (no matplotlib)."""
import os
from PIL import Image, ImageDraw, ImageFont

FONT_DIR = r"C:\Windows\Fonts"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "figures")


def font(size, bold=False):
    names = ["msyhbd.ttc", "msyh.ttc"] if bold else ["msyh.ttc", "simhei.ttf"]
    for n in names:
        p = os.path.join(FONT_DIR, n)
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


INK = (0x26, 0x26, 0x26)
GREY = (0x59, 0x59, 0x59)
GRID = (0xE6, 0xE6, 0xE6)
BLUE = (0x1F, 0x4E, 0x79)
MID = (0x2E, 0x75, 0xB6)
PALE = (0x9D, 0xC3, 0xE6)
ORANGE = (0xC5, 0x5A, 0x11)
GREYBAR = (0xB4, 0xB4, 0xB4)

W, H = 1500, 900
LEFT, RIGHT = 190, 70


def canvas(title, subtitle, top=150, bot=120):
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    size = 44
    while size > 30 and d.textlength(title, font=font(size, True)) > W - LEFT - RIGHT + 40:
        size -= 2
    d.text((LEFT - 20, 34), title, font=font(size, True), fill=INK)
    d.text((LEFT - 20, 96), subtitle, font=font(23), fill=GREY)
    return img, d, top, bot


def axes(d, ymax, ticks, fmt, top, bot):
    pw = W - LEFT - RIGHT
    ph = H - top - bot
    for t in ticks:
        y = top + ph * (1.0 - t / ymax)
        d.line([(LEFT, y), (LEFT + pw, y)], fill=GRID, width=2)
        label = fmt(t)
        tw = d.textlength(label, font=font(24))
        d.text((LEFT - 16 - tw, y - 15), label, font=font(24), fill=GREY)
    d.line([(LEFT, top + ph), (LEFT + pw, top + ph)], fill=(0x8C, 0x8C, 0x8C), width=3)
    return pw, ph


def footnote(d, text):
    d.text((LEFT - 20, H - 40), text, font=font(20), fill=GREY)


def save(img, name):
    path = os.path.abspath(os.path.join(OUT, name))
    img.save(path, "PNG", dpi=(150, 150))
    print("wrote", path)


# ---------------------------------------------------------------- figure 1
def fig_coremark():
    img, d, top, bot = canvas(
        "CoreMark 1.0 成绩演进（同一板卡 / 同一工具链）",
        "纵轴：CoreMark/MHz　·　横轴：版本（v13.5 → v14 → v15，每版只改动上一版的 RTL）",
        top=170)
    data = [("v13.5", 2.335, "116.80 iter/s"), ("v14", 2.408, "120.41 iter/s"),
            ("v15", 2.576, "128.82 iter/s")]
    pw, ph = axes(d, 3.0, [0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], lambda t: "%.1f" % t, top, bot)
    n = len(data)
    slot = pw / n
    bw = slot * 0.40
    for i, (name, val, sub) in enumerate(data):
        cx = LEFT + slot * (i + 0.5)
        y = top + ph * (1.0 - val / 3.0)
        color = PALE if i == 0 else (MID if i == 1 else BLUE)
        d.rectangle([cx - bw / 2, y, cx + bw / 2, top + ph], fill=color)
        t = "%.3f" % val
        tw = d.textlength(t, font=font(34, True))
        d.text((cx - tw / 2, y - 82), t, font=font(34, True), fill=INK)
        tw = d.textlength(sub, font=font(21))
        d.text((cx - tw / 2, y - 44), sub, font=font(21), fill=GREY)
        tw = d.textlength(name, font=font(26, True))
        d.text((cx - tw / 2, top + ph + 20), name, font=font(26, True), fill=INK)
    d.line([(LEFT + slot * 0.5 + bw / 2 + 10, top + 30),
            (LEFT + slot * 2.5 - bw / 2 - 10, top + 30)], fill=ORANGE, width=3)
    d.text((LEFT + slot * 1.0, top - 6), "+10.3%  两轮累计", font=font(26, True), fill=ORANGE)
    footnote(d, "数据来源：上板实测，ITER=1400，10.868 s，CRC 与官方一致（e714 / 1fd7 / 8e3a）")
    save(img, "v17_coremark_trend.png")


# ---------------------------------------------------------------- figure 2
def fig_bp():
    img, d, top, bot = canvas(
        "分支预测容量扫参：收益递减（每档只改 para.sv 两个参数）",
        "纵轴：相对 64 行配置的周期缩减（%）　·　柱下标注 BTB/PHT 行数 / GHR 位宽与绝对拍数",
        top=150, bot=190)
    data = [("64 / 6", 0.0, "482 990 拍 · 基线"),
            ("256 / 6", 2.40, "471 384 拍"),
            ("256 / 8", 3.05, "468 266 拍 · 采用"),
            ("1024 / 8", 4.20, "462 715 拍"),
            ("1024 / 10", 4.38, "461 825 拍")]
    pw, ph = axes(d, 5.0, [0, 1, 2, 3, 4, 5], lambda t: "%d%%" % t, top, bot)
    n = len(data)
    slot = pw / n
    bw = slot * 0.44
    for i, (name, val, note) in enumerate(data):
        cx = LEFT + slot * (i + 0.5)
        y = top + ph * (1.0 - val / 5.0)
        color = GREYBAR if i == 0 else (BLUE if i == 2 else (MID if i < 4 else PALE))
        d.rectangle([cx - bw / 2, y, cx + bw / 2, top + ph], fill=color)
        t = "—" if i == 0 else "-%.2f%%" % val
        tw = d.textlength(t, font=font(30, True))
        d.text((cx - tw / 2, y - 42), t, font=font(30, True), fill=INK)
        tw = d.textlength(name, font=font(26, True))
        d.text((cx - tw / 2, top + ph + 16), name, font=font(26, True), fill=INK)
        tw = d.textlength(note, font=font(19))
        d.text((cx - tw / 2, top + ph + 50), note, font=font(19), fill=GREY)
    footnote(d, "结论：64→256 拿到 3.05%；256→1024 只多 1.15 个百分点，却要多 ~900 LUT 与「1024 选 1」取指 mux，故停在 256")
    save(img, "v17_bp_sweep.png")


# ---------------------------------------------------------------- figure 3
def fig_stall():
    img, d, top, bot = canvas(
        "停顿拍数去向：load-use 改善前后",
        "CoreMark 1 次迭代　·　蓝 = v14 基线，橙 = v15　·　末项「误预测重填」为总拍数减各项反推",
        top=170, bot=150)
    cats = [("load-use 重放", 50339, 22681), ("MDU 迭代", 20868, 20832),
            ("DCache hold", 4547, 4543), ("误预测重填（推算）", 38597, 38718)]
    pw, ph = axes(d, 60000, [0, 10000, 20000, 30000, 40000, 50000, 60000],
                  lambda t: "%d k" % (t // 1000), top, bot)
    n = len(cats)
    slot = pw / n
    bw = slot * 0.26
    for i, (name, a, b) in enumerate(cats):
        cx = LEFT + slot * (i + 0.5)
        for val, color, dx in [(a, MID, -bw * 0.62), (b, ORANGE, bw * 0.62)]:
            y = top + ph * (1.0 - val / 60000.0)
            x0 = cx + dx - bw / 2
            d.rectangle([x0, y, x0 + bw, top + ph], fill=color)
            t = "{:,}".format(val).replace(",", " ")
            tw = d.textlength(t, font=font(21, True))
            d.text((x0 + bw / 2 - tw / 2, y - 32), t, font=font(21, True), fill=INK)
        tw = d.textlength(name, font=font(22))
        d.text((cx - tw / 2, top + ph + 18), name, font=font(22), fill=INK)
    footnote(d, "load-use -55%，总周期 -5.9%，CPI 1.323 → 1.245；"
                "「误预测重填」= 总拍数 - 退休 - 三项实测 = 38 597 / 38 718")
    save(img, "v17_stall_before_after.png")


if __name__ == "__main__":
    fig_coremark()
    fig_bp()
    fig_stall()
