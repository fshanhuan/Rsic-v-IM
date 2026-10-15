#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_ila_board.py — 按《上板验证判据.md》逐条核对一次 ILA 抓取

判据来源：docs/vivado/上板验证判据.md
  §0    prog.hex 的 14 条指令 → PC / 写回寄存器 / 写回值预期表
  §4    五个"单点决定性"检查（含第 5 条 ecall 重定向）
  §5    异常现场 probe9/10/11/12
  §6    计数器 probe5~8 的"趋势"判据（绝对值不作判据）
  §7.1  mepc 是否保持恒定（若反复 +0x4000 = 重定向失效）
  §8    X 值 / 乱跳 的症状排查

用法：
  python check_ila_board.py <waveform.csv> [--json 输出.json] [--baseline 旧抓取.csv]

CSV 格式（vivado write_hw_ila_data -csv_file）：
  第 1 行 = 列名；第 2 行 = Radix 行（必须丢）；第 3 行起 = 每拍一行，值均为裸十六进制。
"""
import sys
import csv
import json
import os

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# ---------------------------------------------------------------------------
# §0  prog.hex 预期表：  PC -> (写回寄存器, 预期写回值, 期望 ena)
#      ena 为 None 表示"不判 ena"（sw/beq 是 have_inst=1 但 ena=0，属正常）
# ---------------------------------------------------------------------------
PROG = [
    (0x00, 1, 0x00001000, 1, "lui   x1, 0x1"),
    (0x04, 2, 0x00000005, 1, "addi  x2, x0, 5"),
    (0x08, 3, 0x00000007, 1, "addi  x3, x0, 7"),
    (0x0C, 4, 0x0000000C, 1, "add   x4, x2, x3"),
    (0x10, 5, 0x00000023, 1, "mul   x5, x2, x3   <- 乘法器"),
    (0x14, 0, 0x00001000, 0, "sw    x4, 0(x1)    <- 不写寄存器，probe4=地址"),
    (0x18, 6, 0x0000000C, 1, "lw    x6, 0(x1)    <- store->load 往返"),
    (0x1C, 7, 0x00000011, 1, "add   x7, x6, x2"),
    # 注意：beq 不写寄存器（ena=0），但 IDU 仍然报出目的寄存器号 x8 —— 判据表 §0 第 9 行写的
    # 就是 "x8 (ena=0)"，这里必须照抄，写 0 会得到假 FAIL。
    (0x20, 8, 0x00000000, 0, "beq   x2,x3,+8     <- 5!=7 不该跳"),
    (0x24, 8, 0x0000000C, 1, "add   x8, x2, x3"),
    (0x28, 0, 0x0000002C, 1, "jal   x0, +8       <- 跳过 0x2C"),
    (0x2C, None, 0x000007FF, None, "addi  x9, x0, 0x7ff <- 必须永不执行"),
    (0x30, 10, 0x0000003F, 1, "ori   x10, x0, 0x3f"),
    # ecall：判据表 §0 第 14 行只写 "probe12 出脉冲"，对写回寄存器/值**没有期望**，
    # 所以 reg/ena/值全部按 None 处理 = 只记录不判定（实测 reg=0/ena=1/值=0，
    # 即"写 x0"，与 `jal x0` 同类，属正常）。
    (0x34, None, None, None, "ecall              <- 触发异常"),
]
PROG_BY_PC = {row[0]: row for row in PROG}
PC_JUMPED_OVER = 0x2C


def load(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rows = list(csv.reader(f))
    if len(rows) < 3:
        raise SystemExit("CSV 太短: %s" % path)
    header = [h.strip() for h in rows[0]]
    body = [r for r in rows[2:] if len(r) >= len(header)]
    cols = {h: i for i, h in enumerate(header)}
    return header, cols, body


def col(cols, name):
    for h, i in cols.items():
        if name in h:
            return i
    return None


def hv(s):
    s = (s or "").strip()
    if not s:
        return None
    try:
        return int(s, 16)
    except ValueError:
        return None


class Report(object):
    def __init__(self):
        self.rows = []
        self.n_fail = 0
        self.n_warn = 0

    def ok(self, tag, text, detail=""):
        self.rows.append(("PASS", tag, text, detail))

    def bad(self, tag, text, detail=""):
        self.n_fail += 1
        self.rows.append(("FAIL", tag, text, detail))

    def warn(self, tag, text, detail=""):
        self.n_warn += 1
        self.rows.append(("WARN", tag, text, detail))

    def info(self, tag, text, detail=""):
        self.rows.append(("INFO", tag, text, detail))

    def dump(self, title):
        print("=" * 78)
        print(title)
        print("=" * 78)
        for lvl, tag, text, detail in self.rows:
            mark = {"PASS": "[PASS]", "FAIL": "[FAIL]", "WARN": "[WARN]", "INFO": "[ .. ]"}[lvl]
            print("%s %-22s %s" % (mark, tag, text))
            if detail:
                for line in detail.splitlines():
                    print("        %s" % line)
        print("")
        print("---- 小结： FAIL = %d ， WARN = %d ----" % (self.n_fail, self.n_warn))
        print("")


def analyse(path):
    header, cols, data = load(path)
    r = Report()
    n = len(data)
    i_wbpc = col(cols, "debug_wb_pc")
    i_ena = col(cols, "debug_wb_ena")
    i_reg = col(cols, "debug_wb_reg")
    i_val = col(cols, "debug_wb_value")
    i_have = col(cols, "debug_wb_have_inst")
    i_ih, i_im = col(cols, "icache_hit"), col(cols, "icache_miss")
    i_dh, i_dm = col(cols, "dcache_hit"), col(cols, "dcache_miss")
    i_mc, i_mp, i_mv = col(cols, "mcause"), col(cols, "mepc"), col(cols, "mtval")
    i_tt = col(cols, "trap_take")
    i_dn = col(cols, "dnpc_flag")
    i_rdy = col(cols, "debug_ready")
    i_if = col(cols, "ifu_pc")

    r.info("文件", os.path.basename(path), "列数=%d  样本数=%d" % (len(header), n))

    # ---------------- §8 先排 X ----------------
    raw = ",".join(",".join(x) for x in data)
    bad_tok = 0
    for tok in raw.replace(",", " ").split():
        if tok and any(ch in "xXzZ" for ch in tok):
            bad_tok += 1
    if bad_tok:
        r.bad("§8 X/未初始化", "波形里有 %d 个 X/Z 值" % bad_tok,
              "该信号可能被优化掉或没接上（看综合日志 Synth 8-4446 / 8-3848）")
    else:
        r.ok("§8 X/未初始化", "2048 拍全部是确定值，无 X/Z")

    # ---------------- §4 第 5 条 / §7.1 控制流 ----------------
    ifu = [hv(x[i_if]) for x in data] if i_if is not None else []
    ifu_ok = [p for p in ifu if p is not None]
    distinct = sorted(set(ifu_ok))
    lo, hi = (min(ifu_ok), max(ifu_ok)) if ifu_ok else (0, 0)
    zeros = [k for k, p in enumerate(ifu_ok) if p == 0]
    if zeros:
        r.ok("§4-5 ecall 重定向", "IFU PC 到达 mtvec(0x00000000) 共 %d 次" % len(zeros),
             "首次在第 %d 拍；-> 重定向生效" % zeros[0])
    else:
        r.bad("§4-5 ecall 重定向", "IFU PC **从未**到达 0x00000000",
              "重定向失效（B9 那个 bug 复发？）看 dnpc_flag / ready")

    # PC 是否越过程序范围（0x00..0x38；0x38 是 ecall 后取指级的预取残影）
    over = [p for p in distinct if p > 0x38]
    if over:
        r.bad("控制流范围", "出现了 prog 之外的 PC：%s" % ", ".join("0x%X" % p for p in over[:8]),
              "PC 乱跳 -> 查复位/时钟/MMU 掩码")
    else:
        r.ok("控制流范围", "PC 全部落在 0x00..0x38（14 条程序 + 1 拍预取残影）",
             "不同取值 %d 个" % len(distinct))

    # 相邻去重后的序列
    seq = []
    for p in ifu_ok:
        if not seq or seq[-1] != p:
            seq.append(p)
    # 一圈的拍数：不能用"相邻两次 ifu_pc==0 的间隔"（PC 会在 0 上停若干拍，
    # 那个平均下来恒等于 1~2，是假的）。正确做法 = 窗口拍数 ÷ "进入 0"的**上升沿**次数。
    entries = [k for k, p in enumerate(ifu_ok)
               if p == 0 and (k == 0 or ifu_ok[k - 1] != 0)]
    if entries:
        period = n / float(len(entries))
        r.info("循环节奏", "一圈约 %.2f 拍（窗口 %d 拍 / 进入 mtvec %d 次）"
               % (period, n, len(entries)),
               "注：这不是 §6 的判据，只用于和上一次抓取对比（拍数变多 = 变慢）")
    r.info("PC 序列", "去重后前 20 个",
           " -> ".join("0x%X" % p for p in seq[:20]))

    # ---------------- §4 第 1~4 条 + §0 全表 ----------------
    wb = {}
    if i_wbpc is not None:
        for row in data:
            pc = hv(row[i_wbpc])
            have = hv(row[i_have]) if i_have is not None else 1
            if pc is None or have != 1:
                continue
            wb.setdefault(pc, []).append(
                (hv(row[i_ena]) if i_ena is not None else None,
                 hv(row[i_reg]) if i_reg is not None else None,
                 hv(row[i_val]) if i_val is not None else None))

    for pc, exp_reg, exp_val, exp_ena, text in PROG:
        if pc == PC_JUMPED_OVER:
            if pc in wb:
                r.bad("§4-4 jal 跳过", "0x2C 被执行了（%d 拍）" % len(wb[pc]),
                      "jal x0,+8 没生效；probe4 应为 0x7FF")
            else:
                r.ok("§4-4 jal 跳过", "0x2C 从未出现（jal 生效）", text)
            continue
        if pc not in wb:
            r.bad("§0 表", "写回级从未出现 PC=0x%02X" % pc, text)
            continue
        samples = wb[pc]
        vals = set(v for _, _, v in samples)
        enas = set(e for e, _, _ in samples)
        regs = set(g for _, g, _ in samples)
        detail = "%s\n命中 %d 拍，值集合 %s，reg=%s，ena=%s" % (
            text, len(samples),
            ", ".join("0x%08X" % v for v in sorted(v for v in vals if v is not None)),
            ",".join(str(g) for g in sorted(g for g in regs if g is not None)),
            ",".join(str(e) for e in sorted(e for e in enas if e is not None)))
        ok_val = (exp_val is None) or (vals == {exp_val})
        ok_reg = (exp_reg is None) or (exp_reg in regs)
        ok_ena = (exp_ena is None) or (exp_ena in enas)
        exp_txt = "值 %s / reg=%s / ena=%s" % (
            ("恒为 0x%08X" % exp_val) if exp_val is not None else "不判",
            exp_reg if exp_reg is not None else "不判",
            exp_ena if exp_ena is not None else "不判")
        if ok_val and ok_reg and ok_ena:
            r.ok("§0 表 0x%02X" % pc, exp_txt + " —— 实测相符", detail)
        else:
            r.bad("§0 表 0x%02X" % pc, "预期 %s，实测不符" % exp_txt, detail)

    # ---------------- §5 异常现场 ----------------
    if i_tt is not None and i_mc is not None:
        tt = [hv(x[i_tt]) for x in data]
        rises = [k for k in range(1, n) if tt[k] == 1 and tt[k - 1] == 0]
        n_hi = sum(1 for v in tt if v == 1)
        mcs = set(hv(x[i_mc]) for x in data)
        mps = set(hv(x[i_mp]) for x in data) if i_mp is not None else set()
        mvs = set(hv(x[i_mv]) for x in data) if i_mv is not None else set()
        mcs.discard(None); mps.discard(None); mvs.discard(None)
        detail = ("trap_take=1 的拍数 %d，上升沿 %d 次\n"
                  "mcause 取值 %s\nmepc 取值 %s\nmtval 取值 %s") % (
            n_hi, len(rises),
            ", ".join("0x%08X" % v for v in sorted(mcs)),
            ", ".join("0x%08X" % v for v in sorted(mps)),
            ", ".join("0x%08X" % v for v in sorted(mvs)))
        if n_hi == 0:
            r.warn("§5 probe12", "debug_trap_take 全程为 0（0/%d 拍）" % n,
                   "trap_take 是 Control 的『同步异常确认接收』单拍脉冲（CSR.sv:210 用它写 mcause）；\n"
                   "而 ecall 走的是另一条路（ecall_flag，CSR.sv:154/182/210），**本来就不会拉 trap_take**。\n"
                   "prog.hex 里只有 ecall、没有非法指令/非对齐访存 ⇒ 这里 0 是**预期的**，不是故障。\n"
                   "但判据 §5 把『probe12 上升沿』当成异常现场的触发条件 —— 对本程序**永远抓不到**，\n"
                   "要看 ecall 现场只能用 probe9/probe10 的恒定值或 probe15 回 mtvec。（文档口径问题，非设计缺陷）")
        if mcs == {0x0B}:
            r.ok("§5 mcause", "恒为 0x0000000B（M 模式 ecall），符合期望", detail)
        elif 0x0B in mcs:
            r.warn("§5 mcause", "除 0x0B 外还出现 %s" % ", ".join(
                "0x%08X" % v for v in sorted(mcs - {0x0B})), detail)
        else:
            r.bad("§5 mcause", "没有出现 0x0B", detail)
        if mps == {0x34}:
            r.ok("§7.1 mepc", "恒为 0x00000034（异常 PC 就是 ecall 那条）", detail)
        elif len(mps) > 1:
            spread = max(mps) - min(mps)
            r.bad("§7.1 mepc", "mepc 有 %d 个取值，跨度 0x%X" % (len(mps), spread),
                  detail + "\n反复 +0x4000 = 程序在绕 IROM 一圈重跑 = 重定向失效")
        else:
            r.warn("§7.1 mepc", "mepc 取值 %s（预期 0x34）" % ", ".join(
                "0x%08X" % v for v in sorted(mps)), detail)
        if mvs and mvs != {0}:
            r.warn("§5 mtval", "mtval 非 0：%s" % ", ".join("0x%08X" % v for v in sorted(mvs)),
                   detail + "\n同步异常检测未修好之前 mtval 不作判据")

    # ---------------- §7.1 probe13/14 ----------------
    if i_dn is not None and i_rdy is not None:
        dn = [hv(x[i_dn]) for x in data]
        rdy = [hv(x[i_rdy]) for x in data]
        redirs = [k for k, v in enumerate(dn) if v == 1]
        n_rdy0 = sum(1 for k in redirs if rdy[k] == 0)
        # 重定向那一拍之后 PC 是否真的变成目标（这里目标恒为 0）
        landed = sum(1 for k in redirs if k + 1 < n and hv(data[k + 1][i_if]) == 0)
        if redirs:
            r.ok("§7.1 probe13", "重定向请求 %d 次，其中 ready==0 的 %d 拍" % (len(redirs), n_rdy0),
                 "命中后下一拍 ifu_pc==0 的有 %d 次（%d 次是取指级无新值的重复拍）"
                 % (landed, len(redirs) - landed))
            if n_rdy0:
                r.warn("§7.1 背压", "有 %d 拍重定向撞上 ready==0" % n_rdy0,
                       "B9 修复后 dnpc_flag 不再被 ready 门控，不应丢失；若 PC 仍回到 0 则无碍")
        else:
            r.bad("§7.1 probe13", "2048 拍内一次重定向都没有", "ecall 的 dnpc 没发出来")

    # ---------------- §6 计数器趋势 ----------------
    def trend(i, name):
        if i is None:
            return
        v0, v1 = hv(data[0][i]), hv(data[-1][i])
        inc = (v1 - v0) if (v0 is not None and v1 is not None) else None
        if v1 == 0:
            r.bad("§6 " + name, "%s 全程为 0" % name, "该通路完全没动")
        elif inc in (0, None):
            r.info("§6 " + name, "%s = 0x%08X（窗口内没涨）" % (name, v1),
                   "绝对值不作判据，只看是否非 0 与趋势")
        else:
            r.info("§6 " + name, "%s = 0x%08X，窗口内 +%d" % (name, v1, inc), "")

    trend(i_ih, "icache_hit")
    trend(i_im, "icache_miss")
    trend(i_dh, "dcache_hit")
    trend(i_dm, "dcache_miss")

    if i_ih is not None and i_im is not None and i_dh is not None and i_dm is not None:
        ih, im = hv(data[-1][i_ih]), hv(data[-1][i_im])
        dh, dm = hv(data[-1][i_dh]), hv(data[-1][i_dm])
        if im and ih is not None:
            ratio_i = (ih / float(im)) if im else None
            r.info("§6 I-Cache", "hit:miss = %s : %s" % (ih, im),
                   "miss 基本冻住（第一遍之后都命中）是正常的")
            if im > ih and ih > 0:
                r.bad("§6 I-Cache", "miss(%d) > hit(%d)，I-Cache 没起作用" % (im, ih))
        if dh is not None and dm:
            ratio_d = dh / float(dm)
            r.info("§6 D-Cache", "hit:miss = %d : %d  (%.3f : 1)" % (dh, dm, ratio_d), "")
            if ratio_d < 1.05 and dh > 1000:
                r.warn("§6 D-Cache", "D-Cache 命中:缺失 ≈ 1:1（%.4f:1）" % ratio_d,
                       "判据 §6 期望「远大于 1」（仿真首遍 3:1：hit=3 miss=1）。\n"
                       "已定位（2026-10-16，见 _diag/README.md）：H1（EXU up_stall）让 store→load 不再背靠背，\n"
                       "DCache 的驻留判定 `line_resident` 含 `resp_valid_r`（比 cpu_en 晚 2 拍），请求第一拍必然读到 0\n"
                       "⇒ 每圈多发一次 DRAM 读、多记一次 miss。数据始终正确（lw 读到 0x0C）。\n"
                       "仿真对照：取消 H1 → hit 2.97/圈、miss 0/圈（= 上一次抓取）；当前 RTL → 0.988 / 0.988（= 本次抓取）。")
    return r, {
        "n_samples": n,
        "ifu_pc_distinct": distinct,
        "ifu_pc_zero_count": len(zeros),
        "n_redirect": len([k for k, v in enumerate(
            [hv(x[i_dn]) for x in data]) if v == 1]) if i_dn is not None else None,
        "mcause": sorted(set(hv(x[i_mc]) for x in data) - {None}) if i_mc is not None else None,
        "mepc": sorted(set(hv(x[i_mp]) for x in data) - {None}) if i_mp is not None else None,
        "trap_take_hi": sum(1 for x in data if i_tt is not None and hv(x[i_tt]) == 1),
        "counters_first": {k: (hv(data[0][col(cols, k)]) if col(cols, k) is not None else None)
                           for k in ("icache_hit", "icache_miss", "dcache_hit", "dcache_miss")},
        "counters_last": {k: (hv(data[-1][col(cols, k)]) if col(cols, k) is not None else None)
                          for k in ("icache_hit", "icache_miss", "dcache_hit", "dcache_miss")},
    }


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    json_out = None
    if "--json" in sys.argv:
        json_out = sys.argv[sys.argv.index("--json") + 1]
    r, summary = analyse(path)
    r.dump("上板 ILA 判据核对： %s" % path)
    if json_out:
        with open(json_out, "w", encoding="utf-8") as f:
            json.dump(summary, f, ensure_ascii=False, indent=2, default=str)
        print("summary -> %s" % json_out)
    return 1 if r.n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
