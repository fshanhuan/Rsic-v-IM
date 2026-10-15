#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_anchors.py — 交叉引用完整性：RTL 里写的 `§XXX-N` 锚点在归档文档里真的存在吗？

为什么需要：
  本次注释迭代的核心手法是"**精简 + 指针**"——
  RTL 里只留 2~5 行结论，细节用 `见 syn/修复史_全量.md §IFU-1` 指过去。
  **指针指空比不写指针更糟**：读者按图索骥找不到东西，就会以为"细节已经丢了"，
  于是重新去翻 git/聊天记录，精简的收益全没了。

本脚本做两件事：
  1. 从 25 个源文件里抓出所有 `§<锚点>` 引用（大小写不敏感）；
  2. 从 syn/修复史_全量.md 里抓出所有已存在的 `<锚点>`（形如 `## IFU-1：...`）；
  3. 报告：悬空引用（RTL 指了但文档没有）、孤儿章节（文档有但没人引用）。

用法：
  python tools/check_anchors.py
  python tools/check_anchors.py --orphans     # 额外列出没人引用的章节
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

CANON = r"E:\share doc\v9"
DOCS = [os.path.join(r"E:\share doc\v9\syn", "修复史_全量.md"),
        os.path.join(ROOT, "syn", "修复史_全量.md")]

RTL = os.path.join(CANON, "rtl")     # 2026-10 整理：21 个 CPU RTL 统一在这里

FILES = [
    ("IFU.sv", RTL), ("ICache.sv", RTL), ("Branch_Predictor.sv", RTL),
    ("Data_hazard.sv", RTL), ("IDU.sv", RTL), ("Reg_Stack.sv", RTL),
    ("RegisterFile.sv", RTL), ("Reg.sv", RTL), ("EXU.sv", RTL),
    ("ALU.sv", RTL), ("add.sv", RTL), ("sext.sv", RTL),
    ("LSU.sv", RTL), ("DCache.sv", RTL), ("WBU.sv", RTL),
    ("Control.sv", RTL), ("CSR.sv", RTL), ("para.sv", RTL),
    ("myCPU.sv", RTL),
    ("MDU_pipelined.sv", RTL),
    ("board_top.sv", os.path.join(CANON, "board")),
    ("board_top_ila.sv", os.path.join(CANON, "board")),
    ("sync_mem.sv", os.path.join(CANON, "board")),
    ("reset_sync.sv", os.path.join(CANON, "board")),
    ("board_top_gui.sv", ROOT),
]

# 只认"看起来像锚点"的：大写字母/数字 + 短横线 + 数字，例如 IFU-1 / CONTROL-5 / MDU-3
ANCHOR_RE = re.compile(r"§\s*([A-Z][A-Z0-9_]*-\d+[a-z]?)", re.I)
# 文档里的章节标题：`## IFU-1：...` 或 `## IFU-1 ...`
HEAD_RE = re.compile(r"^#{2,4}\s+([A-Z][A-Z0-9_]*-\d+[a-z]?)\b", re.I | re.M)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    show_orphans = "--orphans" in sys.argv

    doc = None
    for d in DOCS:
        if os.path.exists(d):
            doc = d
            break
    if not doc:
        print("!! 找不到 syn/修复史_全量.md（先跑 tools/assemble_fix_history.py）")
        return 2
    with open(doc, "r", encoding="utf-8", errors="replace") as f:
        dtext = f.read()
    heads = set(h.upper() for h in HEAD_RE.findall(dtext))
    print("归档文档: %s" % doc)
    print("文档里的章节数 = %d" % len(heads))

    refs = {}          # 锚点 -> [文件...]
    n_src_with_ref = 0
    for name, d in FILES:
        p = os.path.join(d, name)
        if not os.path.exists(p):
            continue
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            txt = f.read()
        found = set(a.upper() for a in ANCHOR_RE.findall(txt))
        if found:
            n_src_with_ref += 1
        for a in found:
            refs.setdefault(a, []).append(name)

    print("有 §锚点 引用的源文件数 = %d，引用到的不同锚点数 = %d"
          % (n_src_with_ref, len(refs)))
    print("")

    dangling = sorted(a for a in refs if a not in heads)
    if dangling:
        print("!! 悬空引用（RTL 指了，但文档里没有这一节）—— 必须补上或改指针：")
        for a in dangling:
            print("     §%-14s ← %s" % (a, ", ".join(refs[a])))
    else:
        print("悬空引用：无 —— 所有 §锚点 都指向存在的章节 OK")

    if show_orphans:
        orphans = sorted(h for h in heads if h not in refs)
        print("")
        print("孤儿章节（文档有、但没有任何 RTL 引用它）共 %d 个：" % len(orphans))
        for h in orphans:
            print("     %s" % h)

    print("")
    ok = not dangling

    # ------------------------------------------------------------------
    # 追加检查：注释里引用的**文件路径**能不能落地（同属"指针"问题）
    #   RTL 注释里常见 `见 syn/修复史_全量.md` / `见 docs/模块阅读文档.md`。
    #   路径写错或文件被改名，指针一样是死的。两种布局都要认：
    #     仓库正本布局：  v9/syn/...   v9/docs/...
    #     工作目录布局：  v9_vivado_ila/syn/...   v9_vivado_ila/docs/vivado/...
    # ------------------------------------------------------------------
    # ★ 后缀后面必须不是标识符字符 —— 否则会把**端口引用**误判成文件名：
    #   `EXU.valid_last` 里的 `.v`、`IFU.valid` 里的 `.v` 都会被贪婪匹配成 "EXU.v"/"IFU.v"。
    #   （这个误报是本工具第一版真实踩过的，靠人工看上下文才发现。）
    DOCREF_RE = re.compile(
        r"([A-Za-z0-9_./\\\u4e00-\u9fff-]+\.(?:md|txt|tcl|xdc|sdc|hex|py|sv|svh|v|vh|do))"
        r"(?![A-Za-z0-9_])")
    refs2 = {}
    for name, d in FILES:
        p = os.path.join(d, name)
        if not os.path.exists(p):
            continue
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            txt = f.read()
        for m in DOCREF_RE.findall(txt):
            refs2.setdefault(m.replace("\\", "/"), set()).add(name)

    # 两种布局 + 所有子目录都要作为候选基目录，否则 `board_top.sv` 这种
    # 「同目录内互相引用」会被误报成死指针。
    bases = []
    for root in (CANON, ROOT):
        for sub in ("", "rtl", "syn", "docs", "docs/vivado", "sim", "board",
                    "experimental", "project_src", "msim", "teach"):
            bases.append(os.path.join(root, *sub.split("/")))
    dead = []
    for ref, srcs in sorted(refs2.items()):
        cand = [os.path.join(b, ref) for b in bases] + [ref]
        if not any(os.path.exists(c) for c in cand):
            dead.append((ref, sorted(srcs)))

    print("")
    print("注释里引用的文件路径共 %d 个，落地失败 %d 个" % (len(refs2), len(dead)))
    if dead:
        print("!! 路径指针指空（下列路径在两种布局里都找不到）：")
        for ref, srcs in dead:
            print("     %-38s ← %s" % (ref, ", ".join(srcs)))
    else:
        print("路径指针：全部可落地 OK")
    ok = ok and not dead

    print("")
    print("判定：%s" % ("PASS —— 指针都能落地" if ok else "FAIL —— 有指针指空"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
