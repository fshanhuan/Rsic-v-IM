#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""wd_io.py —— 把 mem_trace_io.csv（tb_mem + dram_mmio.hex）翻成 W3/W4 的 WaveJSON。

两张图对应两份接口文档：
  figures/存储器/wavedrom/DRAM_全部端口.json  ←→  docs/DRAM_接口详解.md
  figures/存储器/wavedrom/MMIO_全部端口.json  ←→  docs/MMIO_接口详解.md

数据来源与 W1/W2 完全同一条通路（真 board_top + iverilog），只是换了演示程序
（sim/gen_dram_mmio_demo.py）：DRAM 侧把 sw/sb/sh 三种宽度写同一个字，
MMIO 侧把 TXSTAT 读、TXDATA 写（拉高 busy）、LED 写各做一次。

用法：
  python sim/gen_dram_mmio_demo.py
  vvp sim/build/tb_mem.vvp +prog=sim/dram_mmio.hex +csv=sim/build/mem_trace_io.csv +stop=240 +nochk
  python sim/wd_io.py          # 生成 JSON（不开浏览器）
  python sim/wd_render.py      # 出 SVG/PNG（两张新图已在 JOBS 里）
"""
import csv
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wd_mem as W  # noqa: E402  复用 bus_lane / bit_lane / doc

ROOT = os.path.dirname(HERE)
CSV = os.path.join(ROOT, "sim", "build", "mem_trace_io.csv")
OUT = os.path.join(ROOT, "figures", "存储器", "wavedrom")

# 拍窗（含端点），数字是 CSV 的 cycle 列：
#   DRAM 22..34：22 拍地址是 ALU 垃圾 → 23/25/28 三种宽度写 → 29 发读 → 30 回值
#                 0x5555_AA78 → 31 命中（总线零动作）→ 34 MMIO 读时 dram_inst.ren 也拉高
#   MMIO 33..47：34 读 TXSTAT(0) → 38 写 TXDATA → 39 busy=1 且 uart_tx 出起始位
#                 → 39 再读 TXSTAT(1) → 45 写 LED → 46 LED=0x2A
W_DRAM = (22, 34)
W_MMIO = (33, 47)


def load(path):
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
    return rows, {int(r["cycle"]): r for r in rows}


def idx_lane(name, win, by):
    """mmio_idx = addr[4:2]（board_top.sv:442 就是这个式子），CSV 里没单独录。"""
    vals = []
    for c in range(win[0], win[1] + 1):
        a = by[c]["DM_addr"].strip()
        vals.append(None if any(ch in "xz" for ch in a) else "0x%x" % ((int(a, 16) >> 2) & 7))
    return W.bus_lane(name, vals)


def led_lane(name, win, by):
    """★ LED 列在 CSV 里是**十进制**（`%0d`），其它总线列都是 %08x —— 别用 bus_hex。"""
    vals = []
    for c in range(win[0], win[1] + 1):
        v = by[c]["LED"].strip()
        vals.append(None if (not v or any(ch in "xz" for ch in v)) else "0x%02x" % int(v, 10))
    return W.bus_lane(name, vals)


def dram_doc(win, by):
    n = win[1] - win[0] + 1
    signal = [
        ["时钟", W.clk_lane(n)],
        ["地址", W.bus_hex("addr[31:0]", win, by, "DRAM_addr")],
        ["读口", W.bit_col("ren", win, by, "DRAM_ren"),
         W.bus_hex("rdata[31:0]", win, by, "DRAM_rdata")],
        ["写口", W.bit_col("wen", win, by, "DRAM_wen"),
         W.bus_hex("wdata[31:0]", win, by, "DRAM_wdata"),
         W.mask2("mask[1:0]", win, by, "DRAM_mask")],
    ]
    title = "图 W3  DRAM 全部端口（sync_mem / dram_inst）· 第 %d–%d 拍" % win
    foot = ("真实仿真（非手绘），每格 1 拍 = 20 ns。23/25/28 拍三种宽度写同一个字："
            "mask=10 整字、00 字节、01 半字 → 30 拍读回 0x5555_AA78；31 拍命中、总线零动作；"
            "34 拍 MMIO 读时 ren 也拉高（未被译码门控）。reset 接 1'b0。")
    return W.doc(title, foot, signal, win, by)


def mmio_doc(win, by):
    n = win[1] - win[0] + 1
    signal = [
        ["时钟", W.clk_lane(n)],
        ["译码", W.bit_col("mmio_sel", win, by, "DEC_mmio"),
         idx_lane("mmio_idx[2:0]", win, by)],
        ["总线", W.bus_hex("perip_addr[31:0]", win, by, "DM_addr"),
         W.bit_col("perip_ren", win, by, "DM_ren"),
         W.bit_col("perip_wen", win, by, "DM_wen"),
         W.bus_hex("perip_wdata[31:0]", win, by, "DM_wdata"),
         W.mask2("perip_mask[1:0]", win, by, "DM_mask"),
         W.bus_hex("perip_rdata[31:0]", win, by, "DM_rdata")],
        ["外设", W.bit_col("uart_busy", win, by, "UART_busy"),
         W.bit_col("uart_tx", win, by, "UART_tx"),
         led_lane("led[6:0]", win, by)],
    ]
    title = "图 W4  MMIO 全部端口（board_top 内译码 + 寄存器组）· 第 %d–%d 拍" % win
    foot = ("真实仿真（非手绘），每格 1 拍 = 20 ns。mmio_idx = addr[4:2]（0=TXDATA 1=TXSTAT 4=LED）。"
            "34 拍读 TXSTAT 得 0 → 38 拍写 TXDATA=0x41 → 39 拍 busy=1 且 uart_tx 出起始位，"
            "同拍再读 TXSTAT 得 1 → 45 拍写 LED=0x2A。")
    return W.doc(title, foot, signal, win, by)


def check(by):
    ok = True

    def need(c, m):
        nonlocal ok
        print(("  [OK] " if c else "  [!!] ") + m)
        ok = ok and c

    d, m = W_DRAM, W_MMIO

    wen = [c for c in range(d[0], d[1] + 1) if by[c]["DRAM_wen"].strip() == "1"]
    need(wen == [23, 25, 28], "DRAM 三次写在第 %s 拍" % wen)
    need([by[c]["DRAM_mask"].strip() for c in wen] == ["2", "0", "1"], "三次写的 mask 是 2/0/1（字/字节/半字）")
    need([by[c]["DRAM_addr"].strip() for c in wen] == ["00010000", "00010001", "00010002"],
         "三次写落在同一个字的三个字节偏移上")
    need(W.hx(by[30]["DRAM_rdata"]) == "0x5555_aa78", "第 30 拍读回 0x5555_AA78（三次写已合并）")
    need(by[29]["DRAM_ren"].strip() == "1", "第 29 拍发读（单拍）")
    need(by[31]["DC_hit"].strip() == "1", "第 31 拍命中，总线零动作")
    need(by[34]["DRAM_ren"].strip() == "1" and by[34]["DEC_mmio"].strip() == "1",
         "第 34 拍是 MMIO 读，但 dram_inst.ren 也为 1（读使能未被译码门控）")

    need(by[34]["DEC_mmio"].strip() == "1" and by[34]["DM_ren"].strip() == "1",
         "第 34 拍 MMIO 读（TXSTAT）")
    need(W.hx(by[35]["DM_rdata"]) == "0x0000_0000", "TXSTAT 回 0（busy=0）")
    need(by[38]["DM_wen"].strip() == "1" and by[38]["DEC_mmio"].strip() == "1",
         "第 38 拍写 TXDATA")
    need(by[38]["UART_busy"].strip() == "0" and by[39]["UART_busy"].strip() == "1",
         "busy 在 38→39 拉高")
    need(by[39]["UART_tx"].strip() == "0", "第 39 拍 uart_tx=0（起始位）")
    need(W.hx(by[40]["DM_rdata"]) == "0x0000_0001", "第 40 拍 TXSTAT 回 1（busy）")
    need(by[45]["DM_wen"].strip() == "1", "第 45 拍写 LED")
    need(int(by[46]["LED"].strip() or 0, 10) == 0x2A, "第 46 拍 LED 变 0x2A（CSV 里是十进制 42）")
    return ok


def main():
    rows, by = load(CSV)
    print("读入 %s：%d 拍、%d 列" % (os.path.relpath(CSV, ROOT), len(rows), len(rows[0])))
    ok = check(by)

    os.makedirs(OUT, exist_ok=True)
    docs = {"DRAM_全部端口": dram_doc(W_DRAM, by),
            "MMIO_全部端口": mmio_doc(W_MMIO, by)}
    for name, d in docs.items():
        for ext in (".json", ".wave"):
            with open(os.path.join(OUT, name + ext), "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False, indent=2)
        lanes = sum(len(g) - 1 for g in d["signal"] if isinstance(g, list))
        print("  %-18s %2d 条 lane，%2d 格  → %s"
              % (name, lanes, len(d["signal"][0][1]["wave"]), name + ".json"))
    print("下一步：python sim/wd_render.py")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
