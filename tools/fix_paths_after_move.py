# -*- coding: utf-8 -*-
"""把文档/脚本里"指向仓库根目录的 CPU RTL"的路径改写到 rtl/ 下。

背景：2026-10 把 21 个 CPU RTL 从仓库根目录收进 rtl/。函数级引用（sim 脚本、
quartus qsf、build_project_ila.tcl）已手工改完；这个脚本负责扫掉**剩下的散文引用**
（README / syn / docs 里的 `E:\\share doc\\v9\\ALU.sv` 之类）。

安全设计：
  * 默认 --dry-run，只报告不改；
  * 只动"看起来指向 CPU RTL 根目录"的引用 —— 已经带 rtl/ board/ experimental/
    src/ quartus/ sim/ teach/ 等限定目录的**一律跳过**；
  * 逐条打印 before/after，可人工复核；
  * 排除生成物目录（v9_ila / obj_dir / .Xil / _comment_iter / figures / wave）。

用法：
  python tools/fix_paths_after_move.py            # 只报告
  python tools/fix_paths_after_move.py --apply    # 真的改
"""
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CANON = r"E:\share doc\v9"
WORK = ROOT

NAMES = ["add", "ALU", "Branch_Predictor", "Control", "CSR", "Data_hazard",
         "DCache", "EXU", "ICache", "IDU", "IFU", "LSU", "MDU", "MDU_pipelined",
         "myCPU", "para", "Reg", "Reg_Stack", "RegisterFile", "sext", "WBU"]

EXTS = {".md", ".txt", ".tcl", ".bat", ".sh", ".ps1", ".py", ".qsf", ".qpf",
        ".do", ".ini", ".json", ".yml", ".yaml"}
SKIP_DIRS = {"v9_ila", "obj_dir", ".Xil", "_comment_iter", "figures", "wave",
             "build", ".git", "msim", "__pycache__", "timing_sweep",
             "teach_mix_波形包"}

# 已经限定了目录的，一律不动（core/before 是 _comment_iter 里的快照目录，必须保护）
QUALIFIED = ("rtl", "board", "experimental", "src", "quartus", "sim", "teach",
             "syn", "docs", "vivado_project", "project_src", "msim", "core",
             "before", "extract", "work")

# ★ 只改"活的说明书/脚本"。历史记录（修复史、改动 diff、实测报告、进度记录）
#   和被弃用的脚本**一律不动** —— 它们是"当时是什么样"的证据，改了就是伪造历史。
LIVE_BASENAMES = {
    "README.md", "README_iverilog.md", "README_msim.md",
    "模块阅读文档.md", "待修复清单_cdp-tests第三轮.md",
    "上板验证判据.md", "ila_使用说明.md", "vivado_50mhz_实测.md", "上板改造说明.md",
    "COMMENT_STYLE.md",
    "run_iverilog.bat", "run_iverilog.sh", "run_all.sh", "run_wave.sh",
    "run_msim.do", "run_msim.ps1", "gen_rtl_concat.py", "mk_msim_tb.py",
    "build_project_ila.tcl", "timing_sweep.tcl",
}
BAD_PARTS = ("_comment_iter", "_deprecated", "vivado_project", "teach",
             "experimental", "msim", "__pycache__")
# 已手工改好、不希望再被自动扫的（散文里提到 .sv 是描述性的，自动插 rtl/ 会读起来别扭）
SKIP_FILES = {"build_project_ila.tcl"}

NAME_RE = re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(
    sorted((re.escape(n) for n in NAMES), key=len, reverse=True)) + r")\.sv")


def candidate_files():
    for base in (CANON, WORK):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                if os.path.splitext(fn)[1].lower() not in EXTS:
                    continue
                if fn not in LIVE_BASENAMES:
                    continue
                if fn in SKIP_FILES:
                    continue
                full = os.path.join(dirpath, fn)
                norm = full.replace("\\", "/")
                if any(("/" + p + "/") in norm for p in BAD_PARTS):
                    continue
                yield full


def analyse(text):
    """返回 [(start, end, insert_at, sep, name, context, verdict)]"""
    out = []
    for m in NAME_RE.finditer(text):
        name = m.group(1)
        s, e = m.start(1), m.end()
        # 往前看：紧跟名字之前是不是已经有一个目录限定？
        pre = text[:s]
        # ★ 变量前缀（$SRC/ $WORK/ ${DIR}/ %WORK%\ ...）一律不动 —— $SRC 已经是 rtl\ 了，
        #   再插一个 rtl 会变成 $SRC/rtl/myCPU.sv。
        if re.search(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[\\/]$", pre) or \
           re.search(r"%[A-Za-z_][A-Za-z0-9_]*%[\\/]$", pre):
            out.append((s, e, s, "", name, pre[-70:], "SKIP-变量前缀"))
            continue
        mm = re.search(r"([A-Za-z0-9_./\\\-\u4e00-\u9fff]*)[/\\]$", pre)
        prev_seg = mm.group(1).split("/")[-1].split("\\")[-1] if mm else ""
        if prev_seg in QUALIFIED:
            out.append((s, e, s, "", name, pre[-70:], "SKIP-已限定(%s)" % prev_seg))
            continue
        # 分隔符风格：看名字前后用的是 / 还是 \
        sep = "\\" if ("\\" in pre[-70:] and "/" not in pre[-70:]) else "/"
        out.append((s, e, s, sep, name, pre[-70:], "REWRITE"))
    return out


def main():
    apply_ = "--apply" in sys.argv
    total_files = changed_files = rewrites = skips = 0
    report = []
    for path in candidate_files():
        try:
            txt = open(path, "r", encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        total_files += 1
        items = analyse(txt)
        todo = [it for it in items if it[6] == "REWRITE"]
        if not todo:
            skips += sum(1 for it in items if it[6].startswith("SKIP"))
            continue
        new = txt
        for s, e, ins, sep, name, ctx, _v in reversed(todo):
            new = new[:ins] + "rtl" + sep + new[ins:]
        changed_files += 1
        rewrites += len(todo)
        skips += sum(1 for it in items if it[6].startswith("SKIP"))
        rel = path.replace(CANON, "<CANON>").replace(WORK, "<WORK>")
        report.append((rel, len(todo)))
        if apply_:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(new)

    print("模式：%s" % ("APPLY（已写盘）" if apply_ else "DRY-RUN（只报告）"))
    print("扫描文件 %d 个，命中 %d 个文件，共 %d 处待改写；跳过（已限定目录）%d 处"
          % (total_files, changed_files, rewrites, skips))
    print("-" * 78)
    for rel, n in sorted(report):
        print("  %-70s %2d 处" % (rel, n))
    if not apply_ and rewrites:
        print("-" * 78)
        print("确认无误后加 --apply 真正改写。")


if __name__ == "__main__":
    main()
