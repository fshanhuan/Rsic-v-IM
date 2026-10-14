#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render_mix_figs.py — 把 teach_mix（一条主线串起几种机制）渲染成讲解图。

主线：addi → load → addi(load-use) → mul → branch(taken)

本脚本与 sim/render_window.py 的区别：
  * 行表**自己定义**，按【模块边界】组织，名字直接写清"哪一级的哪个端口"：
        IFU_pc / IFU_inst / IFU_valid / IFU_advance_en
        IDU_ready（IFU 看到的握手输入）
        IDU_pc / IDU_ID1_valid / IDU_ID2_valid
        EXU_ready（IDU 看到的握手输入）
        EXU_pc / EXU_result / EXU_valid / EXU_inst_clr
        LSU_ready / LSU_M1_valid / LSU_M2_valid / LSU_M3_valid
        WBU_ready / WBU_valid / WBU_pc / WBU_rd / WBU_rd_value
        CTRL IFU_stall（总）/ 4 个来源 / dnpc_flag / dnpc / mispredict
  * 每一对 **valid↔ready 握手** 都排在一起，方便现场讲"模块之间怎么交收"。
  * 每个窗格可以单独指定起始拍与宽度。

用法：
    python3 teach/render_mix_figs.py [输出目录]
默认输出目录 figures/讲解/ ；同时用 cairosvg 额外导出 PNG。
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
sys.path.insert(0, os.path.join(_ROOT, "sim"))
import vcd2svg as V   # noqa: E402

VCD = os.path.join(_HERE, "wave", "teach_mix.vcd")

# =============================================================================
# 行表：按【模块边界】组织
#
# 命名约定：
#   <模块>_<信号>      —— 该模块的输出 / 内部寄存器
#   <下游模块>_ready   —— 上游看到的握手输入（下游回给上游的 ready）
#   CTRL ...          —— Control 汇总出来的暂停 / 重定向
# =============================================================================
ROWS = [
    ("clk",                        "clk",              "bit"),

    # ─────────── IFU（取指单元）───────────
    ("IFU_pc[31:0]",               "IFU_pc",           "bus"),
    ("IFU_inst[31:0]",             "IFU_inst",         "inst"),
    ("IFU_valid",                  "IFU_valid",        "bit"),
    ("IFU_advance_en →IDU",        "IFU_advance_en",     "bit"),
    ("  IDU_ready (IDU→IFU)",      "IDU_ready",        "bit"),

    # ─────────── IDU（译码单元）───────────
    ("IDU_pc[31:0]",               "IDU_pc",           "bus"),
    ("IDU_ID1_valid",              "IDU_ID1_valid",      "bit"),
    ("IDU_ID2_valid →EXU",         "IDU_ID2_valid",    "bit"),
    ("  EXU_ready (EXU→IDU)",      "EXU_ready",        "bit"),

    # ─────────── EXU（执行单元）───────────
    ("EXU_pc[31:0]",               "EXU_pc",          "bus"),
    ("EXU_result[31:0]",           "EXU_result",         "bus"),
    ("EXU_valid →LSU",             "EXU_valid",        "bit"),
    ("EXU_inst_clr",               "EXU_inst_clr",         "bit"),
    ("  LSU_ready (LSU→EXU)",      "LSU_ready",        "bit"),

    # ─────────── LSU（访存单元，内部三级）───────────
    ("LSU_M1_valid",               "LSU_M1_valid",     "bit"),
    ("LSU_M2_valid",               "LSU_M2_valid",     "bit"),
    ("LSU_M3_valid →WBU",          "LSU_M3_valid",     "bit"),
    ("  WBU_ready (WBU→LSU)",      "WBU_ready",        "bit"),

    # ─────────── WBU（写回单元）───────────
    ("WBU_valid",                  "WBU_valid",        "bit"),
    ("WBU_pc[31:0]",               "WBU_pc",           "bus"),
    ("WBU_rd[4:0]",                "WBU_rd",           "bus"),
    ("WBU_rd_value[31:0]",         "WBU_rd_value",     "bus"),

    # ─────────── Control：暂停与重定向 ───────────
    ("CTRL IFU_stall (总)",        "CTRL_IFU_stall",          "bit"),
    ("CTRL ├ load_use_stall",      "CTRL_load_use_stall",   "bit"),
    ("CTRL ├ mdu_busy",            "CTRL_mdu_busy",     "bit"),
    ("CTRL ├ icache_hold",         "CTRL_icache_hold",      "bit"),
    ("CTRL └ dcache_hold",         "CTRL_dcache_hold",      "bit"),
    ("CTRL dnpc_flag",             "CTRL_dnpc_flag",      "bit"),
    ("CTRL dnpc[31:0]",            "CTRL_dnpc",           "bus"),
    ("CTRL mispredict",            "CTRL_mispredict",     "bit"),
]

# (文件名, 标题, 起始拍, 拍数)
FIGS = [
    ("09_主线总览_addi-load-addi-mul-branch",
     "无冲突主线（共 7 条）：addi → load → addi（不读 load）→ mul → branch(taken) → 错路径 addi → ecall",
     12, 41),

    ("09a_载入与无冲突流水",
     "① addi ② load ③ addi —— ③ 不读 ② 的结果，**没有 load-use 气泡**（只剩 Cache 同步握手）",
     18, 16),

    ("09b_mul与分支重定向",
     "④ mul（EX 占 3 拍）⑤ branch taken：cyc37 算出跳转 → 冲刷错路径 → 跳到 0x18 执行 ecall",
     28, 20),
]


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_ROOT, "figures", "讲解")
    os.makedirs(outdir, exist_ok=True)

    specs = [s for _, s, _ in ROWS]
    idw, sel, samples, _ = V.sample(VCD, specs)
    missing = [s for _, s, _ in ROWS if s not in sel and s != "clk"]
    if missing:
        print("!! 波形里找不到这些信号（会被跳过）:", missing)

    for name, title, start, ncyc in FIGS:
        sub = ("Verilator 仿真 · 每拍采样一次 · 行名 = 模块_信号，缩进行是下游回给上游的 ready · "
               "横轴 0 = 实际第 %d 拍 · 波形源 teach/wave/teach_mix.vcd" % start)
        svg = V.render(ROWS, idw, sel, samples[start:start + ncyc], title, subtitle=sub)
        p_svg = os.path.join(outdir, name + ".svg")
        with open(p_svg, "w", encoding="utf-8") as f:
            f.write(svg)
        print("wrote %s  窗口[%d,%d)  %d 行" % (p_svg, start, start + ncyc, len(ROWS)))
        try:
            import cairosvg
            p_png = os.path.join(outdir, name + ".png")
            cairosvg.svg2png(url=p_svg, write_to=p_png, scale=2.6)
            print("      -> %s" % p_png)
        except Exception as e:
            print("      (PNG 跳过: %s)" % e)


if __name__ == "__main__":
    main()
