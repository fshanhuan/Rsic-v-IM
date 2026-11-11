#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mem_wave.py — 把 sim/build/mem_trace.csv 画成课堂上的存储器时序图（PNG）。

为什么用 CSV 而不是 VCD：CSV 就是测试台每拍采样出来的那几十根线，一列一个信号，
不用再写 VCD 解析；VCD 仍然保留给 GTKWave 现场拖（sim/build/mem_wave_long.vcd）。

用法：
    python sim/mem_wave.py                 # 出全部图 → figures/存储器/
    python sim/mem_wave.py M3              # 只出某一张

★ 改这个文件请用支持 UTF-8 的编辑器/工具，别走 PowerShell 的 Get-Content/Set-Content
  管道 —— 那会按 GBK 解码再写回，中文全变乱码（本项目踩过一次）。
"""
import os
import sys
import textwrap

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
CSV = os.path.join(HERE, "build", "mem_trace.csv")
OUT = os.path.join(ROOT, "figures", "存储器")

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans Mono"]
plt.rcParams["axes.unicode_minus"] = False

C_BIT = "#1f4e9c"
C_BUS = "#1b6b3a"
C_HI = "#b3261e"
C_GRID = "#e3e6ea"
C_LABEL = "#202124"

HEXCOLS = {"FM_addr", "FM_rdata", "CPU_pc", "DM_addr", "DM_wdata", "DM_rdata",
           "IROM_B_rdata", "DRAM_addr", "DRAM_wdata", "DRAM_rdata"}


# ============================== 数据 ==============================
def load():
    import csv as _csv
    rows = list(_csv.DictReader(open(CSV, encoding="utf-8")))
    out = []
    for r in rows:
        d = {}
        for k, v in r.items():
            if k == "cycle":
                d[k] = int(v)
            elif k in HEXCOLS:
                try:
                    d[k] = int(v, 16)
                except ValueError:
                    d[k] = 0
            else:
                d[k] = 0 if v in ("x", "z") else int(v)
        out.append(d)
    db = {r["cycle"]: r for r in out}
    for r in db.values():
        r["DEC_sel_dram"] = 0 if (r["DEC_mmio"] or r["DEC_win"]) else 1
        r["DM_any"] = 1 if (r["DM_ren"] or r["DM_wen"]) else 0
    return db


def window(db, start, ncyc):
    last = db[max(db)]
    return [db.get(c, last) for c in range(start, start + ncyc)]


# ============================== 绘制 ==============================
def fmt_hex(v):
    s = "%x" % v
    return s if len(s) <= 8 else s[-8:]


def render(db, rows, start, ncyc, title, subtitle, notes, png,
           per_cycle=0.34, row_h=0.34, text_pt=6.6):
    data = window(db, start, ncyc)
    n = len(rows)
    notes = notes or []
    nlane = 2 if len(notes) > 1 else len(notes)
    figw = 2.55 + per_cycle * ncyc

    # 标题按宽度折行（中文按 1 em 估）
    tchars = max(18, int((figw - 0.16) * 72 / 10.5))
    tlines = textwrap.wrap(title, tchars) or [title]
    sline_h = 0.19 if subtitle else 0.0

    figh = 0.30 + 0.24 * len(tlines) + sline_h + 0.20 * nlane + 0.16 + row_h * n + 0.42
    fig = plt.figure(figsize=(figw, figh), dpi=240)
    ax = fig.add_axes([0.0, 0.0, 1.0, 1.0])
    ax.set_xlim(-0.02, 1.02)
    ax.set_ylim(0, 1)
    ax.axis("off")

    LW = 1.58 / figw                     # 左侧标签区
    XR = 1 - 0.012                       # 波形区右界
    header = 0.14 + 0.24 * len(tlines) + sline_h + 0.20 * nlane + 0.10
    TOP = 1 - header / figh
    BOT = 0.42 / figh
    step = (TOP - BOT) / n

    def X(c):
        return LW + (XR - LW) * c / ncyc

    for i, ln in enumerate(tlines):
        ax.text(0.006, 1 - (0.16 + 0.24 * i) / figh, ln, fontsize=10.5, fontweight="bold",
                color="#111", va="top")
    if subtitle:
        ax.text(0.006, 1 - (0.16 + 0.24 * len(tlines)) / figh, subtitle,
                fontsize=7.4, color="#5f6368", va="top")

    for c in range(ncyc + 1):
        ax.plot([X(c), X(c)], [BOT, TOP], color=C_GRID, lw=0.6, zorder=0)

    for i, spec in enumerate(rows):
        label, key, kind = spec[0], spec[1], spec[2]
        gate = spec[3] if len(spec) > 3 else None
        yt = TOP - i * step
        yb = yt - step
        yc = (yt + yb) / 2
        ax.add_patch(Rectangle((0.004, yb + step * 0.06), XR - 0.006, step * 0.88,
                               facecolor="#f6f8fa" if i % 2 == 0 else "#ffffff",
                               edgecolor="none", zorder=0))
        ax.text(0.010, yc, label, fontsize=7.2, color=C_LABEL, va="center", ha="left")

        vals = [d[key] for d in data]
        gok = [True] * ncyc if gate is None else [bool(d[gate]) for d in data]
        col = C_HI if kind == "bit_hi" else (C_BUS if kind != "bit" else C_BIT)
        if kind.startswith("bit"):
            hi = yc + step * 0.30
            lo = yc - step * 0.30
            lvl = lambda v: hi if v else lo          # noqa: E731
            xs, ys = [X(0)], [lvl(vals[0])]
            for c in range(ncyc):
                xs.append(X(c + 1))
                ys.append(lvl(vals[c]))
                if c + 1 < ncyc and vals[c + 1] != vals[c]:
                    xs.append(X(c + 1))
                    ys.append(lvl(vals[c + 1]))
            for c, v in enumerate(vals):
                if v:
                    ax.add_patch(Rectangle((X(c), lo), X(c + 1) - X(c), hi - lo,
                                           facecolor=col, alpha=0.10, edgecolor="none", zorder=2))
            ax.plot(xs, ys, color=col, lw=1.25, solid_joinstyle="miter", zorder=3)
            continue

        c, lane = 0, 0
        while c < ncyc:
            c2 = c
            while (c2 + 1 < ncyc and vals[c2 + 1] == vals[c]
                   and gok[c2 + 1] == gok[c]):
                c2 += 1
            live = gok[c]
            x1, x2 = X(c), X(c2 + 1)
            one = (c2 == c)
            if not live:
                ax.text((x1 + x2) / 2, yc, "·", fontsize=text_pt, color="#c4c8cc",
                        ha="center", va="center", zorder=4)
            else:
                if one:
                    ax.plot([x1, x1], [yc - step * 0.19, yc + step * 0.19],
                            color=col, lw=0.55, alpha=0.45, zorder=3)
                else:
                    ax.add_patch(Rectangle((x1 + 0.0012, yc - step * 0.24), (x2 - x1) - 0.0024,
                                           step * 0.48, facecolor="white", edgecolor=col,
                                           lw=0.9, zorder=3))
                txt = fmt_hex(vals[c]) if kind == "hex" else str(vals[c])
                px = (x2 - x1) * figw * 240
                cand = [text_pt] if not one else [5.8, 5.2, 4.6]
                for fs in cand:
                    if px > len(txt) * fs * 240 / 72 * 0.602 + 8:
                        ax.text((x1 + x2) / 2, yc, txt, fontsize=fs, color=col,
                                ha="center", va="center", zorder=4, family="monospace")
                        break
                else:
                    yy = yc + (step * 0.20 if lane % 2 == 0 else -step * 0.20)
                    ax.text((x1 + x2) / 2, yy, txt, fontsize=4.8, color=col,
                            ha="center", va="center", zorder=4, family="monospace",
                            bbox=dict(boxstyle="round,pad=0.10", fc="white", ec="none", alpha=0.85))
                    lane += 1
            c = c2 + 1

    # 拍号
    ax.text(0.010, BOT - 0.16 / figh, "拍号", fontsize=6.6, color="#5f6368",
            ha="left", va="center")
    tick = 1 if ncyc <= 26 else 2
    for c in range(0, ncyc + 1, tick):
        x = X(c)
        ax.plot([x, x], [BOT, BOT - 0.05 / figh], color="#9aa0a6", lw=0.7)
        ax.text(x, BOT - 0.16 / figh, str(start + c), fontsize=6.4, color="#5f6368",
                ha="center", va="center")

    # 关键拍注解：竖虚线 + 顶部错层文字（相邻两拍的两条注解不会压字）
    for k, (cyc, txt) in enumerate(notes):
        if not (start <= cyc < start + ncyc):
            continue
        x = X(cyc - start + 0.5)
        ax.plot([x, x], [BOT, TOP], color="#b3261e", lw=0.9, ls=(0, (4, 3)),
                alpha=0.75, zorder=5)
        lane = k % max(nlane, 1)
        ytxt = TOP + (0.05 + 0.19 * (nlane - 1 - lane)) / figh
        ax.text(x, ytxt, txt, fontsize=6.6, color="#b3261e", ha="center", va="bottom",
                bbox=dict(boxstyle="round,pad=0.18", fc="#fff5f4", ec="#f0c0bb", lw=0.6))

    fig.savefig(png, dpi=240, facecolor="white")
    plt.close(fig)
    print("wrote %-52s %d 拍 × %d 行" % (os.path.basename(png), ncyc, len(rows)))


# ============================== 图定义 ==============================
R_FETCH = [
    ("CPU 取指 PC", "CPU_pc", "hex"),
    ("IROM 端口A ren（irom_en）", "FM_en", "bit"),
    ("IROM 端口A 地址", "FM_addr", "hex", "FM_en"),
    ("IROM 端口A 读数据", "FM_rdata", "hex"),
    ("取指有效（resp_valid）", "CPU_fetch_vld", "bit"),
]
R_LOAD = [
    ("LSU M2（发请求那级）", "LSU_M2", "bit"),
    ("数据口 ren（perip_ren）", "DM_ren", "bit"),
    ("数据口 地址", "DM_addr", "hex", "DM_any"),
    ("数据口 读数据", "DM_rdata", "hex"),
    ("LSU 冻结（dcache_hold）", "DC_hold", "bit"),
    ("DCache 未命中", "DC_miss", "bit"),
    ("DCache 命中", "DC_hit", "bit"),
    ("前端暂停（IFU_stall）", "CPU_stall", "bit"),
]
R_STORE = [
    ("数据口 wen（perip_wen）", "DM_wen", "bit"),
    ("数据口 字节掩码", "DM_mask", "int", "DM_any"),
    ("数据口 写数据", "DM_wdata", "hex", "DM_wen"),
    ("数据口 地址", "DM_addr", "hex", "DM_any"),
    ("译码：落 DRAM", "DEC_sel_dram", "bit"),
    ("DRAM 端口 wen", "DRAM_wen", "bit"),
    ("DRAM 端口 地址", "DRAM_addr", "hex", "DRAM_wen"),
    ("DRAM 端口 写数据", "DRAM_wdata", "hex", "DRAM_wen"),
]
R_WIN = [
    ("译码：落 IROM 窗口(0x2_xxxx)", "DEC_win", "bit"),
    ("IROM 端口B ren", "IROM_B_ren", "bit"),
    ("IROM 端口B wen", "IROM_B_wen", "bit"),
    ("IROM 端口B 读数据", "IROM_B_rdata", "hex"),
    ("DRAM 端口 wen（必须为 0）", "DRAM_wen", "bit"),
    ("数据口 地址", "DM_addr", "hex", "DM_any"),
    ("同时：端口A 取指地址", "FM_addr", "hex"),
    ("同时：端口A 取指数据", "FM_rdata", "hex"),
]
R_MMIO = [
    ("译码：落 MMIO", "DEC_mmio", "bit"),
    ("数据口 wen", "DM_wen", "bit"),
    ("数据口 地址", "DM_addr", "hex", "DM_any"),
    ("数据口 写数据", "DM_wdata", "hex", "DM_wen"),
    ("UART 忙（uart_busy）", "UART_busy", "bit"),
    ("UART TX 引脚（uart_tx）", "UART_tx", "bit"),
]
R_SELF = [
    ("CPU 取指 PC", "CPU_pc", "hex"),
    ("IROM 端口A 取指地址", "FM_addr", "hex"),
    ("IROM 端口A 取指数据", "FM_rdata", "hex"),
    ("IROM 端口B wen（写代码区）", "IROM_B_wen", "bit"),
    ("IROM 端口B 写数据", "DM_wdata", "hex", "IROM_B_wen"),
    ("数据口 地址", "DM_addr", "hex", "DM_any"),
    ("DCache 未命中", "DC_miss", "bit"),
]

FIGS = [
    ("M2_取指口_1拍延迟", R_FETCH, 10, 14,
     "图 M2　取指口（IROM 端口A）：给地址的那一拍不算数，下一拍数据才有效",
     "iverilog 仿真 board_top（真 RTL）· 50 MHz（20 ns/拍）· 每格 1 拍 · 源 sim/build/mem_trace.csv",
     [(12, "T：ren=1 + 地址 0x00"), (13, "T+1：数据 0x102b7（lui t0,0x10）")]),
    ("M3_数据口_load_未命中与命中", R_LOAD, 20, 14,
     "图 M3　一次 load：未命中 → 发读 → 等 1 拍 → 回填；紧接着第二次 load 命中，总线上没有第二次读",
     "hold 宽度实测 2 拍 · miss/hit 是 DCache 当拍判定 · 地址 0x1_0000 在 DRAM",
     [(26, "发读 ren"), (27, "数据回来"), (28, "第二次 load 命中")]),
    ("M4_数据口_store_单拍写", R_STORE, 21, 9,
     "图 M4　一次 store（sw）：总线写使能只有 1 拍，地址/数据/掩码同拍有效",
     "掩码 = funct3[1:0]（LSU.sv:249）：2'b00 字节 / 2'b01 半字 / 2'b10 整字，sw 实测 = 2",
     [(25, "store 到 0x1_0000")]),
    ("M5_IROM数据窗口", R_WIN, 29, 12,
     "图 M5　IROM 数据窗口 0x2_0000：同一条数据总线，端口B 读 IROM；写时 DRAM 的 wen 必须为 0",
     "端口A 仍在正常取指（下面两行）—— 一块 BRAM 两个口，一个取指一个访存",
     [(30, "窗口读 IROM[0]"), (35, "窗口写 IROM[0x100]")]),
    ("M6_MMIO写与UART起始位", R_MMIO, 40, 9,
     "图 M6　MMIO 写 0x1000_0000（TXDATA）：1 拍写脉冲之后，UART 引脚被拉低 = 起始位",
     "MMIO 不可缓存（地址 ≥ 0x1000_0000），DCache 不分配行、写直达外设",
     [(43, "写 TXDATA='A'"), (44, "起始位开始")]),
    ("M7_写代码区后跳过去执行", R_SELF, 4405, 15,
     "图 M7　把两条指令写进 IROM（端口B），再 jalr 跳过去 —— 取指口（端口A）取到的就是刚写的字",
     "这就是 shell 的 load/run 通路：数据口写代码区，取指口立刻执行",
     [(4409, "写 0x1000←addi a5,0x7b"), (4411, "写 0x1004←jal x0,0"), (4415, "取到 0x7b00793")]),
]


def uart_frame(db):
    """UART 整帧：按实测边沿画位格（434 拍/位），而不是逐拍采样。"""
    edges, prev = [], db[min(db)]["UART_tx"]
    for c in sorted(db):
        if db[c]["UART_tx"] != prev:
            edges.append((c, db[c]["UART_tx"]))
            prev = db[c]["UART_tx"]
    if len(edges) < 3:
        print("!! UART 边沿不足，跳过 M8")
        return
    bitw = edges[1][0] - edges[0][0]
    val = 0x41
    bits = [(val >> i) & 1 for i in range(8)]

    fig = plt.figure(figsize=(7.6, 3.2), dpi=240)
    ax = fig.add_axes([0.085, 0.22, 0.895, 0.58])
    ax.set_xlim(-0.4, 10.4)
    ax.set_ylim(-0.35, 1.55)
    ax.set_yticks([0, 1])
    ax.set_yticklabels(["0", "1"], fontsize=9)
    ax.set_xticks([i + 0.5 for i in range(10)])
    ax.set_xticklabels(["起始\n0", "D0\n1", "D1\n0", "D2\n0", "D3\n0", "D4\n0",
                        "D5\n0", "D6\n1", "D7\n0", "停止\n1"], fontsize=8.2)
    ax.set_xlabel("每位 %d 拍 = %.2f µs @50 MHz → %.1f kbit/s；整帧 10 位 = %d 拍 = %.1f µs"
                  % (bitw, bitw * 20e-3, 1000.0 / (bitw * 20e-3), bitw * 10, bitw * 10 * 20e-3),
                  fontsize=9.0)
    lv = [1, 0] + bits + [1, 1]                 # 空闲、起始位、D0..D7、停止位、结束空闲
    edges = [-0.4, 0] + list(range(1, 11)) + [10.4]
    xs, ys = [edges[0]], [lv[0]]
    for i in range(len(lv)):
        xs.append(edges[i + 1])
        ys.append(lv[i])
        if i + 1 < len(lv) and lv[i + 1] != lv[i]:
            xs.append(edges[i + 1])
            ys.append(lv[i + 1])
    ax.plot(xs, ys, color=C_HI, lw=1.8)
    for i in range(1, 10):
        ax.axvline(i, color="#c9cdd2", lw=0.6, ls=(0, (3, 3)))
    ax.grid(axis="y", color="#e3e6ea", lw=0.6)
    ax.set_title("图 M8　UART 整帧（发送 'A' = 0x41，低位先发）：位宽由仿真边沿实测",
                 fontsize=10.4, color="#111", pad=8)
    ax.text(0.5, 1.28, "空闲=1", fontsize=7.8, color="#5f6368", ha="center")
    ax.text(9.5, 1.28, "停止位后回到空闲=1", fontsize=7.8, color="#5f6368", ha="center")
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    png = os.path.join(OUT, "M8_UART整帧.png")
    fig.savefig(png, dpi=240, facecolor="white")
    plt.close(fig)
    print("wrote %-52s 位宽 %d 拍，整帧 %d 拍" % (os.path.basename(png), bitw, bitw * 10))


def main():
    os.makedirs(OUT, exist_ok=True)
    db = load()
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    for name, rows, start, ncyc, title, sub, notes in FIGS:
        if only and only not in name:
            continue
        render(db, rows, start, ncyc, title, sub, notes, os.path.join(OUT, name + ".png"))
    if (not only) or ("M8" in only):
        uart_frame(db)


if __name__ == "__main__":
    main()
