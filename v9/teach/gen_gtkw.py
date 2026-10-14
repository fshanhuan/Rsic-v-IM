#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_gtkw.py — 给 teach/wave/*.vcd（verilator 产出，顶层作用域 TOP）生成 GTKWave 会话。

    python3 teach/gen_gtkw.py

生成的 .gtkw 与 .vcd 同目录，用**裸文件名**，所以：
    cd teach/wave && gtkwave teach_alu.gtkw
"""
import os
import glob

# (分组, [(完整信号路径, 是否总线)]) ；名字与 teach/tb 里的探针命名一致：
#   <模块>_<信号> = 该模块输出；缩进的 <下游>_ready = 握手输入；CTRL_* = 暂停/重定向
GROUPS = [
    ("CLK", [("TOP.tb_iverilog.clk", False)]),
    ("IFU", [
        ("TOP.tb_iverilog.IFU_pc[31:0]", True),
        ("TOP.tb_iverilog.IFU_inst[31:0]", True),
        ("TOP.tb_iverilog.IFU_valid", False),
        ("TOP.tb_iverilog.IFU_advance_en", False),
        ("TOP.tb_iverilog.IDU_ready", False),
    ]),
    ("IDU", [
        ("TOP.tb_iverilog.IDU_pc[31:0]", True),
        ("TOP.tb_iverilog.IDU_ID1_valid", False),
        ("TOP.tb_iverilog.IDU_ID2_valid", False),
        ("TOP.tb_iverilog.EXU_ready", False),
    ]),
    ("EXU", [
        ("TOP.tb_iverilog.EXU_pc[31:0]", True),
        ("TOP.tb_iverilog.EXU_result[31:0]", True),
        ("TOP.tb_iverilog.EXU_rd[4:0]", True),
        ("TOP.tb_iverilog.EXU_valid", False),
        ("TOP.tb_iverilog.EXU_inst_clr", False),
        ("TOP.tb_iverilog.LSU_ready", False),
    ]),
    ("LSU", [
        ("TOP.tb_iverilog.LSU_M1_valid", False),
        ("TOP.tb_iverilog.LSU_M2_valid", False),
        ("TOP.tb_iverilog.LSU_M3_valid", False),
        ("TOP.tb_iverilog.LSU_mem_wen", False),
        ("TOP.tb_iverilog.LSU_mem_addr[31:0]", True),
        ("TOP.tb_iverilog.WBU_ready", False),
    ]),
    ("WBU", [
        ("TOP.tb_iverilog.WBU_valid", False),
        ("TOP.tb_iverilog.WBU_pc[31:0]", True),
        ("TOP.tb_iverilog.WBU_rd[4:0]", True),
        ("TOP.tb_iverilog.WBU_rd_value[31:0]", True),
    ]),
    ("CTRL", [
        ("TOP.tb_iverilog.CTRL_IFU_stall", False),
        ("TOP.tb_iverilog.CTRL_load_use_stall", False),
        ("TOP.tb_iverilog.CTRL_mdu_busy", False),
        ("TOP.tb_iverilog.CTRL_icache_hold", False),
        ("TOP.tb_iverilog.CTRL_dcache_hold", False),
        ("TOP.tb_iverilog.CTRL_dnpc_flag", False),
        ("TOP.tb_iverilog.CTRL_dnpc[31:0]", True),
        ("TOP.tb_iverilog.CTRL_pred_taken", False),
        ("TOP.tb_iverilog.CTRL_mispredict", False),
        ("TOP.tb_iverilog.CTRL_ecall", False),
    ]),
    ("REGS", [("TOP.tb_iverilog.p_r%d[31:0]" % i, True) for i in range(1, 11)]),
]


def write_gtkw(path, vcd_name):
    out = ["[*]", "[*] 讲解版波形会话（verilator VCD，顶层 TOP）", "[*]",
           '[dumpfile] "%s"' % vcd_name,
           "[timestart] 0", "[size] 1600 950", "[pos] -1 -1",
           "[sst_width] 260", "[signals_width] 320", "[sst_expanded] 1"]
    for g, sigs in GROUPS:
        out.append("-%s" % g)
        for sig, bus in sigs:
            out.append("@23" if bus else "@28")
            out.append(sig)
    out += ["[pattern_trace] 1", "[pattern_trace] 0", ""]
    open(path, "w", encoding="utf-8").write("\n".join(out))
    print("wrote", path)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    wave = os.path.join(here, "wave")
    for v in sorted(glob.glob(os.path.join(wave, "*.vcd"))):
        base = os.path.basename(v)[:-4]
        write_gtkw(os.path.join(wave, base + ".gtkw"), base + ".vcd")


if __name__ == "__main__":
    main()
