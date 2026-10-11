#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render_window.py — 在 vcd2svg.py 的基础上增加「起始拍」参数，便于把波形裁到
讲解关心的窗口（不改动 vcd2svg.py 本身，也不改动任何 RTL）。

用法：
    python3 sim/render_window.py <in.vcd> <out.svg> "<标题>" [起始拍] [拍数]

例：
    python3 sim/render_window.py wave/teach_loop_alu.vcd \
        figures/讲解/01_流水线_ALU.svg "稳态 1 IPC：循环做加法" 40 24
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vcd2svg as V


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    vcd, outsvg = sys.argv[1], sys.argv[2]
    title = sys.argv[3]
    start = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    ncyc = int(sys.argv[5]) if len(sys.argv) > 5 else 24

    specs = [s for _, s, _ in V.PIPE_ROWS]
    idw, sel, samples, _ = V.sample(vcd, specs)
    sub = ("Verilator 仿真 · 每拍采样一次 · 上方为十六进制/已译码指令 · "
           "横轴 0 = 实际第 %d 拍" % start)
    svg = V.render(V.PIPE_ROWS, idw, sel, samples[start:start + ncyc], title, subtitle=sub)
    with open(outsvg, "w", encoding="utf-8") as f:
        f.write(svg)
    print("wrote %s  窗口[%d, %d)  共 %d 拍" %
          (outsvg, start, start + ncyc, len(samples)))


if __name__ == "__main__":
    main()
