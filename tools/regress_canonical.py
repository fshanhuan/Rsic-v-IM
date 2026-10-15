#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
regress_canonical.py — 用**仓库正本**（新注释版）跑 iverilog 全量回归

为什么需要单独一个：
  `sim\\run_iverilog.bat` 跑的是**工作目录**根下的 .sv。注释迭代期间所有改动
  都只落在仓库正本 `E:\\share doc\\v9\\`，工作目录还是旧的。
  这个脚本在 `_comment_iter\\regress\\` 里搭一个隔离环境，**只取正本的 RTL**
  （+ 工作目录的 sim 测试台与 .hex），跑完 7 个程序，因此可以在最终同步之前
  就拿到"新注释的 RTL 仍然 7/7 全过"的证据。

目录布局（跑完保留，便于复查）：
  _comment_iter\\regress\\sim\\<prog>.hex, tb_iverilog.sv
  _comment_iter\\regress\\wave\\            （VCD 输出）
  _comment_iter\\regress\\build\\            （vvp 与日志）

用法：
  python tools/regress_canonical.py
  python tools/regress_canonical.py --keep-log     # 保留每个程序的完整日志
  python tools/regress_canonical.py --skip-gate    # RTL 被**有意修改**过时用（H1/H2/H3 等真实修复）
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from strip_sv_comments import strip, normalize      # noqa: E402

CANON = r"E:\share doc\v9"
IVERILOG = r"D:\eda_tools\iverilog\bin\iverilog.exe"
VVP = r"D:\eda_tools\iverilog\bin\vvp.exe"

CORE = ["myCPU.sv", "IFU.sv", "ICache.sv", "Branch_Predictor.sv", "IDU.sv",
        "Reg_Stack.sv", "RegisterFile.sv", "CSR.sv", "EXU.sv", "ALU.sv",
        "MDU_pipelined.sv", "LSU.sv", "DCache.sv", "WBU.sv",
        "Data_hazard.sv", "Control.sv", "add.sv", "sext.sv", "Reg.sv"]

PROGS = [("prog", 0), ("prog_mul", 1), ("prog_div", 2), ("prog_load_lane", 3),
         ("prog_load_use", 4), ("prog_loop", 5), ("prog_div_pair", 6)]


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    keep = "--keep-log" in sys.argv
    skip_gate = "--skip-gate" in sys.argv

    # ------------------------------------------------------------------
    # 前置闸门：先确认正本的"代码等价性"全部成立。
    #   为什么要有这道闸门：注释迭代是**并行**进行的，某个 agent 可能正好写到一半
    #   （实测踩到过：Control.sv 的 `Data_hazard Data_hazard_inst (` 被粘到了上一行
    #   `//` 注释末尾，整个例化头被注释掉 → 编译报 invalid module item）。
    #   那种情况下编译失败**不代表注释迭代有问题**，只代表现在不是跑回归的时机。
    #   让脚本自己说清楚，免得把中途状态当成真故障去查。
    # ------------------------------------------------------------------
    man = os.path.join(ROOT, "_comment_iter", "manifest_before.tsv")
    snap = os.path.join(ROOT, "_comment_iter", "before")
    broken = []
    entries = []
    with open(man, "r", encoding="utf-8-sig") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) >= 2:
                entries.append(p[0].lstrip("\ufeff"))
    if skip_gate:
        print("!! --skip-gate：跳过 code-equivalence 前置闸门")
        print("   （正本 RTL 已按真实缺陷修复有意改动——H1 up_stall / H2 读窗口整字 mask——")
        print("    此时与'注释迭代前快照'代码不同是**预期**的，不是写坏了）")
        print("   ★ 但请在修完后重跑 tools/acceptance_report.py 的其余维度，并重建 Vivado 工程。")
        print("-" * 78)
    for rel in ([] if skip_gate else entries):
        rel2 = rel.replace("/", os.sep)
        d, name = os.path.split(rel2)
        if d == "core":
            cur = os.path.join(CANON, "rtl", name)
        elif d == "board":
            cur = os.path.join(CANON, "board", name)
        else:
            continue
        old = os.path.join(snap, rel2)
        if not (os.path.exists(old) and os.path.exists(cur)):
            continue
        with open(old, "r", encoding="utf-8", errors="replace") as f:
            a = normalize(strip(f.read()))
        with open(cur, "r", encoding="utf-8", errors="replace") as f:
            b = normalize(strip(f.read()))
        if a != b:
            broken.append(name)
    if broken:
        print("!! 正本里有文件在【剥离注释后】与快照不一致，现在**不是**跑回归的时机：")
        for b in broken:
            print("     %s   （可能是某个 agent 正写到一半，或真的改坏了）" % b)
        print("   先让所有 agent 停下，再跑 tools/check_all.py 确认 25 个文件全 CODE-IDENTICAL。")
        return 4

    work = os.path.join(ROOT, "_comment_iter", "regress")
    simd = os.path.join(work, "sim")
    for d in (simd, os.path.join(work, "wave"), os.path.join(work, "build")):
        os.makedirs(d, exist_ok=True)

    # 1) 测试台与程序镜像从工作目录取（它们不属于本次注释迭代的 25 个文件）
    tb_src = os.path.join(ROOT, "sim", "tb_iverilog.sv")
    shutil.copyfile(tb_src, os.path.join(simd, "tb_iverilog.sv"))
    n_hex = 0
    for fn in os.listdir(os.path.join(ROOT, "sim")):
        if fn.endswith(".hex"):
            shutil.copyfile(os.path.join(ROOT, "sim", fn), os.path.join(simd, fn))
            n_hex += 1

    # 2) 用**正本**的 RTL 编译
    srcs = [os.path.join(CANON, "rtl", f).replace("/", os.sep) for f in CORE]
    srcs.append(os.path.join(simd, "tb_iverilog.sv"))
    for s in srcs:
        if not os.path.exists(s):
            print("!! 缺文件: %s" % s)
            return 2
    vvp = os.path.join(work, "build", "tb_iverilog.vvp")
    # ★ 先删旧产物：否则编译失败时会**跑上一次的旧 vvp**，报出假的 7/7。
    #   实测踩到过：RTL 收进 rtl/ 之后 `include "para.sv" 找不到，iverilog 只打
    #   "Include file para.sv not found"（**不含** ": error"），旧的检测式判定"编译 OK"，
    #   接着跑的还是搬迁前的旧二进制 → 假通过。
    if os.path.exists(vvp):
        os.remove(vvp)
    # ★ -I <正本>/rtl：iverilog 只在**当前目录**与 -I 目录里找 `include，
    #   不会去源文件自己所在的目录找（para.sv 现在就在 rtl\ 下）。
    cmd = [IVERILOG, "-g2012", "-I", os.path.join(CANON, "rtl"), "-o", vvp] + srcs
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    blob = (r.stdout or "") + (r.stderr or "")
    BAD = (": error", "Include file", "not found", "No top level modules",
           "%Error", "syntax error")
    errs = [l for l in blob.splitlines() if any(b in l for b in BAD)]
    print("编译：%d 个源文件（正本 RTL + 工作目录测试台），%d 个 .hex"
          % (len(srcs), n_hex))
    if errs or not os.path.exists(vvp):
        print("!! 编译失败（或根本没产出 vvp）：")
        for l in errs[:10]:
            print("   " + l)
        if not errs:
            print("   （没有匹配到已知错误样式，但 %s 不存在）" % vvp)
        return 3
    print("编译 OK")
    print("-" * 78)

    n_pass = n_fail = 0
    for name, pid in PROGS:
        cmd = [VVP, vvp, "+prog=sim/%s.hex" % name, "+prog_id=%d" % pid,
               "+vcd=wave/tb_%s.vcd" % name]
        rr = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                            errors="replace", cwd=work)
        out = rr.stdout + rr.stderr
        m = re.search(r"\[SELFCHECK\] status=(\w+)\s+\(([^)]*)\)", out)
        status = m.group(1) if m else "NO_SELFCHECK"
        detail = m.group(2) if m else ""
        ok = (status == "PASS" and rr.returncode == 0)
        n_pass += ok
        n_fail += (not ok)
        print("  %-16s %-10s %-22s %s"
              % (name, status, detail, "OK" if ok else "<<<< 失败"))
        if not ok:
            tail = [l for l in out.splitlines() if "FAIL" in l or "error" in l]
            for l in tail[:6]:
                print("        " + l.strip())
        if keep:
            with open(os.path.join(work, "build", name + ".log"), "w",
                      encoding="utf-8") as f:
                f.write(out)

    print("-" * 78)
    print("iverilog 全量回归（正本新注释版）：%d 通过 / %d 失败" % (n_pass, n_fail))
    print("判定：%s" % ("PASS —— 注释迭代没有影响功能" if n_fail == 0 else "FAIL"))
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
