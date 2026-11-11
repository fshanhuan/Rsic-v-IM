# -*- coding: utf-8 -*-
"""check_mem_doc.py — 交付前自检：讲义里不该出现的东西 + 关键数字/图表都在。"""
import sys

import docx

p = sys.argv[1] if len(sys.argv) > 1 else "docs/存储器专题_研讨.docx"
d = docx.Document(p)
txt = "\n".join(x.text for x in d.paragraphs)
tbl = "\n".join(c.text for t in d.tables for r in t.rows for c in r.cells)
allt = txt + "\n" + tbl

fails = []
for bad, why in [("`", "反引号没去掉"), ("**", "markdown 星号没去掉"),
                 ("TODO", "占位符")]:
    n = allt.count(bad)
    print("  %-6r %d  %s" % (bad, n, why))
    if n:
        fails.append(bad)

must = ["620/620", "434 拍", "115.2 kbit/s", "0x0002_0000", "0x1000_0000",
        "66.5", "36 150", "UNCACHE_MASK", "34 条指令", "22 条自检"]
for m in must:
    ok = m in allt
    print("  %-14s %s" % (m, "有" if ok else "缺!"))
    if not ok:
        fails.append(m)

figs = [n for n in ["M1", "M2", "M3", "M4", "M5", "M6", "M7", "M8", "M9"] if "图 " + n in allt]
print("  图的引用：", figs)
imgs = [r for r in d.part.rels.values() if "image" in r.reltype]
print("  内嵌图片 %d 张，表格 %d 张，段落 %d 个，字符 %d" % (len(imgs), len(d.tables), len(d.paragraphs), len(allt)))

if fails:
    print("FAIL:", fails)
    sys.exit(1)
print("OK")
