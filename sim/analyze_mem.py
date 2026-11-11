#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze_mem.py — 读 sim/build/mem_trace.csv，出「存储器专题」要用的实测数字。

用法：
    python sim/analyze_mem.py                 # 摘要（各口脉冲计数、延迟、UART 帧）
    python sim/analyze_mem.py 100 140         # 打印 [100,140) 拍的逐拍表
    python sim/analyze_mem.py --find win      # 找窗口读写事件
    python sim/analyze_mem.py --json          # 把关键词数字写成 sim/build/mem_facts.json
"""
import csv
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, "build", "mem_trace.csv")


def hx(v):
    """十六进制串 -> int；x/z 一律当 0（复位前的未知态）。"""
    try:
        return int(v, 16)
    except ValueError:
        return 0


def load():
    rows = list(csv.DictReader(open(CSV, encoding="utf-8")))
    out = []
    for r in rows:
        d = {}
        for k, v in r.items():
            if k == "cycle":
                d[k] = int(v)
            elif len(v) <= 1 and v in ("0", "1", "x", "z"):
                # 单比特列：'x' 只在复位后第一拍出现，按 0 计（不影响脉冲统计）
                d[k] = 0 if v in ("x", "z") else int(v)
            else:
                # 其余一律按 32 位十六进制总线解析（'xxxxxxxx' → 0）
                d[k] = hx(v)
        out.append(d)
    return out


def pulses(rows, key):
    """返回 [(cycle, row)]，只在 key 由 0->1 的那一拍（脉冲起点）。"""
    res, prev = [], 0
    for r in rows:
        if r[key] and not prev:
            res.append(r)
        prev = r[key]
    return res


def widths(rows, key):
    """脉冲宽度分布。"""
    ws, run = [], 0
    for r in rows:
        if r[key]:
            run += 1
        elif run:
            ws.append(run)
            run = 0
    if run:
        ws.append(run)
    return ws


def tab(rows, a, b):
    hdr = ("cyc  PC        FM_en addr     rdata     | DM_en ren wen addr     mask wdata    rdata    "
           "| mm win | B_ren B_wen B_rdata  | DR_ren DR_wen DR_addr  DR_rdata | hit mis hold M1 M2 M3 | tx")
    print(hdr)
    for r in rows:
        if not (a <= r["cycle"] < b):
            continue
        print("%4d %08x  %d    %08x %08x | %d    %d   %d   %08x %d    %08x %08x | %d  %d  | "
              "%d     %d     %08x | %d     %d     %08x %08x | %d   %d   %d    %d  %d  %d | %d"
              % (r["cycle"], r["CPU_pc"], r["FM_en"], r["FM_addr"], r["FM_rdata"],
                 r["DM_en"], r["DM_ren"], r["DM_wen"], r["DM_addr"], r["DM_mask"],
                 r["DM_wdata"], r["DM_rdata"], r["DEC_mmio"], r["DEC_win"],
                 r["IROM_B_ren"], r["IROM_B_wen"], r["IROM_B_rdata"],
                 r["DRAM_ren"], r["DRAM_wen"], r["DRAM_addr"], r["DRAM_rdata"],
                 r["DC_hit"], r["DC_miss"], r["DC_hold"], r["LSU_M1"],
                 r["LSU_M2"], r["LSU_M3"], r["UART_tx"]))


def summary(rows):
    by_c = {r["cycle"]: r for r in rows}
    facts = {}
    f_en = pulses(rows, "FM_en")
    facts["fetch_cycles"] = len(f_en)
    facts["data_bus_reads"] = len(pulses(rows, "DM_ren"))
    facts["data_bus_writes"] = len(pulses(rows, "DM_wen"))
    facts["dram_reads"] = len(pulses(rows, "DRAM_ren"))
    facts["dram_writes"] = len(pulses(rows, "DRAM_wen"))
    facts["win_reads"] = len(pulses(rows, "IROM_B_ren"))
    facts["win_writes"] = len(pulses(rows, "IROM_B_wen"))
    facts["mmio_reads"] = sum(1 for r in pulses(rows, "DM_ren") if r["DEC_mmio"])
    facts["dcache_hits"] = len(pulses(rows, "DC_hit"))
    facts["dcache_misses"] = len(pulses(rows, "DC_miss"))
    facts["hold_widths"] = widths(rows, "DC_hold")
    facts["ren_widths"] = widths(rows, "DM_ren")
    facts["wen_widths"] = widths(rows, "DM_wen")
    facts["bwen_widths"] = widths(rows, "IROM_B_wen")

    print("=" * 78)
    print(" 抓到的脉冲（每项都是 0→1 的**起点**；宽度见括号）")
    print("=" * 78)
    for k, v in facts.items():
        print("  %-18s %s" % (k, v))

    # ---- 读延迟：FM_en 起点那一拍给地址 T，rdata 在 T+1 有效 ----
    #   严格校验：rdata(T+1) 必须等于**镜像里 addr(T) 那个字**。
    img = []
    hexf = os.path.join(HERE, "mem_demo.hex")
    if os.path.exists(hexf):
        img = [int(x, 16) for x in open(hexf).read().split()]
    print("-" * 78)
    print(" 取指口时序（T 拍给地址，T+1 拍 rdata 有效；逐条对照 mem_demo.hex）:")
    ok = True
    shown = 0
    for r in f_en:
        t = r["cycle"]
        nxt = by_c.get(t + 1)
        if not nxt or (r["FM_addr"] >> 2) >= len(img):
            continue
        want = img[r["FM_addr"] >> 2]
        good = (nxt["FM_rdata"] == want)
        ok = ok and good
        if shown < 8:
            print("   T=%4d addr=%08x  →  T+1 rdata=%08x  镜像=%08x  %s"
                  % (t, r["FM_addr"], nxt["FM_rdata"], want, "一致" if good else "不一致!"))
            shown += 1
    print("   …… 全程取指 %d 次，逐条比对结果：%s" % (len(f_en), "全部一致" if ok else "有不一致"))
    facts["fetch_latency_ok"] = ok

    # ---- 数据口：一次 load miss 的完整过程 ----
    dr = pulses(rows, "DM_ren")
    if dr:
        r0 = dr[0]
        t0 = r0["cycle"]
        print("-" * 78)
        print(" 第一次数据口读（DRAM load miss）逐拍:")
        for t in range(t0 - 3, t0 + 6):
            r = by_c.get(t)
            if r:
                print("   %4d PC=%08x ren=%d addr=%08x rdata=%08x hold=%d miss=%d hit=%d M2=%d M3=%d"
                      % (r["cycle"], r["CPU_pc"], r["DM_ren"], r["DM_addr"], r["DM_rdata"],
                         r["DC_hold"], r["DC_miss"], r["DC_hit"], r["LSU_M2"], r["LSU_M3"]))
        facts["first_read"] = {"cycle": t0, "addr": r0["DM_addr"], "rdata": r0["DM_rdata"]}

    # ---- UART 帧：tx 的边沿与位宽 ----
    edges = []
    prev = rows[0]["UART_tx"]
    for r in rows:
        if r["UART_tx"] != prev:
            edges.append((r["cycle"], r["UART_tx"]))
            prev = r["UART_tx"]
    if len(edges) >= 2:
        bits = [edges[i + 1][0] - edges[i][0] for i in range(len(edges) - 1)]
        print("-" * 78)
        print(" UART 帧边沿（起始位从高到低）：")
        for i, (c, v) in enumerate(edges):
            print("   边沿 %d: cycle=%-6d 电平=%d" % (i, c, v))
        print("   相邻边沿间隔（拍）:", bits)
        facts["uart_edges"] = edges
        facts["uart_bit_widths"] = bits
        facts["uart_bit_cycles_median"] = sorted(bits)[len(bits) // 2]

    print("=" * 78)
    return facts


def main():
    rows = load()
    args = sys.argv[1:]
    if args and args[0] == "--json":
        facts = summary(rows)
        out = os.path.join(HERE, "build", "mem_facts.json")
        json.dump(facts, open(out, "w", encoding="utf-8"), indent=1)
        print("wrote", out)
    elif len(args) == 2:
        tab(rows, int(args[0]), int(args[1]))
    elif args and args[0] == "--find":
        key = args[1]
        for r in rows:
            if key == "win" and r["IROM_B_wen"]:
                print("W cycle=%d addr=%08x wdata=%08x mask=%d DRAM_wen=%d"
                      % (r["cycle"], r["DM_addr"], r["DM_wdata"], r["DM_mask"], r["DRAM_wen"]))
            if key == "winr" and r["IROM_B_ren"]:
                print("R cycle=%d addr=%08x b_rdata=%08x" % (r["cycle"], r["DM_addr"], r["IROM_B_rdata"]))
            if key == "mmio" and r["DEC_mmio"] and (r["DM_ren"] or r["DM_wen"]):
                print("M cycle=%d %s addr=%08x wdata=%08x idx=%d"
                      % (r["cycle"], "W" if r["DM_wen"] else "R", r["DM_addr"], r["DM_wdata"], 0))
    else:
        summary(rows)


if __name__ == "__main__":
    main()
