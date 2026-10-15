#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
acceptance_report.py — 注释迭代的**验收总表**（一条命令出全部证据）

汇总五个维度：
  1. 代码等价性   —— 只改了注释？（机械证明，来自 check_all 的同款算法）
  2. 注释预算     —— 每个文件落在 tools/COMMENT_STYLE.md §7.1 的上限内？
  3. 两树一致性   —— 仓库正本 vs 工作目录副本字节一致？
  4. 知识覆盖率   —— 删掉的注释都搬进 extract 了吗？（调 check_extract_coverage）
  5. 编码         —— 中文注释没变乱码？（调 check_encoding）

用法：
  python tools/acceptance_report.py
  python tools/acceptance_report.py --csv out.csv     # 额外导出明细
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from strip_sv_comments import strip, normalize      # noqa: E402
from check_extract_coverage import comment_text, current_path   # noqa: E402

SNAP = os.path.join(ROOT, "_comment_iter", "before")
WORK = ROOT
CANON = r"E:\share doc\v9"
PY = sys.executable

# tools/COMMENT_STYLE.md §7.1 的上限表（单一权威在这里，改预算只改这一处）
BUDGET = {
    # ★ 2026-10 第二次预算修正（见 tools/COMMENT_STYLE.md §7.6）：
    #   H1/H2/H3 三个**真实缺陷修复**带来的"不许改回去"说明是新知识，不是注释膨胀。
    #   这 4 个文件因此各涨了几行（EXU +12 / DCache +10 / MDU_pipelined +10 / myCPU +2），
    #   预算同步上调并留少量余量。
    "Control.sv": 120, "EXU.sv": 105, "board_top_ila.sv": 75, "myCPU.sv": 140,
    "DCache.sv": 90, "IDU.sv": 85, "board_top.sv": 68, "ICache.sv": 60,
    "IFU.sv": 50, "Data_hazard.sv": 55, "CSR.sv": 75, "board_top_gui.sv": 60,
    "MDU_pipelined.sv": 55, "para.sv": 65, "sync_mem.sv": 45,
    "Branch_Predictor.sv": 45, "LSU.sv": 75, "reset_sync.sv": 25, "WBU.sv": 35,
    "Reg_Stack.sv": 35, "RegisterFile.sv": 15, "ALU.sv": 18, "add.sv": 6,
    "Reg.sv": 10, "sext.sv": 6,
}
# 改动前基线（tools/check_all.py 首次运行得到，用于算降幅）
BASELINE = {
    "Control.sv": 206, "EXU.sv": 146, "board_top_ila.sv": 140, "myCPU.sv": 133,
    "DCache.sv": 120, "IDU.sv": 116, "board_top.sv": 88, "ICache.sv": 84,
    "IFU.sv": 81, "Data_hazard.sv": 75, "CSR.sv": 74, "board_top_gui.sv": 73,
    "MDU_pipelined.sv": 55, "para.sv": 54, "sync_mem.sv": 54,
    "Branch_Predictor.sv": 38, "LSU.sv": 38, "reset_sync.sv": 28, "WBU.sv": 16,
    "Reg_Stack.sv": 15, "RegisterFile.sv": 8, "ALU.sv": 6, "add.sv": 3,
    "Reg.sv": 2, "sext.sv": 1,
}

# ★ 有意改动的文件（**真实缺陷修复**，不是注释迭代）。
#   这些文件与"注释迭代前快照"代码不同是**预期**的；**其它**文件若也不同，才是写坏了。
#   归档：syn/修复史_全量.md §EXU-11 / §DCACHE-6；验证：官方 cdp-tests 39/39。
INTENTIONAL = {
    "EXU.sv":    "H1：新增 up_stall 接收门控（§EXU-11）",
    "myCPU.sv":  "H1：接 .up_stall(IFU_stall)",
    "DCache.sv": "H2：读窗口整字 mask（§DCACHE-6）",
}


def work_copy(rel):
    rel = rel.replace("/", os.sep)
    d, name = os.path.split(rel)
    if d == "core":
        return os.path.join(WORK, "rtl", name)
    if d == "board":
        return os.path.join(WORK, "board", name)
    if d == "work":
        return os.path.join(WORK, "project_src", name)
    return None


def code_of(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return normalize(strip(f.read()))


def clines(p):
    n = 0
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        for ln in f:
            t = ln.strip()
            if t.startswith("//") or t.startswith("/*") or t.startswith("*"):
                n += 1
    return n


def star_count(p):
    """★ 不变量 / ★ 接口契约 标记数（A 类显式化的程度）"""
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        s = f.read()
    return len(re.findall(r"★\s*(?:不变量|接口契约)", s))


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    man = os.path.join(ROOT, "_comment_iter", "manifest_before.tsv")
    entries = []
    with open(man, "r", encoding="utf-8-sig") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) >= 2:
                entries.append(p[0].lstrip("\ufeff"))

    rows = []
    sum_before = sum_after = 0
    n_code_bad = n_budget_bad = n_sync_bad = n_star = n_missing = n_intentional = 0
    for rel in entries:
        name = os.path.basename(rel)
        old = os.path.join(SNAP, rel.replace("/", os.sep))
        new = current_path(rel)
        if not new or not os.path.exists(new):
            # ★ 不许静默跳过 —— 文件不在就是真问题，必须显式暴露。
            #   实测踩到过：board_top_gui.sv 挪了位置之后这里默默 continue，
            #   报表少一行、合计悄悄变小，看上去仍然"全绿"。
            print("!! 报表缺行（文件不存在）：%-34s -> %s" % (rel, new))
            n_missing += 1
            continue
        same = code_of(old) == code_of(new)
        nb, na = BASELINE.get(name), clines(new)
        bud = BUDGET.get(name)
        ok_bud = (bud is None) or (na <= bud)
        wc = work_copy(rel)
        sync = True
        if wc and os.path.exists(wc):
            with open(new, "rb") as a, open(wc, "rb") as b:
                sync = (a.read() == b.read())
        st = star_count(new)
        n_star += st
        if same:
            pass
        elif name in INTENTIONAL:
            n_intentional += 1          # 有意修复，不算"写坏了"
        else:
            n_code_bad += 1
        n_budget_bad += (not ok_bud)
        n_sync_bad += (not sync)
        sum_before += (nb or 0)
        sum_after += na
        rows.append((name, nb, na, bud, ok_bud, same, sync, st))

    rows.sort(key=lambda r: (-(r[2] - (r[1] or 0)), r[0]))

    print("=" * 100)
    print("v9 注释迭代 · 验收总表")
    print("=" * 100)
    print("%-24s %6s %6s %7s %8s %6s %7s %6s %s"
          % ("文件", "改前", "现在", "Δ", "预算", "超限", "代码仅注释", "两树", "★不变量"))
    print("-" * 100)
    for name, nb, na, bud, ok_bud, same, sync, st in rows:
        d = (na - nb) if nb is not None else None
        print("%-24s %6s %6s %7s %8s %6s %7s %6s %6d"
              % (name, nb if nb is not None else "-", na,
                 ("%+d" % d) if d is not None else "-",
                 bud if bud else "-",
                 "" if ok_bud else "<<<<",
                 "OK" if same else ("有意修复" if name in INTENTIONAL else "FAIL<<<<"),
                 "OK" if sync else "待同步",
                 st))
    print("-" * 100)
    print("注释行数合计：%d -> %d  (%+d, %+.1f%%)"
          % (sum_before, sum_after, sum_after - sum_before,
             100.0 * (sum_after - sum_before) / max(sum_before, 1)))
    print("★ 不变量 / 接口契约 标记总数（改动前为 0，这些标记是本次新增的显式化）：%d" % n_star)

    print("")
    print("---- 外部检查 ----")
    rc1, o1 = run([PY, os.path.join(HERE, "check_extract_coverage.py")])
    last1 = [l for l in o1.strip().splitlines() if l.strip()][-2:]
    print("[知识覆盖率]")
    for l in last1:
        print("   " + l)
    rc2, o2 = run([PY, os.path.join(HERE, "check_encoding.py")])
    last2 = [l for l in o2.strip().splitlines() if l.strip()][-1:]
    print("[编码]")
    for l in last2:
        print("   " + l)
    rc3, o3 = run([PY, os.path.join(HERE, "check_anchors.py")])
    last3 = [l for l in o3.strip().splitlines() if l.strip()][-1:]
    print("[交叉引用（§锚点能不能落地）]")
    for l in last3:
        print("   " + l)

    print("")
    print("=" * 100)
    verdict = []
    verdict.append(("代码等价（只改注释）", n_code_bad == 0,
                    "%d 个非预期改动；另有 %d 个有意修复(H1/H2)" % (n_code_bad, n_intentional)))
    verdict.append(("注释预算", n_budget_bad == 0, "%d 个文件超上限" % n_budget_bad))
    verdict.append(("两树一致", n_sync_bad == 0, "%d 个文件待同步" % n_sync_bad))
    verdict.append(("报表完整（无缺行）", n_missing == 0, "%d 个文件缺行" % n_missing))
    verdict.append(("知识覆盖率", rc1 == 0, "见上"))
    verdict.append(("编码无乱码", rc2 == 0, "见上"))
    verdict.append(("§锚点可落地", rc3 == 0, "见上"))
    for name, ok, extra in verdict:
        print("  %-22s %s   %s" % (name, "PASS" if ok else "FAIL", extra))
    allok = all(v[1] for v in verdict)
    print("=" * 100)
    print("总判定：%s" % ("PASS —— 注释迭代达标" if allok else "FAIL —— 见上面 FAIL 项"))
    if "--csv" in sys.argv:
        p = sys.argv[sys.argv.index("--csv") + 1]
        with open(p, "w", encoding="utf-8-sig", newline="") as f:
            f.write("文件,改前,现在,差值,预算,超限,代码仅注释,两树,星不变量\n")
            for name, nb, na, bud, ok_bud, same, sync, st in rows:
                f.write("%s,%s,%s,%s,%s,%s,%s,%s,%d\n"
                        % (name, nb, na, (na - nb) if nb is not None else "",
                           bud or "", "" if ok_bud else "超限",
                           "OK" if same else "FAIL", "OK" if sync else "待同步", st))
        print("明细已导出: %s" % p)
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
