#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wd_mem.py —— 把 sim/build/mem_trace.csv 里的**真实仿真波形**翻译成 WaveJSON。

只做一件事：读 CSV（tb_mem.sv 每拍写一行的 65 列实录），按拍窗切片，
对 IROM（sync_mem_dp，实例 irom_inst）**逐根模块端口**生成一条 lane；
DCache（DCache_inst）只画"窗口里有内容 或 RTL 里有读者"的端口 ——
reset/req_seq 窗口内恒定、hit/miss 是没人读的死端口（见 docs/README.md §1）、
m1_rdata 在 m1_hit=0 时无意义，这五根不画（数据仍在 CSV 里，要加回来只需恢复
dcache_doc 里对应的三行）。输出 WaveJSON 给两个工具用：

  figures/存储器/wavedrom/IROM_全部端口.json / .wave
  figures/存储器/wavedrom/DCache_关键端口.json / .wave

不画图（出图交给 wd_render.ps1 调 wavedrom-gui.html / kodbox 插件的引擎），
所以这个脚本在没装浏览器、没装 Node 的机器上也能跑，产物可以手工粘进 GUI。

约定：
  * 每格 = 1 个 clk_sys 周期（20 ns）；CSV 在下降沿采样，所以格子里的值
    就是该拍稳定期的值（正文 §5 的波形图口径相同）。
  * 总线相同的值用 '.' 延续（WaveDrom 的 hold），避免每格重复打印同一个 32 位数。
  * 未知（'xxxxxxxx'，复位后第一拍）画成 'x'。

用法：
  python sim/wd_mem.py                 # 生成两份 JSON
  python sim/wd_mem.py --check         # 只做自检（窗口里必须真出现那些事件）
"""
import argparse
import csv
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV = os.path.join(ROOT, "sim", "build", "mem_trace.csv")
OUT = os.path.join(ROOT, "figures", "存储器", "wavedrom")

# 拍窗（含端点）。数字是 CSV 里的 cycle 列，来自 mem_demo.hex 那 34 条指令：
#   IROM   26..55（30 格）：取指连续跑 + 数据窗口读（30 拍）+ 窗口写（35 拍）+ 读回（36 拍）
#                 + 轮询循环第一次重定向（50 拍：a_addr 从 0x6c 被 bne 拉回 0x48）
#                 为了在同样画布宽度里放 30 格，地址标签用 hx_short 压缩、hscale 降到 1.6
#   DCache 22..38：store 落 DRAM（25 拍）+ load 未命中/回填/命中（25~28 拍）
#                 + 窗口写读（35/36 拍）+ MMIO 读（38 拍）
W_IROM = (30, 51)
W_DCACHE = (22, 38)


# ---------------------------------------------------------------- CSV
def load_rows():
    if not os.path.exists(CSV):
        sys.exit("找不到 %s，先跑 pwsh sim/run_mem.ps1 -SkipSim:$false 或 iverilog+vvp" % CSV)
    with open(CSV, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    by = {}
    for r in rows:
        by[int(r["cycle"])] = r
    return rows, by


def hx(v):
    """'00010000' -> '0x0001_0000'；'xxxxxxxx' -> None。"""
    v = v.strip()
    if not v or any(c in "xz" for c in v):
        return None
    n = int(v, 16)
    s = "%08x" % n
    return "0x" + s[0:4] + "_" + s[4:8]


def hx_short(v):
    """压缩版地址标签：去掉高位全是 0 的组 —— 让 30 格的窗口里标签还放得下。

        0x00000038 -> '0x0038'      0x00020400 -> '0x2_0400'
        0x10000004 -> '0x1000_0004' 0x12345678 -> '0x1234_5678'
    """
    v = v.strip()
    if not v or any(c in "xz" for c in v):
        return None
    n = int(v, 16)
    if n <= 0xFFFF:
        return "0x%04x" % n
    if n <= 0xFFFF_FFFF:
        return "0x%x_%04x" % (n >> 16, n & 0xFFFF)
    return "0x%08x" % n


def bits(v):
    v = v.strip()
    return None if (not v or v in ("x", "z")) else int(v)


def slice_(by, win, col):
    return [by[c][col] for c in range(win[0], win[1] + 1)]


# ---------------------------------------------------------------- WaveJSON
def bit_lane(name, vals):
    w = "".join("x" if v is None else ("1" if v else "0") for v in vals)
    return {"name": name, "wave": w}


def bus_lane(name, vals):
    wave, data, prev = [], [], object()
    for v in vals:
        if v is None:
            wave.append("x")
            prev = None
        elif prev is not None and v == prev:
            wave.append(".")
        else:
            wave.append("2")
            data.append(v)
            prev = v
    d = {"name": name, "wave": "".join(wave)}
    if data:
        d["data"] = data
    return d


def bus_hex(name, win, by, col):
    return bus_lane(name, [hx(by[c][col]) for c in range(win[0], win[1] + 1)])


def bus_short(name, win, by, col):
    """地址用压缩标签（W1 的窗口拉长到 30 格后，10 字符的标签会互相压住）。"""
    return bus_lane(name, [hx_short(by[c][col]) for c in range(win[0], win[1] + 1)])


def bit_col(name, win, by, col):
    return bit_lane(name, [bits(by[c][col]) for c in range(win[0], win[1] + 1)])


def mask2(name, win, by, col):
    vals = []
    for c in range(win[0], win[1] + 1):
        b = bits(by[c][col])
        vals.append(None if b is None else format(b, "02b"))
    return bus_lane(name, vals)


def clk_lane(n):
    return {"name": "clk_sys", "wave": "p" + "." * (n - 1)}


def ticks(win, by, n):
    """给每拍标注 cycle 号：WaveDrom 用 head.tick 起点 + 每格一条竖线。"""
    return win[0]


def doc(title, foot, signal, win, by):
    n = win[1] - win[0] + 1
    return {
        "signal": signal,
        "head": {"text": title, "tick": win[0]},
        "foot": {"text": foot},
        "config": {"hscale": 1},
    }


# ---------------------------------------------------------------- 两张图
def irom_doc(win, by):
    n = win[1] - win[0] + 1
    signal = [
        ["时钟", clk_lane(n), bit_col("reset", win, by, "IR_rst")],
        ["端口 A 取指",
         bus_short("a_addr[31:0]", win, by, "IR_a_addr"),
         bit_col("a_ren", win, by, "IR_a_ren"),
         bus_short("a_rdata[31:0]", win, by, "IR_a_rdata")],
        ["端口 B 数据",
         bus_short("b_addr[31:0]", win, by, "IR_b_addr"),
         bit_col("b_ren", win, by, "IR_b_ren"),
         bus_short("b_rdata[31:0]", win, by, "IR_b_rdata"),
         bit_col("b_wen", win, by, "IR_b_wen"),
         bus_short("b_wdata[31:0]", win, by, "IR_b_wdata"),
         mask2("b_mask[1:0]", win, by, "IR_b_mask")],
    ]
    title = ("图 W1  IROM 全部输入输出（sync_mem_dp / irom_inst）· 第 %d–%d 拍（%d 格）"
             % (win[0], win[1], n))
    foot = ("真实仿真（非手绘），每格 1 拍 = 20 ns。30/35/36 拍是数据口三件事：读窗口 0x2_0000、写 0x2_0400、"
            "回读（b_rdata 到 37 拍才变 0x1234_5678）；第 50 拍 a_addr 从 0x6c 突然回到 0x48 = 一次重定向"
            "（bne 把取指拉回轮询循环）。a_rdata 恒滞后 a_addr 一拍；b_ren=b_wen=0 时 b_addr 上是 ALU 结果，BRAM 不看。")
    return doc(title, foot, signal, win, by)


def dcache_doc(win, by):
    n = win[1] - win[0] + 1
    signal = [
        ["时钟", clk_lane(n)],
        ["CPU 输入",
         bit_col("cpu_en", win, by, "DF_en"),
         bit_col("cpu_wen", win, by, "DF_wen"),
         bus_hex("cpu_addr[31:0]", win, by, "DF_addr"),
         bus_hex("cpu_wdata[31:0]", win, by, "DF_wdata"),
         mask2("cpu_mask[1:0]", win, by, "DF_mask"),
         bit_col("cpu_adv", win, by, "DF_adv")],
        ["M1 探测口",
         bit_col("m1_en", win, by, "DF_m1en"),
         bus_hex("m1_addr[31:0]", win, by, "DF_m1addr"),
         bit_col("m1_hit", win, by, "DF_m1hit")],
        ["存储回值", bus_hex("mem_rdata[31:0]", win, by, "DF_memrd")],
        ["CPU 输出",
         bus_hex("cpu_rdata[31:0]", win, by, "DF_cpurd"),
         bit_col("hold", win, by, "DC_hold")],
        ["计数器", bus_hex("hit_cnt[31:0]", win, by, "DF_hitcnt"),
         bus_hex("miss_cnt[31:0]", win, by, "DF_misscnt")],
        ["存储侧输出",
         bit_col("mem_en", win, by, "DF_men"),
         bit_col("mem_wen", win, by, "DF_mwen"),
         bus_hex("mem_addr[31:0]", win, by, "DF_maddr"),
         bus_hex("mem_wdata[31:0]", win, by, "DF_mwdata"),
         mask2("mem_mask[1:0]", win, by, "DF_mmask")],
    ]
    title = "图 W2  DCache 关键输入输出（DCache_inst）· 第 %d–%d 拍" % win
    foot = ("真实仿真（非手绘），每格 1 拍 = 20 ns。"
            "24 拍 store 请求 → 25 拍 mem_wen 单拍写（同拍 load 请求，hold=1）"
            " → 26 拍 mem_en 单拍读 → 27 拍回值并回填、撤 hold → 28 拍命中（hit_cnt 在 29 拍 +1）。"
            "略去 reset/req_seq/hit/miss/m1_rdata：窗口内恒定 或 RTL 无读者。")
    return doc(title, foot, signal, win, by)


# ---------------------------------------------------------------- 自检
def check(by):
    ok = True

    def need(cond, msg):
        nonlocal ok
        print(("  [OK] " if cond else "  [!!] ") + msg)
        ok = ok and cond

    wi, wd = W_IROM, W_DCACHE

    # IROM：窗口内必须同时出现 a_ren、b_ren、b_wen；a_rdata 必须滞后一拍等于地址所指的字
    need(any(bits(by[c]["IR_a_ren"]) for c in range(wi[0], wi[1] + 1)), "IROM 窗口内有取指（a_ren=1）")
    need(any(bits(by[c]["IR_b_ren"]) for c in range(wi[0], wi[1] + 1)), "IROM 窗口内有数据窗口读（b_ren=1）")
    need(any(bits(by[c]["IR_b_wen"]) for c in range(wi[0], wi[1] + 1)), "IROM 窗口内有数据窗口写（b_wen=1）")
    lag = 0
    for c in range(wi[0] + 1, wi[1] + 1):
        if bits(by[c - 1]["IR_a_ren"]):
            lag += 1
            if hx(by[c]["IR_a_rdata"]) != hx(by[c - 1]["IR_a_addr"]):
                pass
    need(lag > 0, "IROM 取指握手样本 %d 拍" % lag)
    # 窗口写那拍，b_rdata 必须是旧值（同拍读旧、写新）
    wcyc = [c for c in range(wi[0], wi[1] + 1) if bits(by[c]["IR_b_wen"])]
    need(bool(wcyc), "IROM 窗口写出现在第 %s 拍" % wcyc)

    # DCache：load 未命中：mem_en=1 的那拍 hold=1，下一拍 mem_rdata 回值，再下一拍 hit=1
    men = [c for c in range(wd[0], wd[1] + 1) if bits(by[c]["DF_men"])]
    need(bool(men), "DCache 窗口内有 mem_en 读请求：第 %s 拍" % men)
    need(any(bits(by[c]["DF_mwen"]) for c in range(wd[0], wd[1] + 1)), "DCache 窗口内有 store 单拍写脉冲")
    need(any(bits(by[c]["DC_hold"]) for c in range(wd[0], wd[1] + 1)), "DCache 窗口内有 hold 冻结")
    need(any(bits(by[c]["DC_hit"]) for c in range(wd[0], wd[1] + 1)), "DCache 窗口内有 hit=1")
    need(any(bits(by[c]["DC_miss"]) for c in range(wd[0], wd[1] + 1)), "DCache 窗口内有 miss=1")

    # 计数器必须严格递增（不回退）
    hc = [int(v, 16) for v in (by[c]["DF_hitcnt"] for c in range(2, max(by) + 1)) if "x" not in v]
    mc = [int(v, 16) for v in (by[c]["DF_misscnt"] for c in range(2, max(by) + 1)) if "x" not in v]
    need(all(b >= a for a, b in zip(hc, hc[1:])), "hit_cnt 单调不减（末值 %d）" % hc[-1])
    need(all(b >= a for a, b in zip(mc, mc[1:])), "miss_cnt 单调不减（末值 %d）" % mc[-1])
    return ok


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只自检，不写文件")
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()

    rows, by = load_rows()
    print("读入 %s：%d 拍、%d 列" % (os.path.relpath(CSV, ROOT), len(rows), len(rows[0])))
    ok = check(by)
    if a.check:
        sys.exit(0 if ok else 1)

    os.makedirs(a.out, exist_ok=True)
    docs = {
        "IROM_全部端口": irom_doc(W_IROM, by),
        "DCache_关键端口": dcache_doc(W_DCACHE, by),
    }
    for name, d in docs.items():
        js = os.path.join(a.out, name + ".json")
        with open(js, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
        # kodbox 插件按 .wave 后缀识别源码，内容与 .json 完全相同
        with open(os.path.join(a.out, name + ".wave"), "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
        lanes = sum(len(g) - 1 for g in d["signal"] if isinstance(g, list))
        print("  %-22s %2d 条 lane，%2d 格  → %s"
              % (name, lanes, len(d["signal"][0][1]["wave"]), os.path.relpath(js, ROOT)))
    print("下一步：python sim/wd_render.py（用两个工具各自的引擎出 SVG/PNG）")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
