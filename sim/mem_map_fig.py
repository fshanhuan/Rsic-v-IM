#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mem_map_fig.py — 画「存储器在芯片里的位置 / 地址空间 / 三路译码」示意图。

事实来源（全部可在 RTL 里点开看）：
  board/board_top.sv   容量参数 IROM_WORDS=16384 / DRAM_WORDS=32768、三路译码
                       mmio_sel / irom_win_sel / 其余落 DRAM、MMIO 寄存器表
  board/sync_mem_dp.sv IROM 的 2R1W 模板、1 拍读延迟
  board/sync_mem.sv    DRAM 同步读 + mask 字节写
  rtl/DCache.sv        256 行直接映射、UNCACHE_MASK=0x0FFF_FFFF

用法：python sim/mem_map_fig.py   →  figures/存储器/M1_*.png / M9_*.png
"""
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
OUT = os.path.join(ROOT, "figures", "存储器")

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

C_CPU, C_CPU_E = "#e8f0fe", "#1f4e9c"
C_MEM, C_MEM_E = "#e6f4ea", "#1b6b3a"
C_MMIO, C_MMIO_E = "#fff4e5", "#b26a00"
C_TXT, C_GREY = "#202124", "#5f6368"

FIGW, FIGH = 9.6, 6.4


def box(ax, x, y, w, h, title, lines=(), fc="#fff", ec="#333", fs_t=9.0, fs_l=6.9, lw=1.2):
    """y 是底边，h 是高度（axes 分数）。行距按英寸折算，避免文字溢出框。"""
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.004,rounding_size=0.010",
                                facecolor=fc, edgecolor=ec, lw=lw, zorder=3))
    lh = 0.0195                      # 一行 ≈ 0.0195 * 6.4 in ≈ 0.125 in
    ax.text(x + w / 2, y + h - 0.014, title, ha="center", va="top",
            fontsize=fs_t, color=C_TXT, fontweight="bold", zorder=4)
    for i, ln in enumerate(lines):
        ax.text(x + w / 2, y + h - 0.048 - i * lh, ln, ha="center", va="top",
                fontsize=fs_l, color=C_GREY, zorder=4)


def arrow(ax, p1, p2, color="#5f6368", lw=1.1, ls="-", rad=0.0, z=2):
    ax.add_patch(FancyArrowPatch(p1, p2, arrowstyle="-|>", mutation_scale=9,
                                 color=color, lw=lw, linestyle=ls, zorder=z,
                                 connectionstyle="arc3,rad=%s" % rad))


def fig_position():
    """图 M1：存储器在芯片里的位置 + 两条总线 + 两张地址空间。"""
    fig = plt.figure(figsize=(FIGW, FIGH), dpi=240)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    ax.text(0.02, 0.985, "图 M1　存储器在芯片里的位置、连接方式与地址空间",
            fontsize=11, fontweight="bold", color="#111", va="top")
    ax.text(0.02, 0.945, "一片 xc7z020 里：CPU 是逻辑（LUT/FF），三块存储器是 BRAM 或触发器阵列；"
                         "取指与访存是两条独立总线（哈佛结构）",
            fontsize=7.4, color=C_GREY, va="top")

    # ---------------- CPU ----------------
    box(ax, 0.020, 0.545, 0.215, 0.360, "myCPU（8 级流水）",
        ["IFU 取指", "IDU 译码", "EXU 执行 + MDU", "LSU 访存",
         "WBU 写回", "", "寄存器堆 32×32", "DCache 1 KB（256 行）"],
        fc=C_CPU, ec=C_CPU_E, fs_t=9.2, fs_l=6.8)

    # ---------------- 存储器 ----------------
    ax.add_patch(Rectangle((0.585, 0.535), 0.395, 0.372, facecolor="#fafbfc",
                           edgecolor="#c9cdd2", lw=1.0, zorder=1))

    box(ax, 0.598, 0.752, 0.370, 0.135, "IROM — 64 KB（16384 字 × 32 b）",
        ["双口 BRAM：端口A 取指、端口B 数据窗口",
         "取指地址 0x0000_0000..0x0000_FFFF",
         "数据窗口 0x0002_0000..0x0002_FFFF（v16 起可写）"],
        fc=C_MEM, ec=C_MEM_E, fs_t=8.6, fs_l=6.5)
    box(ax, 0.598, 0.636, 0.370, 0.108, "DRAM — 128 KB（32768 字 × 32 b）",
        ["单口同步 BRAM：ren 读 / wen 按 mask 写",
         "地址 0x0000_0000..0x0001_FFFF，软件只用 0x1_0000 以上"],
        fc=C_MEM, ec=C_MEM_E, fs_t=8.6, fs_l=6.5)
    box(ax, 0.598, 0.545, 0.370, 0.078, "MMIO — 7 个寄存器（触发器，不占 BRAM）",
        ["+0 TXDATA　+4 TXSTAT　+8 RXDATA　+C RXSTAT　+10 LED　+14 BOOTREQ　+18 RXPOP"],
        fc=C_MMIO, ec=C_MMIO_E, fs_t=8.2, fs_l=5.9)

    # ---------------- 两条总线 ----------------
    for y, col, name, sig in ((0.830, C_CPU_E, "取指总线 irom_*  →  IROM 端口A",
                               "irom_en / irom_addr / irom_data（只读，1 拍延迟）"),
                              (0.640, C_MEM_E, "数据总线 perip_*  →  三路译码",
                               "perip_wen / ren / addr / mask / wdata / rdata")):
        ax.plot([0.245, 0.588], [y, y], color=col, lw=2.6, solid_capstyle="butt", zorder=2)
        ax.annotate("", xy=(0.586, y), xytext=(0.55, y),
                    arrowprops=dict(arrowstyle="-|>", color=col, lw=1.6))
        ax.text(0.412, y + 0.012, name, fontsize=8.0, color=col, fontweight="bold",
                ha="center", va="bottom")
        ax.text(0.412, y - 0.014, sig, fontsize=6.4, color=col, ha="center", va="top")

    # ---------------- 地址空间 ----------------
    ax.text(0.020, 0.500, "取指侧地址空间（只有 IROM 一块）", fontsize=8.4, color=C_CPU_E,
            fontweight="bold", va="top")
    ax.text(0.520, 0.500, "数据侧地址空间（同一根总线，三路译码）", fontsize=8.4, color=C_MEM_E,
            fontweight="bold", va="top")

    def band(x, y, w, h, txt, sub, fc, ec, tc=C_TXT):
        ax.add_patch(Rectangle((x, y), w, h, facecolor=fc, edgecolor=ec, lw=1.0, zorder=3))
        ax.text(x + 0.008, y + h * 0.68, txt, fontsize=7.0, color=tc, va="center", zorder=4)
        if sub:
            ax.text(x + 0.008, y + h * 0.26, sub, fontsize=6.1, color=C_GREY, va="center", zorder=4)

    band(0.020, 0.360, 0.440, 0.095, "IROM　0x0000_0000 – 0x0000_FFFF（64 KB）",
         "取指唯一可达区：PC 只能落在这里", C_MEM, C_MEM_E)
    band(0.020, 0.265, 0.440, 0.070, "其余地址：取指口不会去",
         "PC 越界 → 读到 0 → 非法指令", "#f1f3f4", "#bdc1c6", C_GREY)

    band(0.520, 0.400, 0.460, 0.062, "MMIO　0x1000_0000 – 0x1000_00FF",
         "不可缓存（≥ 0x1000_0000）：读直通外设、写直达", C_MMIO, C_MMIO_E, "#8a4b00")
    band(0.520, 0.325, 0.460, 0.062, "IROM 数据窗口　0x0002_0000 – 0x0002_FFFF（64 KB）",
         "读走端口B；写 = 直接改代码区", C_MEM, C_MEM_E)
    band(0.520, 0.250, 0.460, 0.062, "DRAM　0x0000_0000 – 0x0001_FFFF（128 KB）",
         "可缓存（< 0x1000_0000）；软件只用 0x1_0000 以上", C_MEM, C_MEM_E)
    band(0.520, 0.185, 0.460, 0.048, "0x0000_0000 – 0x0000_FFFF：与取指侧同址，故意不用",
         "", "#f1f3f4", "#bdc1c6", C_GREY)

    ax.text(0.020, 0.175, "★ 四段不是按比例画的：0x0 ~ 0x2_FFFF 一共 192 KB，而 MMIO 在 0x1000_0000（再往上 256 MB）。",
            fontsize=6.6, color="#b3261e", va="top")
    ax.text(0.020, 0.120, "★ 同一根数据总线上的判定顺序（board_top.sv:441、546）：先 mmio_sel，再 irom_win_sel，其余落 DRAM。",
            fontsize=6.6, color=C_GREY, va="top")
    ax.text(0.020, 0.077, "★ 写使能必须各自门控（board_top.sv:583 挡 MMIO 与窗口、:387 给端口B）；读则不门控，只有 rdata 的 3 选 1。",
            fontsize=6.6, color=C_GREY, va="top")
    ax.text(0.020, 0.034, "★ DCache 用 0x0FFF_FFFF 当“可缓存 / 不可缓存”的分界（DCache.sv:47），所以 MMIO 天然绕过缓存。",
            fontsize=6.6, color=C_GREY, va="top")

    png = os.path.join(OUT, "M1_存储器位置与地址空间.png")
    fig.savefig(png, dpi=240, facecolor="white")
    plt.close(fig)
    print("wrote", png)


def fig_decode():
    """图 M9：一次数据访问在 board_top 里怎么被分成三路。"""
    fig = plt.figure(figsize=(9.6, 4.6), dpi=240)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    ax.text(0.02, 0.965, "图 M9　一根数据总线、三路译码：perip_addr 的高位决定这拍访问谁",
            fontsize=10.6, fontweight="bold", color="#111", va="top")
    ax.text(0.02, 0.912, "读数据是 3 选 1 的 mux，写使能是各窗口“与”出来的 —— 一次 store 只会落到一个地方",
            fontsize=7.4, color=C_GREY, va="top")

    box(ax, 0.020, 0.300, 0.150, 0.500, "LSU / DCache",
        ["perip_addr", "perip_wen", "perip_ren", "perip_mask", "perip_wdata"],
        fc=C_CPU, ec=C_CPU_E, fs_t=8.6, fs_l=6.8)

    box(ax, 0.225, 0.690, 0.190, 0.130, "addr[31:16]==0x1000", ["且 addr[15]==0 → mmio_sel"],
        fc=C_MMIO, ec=C_MMIO_E, fs_t=7.8, fs_l=6.8)
    box(ax, 0.225, 0.520, 0.190, 0.130, "addr[31:16]==0x0002", ["→ irom_win_sel"],
        fc=C_MEM, ec=C_MEM_E, fs_t=7.8, fs_l=6.8)
    box(ax, 0.225, 0.350, 0.190, 0.130, "其余", ["→ 默认落 DRAM"],
        fc="#f1f3f4", ec="#9aa0a6", fs_t=7.8, fs_l=6.8)

    box(ax, 0.500, 0.690, 0.215, 0.130, "MMIO 寄存器组",
        ["TXDATA→UART 发送器", "RXDATA/RXSTAT←RX FIFO"],
        fc=C_MMIO, ec=C_MMIO_E, fs_t=8.2, fs_l=6.4)
    box(ax, 0.500, 0.520, 0.215, 0.130, "IROM 端口B",
        ["读 b_rdata；写 b_wen", "b_wen = perip_wen & win_sel"],
        fc=C_MEM, ec=C_MEM_E, fs_t=8.2, fs_l=6.4)
    box(ax, 0.500, 0.350, 0.215, 0.130, "DRAM",
        ["wen = perip_wen", "& ~mmio & ~win_sel"],
        fc=C_MEM, ec=C_MEM_E, fs_t=8.2, fs_l=6.4)

    for y in (0.755, 0.585, 0.415):
        arrow(ax, (0.172, 0.470), (0.222, y), color="#9aa0a6", lw=0.9, rad=0.08)
        arrow(ax, (0.417, y), (0.497, y), color="#5f6368", lw=1.0)

    box(ax, 0.790, 0.350, 0.190, 0.470, "读数据 3 选 1",
        ["mmio_sel ?", "  寄存器值", ": win_sel ?", "  b_rdata", ": dram_rdata",
         "", "→ perip_rdata"], fc="#f6f8fa", ec="#5f6368", fs_t=8.2, fs_l=6.4)
    for y in (0.755, 0.585, 0.415):
        arrow(ax, (0.717, y), (0.787, 0.560), color="#9aa0a6", lw=0.9, rad=0.10)

    ax.text(0.020, 0.235, "★ 不变量：MMIO 写必须挡住 DRAM 的写使能 —— 否则一次 `sw 0x10000000` 会同时改掉 DRAM 第 0 个字；",
            fontsize=6.8, color="#b3261e", va="top")
    ax.text(0.020, 0.185, "   IROM 窗口写同样必须挡住 DRAM（board_top.sv:583）。",
            fontsize=6.8, color=C_GREY, va="top")
    ax.text(0.020, 0.135, "★ 读口没有门控：三块存储器都看到 ren，只是数据被 mux 选一路 —— 这是省 LUT 的做法，代价是白读一次（功耗）。",
            fontsize=6.8, color=C_GREY, va="top")

    png = os.path.join(OUT, "M9_三路译码.png")
    fig.savefig(png, dpi=240, facecolor="white")
    plt.close(fig)
    print("wrote", png)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    fig_position()
    fig_decode()
