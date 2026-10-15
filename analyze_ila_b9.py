#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
analyze_ila_b9.py — 分析 v9 B9 修复后的 ILA 抓取（16 探针）

专门回答三个问题：
  1. ecall 之后 PC 到底有没有回到 mtvec(=0)？        -> 看 debug_ifu_pc
  2. 重定向请求发出了吗？那一拍 ready 是几？          -> 看 debug_dnpc_flag / debug_ready
  3. 重定向之后 PC 是不是真的落到目标上了？            -> 看 debug_ifu_pc 的变化序列

用法：
  python analyze_ila_b9.py ila_b9_pc0.csv [ila_b9_redir.csv ...]

CSV 格式（write_hw_ila_data -csv_file）：
  第 1 行 = 列名（Sample in Buffer,Sample in Window,TRIGGER,debug_wb_have_inst,...）
  第 2 行 = 进制说明（Radix - UNSIGNED,...）—— 必须丢掉
  第 3 行起 = 每拍一行；所有值都是**不带 0x 的十六进制**
"""
import sys
import csv

# Windows 控制台默认 GBK，直接 print 中文 + 符号会 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def load(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rows = list(csv.reader(f))
    if len(rows) < 3:
        raise SystemExit("CSV 太短: %s" % path)
    header = [h.strip() for h in rows[0]]
    body = rows[2:]                      # 丢掉 Radix 行
    cols = {}
    for i, h in enumerate(header):
        cols[h] = i
    data = []
    for r in body:
        if len(r) < len(header):
            continue
        data.append(r)
    return header, cols, data


def find(cols, *names):
    """按子串找列号（CSV 里带 [31:0] 之类的后缀）"""
    for n in names:
        for h, i in cols.items():
            if n in h:
                return h, i
    return None, None


def hexval(s):
    s = (s or "").strip()
    if s == "":
        return None
    try:
        return int(s, 16)
    except ValueError:
        return None


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for path in sys.argv[1:]:
        print("=" * 78)
        print("文件: %s" % path)
        header, cols, data = load(path)
        print("列数 = %d，样本数 = %d" % (len(header), len(data)))
        print("列名: %s" % ", ".join(header))

        c_pc, i_pc = find(cols, "debug_ifu_pc")
        c_wbpc, i_wbpc = find(cols, "debug_wb_pc")
        c_fl, i_fl = find(cols, "debug_dnpc_flag")
        c_rdy, i_rdy = find(cols, "debug_ready")
        c_mepc, i_mepc = find(cols, "debug_mepc")
        c_mc, i_mc = find(cols, "debug_mcause")
        c_tr, i_tr = find(cols, "TRIGGER")

        # ---------- 1) 关键结论：IFU PC 到过 0 吗 ----------
        if i_pc is not None:
            pcs = [hexval(r[i_pc]) for r in data]
            pcs = [p for p in pcs if p is not None]
            zeros = [k for k, p in enumerate(pcs) if p == 0]
            print("")
            print("---- 【1】debug_ifu_pc（取指级 PC 本体）----")
            print("  不同取值个数 = %d" % len(set(pcs)))
            print("  取值范围     = 0x%08X .. 0x%08X" % (min(pcs), max(pcs)))
            if zeros:
                print("  [OK] PC 到达 0x00000000（= mtvec）共 %d 次，首次在第 %d 个样本"
                      % (len(zeros), zeros[0]))
                k = zeros[0]
                lo = max(0, k - 4)
                hi = min(len(pcs), k + 10)
                print("  PC 轨迹（样本 %d..%d，← 标记命中 mtvec）:" % (lo, hi - 1))
                for j in range(lo, hi):
                    mark = "  <-- mtvec" if pcs[j] == 0 else ""
                    print("     [%4d] ifu_pc = 0x%08X%s" % (j, pcs[j], mark))
            else:
                print("  [FAIL] PC **从未**到达 0x00000000 -> ecall 重定向仍然失效！")
            # PC 变化序列（去重相邻）
            seq = []
            for p in pcs:
                if not seq or seq[-1] != p:
                    seq.append(p)
            print("  相邻去重后的 PC 序列（前 30 个）:")
            print("     " + " -> ".join("0x%08X" % p for p in seq[:30]))
        else:
            print("WARN: CSV 里没有 debug_ifu_pc 列")

        # ---------- 2) 重定向请求 vs ready ----------
        if i_fl is not None:
            flags = [hexval(r[i_fl]) for r in data]
            redirs = [k for k, v in enumerate(flags) if v]
            print("")
            print("---- 【2】debug_dnpc_flag（重定向请求）----")
            print("  请求拍数 = %d" % len(redirs))
            if redirs:
                for k in redirs[:20]:
                    rdy = hexval(data[k][i_rdy]) if i_rdy is not None else None
                    pcv = hexval(data[k][i_pc]) if i_pc is not None else None
                    pcv2 = hexval(data[k + 1][i_pc]) if (i_pc is not None and k + 1 < len(data)) else None
                    dnpc = None
                    _, i_dn = find(cols, "dnpc")
                    if i_dn is not None and "flag" not in header[i_dn]:
                        dnpc = hexval(data[k][i_dn])
                    print("     [%4d] dnpc_flag=1  ready=%s  dnpc=%s  ifu_pc: %s -> %s"
                          % (k, rdy,
                             ("0x%08X" % dnpc) if dnpc is not None else "?",
                             ("0x%08X" % pcv) if pcv is not None else "?",
                             ("0x%08X" % pcv2) if pcv2 is not None else "?"))
                n_rdy0 = sum(1 for k in redirs
                             if i_rdy is not None and hexval(data[k][i_rdy]) == 0)
                print("  其中 ready==0 的拍数 = %d  （修复前：这些重定向会被静默丢弃）"
                      % n_rdy0)

        # ---------- 3) mepc / mcause ----------
        if i_mepc is not None:
            mepcs = [hexval(r[i_mepc]) for r in data]
            mepcs = [m for m in mepcs if m is not None]
            print("")
            print("---- 【3】debug_mepc / debug_mcause ----")
            print("  mepc 不同取值 = %s"
                  % ", ".join("0x%08X" % v for v in sorted(set(mepcs))[:8]))
            if len(set(mepcs)) > 1:
                lo, hi = min(mepcs), max(mepcs)
                print("  mepc 变化范围 = 0x%08X .. 0x%08X  (差 0x%X)" % (lo, hi, hi - lo))
                print("  注：修复前 mepc 每次 +0x4000（= 一圈 IROM），说明程序在绕圈重跑")
        if i_mc is not None:
            mcs = [hexval(r[i_mc]) for r in data]
            mcs = [m for m in mcs if m is not None]
            print("  mcause 不同取值 = %s"
                  % ", ".join("0x%08X" % v for v in sorted(set(mcs))[:8]))
        if i_tr is not None:
            trs = [hexval(r[i_tr]) for r in data]
            trs = [t for t in trs if t is not None]
            print("  TRIGGER 位置（样本序号）= %s" % trs[:5])
        print("")


if __name__ == "__main__":
    main()
