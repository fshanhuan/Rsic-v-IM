# -*- coding: utf-8 -*-
"""pdf2png.py — 把 PDF 每页渲染成 PNG（校验排版用，PyMuPDF）。

用法: python sim/pdf2png.py sim/build/memdoc.pdf sim/build/pages 120
"""
import os
import sys

import fitz

pdf = sys.argv[1]
out = sys.argv[2]
dpi = int(sys.argv[3]) if len(sys.argv) > 3 else 110
os.makedirs(out, exist_ok=True)
doc = fitz.open(pdf)
print("pages", doc.page_count)
for i, page in enumerate(doc):
    pix = page.get_pixmap(dpi=dpi)
    p = os.path.join(out, "p%02d.png" % (i + 1))
    pix.save(p)
    print("wrote", p, pix.width, "x", pix.height)
