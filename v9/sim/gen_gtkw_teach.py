#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_gtkw_teach.py — 为「上台讲解」的每个波形生成 GTKWave 会话文件（.gtkw）。

放在 wave/ 下、与 .vcd 同目录，[dumpfile] 用**裸文件名**；这样只要在 wave/
目录里启动 gtkwave 就能打开（见 sim/gtkwave_teach.sh）。

格式要点（GTKWave 3.3.116 实测）：
  - `@23` = 后面的信号按**十六进制**显示（总线）；
  - `@28` = 后面的信号按位显示（单比特）；
  - `-组名` = 分组标题行；
  - 组名用 ASCII，避免 Tcl/savefile 的编码问题。

只新增文件，不改任何 RTL。
"""
import os

# (信号名, 是否总线)
GROUPS = [
    ("CLK", [
        ("tb_iverilog.clk", False),
    ]),
    ("IF", [
        ("tb_iverilog.p_if_pc[31:0]", True),
        ("tb_iverilog.p_if_inst[31:0]", True),
        ("tb_iverilog.p_stall", False),
        ("tb_iverilog.u_cpu.IFU_Inst0.advance_en", False),
    ]),
    ("ID", [
        ("tb_iverilog.p_id_pc[31:0]", True),
        ("tb_iverilog.u_cpu.IDU_Inst0.valid", False),   # ID1 valid
        ("tb_iverilog.p_id_valid", False),              # ID2 valid
    ]),
    ("EX", [
        ("tb_iverilog.p_ex_pc[31:0]", True),
        ("tb_iverilog.p_ex_res[31:0]", True),
        ("tb_iverilog.p_ex_rd[4:0]", True),
        ("tb_iverilog.p_ex_valid", False),
        ("tb_iverilog.u_cpu.EXU_inst_clear", False),
    ]),
    ("MEM", [
        ("tb_iverilog.p_mem_valid", False),              # LSU 第一级 M1
        ("tb_iverilog.u_cpu.LSU_valid_pipe", False),     # LSU 第二级 M2
        ("tb_iverilog.u_cpu.LSU_valid_wb", False),       # LSU 第三级 M3
        ("tb_iverilog.p_mem_wen", False),
        ("tb_iverilog.p_mem_addr[31:0]", True),
    ]),
    ("WB", [
        ("tb_iverilog.p_wb_valid", False),
        ("tb_iverilog.p_wb_pc[31:0]", True),
        ("tb_iverilog.p_wb_rd[4:0]", True),
        ("tb_iverilog.p_wb_val[31:0]", True),
    ]),
    ("CTRL", [
        ("tb_iverilog.p_dnpc_flag", False),
        ("tb_iverilog.p_dnpc[31:0]", True),
        ("tb_iverilog.p_pred_taken", False),
        ("tb_iverilog.p_mispredict", False),
        ("tb_iverilog.p_ecall", False),
    ]),
    ("REGS", [
        ("tb_iverilog.p_r%d[31:0]" % i, True) for i in range(1, 11)
    ]),
    ("CSR", [
        ("tb_iverilog.p_mepc[31:0]", True),
        ("tb_iverilog.p_mcause[31:0]", True),
        ("tb_iverilog.p_mstatus[31:0]", True),
        ("tb_iverilog.p_mtvec[31:0]", True),
    ]),
]


def write_gtkw(path, vcd_name, title):
    out = []
    out.append("[*]")
    out.append("[*] GTKWave Analyzer v3.3.116 (w)1999-2023 BSI")
    out.append("[*] %s" % title)
    out.append("[*]")
    out.append('[dumpfile] "%s"' % vcd_name)
    out.append("[timestart] 0")
    out.append("[size] 1600 950")
    out.append("[pos] -1 -1")
    out.append("[sst_width] 240")
    out.append("[signals_width] 240")
    out.append("[sst_expanded] 1")
    out.append("[sst_vpaned_height] 280")
    for gname, sigs in GROUPS:
        out.append("-%s" % gname)
        for sig, is_bus in sigs:
            out.append("@23" if is_bus else "@28")
            out.append(sig)
    out.append("[pattern_trace] 1")
    out.append("[pattern_trace] 0")
    out.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print("wrote %s" % path)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    wave = os.path.join(here, "..", "wave")
    progs = {
        "teach_alu":          "01 流水线基础 + 数据前递",
        "teach_loaduse":      "02 load-use 冒险",
        "teach_branch":       "03 分支/跳转 重定向",
        "teach_mul":          "04 mul 单拍",
        "teach_div":          "05 div 多拍冻结",
        "teach_mem":          "06 访存 sw/lw",
        "teach_loop_alu":     "07 循环 重复执行",
        "teach_loop_loaduse": "07b 循环 + load-use",
        "teach_loop_mul":     "07c 循环 mul",
        "teach_loop_div":     "07d 循环 div",
        "tb_iverilog_prog":   "08 完整综合演示 prog",
    }
    for name, title in progs.items():
        vcd = "%s.vcd" % name
        if not os.path.exists(os.path.join(wave, vcd)):
            print("skip (no vcd): %s" % vcd)
            continue
        write_gtkw(os.path.join(wave, "%s.gtkw" % name), vcd, title)


if __name__ == "__main__":
    main()
