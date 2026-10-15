# analyze_ila_csv.py — 解析 write_hw_ila_data -csv_file 导出的 ILA 抓取数据
# -----------------------------------------------------------------------------
# 用法:
#   python analyze_ila_csv.py <capture.csv>
#
# Vivado 的 CSV 结构（实测）：
#   第 1 行 = 列名（Sample in Buffer,Sample in Window,TRIGGER,debug_xxx,...）
#   第 2 行 = 基数行（Radix - UNSIGNED,...,HEX,...）      ← 必须丢掉
#   之后每行一个采样点
import sys
import pandas as pd

pd.set_option("display.width", 250)
pd.set_option("display.max_columns", 60)


def load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        head = f.readline().rstrip("\n")
    cols = [c.strip() for c in head.split(",")]
    df = pd.read_csv(path, dtype=str, skiprows=2, names=cols)
    # 丢掉任何非数字开头的残行（保险）
    df = df[df[cols[0]].astype(str).str.match(r"^\d+$", na=False)].reset_index(drop=True)
    return df


def col(df, *keys):
    for c in df.columns:
        low = str(c).lower()
        if all(k.lower() in low for k in keys):
            return c
    return None


def hx(s):
    """CSV 里的值都是十六进制（无 0x 前缀）"""
    if s is None:
        return None
    s = str(s).strip()
    if s == "" or s.lower() == "nan":
        return None
    try:
        return int(s, 16)
    except Exception:
        return None


def main(path):
    df = load(path)
    print(f"== {path} ==")
    print(f"采样数 = {len(df)}   列 = {len(df.columns)}")

    c_pc = col(df, "wb_pc")
    c_hi = col(df, "have_inst")
    c_en = col(df, "wb_ena")
    c_rg = col(df, "wb_reg")
    c_vl = col(df, "wb_value")
    c_ih = col(df, "icache_hit")
    c_im = col(df, "icache_miss")
    c_dh = col(df, "dcache_hit")
    c_dm = col(df, "dcache_miss")
    c_mc = col(df, "mcause")
    c_me = col(df, "mepc")
    c_mt = col(df, "mtval")
    c_tt = col(df, "trap_take")

    pc = [hx(v) for v in df[c_pc]] if c_pc else []

    # ---------------------------------------------------------- PC 取值分布
    print("\n================ 1) debug_wb_pc 的取值分布 ================")
    vals = [v for v in pc if v is not None]
    from collections import Counter
    cnt = Counter(vals)
    print(f"  不同取值 {len(cnt)} 个：")
    for v, n in sorted(cnt.items(), key=lambda kv: -kv[1])[:20]:
        print(f"    0x{v:08X}  出现 {n:5d} 拍   低14位=0x{v & 0x3FFF:04X}  高18位=0x{v >> 14:05X}")
    bases = sorted({v >> 14 for v in vals})
    print(f"\n  高 18 位(bit31:14) 的取值集合 = {[hex(b) for b in bases]}")
    print(f"  → bit31:14 全 0 ? {'是（干净）' if bases == [0] else '否  ← 基址被污染'}")

    # ---------------------------------------------------------- PC 变化序列（前 80 次）
    print("\n================ 2) debug_wb_pc 变化序列（前 80 次跳变） ================")
    prev, shown = object(), 0
    for i, v in enumerate(pc):
        if v != prev:
            mark = ""
            if c_hi and df[c_hi].iloc[i] == "1":
                mark += " hi"
            if c_en and df[c_en].iloc[i] == "1":
                mark += " ena"
            if c_rg:
                mark += f" reg={df[c_rg].iloc[i]}"
            if c_vl:
                mark += f" val={df[c_vl].iloc[i]}"
            print(f"  [{i:5d}] 0x{v:08X}{mark}" if v is not None else f"  [{i:5d}] <无>")
            prev = v
            shown += 1
            if shown >= 80:
                print("  ...")
                break

    # ---------------------------------------------------------- CSR
    print("\n================ 3) CSR 现场（mcause / mepc / mtval / trap_take） ================")
    for name, c in [("mcause", c_mc), ("mepc", c_me), ("mtval", c_mt), ("trap_take", c_tt)]:
        if not c:
            continue
        vs = [hx(v) for v in df[c]]
        vs = [v for v in vs if v is not None]
        cc = Counter(vs)
        print(f"  {name:10s} 不同取值 {len(cc)}：{[hex(k) for k in list(cc)[:8]]}")
        if name == "trap_take":
            n1 = sum(1 for v in vs if v == 1)
            print(f"             为 1 的拍数 = {n1}")

    # ---------------------------------------------------------- 计数器
    print("\n================ 4) Cache 计数器 ================")
    res = {}
    for name, c in [("icache_hit", c_ih), ("icache_miss", c_im),
                    ("dcache_hit", c_dh), ("dcache_miss", c_dm)]:
        if not c:
            continue
        s = [hx(v) for v in df[c]]
        s = [v for v in s if v is not None]
        if not s:
            continue
        d = s[-1] - s[0]
        res[name] = (s[0], s[-1], d)
        print(f"  {name:12s} 首=0x{s[0]:08X}  末=0x{s[-1]:08X}  窗口内增量={d:6d}  每拍={d/max(1,len(s)-1):.3f}")
    if "icache_hit" in res and "icache_miss" in res:
        dh, dm = res["icache_hit"][2], res["icache_miss"][2]
        tot = dh + dm
        print(f"\n  I-Cache 窗口内 命中:缺失 = {dh}:{dm}"
              + (f"  (命中率 {100.0*dh/tot:.1f}%，仿真参考 75%)" if tot else ""))
    if "dcache_hit" in res and "dcache_miss" in res:
        dh, dm = res["dcache_hit"][2], res["dcache_miss"][2]
        print(f"  D-Cache 窗口内 命中:缺失 = {dh}:{dm}")

    # ---------------------------------------------------------- 写回事件表
    print("\n================ 5) 写回事件表（按 pc 分组，看每条指令执行了几次/什么值） ================")
    if c_pc and c_rg and c_vl:
        sub = pd.DataFrame({
            "pc": [f"0x{hx(v):08X}" if hx(v) is not None else "?" for v in df[c_pc]],
            "ena": df[c_en] if c_en else "",
            "reg": df[c_rg],
            "val": df[c_vl],
        })
        sub = sub[sub["ena"] == "1"] if c_en else sub
        g = sub.groupby(["pc", "reg", "val"]).size().reset_index(name="次数")
        g = g.sort_values("次数", ascending=False)
        print(g.head(25).to_string(index=False))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])
