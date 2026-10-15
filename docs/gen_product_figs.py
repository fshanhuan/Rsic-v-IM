# -*- coding: utf-8 -*-
"""
gen_product_figs.py — 生成产品说明文档用的两张配图。

  1. figures/v9_arch_overview.png : 微架构总览（功能 5 级 / 物理 8 级 + 片外接口 + 控制通路）
  2. figures/v9_capacity.png      : 资源/容量画像（EP4CE6 vs EP4CE30 占用百分比）

只依赖 Pillow。字体优先用 Windows 的微软雅黑。
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIG = os.path.join(ROOT, "figures")
os.makedirs(FIG, exist_ok=True)

CJK_CANDIDATES = [
    (r"C:\Windows\Fonts\msyh.ttc", 0),
    (r"C:\Windows\Fonts\msyhbd.ttc", 0),
    (r"C:\Windows\Fonts\simhei.ttf", 0),
    (r"C:\Windows\Fonts\simsun.ttc", 0),
]


def load_font(size, bold=False):
    order = CJK_CANDIDATES[::-1] if not bold else CJK_CANDIDATES
    for path, idx in order:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size, index=idx)
            except Exception:
                continue
    return ImageFont.load_default()


# ---------------------------------------------------------------- 绘图小工具
def box(d, x, y, w, h, title, lines, fill, edge, ts=27, ls=20, radius=14,
        title_color=(20, 35, 55)):
    d.rounded_rectangle([x, y, x + w, y + h], radius=radius, fill=fill,
                        outline=edge, width=3)
    if title:
        f = load_font(ts)
        bb = d.textbbox((0, 0), title, font=f)
        d.text((x + (w - (bb[2] - bb[0])) / 2, y + 12), title, font=f,
               fill=title_color)
    if lines:
        f2 = load_font(ls)
        ty = y + 14 + (ts + 10 if title else 0)
        for ln in lines:
            bb = d.textbbox((0, 0), ln, font=f2)
            d.text((x + (w - (bb[2] - bb[0])) / 2, ty), ln, font=f2,
                   fill=(70, 78, 90))
            ty += ls + 8


def arrow(d, p1, p2, color=(60, 80, 110), width=3, head=11):
    d.line([p1, p2], fill=color, width=width)
    import math
    ang = math.atan2(p2[1] - p1[1], p2[0] - p1[0])
    pts = []
    for da in (math.radians(155), math.radians(-155)):
        pts.append((p2[0] + head * math.cos(ang + da),
                    p2[1] + head * math.sin(ang + da)))
    d.polygon([p2] + pts, fill=color)


def dashes(d, p1, p2, color, width=2, dash=10, gap=7):
    import math
    total = math.hypot(p2[0] - p1[0], p2[1] - p1[1])
    if total == 0:
        return
    ux, uy = (p2[0] - p1[0]) / total, (p2[1] - p1[1]) / total
    t = 0.0
    while t < total:
        e = min(t + dash, total)
        d.line([(p1[0] + ux * t, p1[1] + uy * t),
                (p1[0] + ux * e, p1[1] + uy * e)], fill=color, width=width)
        t = e + gap


# ------------------------------------------------------- 图 1：微架构总览
def arch_overview():
    W, H = 1860, 930
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)

    f_title = load_font(40)
    d.text((46, 36), "BigBird v9 微架构总览", font=f_title, fill=(16, 32, 56))
    f_sub = load_font(23)
    d.text((48, 82), "功能 5 级（IF/ID/EX/MEM/WB）  ·  物理 8 个寄存器边界（IF→ID1→ID2→EX→M1→M2→M3→WB）"
                     "  ·  单发射顺序执行  ·  稳态 1 IPC", font=f_sub, fill=(95, 105, 120))

    PIPE_FILL, PIPE_EDGE = (232, 241, 251), (47, 111, 181)
    SUP_FILL, SUP_EDGE = (243, 247, 238), (111, 155, 79)
    CTL_FILL, CTL_EDGE = (253, 241, 227), (200, 127, 42)
    IF_FILL, IF_EDGE = (242, 242, 246), (107, 107, 123)

    y0, bh = 150, 190
    bw, gap = 214, 18
    xs = [50 + i * (bw + gap) for i in range(5)]
    stages = [
        ("IF 取指", ["IFU 维护 PC", "顺序 / 暂停", "重定向 / 预测跳转"]),
        ("ID 译码", ["IDU 两级译码", "读寄存器堆", "主控 + 系统事件"]),
        ("EX 执行", ["EXU 运算", "分支判定 / 目标", "预测校验"]),
        ("MEM 访存", ["LSU 三级流水", "地址成型", "数据整理"]),
        ("WB 写回", ["WBU 结果归一", "写寄存器堆", "写 CSR"]),
    ]
    for x, (t, ls) in zip(xs, stages):
        box(d, x, y0, bw, bh, t, ls, PIPE_FILL, PIPE_EDGE, ts=27, ls=19)
    for i in range(4):
        arrow(d, (xs[i] + bw + 2, y0 + bh / 2), (xs[i + 1] - 2, y0 + bh / 2))

    # 配套单元（挂在各功能级下方）
    sy, sh = y0 + bh + 34, 132
    sup = [
        ("ICache + BPU", ["ICache 64 行直接映射", "gshare 64×2b + BTB 64", "miss 停拍重试 +1 拍"]),
        ("RF / Reg_Stack / CSR", ["32×32 寄存器堆", "M 模式 CSR 组", "MSIP / MTIP 中断"]),
        ("ALU + MDU", ["ALU 组合运算", "mul 1 拍", "div 32 拍迭代"]),
        ("DCache", ["64 行直接映射", "写直达 + 命中更新", "MMIO 直通不缓存"]),
        ("写回端口", ["前递旁路", "提交观测口", "debug_wb_*"]),
    ]
    for x, (t, ls) in zip(xs, sup):
        box(d, x, sy, bw, sh, t, ls, SUP_FILL, SUP_EDGE, ts=20, ls=17)
        dashes(d, (x + bw / 2, y0 + bh), (x + bw / 2, sy), SUP_EDGE, 2, 8, 6)

    # 物理边界条
    by = sy + sh + 26
    f_b = load_font(19)
    d.rounded_rectangle([xs[0], by, xs[-1] + bw, by + 54], radius=10,
                        fill=(248, 249, 251), outline=(190, 196, 206), width=2)
    bnames = ["IF", "ID1", "ID2", "EX", "M1", "M2", "M3", "WB"]
    step = (xs[-1] + bw - xs[0]) / len(bnames)
    for i, n in enumerate(bnames):
        cx = xs[0] + step * (i + 0.5)
        bb = d.textbbox((0, 0), n, font=f_b)
        d.text((cx - (bb[2] - bb[0]) / 2, by + 15), n, font=f_b, fill=(60, 72, 92))
        if i:
            d.line([(xs[0] + step * i, by + 6), (xs[0] + step * i, by + 48)],
                   fill=(190, 196, 206), width=2)
    f_note = load_font(18)
    d.text((xs[0] + 6, by + 60), "", font=f_note, fill=(120, 128, 140))

    # 控制与冒险通路
    cy = by + 96
    box(d, xs[0], cy, 5 * bw + 4 * gap, 166, "控制与冒险通路（Control + Data_hazard）",
        ["Control：重定向 / 冲刷 / load-use 停顿 / 中断接收 / 预测更新",
         "Data_hazard：唯一前递与冒险裁决源，5 个前递点（EX · M1 · M2 · M3 · WB）",
         "load 数据固定在 M3 出现；非法指令不会被执行（no_side_effect）"],
        CTL_FILL, CTL_EDGE, ts=25, ls=19)
    for x in xs:
        dashes(d, (x + bw / 2, cy), (x + bw / 2, sy + sh + 2), CTL_EDGE, 2, 9, 7)

    # 片外接口面板（右侧）
    ix, iw = xs[-1] + bw + 34, 250
    box(d, ix, y0, iw, 372, "片外接口", [], IF_FILL, IF_EDGE, ts=26)
    box(d, ix + 14, y0 + 66, iw - 28, 132, "取指总线",
        ["irom_addr[31:0]", "irom_en", "irom_data[31:0]", "同步读，1 拍返回"],
        (255, 255, 255), (150, 158, 172), ts=19, ls=16)
    box(d, ix + 14, y0 + 208, iw - 28, 152, "数据总线",
        ["perip_addr/wen/ren", "perip_mask[1:0]", "perip_wdata/rdata", "MMIO ≥0x1000_0000 直通"],
        (255, 255, 255), (150, 158, 172), ts=19, ls=16)
    box(d, ix, y0 + 396, iw, 300, "观测 / 调试",
        ["debug_wb_have_inst", "debug_wb_pc / ena", "debug_wb_reg / value",
         "debug_icache_hit/miss_cnt", "debug_dcache_hit/miss_cnt",
         "debug_mcause / mepc", "debug_mtval / trap_take",
         "无 JTAG，无硬件断点"],
        (255, 255, 255), (150, 158, 172), ts=20, ls=17)
    arrow(d, (ix - 2, y0 + 130), (xs[-1] + bw + 2, y0 + 130), (150, 158, 172), 2)
    arrow(d, (xs[-1] + bw + 2, y0 + 300), (ix - 2, y0 + 300), (150, 158, 172), 2)

    f_foot = load_font(19)
    d.text((50, H - 46),
           "取指→写回约 6~7 拍（IDU 内部 2 拍、LSU 内部 3 拍）   ·   时钟：单时钟域 cpu_clk   ·   "
           "复位：cpu_rst 高有效同步复位（board 层异步置位 / 同步释放）",
           font=f_foot, fill=(120, 128, 140))
    img.save(os.path.join(FIG, "v9_arch_overview.png"))


# ------------------------------------------------------- 图 2：容量画像
def capacity():
    W, H = 1500, 760
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    f_t = load_font(38)
    d.text((46, 30), "整机资源占用（相对器件容量）", font=f_t, fill=(16, 32, 56))
    f_s = load_font(22)
    d.text((48, 82), "整机含 64 KB DRAM + 16 KB IROM；低于 100% 线才算能装下", font=f_s,
           fill=(95, 105, 120))

    items = [
        ("逻辑单元 LE", 306, 67),
        ("寄存器 FF", 139, 30),
        ("M9K 存储块", 227, 103),
        ("存储位", 192, 23),
        ("引脚", 218, 61),
    ]
    top, bottom = 210, 600
    vmax = 340.0
    plot_l, plot_r = 150, W - 60

    # 图例（放在绘图区上方，避免与类目名重叠）
    lx, ly = plot_l, 132
    f_leg = load_font(21)
    d.rounded_rectangle([lx, ly + 3, lx + 26, ly + 23], radius=4, fill=(205, 74, 74))
    d.text((lx + 36, ly), "EP4CE6E22C8（征途板：6,272 LE / 30 M9K / 92 脚）", font=f_leg,
           fill=(70, 78, 90))
    d.rounded_rectangle([lx + 620, ly + 3, lx + 646, ly + 23], radius=4, fill=(74, 130, 196))
    d.text((lx + 656, ly), "EP4CE30F23C6（28,848 LE / 66 M9K / 329 脚）", font=f_leg,
           fill=(70, 78, 90))

    def yv(v):
        return bottom - (bottom - top) * min(v, vmax) / vmax

    for gv in range(0, 341, 50):
        y = yv(gv)
        col = (210, 60, 60) if gv == 100 else (226, 230, 236)
        wid = 3 if gv == 100 else 1
        d.line([(plot_l, y), (plot_r, y)], fill=col, width=wid)
        fl = load_font(18)
        d.text((plot_l - 66, y - 11), f"{gv}%", font=fl,
               fill=(190, 50, 50) if gv == 100 else (140, 148, 160))

    f_lab = load_font(21)
    n = len(items)
    slot = (plot_r - plot_l) / n
    bwid = 56
    for i, (name, e6, e30) in enumerate(items):
        cx = plot_l + slot * (i + 0.5)
        for k, (val, colr, tcol) in enumerate(
                [(e6, (205, 74, 74), (150, 40, 40)), (e30, (74, 130, 196), (30, 60, 120))]):
            x = cx + (k - 1) * (bwid + 10) - bwid / 2
            y = yv(val)
            d.rounded_rectangle([x, y, x + bwid, bottom], radius=5, fill=colr)
            fv = load_font(21)
            bb = d.textbbox((0, 0), f"{val}%", font=fv)
            d.text((x + (bwid - (bb[2] - bb[0])) / 2, y - 32), f"{val}%",
                   font=fv, fill=tcol)
        bb = d.textbbox((0, 0), name, font=f_lab)
        d.text((cx - (bb[2] - bb[0]) / 2, bottom + 26), name, font=f_lab,
               fill=(50, 62, 82))

    d.line([(plot_l, bottom), (plot_r, bottom)], fill=(120, 128, 140), width=2)
    f_c = load_font(21)
    d.text((plot_l, H - 96), "结论：CE6 四项全爆（逻辑 306% / 寄存器 139% / 存储 192% / 引脚 218%）；",
           font=f_c, fill=(150, 40, 40))
    d.text((plot_l, H - 60), "换 CE30 后四项都够，只剩 M9K 差 2 块（68/66）——瓶颈是 64 KB DRAM。",
           font=f_c, fill=(150, 40, 40))
    img.save(os.path.join(FIG, "v9_capacity.png"))


if __name__ == "__main__":
    arch_overview()
    capacity()
    print("OK:", os.path.join(FIG, "v9_arch_overview.png"))
    print("OK:", os.path.join(FIG, "v9_capacity.png"))
