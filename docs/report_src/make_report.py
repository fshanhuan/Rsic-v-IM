# -*- coding: utf-8 -*-
"""Build the BigBird RV32 v17 product report (DOCX)."""
import os
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.section import WD_SECTION
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FIG = os.path.join(ROOT, "figures")
OUT = os.path.join(ROOT, "docs",
                   os.environ.get("REPORT_OUT", "BigBird_RV32_产品报告_v17.docx"))

NAVY = RGBColor(0x1F, 0x4E, 0x79)
INK = RGBColor(0x26, 0x26, 0x26)
GREY = RGBColor(0x59, 0x59, 0x59)
LIGHTGREY = RGBColor(0x80, 0x80, 0x80)

doc = Document()

# ------------------------------------------------------------------ page setup
sec = doc.sections[0]
sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
sec.top_margin, sec.bottom_margin = Cm(2.4), Cm(2.2)
sec.left_margin, sec.right_margin = Cm(2.3), Cm(2.3)
sec.header_distance, sec.footer_distance = Cm(1.3), Cm(1.2)
TEXT_W = 21.0 - 2.3 - 2.3  # 16.4 cm


def set_style_font(style, name, size, bold=False, color=INK):
    style.font.name = name
    style.font.size = Pt(size)
    style.font.bold = bold
    style.font.color.rgb = color
    rpr = style.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), name)
    rfonts.set(qn("w:hAnsi"), name)
    rfonts.set(qn("w:eastAsia"), name)


normal = doc.styles["Normal"]
set_style_font(normal, "宋体", 10.5)
normal.paragraph_format.line_spacing = 1.38
normal.paragraph_format.space_after = Pt(3)


def run_font(run, name="宋体", size=10.5, bold=False, color=INK, italic=False):
    run.font.name = name
    run.font.size = Pt(size)
    run.bold = bold
    run.italic = italic
    run.font.color.rgb = color
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), name)
    rfonts.set(qn("w:hAnsi"), name)
    rfonts.set(qn("w:eastAsia"), name)


def para(text="", style=None, size=10.5, bold=False, color=INK, name="宋体",
         indent=True, align=None, before=0, after=3, spacing=1.38):
    p = doc.add_paragraph(style=style)
    r = p.add_run(text)
    run_font(r, name, size, bold, color)
    pf = p.paragraph_format
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    pf.line_spacing = spacing
    if indent:
        pf.first_line_indent = Pt(size * 2)
    if align is not None:
        p.alignment = align
    return p


def rich(parts, indent=True, size=10.5, after=3, spacing=1.38, bullet=False):
    """parts: list of (text, bold) tuples."""
    p = doc.add_paragraph(style="List Bullet" if bullet else None)
    for text, bold in parts:
        r = p.add_run(text)
        run_font(r, "宋体", size, bold, INK if not bold else NAVY)
    pf = p.paragraph_format
    pf.space_before = Pt(0)
    pf.space_after = Pt(after)
    pf.line_spacing = spacing
    if indent and not bullet:
        pf.first_line_indent = Pt(size * 2)
    if bullet:
        pf.left_indent = Cm(0.75)
    return p


def para_border(p, edge="bottom", color="1F4E79", sz=8, space=2):
    pPr = p._p.get_or_add_pPr()
    pbdr = OxmlElement("w:pBdr")
    el = OxmlElement("w:%s" % edge)
    el.set(qn("w:val"), "single")
    el.set(qn("w:sz"), str(sz))
    el.set(qn("w:space"), str(space))
    el.set(qn("w:color"), color)
    pbdr.append(el)
    pPr.append(pbdr)
    _reorder(pPr, PPR_ORDER)


def H1(text):
    p = doc.add_paragraph(style="Heading 1")
    r = p.add_run(text)
    run_font(r, "黑体", 15.5, True, NAVY)
    pf = p.paragraph_format
    pf.space_before = Pt(17)
    pf.space_after = Pt(7)
    pf.keep_with_next = True
    para_border(p)
    return p


def H2(text):
    p = doc.add_paragraph(style="Heading 2")
    r = p.add_run(text)
    run_font(r, "黑体", 12, True, NAVY)
    pf = p.paragraph_format
    pf.space_before = Pt(11)
    pf.space_after = Pt(4)
    pf.keep_with_next = True
    return p


def H3(text):
    p = doc.add_paragraph(style="Heading 3")
    r = p.add_run(text)
    run_font(r, "黑体", 10.5, True, RGBColor(0x2E, 0x75, 0xB6))
    pf = p.paragraph_format
    pf.space_before = Pt(8)
    pf.space_after = Pt(3)
    pf.keep_with_next = True
    return p


def shade(cell, color):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), color)
    tcPr.append(shd)


TBLPR_ORDER = ["tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize",
               "tblStyleColBandSize", "tblW", "jc", "tblCellSpacing", "tblInd",
               "tblBorders", "shd", "tblLayout", "tblCellMar", "tblLook",
               "tblCaption", "tblDescription"]
PPR_ORDER = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr",
             "widowControl", "numPr", "suppressLineNumbers", "pBdr", "shd", "tabs",
             "suppressAutoHyphens", "kinsoku", "wordWrap", "overflowPunct", "topLinePunct",
             "autoSpaceDE", "autoSpaceDN", "bidi", "adjustRightInd", "snapToGrid", "spacing",
             "ind", "contextualSpacing", "mirrorIndents", "suppressOverlap", "jc",
             "textDirection", "textAlignment", "textboxTightWrap", "outlineLvl", "divId",
             "cnfStyle", "rPr", "sectPr", "pPrChange"]


def _reorder(parent, order):
    kids = list(parent)
    def key(el):
        tag = el.tag.split("}")[-1]
        return order.index(tag) if tag in order else 99
    for el in kids:
        parent.remove(el)
    for el in sorted(kids, key=key):
        parent.append(el)


def set_col_widths(t, widths):
    """Force a fixed layout with explicit grid columns (LibreOffice/Word both honour this)."""
    grid = t._tbl.tblGrid
    for i, gc in enumerate(grid.findall(qn("w:gridCol"))):
        gc.set(qn("w:w"), str(int(Cm(widths[i]).twips)))
    for row in t.rows:
        for i, cell in enumerate(row.cells):
            cell.width = Cm(widths[i])
    _reorder(t._tbl.tblPr, TBLPR_ORDER)


def table_borders(table, color="BFBFBF", sz=4):
    tbl = table._tbl
    tblPr = tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        el = OxmlElement("w:%s" % edge)
        el.set(qn("w:val"), "single")
        el.set(qn("w:sz"), str(sz))
        el.set(qn("w:space"), "0")
        el.set(qn("w:color"), color)
        borders.append(el)
    tblPr.append(borders)


def cell_margins(table, top=40, bottom=40, left=80, right=80):
    tblPr = table._tbl.tblPr
    mar = OxmlElement("w:tblCellMar")
    for edge, val in (("top", top), ("left", left), ("bottom", bottom), ("right", right)):
        el = OxmlElement("w:%s" % edge)
        el.set(qn("w:w"), str(val))
        el.set(qn("w:type"), "dxa")
        mar.append(el)
    tblPr.append(mar)


def repeat_header(row):
    trPr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:tblHeader")
    el.set(qn("w:val"), "true")
    trPr.append(el)


def no_split(row):
    trPr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:cantSplit")
    el.set(qn("w:val"), "true")
    trPr.append(el)


def spacer(pts=4):
    """Tiny empty paragraph: separates a table from the following text without wasting a line."""
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_before = Pt(0)
    pf.space_after = Pt(0)
    pf.line_spacing = 1.0
    pPr = p._p.get_or_add_pPr()
    rPr = OxmlElement("w:rPr")
    sz = OxmlElement("w:sz")
    sz.set(qn("w:val"), str(int(pts * 2)))
    rPr.append(sz)
    szcs = OxmlElement("w:szCs")
    szcs.set(qn("w:val"), str(int(pts * 2)))
    rPr.append(szcs)
    pPr.append(rPr)
    _reorder(pPr, PPR_ORDER)
    return p


def T(headers, rows, widths, align=None, fs=8.5, header_fill="1F4E79",
      zebra=True, caption=None):
    ncol = len(widths)
    assert sum(widths) <= TEXT_W + 0.01, (sum(widths), TEXT_W)
    if caption:
        CAP(caption)
    t = doc.add_table(rows=1, cols=ncol)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    table_borders(t)
    cell_margins(t)
    hdr = t.rows[0]
    repeat_header(hdr)
    for i, h in enumerate(headers):
        c = hdr.cells[i]
        c.width = Cm(widths[i])
        shade(c, header_fill)
        p = c.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(0)
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.line_spacing = 1.1
        r = p.add_run(h)
        run_font(r, "黑体", fs, True, RGBColor(0xFF, 0xFF, 0xFF))
    for ri, row in enumerate(rows):
        cells = t.add_row().cells
        no_split(t.rows[-1])
        for i, val in enumerate(row):
            c = cells[i]
            c.width = Cm(widths[i])
            if zebra and ri % 2 == 1:
                shade(c, "F4F7FB")
            p = c.paragraphs[0]
            a = (align[i] if align else "l")
            p.alignment = {"l": WD_ALIGN_PARAGRAPH.LEFT, "c": WD_ALIGN_PARAGRAPH.CENTER,
                           "r": WD_ALIGN_PARAGRAPH.RIGHT}[a]
            p.paragraph_format.space_before = Pt(0)
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.12
            bold = val.startswith("**") and val.endswith("**")
            text = val.replace("**", "")
            r = p.add_run(text)
            run_font(r, "宋体", fs, bold, INK)
    set_col_widths(t, widths)
    spacer()
    return t


def code(lines, fs=8.5):
    p = doc.add_paragraph()
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), "F5F5F5")
    pPr.append(shd)
    _reorder(pPr, PPR_ORDER)
    pf = p.paragraph_format
    pf.left_indent = Cm(0.5)
    pf.right_indent = Cm(0.2)
    pf.space_before = Pt(4)
    pf.space_after = Pt(6)
    pf.line_spacing = 1.15
    for i, line in enumerate(lines):
        r = p.add_run(line)
        run_font(r, "Consolas", fs, False, RGBColor(0x1A, 0x1A, 0x1A))
        if i != len(lines) - 1:
            r.add_break()
    return p


def CAP(text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    pf = p.paragraph_format
    pf.space_before = Pt(4)
    pf.space_after = Pt(3)
    pf.line_spacing = 1.0
    pf.keep_with_next = True
    r = p.add_run(text)
    run_font(r, "黑体", 8.5, False, GREY)
    return p


def caption_below(text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    pf = p.paragraph_format
    pf.space_before = Pt(2)
    pf.space_after = Pt(8)
    pf.line_spacing = 1.0
    r = p.add_run(text)
    run_font(r, "黑体", 8.5, False, GREY)
    return p


def figure(path, caption, width=14.6):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(0)
    p.paragraph_format.keep_with_next = True
    p.add_run().add_picture(path, width=Cm(width))
    caption_below(caption)


def callout(title, body, fill="EAF1F8", edge="1F4E79"):
    t = doc.add_table(rows=1, cols=1)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    tblPr = t._tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for e in ("top", "bottom", "right", "insideH", "insideV"):
        el = OxmlElement("w:%s" % e)
        el.set(qn("w:val"), "nil")
        borders.append(el)
    el = OxmlElement("w:left")
    el.set(qn("w:val"), "single")
    el.set(qn("w:sz"), "18")
    el.set(qn("w:space"), "0")
    el.set(qn("w:color"), edge)
    borders.append(el)
    tblPr.append(borders)
    cell_margins(t, top=80, bottom=80, left=140, right=120)
    c = t.rows[0].cells[0]
    c.width = Cm(TEXT_W)
    shade(c, fill)
    no_split(t.rows[0])
    p = c.paragraphs[0]
    p.paragraph_format.space_before = Pt(0)
    p.paragraph_format.space_after = Pt(2)
    p.paragraph_format.line_spacing = 1.25
    r = p.add_run(title)
    run_font(r, "黑体", 9.5, True, NAVY)
    for line in body:
        q = c.add_paragraph()
        q.paragraph_format.space_before = Pt(0)
        q.paragraph_format.space_after = Pt(1)
        q.paragraph_format.line_spacing = 1.25
        rr = q.add_run(line)
        run_font(rr, "宋体", 9.5, False, RGBColor(0x33, 0x33, 0x33))
    set_col_widths(t, [TEXT_W])
    spacer(6)


# ---------------------------------------------------------------- header/footer
sec.different_first_page_header_footer = True
hp = sec.header.paragraphs[0]
hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
hr = hp.add_run("BigBird RV32 处理器核 · 产品报告（v17）")
run_font(hr, "宋体", 8, False, LIGHTGREY)
para_border(hp, "bottom", "D9D9D9", 4, 1)

fp = sec.footer.paragraphs[0]
try:
    doc.styles["Footer"].paragraph_format.tab_stops.clear_all()
except KeyError:
    pass
fp.paragraph_format.tab_stops.clear_all()
fp.paragraph_format.tab_stops.add_tab_stop(Cm(TEXT_W), WD_TAB_ALIGNMENT.RIGHT)
run_font(fp.add_run("2026-10-20  ·  内部资料"), "宋体", 8, False, LIGHTGREY)
run_font(fp.add_run("\t第 "), "宋体", 8, False, LIGHTGREY)


def add_field(par, instr, placeholder="1"):
    r = par.add_run()
    fld_begin = OxmlElement("w:fldChar")
    fld_begin.set(qn("w:fldCharType"), "begin")
    it = OxmlElement("w:instrText")
    it.set(qn("xml:space"), "preserve")
    it.text = " %s " % instr
    fld_sep = OxmlElement("w:fldChar")
    fld_sep.set(qn("w:fldCharType"), "separate")
    t = OxmlElement("w:t")
    t.text = placeholder
    fld_end = OxmlElement("w:fldChar")
    fld_end.set(qn("w:fldCharType"), "end")
    r._r.append(fld_begin)
    r._r.append(it)
    r._r.append(fld_sep)
    r._r.append(t)
    r._r.append(fld_end)
    run_font(r, "宋体", 8, False, LIGHTGREY)


add_field(fp, "PAGE")
run_font(fp.add_run(" 页  /  共 "), "宋体", 8, False, LIGHTGREY)
add_field(fp, "NUMPAGES")
run_font(fp.add_run(" 页"), "宋体", 8, False, LIGHTGREY)

# ================================================================== cover
for _ in range(4):
    doc.add_paragraph().paragraph_format.space_after = Pt(0)

p = doc.add_paragraph()
p.paragraph_format.space_after = Pt(2)
run_font(p.add_run("PRODUCT REPORT   ·   产品报告"), "黑体", 11, True, LIGHTGREY)

p = doc.add_paragraph()
p.paragraph_format.space_after = Pt(0)
p.paragraph_format.line_spacing = 1.05
run_font(p.add_run("BigBird RV32"), "黑体", 34, True, NAVY)

p = doc.add_paragraph()
p.paragraph_format.space_after = Pt(4)
p.paragraph_format.space_before = Pt(2)
run_font(p.add_run("处理器核产品报告"), "黑体", 34, True, NAVY)

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(8)
p.paragraph_format.space_after = Pt(6)
run_font(p.add_run("RV32IM  ·  物理 8 级流水  ·  64 KB IROM / 128 KB DRAM  ·  全链路已上板验证"),
         "宋体", 11.5, False, GREY)
para_border(p, "bottom", "1F4E79", 12, 6)

doc.add_paragraph().paragraph_format.space_after = Pt(18)

info = [
    ("产品版本", "v17（RTL 代号）。综合产物 board_top_gui_boot_v16.bit / .ltx"),
    ("文档编号", "BB-RV32-PR-017"),
    ("报告日期", "2026 年 10 月 20 日"),
    ("适用器件", "Xilinx xc7z020clg484-1（EES-331 开发板），Vivado 2025.2"),
    ("核心成绩", "CoreMark 1.0 = 128.82 iter/s @ 50 MHz，即 2.576 CoreMark/MHz"),
    ("验证状态", "仿真回归 38/38、上板冒烟 6 项全过、CoreMark CRC 与官方一致"),
    ("数据口径", "报告内全部数字均来自本机可复现的实测日志（见附录 C）"),
]
t = doc.add_table(rows=0, cols=2)
t.autofit = False
table_borders(t, "D9D9D9", 4)
cell_margins(t, top=70, bottom=70, left=100, right=100)
for k, v in info:
    cells = t.add_row().cells
    cells[0].width = Cm(3.4)
    cells[1].width = Cm(12.4)
    shade(cells[0], "F4F7FB")
    for cell, text, bold, color, name in (
            (cells[0], k, True, NAVY, "黑体"), (cells[1], v, False, INK, "宋体")):
        q = cell.paragraphs[0]
        q.paragraph_format.space_before = Pt(0)
        q.paragraph_format.space_after = Pt(0)
        q.paragraph_format.line_spacing = 1.2
        run_font(q.add_run(text), name, 9, bold, color)
set_col_widths(t, [3.4, 12.4])

for _ in range(3):
    doc.add_paragraph().paragraph_format.space_after = Pt(0)
p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(10)
run_font(p.add_run("编制：BigBird 处理器核项目组　｜　分类：技术产品报告　｜　版本：v17（2026-10）"),
         "宋体", 8.5, False, LIGHTGREY)

doc.add_page_break()

# ================================================================== TOC
p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(0)
p.paragraph_format.space_after = Pt(10)
run_font(p.add_run("目　录"), "黑体", 18, True, NAVY)
para_border(p, "bottom", "1F4E79", 10, 4)

toc = [
    ("1　执行摘要", "一句话结论、关键指标与三条判断"),
    ("2　产品定位", "目标用户、能力边界、与上一版的关系"),
    ("3　规格参数", "指令集、微架构、存储与地址空间、外设、启动形态"),
    ("4　关键技术改进", "分支预测扫参、IROM 双读口、load-use、缺陷修复、shell、load-and-run"),
    ("5　性能评估", "CoreMark 上板成绩、演进轨迹、CPI 与停顿分解、横向定位"),
    ("6　资源与时序", "Vivado 综合/实现数据、时序余量与风险"),
    ("7　质量保证与验收", "三层验证、关键判据、缺陷清单、复现方式"),
    ("8　交付物清单", "RTL / 板级 / 仿真 / 软件 / 工具 / 文档"),
    ("9　风险与限制", "已量化风险、四道硬边界"),
    ("10　路线图", "按收益/成本排序的后续计划"),
    ("附录 A / B / C", "术语、测量条件、数据溯源"),
]
t = doc.add_table(rows=0, cols=2)
t.autofit = False
table_borders(t, "FFFFFF", 2)
cell_margins(t, top=30, bottom=30, left=60, right=60)
for k, v in toc:
    cells = t.add_row().cells
    cells[0].width = Cm(5.4)
    cells[1].width = Cm(10.4)
    q = cells[0].paragraphs[0]
    q.paragraph_format.space_before = Pt(0)
    q.paragraph_format.space_after = Pt(0)
    q.paragraph_format.line_spacing = 1.0
    run_font(q.add_run(k), "黑体", 10.5, True, NAVY)
    q = cells[1].paragraphs[0]
    q.paragraph_format.space_before = Pt(0)
    q.paragraph_format.space_after = Pt(0)
    q.paragraph_format.line_spacing = 1.0
    run_font(q.add_run(v), "宋体", 9.5, False, GREY)
set_col_widths(t, [5.4, 10.4])

doc.add_paragraph()

# ================================================================== 1
H1("1　执行摘要")

para("本报告给出 BigBird RV32 处理器核在 v17 这一交付点的产品状态：它是什么、能跑多快、"
     "代价是多少、哪些能力明确没有、下一版该往哪里投。所有性能、资源与时序数字都取自本机"
     "可复现的实测日志，未使用估算值；凡是估算或外部参考，文中均显式标注。")

H2("1.1　关键指标")
T(["项目", "指标"], [
    ["指令集", "RV32IM + Zicsr + Zicntr，仅机器模式（M 模式）"],
    ["微架构", "单发射、顺序执行、物理 8 级流水（IF→ID1→ID2→EX→M1→M2→M3→WB），稳态 1 IPC"],
    ["运行频率", "50 MHz（板上 100 MHz 输入经 MMCM ÷2）；时序全满足，WNS +0.048 ns"],
    ["CoreMark 1.0", "**128.82 iter/s ⇒ 2.576 CoreMark/MHz**（1400 次迭代，10.868 s）"],
    ["片上存储", "IROM 64 KB（取指，2 读口 + 可写数据窗口）+ DRAM 128 KB（数据，字节/半字写）"],
    ["逻辑资源", "LUT 36 150（67.9%）、FF 34 058（32.0%）、BRAM 66.5 tile（47.5%）、DSP 4 个"],
    ["软件栈", "串口引导器 + 16 命令交互 shell + C 应用 load-and-run（写代码区后直接执行）"],
    ["验证", "仿真回归 38/38 PASS；上板冒烟 6 项 PASS；CoreMark CRC = e714/1fd7/8e3a（官方值）"],
], [3.4, 13.0], align=["l", "l"], fs=9, caption="表 1　产品关键指标（v17）")

H2("1.2　三条判断")

rich([("① 性能已进入同类单发射 RV32 软核的主流区间。", True),
      ("从 v13.5 的 2.335 到 v15 的 2.576 CoreMark/MHz，两轮改动合计 +10.3%；"
       "每一版都能给出「停顿拍数为什么少了」的逐项分解，而不是只报一个总分。", False)], bullet=True)
rich([("② 瓶颈已经不在 IPC，而在频率与调试。", True),
      ("同一块 Zynq-7020 上 Fmax 约 50.1 MHz，主流软核普遍在 100 MHz 以上；"
       "且本核没有 JTAG 调试模块，调试依赖串口 shell 与片内 ILA。"
       "下一个数量级的速度提升必须来自关键路径重构，而不是再挤 CPI。", False)], bullet=True)
rich([("③ 可信度来自「可复现 + 敢纠错」。", True),
      ("本轮修掉一个真实总线缺陷（一次 MMIO 读被发两次），把此前"
       "「load-use 2 拍是下界」的结论改写为「1 拍可达」，并且推翻了"
       "自己关于 fence.i 的一处误判——三次都留下了证据链与更正记录。", False)], bullet=True)

callout("本报告的一句话结论",
        ["这颗核现在是一颗「跑得对、测得准、讲得清」的 RV32IM 软核：2.58 CoreMark/MHz 的性能、"
         "完整的引导与在线调试手段、38 项回归加 6 项上板冒烟守着每次改动；"
         "它还不是「跑得快」的核——频率停在 50 MHz，这是下一阶段的唯一主战场。"])

# ================================================================== 2
H1("2　产品定位")

H2("2.1　目标用户与典型场景")
T(["用户类型", "用它做什么", "本版本最相关的特性"], [
    ["教学与实验平台", "讲清流水线、冒险、Cache、分支预测、异常与中断", "周期可静态推算、停顿可分解、波形与日志一一对应"],
    ["科研与验证平台", "作为 DUT 基座做故障注入、功耗建模、加速器挂载", "无乱序、单时钟域、提交级观测口、无厂商 IP 依赖"],
    ["嵌入式原型", "≤50 MHz 的裸机控制、协议处理、传感器聚合", "UART 引导 + 交互 shell + 在线 load-and-run，改程序不用重新综合"],
    ["软硬件协同团队", "需要可解释的周期模型来标定性能预算", "+perf 停顿普查、CPI 分解、CoreMark 上板报分"],
], [3.2, 6.4, 6.8], align=["l", "l", "l"], fs=8.5, caption="表 2　目标用户")

H2("2.2　能力边界（先说清楚「没有」）")
T(["维度", "支持", "不支持 / 未实现"], [
    ["指令集", "RV32I 全部整数指令、M 扩展 8 条乘除、Zicsr、Zicntr", "A / F / D / C 扩展、ebreak"],
    ["特权级", "M 模式，含全部标准 M 模式 CSR", "U 模式、MMU、PMP、特权级切换"],
    ["异常", "ecall、非法指令、取指/访存非对齐陷入（默认开启）", "断点异常、单步"],
    ["中断", "MSIP（软件）、MTIP（内部定时器）", "MEIP 外部中断（编码保留、端口未引出）"],
    ["存储", "片内 IROM 64 KB + DRAM 128 KB；IROM 数据窗口可读可写", "片外 SDRAM / Flash、Cache 一致性协议"],
    ["调试", "串口 shell（16 命令）、提交级观测口、片内 ILA", "JTAG DTM、硬件断点、GDB 连接"],
    ["操作系统", "裸机 + 轻量 RTOS（任务、tick 中断已验证）", "Linux 等需要 MMU 的通用 OS"],
], [2.6, 7.6, 6.2], align=["l", "l", "l"], fs=8.5, caption="表 3　能力边界")

H2("2.3　与上一版产品说明的关系")
para("v9 的《产品说明（客户版）》描述的是「能综合、能上板、能跑回归」的形态；本报告描述的是"
     "经过 v10–v17 十二个版本迭代之后、已经在真实硅片上跑出 CoreMark 成绩并支持在线加载执行的形态。"
     "两者在定位上一致（教学/科研/原型，非量产 MCU），差别在于：v9 的多项已知缺陷（异常体系、"
     "MMIO 副作用、引导方式）在本版本中已经闭合，性能数字也换成了同一块板上连续可比的实测序列。")

# ================================================================== 3
H1("3　规格参数")

H2("3.1　指令集与特权级")
T(["类别", "内容"], [
    ["基址", "RV32I（算术、逻辑、移位、比较、load/store、跳转、lui/auipc）"],
    ["扩展 M", "mul / mulh / mulhsu / mulhu / div / divu / rem / remu"],
    ["CSR", "Zicsr：mstatus、misa、mie、mtvec、mscratch、mepc、mcause、mtval、mip"],
    ["计数器", "Zicntr：mcycle(0xB00)、minstret(0xB02)；自定义 mtime(0x7C0)、mtimecmp(0x7C1)"],
    ["异常", "ecall、非法指令、取指非对齐、load/store 非对齐；精确陷入 mtvec，mret 返回 mepc"],
    ["中断", "MSIP > MTIP 优先级；MEIP 编码保留但端口固定为 0"],
], [2.6, 13.8], align=["l", "l"], fs=8.5, caption="表 4　指令集与特权级")

H2("3.2　微架构")
para("对外按经典五级描述，物理上为 8 个寄存器边界。多出的 3 级不是浪费，而是为了让整条通路只依赖"
     "「同步存储器、读延迟 1 拍」这一种最容易被综合成 BRAM 的时序模型：")
code([
    "物理级:   IF    ID1   ID2   EX    M1    M2    M3    WB",
    "模块:     IFU   IDU   IDU   EXU   LSU   LSU   LSU   WBU",
    "配套:     BPU   RF    -     ALU   DCache           写回口",
    "                          MDU   地址   发总线  整理",
])
T(["项目", "实现"], [
    ["流水线", "8 级（IF→ID1→ID2→EX→M1→M2→M3→WB），单发射顺序执行"],
    ["取指", "直连 IROM 同步读（v13 起旁路 I-Cache），请求后 1 拍返回"],
    ["分支预测", "gshare：BTB/PHT 256 项 + GHR 8 位 + RAS 8 深度；EX 级校验、误预测冲刷前端"],
    ["数据缓存", "DCache 直接映射 256 行 × 1 字，写直达 + 命中合并；带 M1 探测读口"],
    ["访存", "字节/半字按地址低位选道；MMIO（≥0x1000_0000）恒不缓存、读直通外设"],
    ["乘除", "乘法 1 拍不阻塞；除法 16 拍 radix-4 迭代（busy 17 拍），三类快路径 1 拍"],
    ["冒险", "Data_hazard 为唯一裁决源；load-use 仅停 1 拍（M1 命中当拍前递）"],
], [3.0, 13.4], align=["l", "l"], fs=8.5, caption="表 5　微架构要点")

H2("3.3　存储层次与地址空间")
T(["空间", "范围", "容量", "属性与索引"], [
    ["IROM（取指）", "0x0000_0000 – 0x0000_FFFF", "16 384 字 = 64 KB", "只读取指；字索引 addr[15:2]；2 读口 + 1 写口"],
    ["IROM 数据窗口", "0x0002_0000 – 0x0002_FFFF", "同上（全量可见）", "CPU 数据读写同一数组；v16 起可写 ⇒ 支持 load-and-run"],
    ["DRAM（数据）", "0x0000_0000 – 0x0001_FFFF", "32 768 字 = 128 KB", "读写，支持字节/半字写；索引 addr[16:2]"],
    ["MMIO（外设）", "0x1000_0000 – 0x1000_00FF", "8 个寄存器", "恒不缓存；优先级高于 IROM 窗口与 DRAM"],
], [3.0, 5.0, 3.4, 5.0], align=["l", "l", "l", "l"], fs=8.5, caption="表 6　地址空间")

para("地址译码优先级为 MMIO > IROM 窗口 > DRAM；窗口地址小于 0x1000_0000，因此会被 DCache 缓存，"
     "这在本核是安全的：IROM 唯一的写者在引导期间工作，而那时 CPU 与 DCache 一起处于复位状态。")

T(["偏移", "名称", "读写", "说明"], [
    ["+0x00", "TXDATA", "WO", "写低 8 位入发送器；发送器忙时丢弃"],
    ["+0x04", "TXSTAT", "RO", "bit0 = busy（上一帧未发完）"],
    ["+0x08", "RXDATA", "RO", "**幂等 peek**：只看队头，不弹出"],
    ["+0x0c", "RXSTAT", "RO", "bit0 = FIFO 非空；bit1 = 曾溢出（读即清）"],
    ["+0x10", "LED", "RW", "低 7 位驱动板载 LED1–LED7"],
    ["+0x14", "BOOTREQ", "WO", "写 1 重新武装串口引导器"],
    ["+0x18", "RXPOP", "WO", "写 1 弹出队头字节（与 RXDATA 配合）"],
], [2.0, 3.2, 2.0, 9.2], align=["c", "l", "c", "l"], fs=8.5, caption="表 7　MMIO 寄存器映射")

callout("为什么 RXDATA 要做成幂等",
        ["v13.5 实测发现：一次 lw 0x1000_0008 会让总线出现两个读脉冲，若「读即弹」，"
         "每读一个字节就多吃掉一个——命令 l 3f 变成 l3。根因在数据通路（P4，见 §4.4），"
         "外设侧的正确防御是让读没有副作用：RXDATA 只看不弹，出队必须写 RXPOP。",
         "这条已成为不变量：RXDATA 永远不许再带回弹出副作用。"])

H2("3.4　外设与时基")
T(["外设", "参数", "说明"], [
    ["UART", "115200 8N1，收/发各一路（两个 uart_rx 实例）", "引导器与 console 是独立消费者，各自监听同一根线，避免抢字节"],
    ["RX FIFO", "8 深（约 36 FF）", "115200 下每字节 87 µs，单字节寄存器必然丢字节"],
    ["GPIO", "LED1–LED7（7 位）", "软件写 0x1000_0010 低 7 位"],
    ["时基", "mtime @ 500 kHz（sys_clk ÷ 100）", "uptime 命令按 s.mmm 输出；定时器中断比较 mtimecmp"],
], [2.6, 6.4, 7.4], align=["l", "l", "l"], fs=8.5, caption="表 8　外设与时基")

H2("3.5　启动与运行形态")
para("上电后由串口引导器接管：宿主机把程序镜像按帧写入 IROM，校验通过后释放 CPU 从 0 地址取指。"
     "运行期通过 shell 可以再次进入引导器（b 命令）而不必按键复位；也可以把新代码直接写进 IROM 的"
     "数据窗口并跳转执行（L / D / r 三条命令），全程不需要重新综合比特流。")
code([
    "上电 → boot_loader 监听 UART → 收帧写 IROM → 校验 OK → 释放 CPU",
    "     → shell 启动（提示符 >）",
    "     → L 0x4000（写代码）→ D 0x10000（写 .rodata/.data）→ r 0x4034（fence.i 后跳转）",
    "     → 应用返回 shell（应用用 return 回到调用点，沿用 shell 的栈）",
])

# ================================================================== 4
H1("4　关键技术改进（v13.5 → v17）")
para("这一轮共 6 项改动，每一项都对应一个具体问题。下表先给总账，随后逐项展开；"
     "所有收益均为同一板卡、同一工具链下的实测差值。")
T(["#", "改动", "解决什么问题", "实测收益", "主要代价"], [
    ["1", "分支预测容量 64→256 行、GHR 6→8", "误预测率 14.5% 偏高", "周期 −3.05%", "LUTRAM +120，0 BRAM"],
    ["2", "IROM 双读口 + 数据窗口 0x2_xxxx", "lw 读不到自己的代码", "打通在线校验与加载", "BRAM 占用不变"],
    ["3", "DCache M1 探测读口", "load-use 停 2 拍", "**周期 −5.9%，load-use −55%**", "两个 256:1 读多路器；WNS −0.54 ns"],
    ["4", "请求身份证 req_seq", "一次 MMIO 读被发两次", "读/出队 26:13 → 13:13", "0（仅 1 根线）"],
    ["5", "命令表驱动的 shell", "扩展性差、帮助要写两遍", "16 命令 + 行编辑/历史", "镜像约 13–14 KB"],
    ["6", "load-and-run（L/D/r + 链接脚本）", "改程序必须重新综合", "C 应用在线执行并返回", "下界需按 _etext 自适应"],
], [0.8, 4.5, 4.2, 3.9, 3.0], align=["c", "l", "l", "l", "l"], fs=8.5,
    caption="表 9　本轮六项改动总账")

H2("4.1　分支预测：扫参后停在 256 行")
para("不靠直觉，只改 rtl/para.sv 的两个参数（BP_INDEX_BITS / BP_HIST_BITS），其他 RTL 一个字不动，"
     "每档跑 CoreMark 1 次迭代：")
T(["BTB/PHT 行数", "GHR 位宽", "总拍数", "误预测", "分支总数", "误预测率", "相对 64 行"], [
    ["64", "6", "482 990", "10 680", "73 707", "14.5%", "—"],
    ["256", "6", "471 384", "8 376", "73 685", "11.4%", "−2.40%"],
    ["**256**", "**8**", "**468 266**", "**7 753**", "**73 694**", "**10.5%**", "**−3.05%（采用）**"],
    ["1024", "8", "462 715", "6 618", "73 710", "9.0%", "−4.20%"],
    ["1024", "10", "461 825", "6 466", "73 675", "8.8%", "−4.38%"],
], [2.8, 1.8, 2.4, 2.2, 2.2, 2.0, 2.6], align=["c", "c", "r", "r", "r", "r", "c"],
    fs=8.5, caption="表 10　分支预测容量扫参（CoreMark 1 次迭代）")

figure(os.path.join(FIG, "v17_bp_sweep.png"), "图 1　容量扫参的收益递减")

para("结论是停在 256 行：64→256 拿到 3.05%，256→1024 只多 1.15 个百分点，却要多约 900 个 LUT 和"
     "一个「1024 选 1」的取指读多路器（还要吃掉本已紧张的时序余量）；历史 8→10 只多 0.2%，已饱和。"
     "剩下 10.5% 的误预测主要来自冷启动与 gshare 的容量冲突，堆尺寸治不好。")

H3("实现上踩过的两个坑（都影响了最终代码形态）")
rich([("Verilator 的循环展开上限：", True),
      ("表项原来是 unpacked 数组，在 for 循环里做非阻塞赋值，LINES=64 能过、256 直接报 "
       "%Error-BLKLOOPINIT。改成打包向量后通过。", False)], bullet=True)
rich([("iverilog 不支持二维打包数组连续索引：", True),
      ("pht[idx][1] 报「索引必须是常量」。于是把 2 位饱和计数器拆成 pht_hi / pht_lo 两根 1 位向量，"
       "加减法按位写（+1：lo'=~lo|hi，hi'=hi|lo；−1：lo'=hi&~lo，hi'=hi&lo），与原 ±1 逐状态等价。", False)], bullet=True)
rich([("必须声明 ram_style = distributed：", True),
      ("四张表是「同步写 + 组合读」，BRAM 做不到组合读；不声明就会退化成约 14.6 k 个触发器。", False)], bullet=True)

H2("4.2　IROM 双读口与数据窗口：解掉「lw 读不到代码」")
para("哈佛结构下取指走 IROM、访存走 DRAM，同一数值区间被两侧分别解释，因此之前无法用 lw 读自己的代码，"
     "也就无法在板上做「代码区自校验」。解法不是把两块存储器合成统一地址空间（那要改链接脚本、引导协议和"
     "全部测试台），而是给 IROM 加第二个读口并开一个数据窗口。")
T(["位置", "改动"], [
    ["board/sync_mem_dp.sv", "新增 2 读口 + 1 写口存储器；三个口写在同一段 always_ff 里——Vivado 只有这样才能推成 True Dual Port BRAM，拆成两段会占用翻倍"],
    ["board/board_top.sv", "IROM 换用 sync_mem_dp：端口 A = 取指（只读），端口 B = CPU 数据读 或 引导器写（二者互斥）"],
    ["地址译码", "perip_addr[31:16]==0x0002 → IROM 字[perip_addr[15:2]]；优先级 MMIO > 窗口 > DRAM"],
    ["写保护", "DRAM 写使能被窗口地址门掉——代码区曾经刻意只读"],
], [3.6, 12.8], align=["l", "l"], fs=8.5, caption="表 11　双读口与数据窗口的实现")

H3("验收：三个口径逐位相同")
para("新增 dptest 程序在 Verilator 全 RTL 上跑：从窗口前 64 个字算 djb2 校验和，与链接时算出的期望值比对"
     "（期望值必须是可写变量，否则会落进被校验的 .text 里造成自我指涉）。结果 D1–D4 全 0，"
     "其中 W0 = 0x00011197 正是 IROM 第 0 个字（复位向量那条指令）。上板再验一次：")
code([
    "板上:  k 20000  →  cksum 0xf7b9ad39",
    "主机:  python 算 monitor_irom.hex 前 64 字 djb2  →  0xf7b9ad39",
    "结论: 一边是工程里的 hex 文件，一边是硅片上的 lw —— 逐位相同",
])
para("这也是 board_smoke.ps1 的 S3 判据：它自己做主机侧对拍，而不是只信板上打印的数字。")

H2("4.3　load-use：从 2 拍压到 1 拍")
para("此前结论是「load-use 2 拍是这套微架构的下界」：消费者在 ID2 的第 1 拍 load 还在 EX（地址没算出来），"
     "第 2 拍 load 在 M1（同步读还没返回），第 3 拍数据才在 M2 有效。当时还估算过「M1 命中前递要再加一套 "
     "256:1 读 mux，约 1 700 LUT，不划算」。")
para("这个估算错在只想「再加一套 mux」，而正确做法是给 DCache 增加一个只读探测口：把 M1 那一段已经算好的"
     "有效地址也拿去查数组，命中时数据当拍就有。改动很小：")
code([
    "DCache:  m1_addr / m1_en  ->  m1_hit / m1_rdata   （第二个读口，组合读）",
    "LSU:     LSU_Rdata_m1 = lane_extract(m1_rdata, funct3_reg, addr_reg[1:0])",
    "         m1_load_ok   = mem_ren_reg & valid_reg & m1_hit",
    "Hazard:  mem_load_use &= ~MEM_m1_ok        （命中则不必等 M2）",
    "myCPU:   MEM_forward_val = m1_load_ok ? LSU_Rdata_m1 : (jump|csr ? rd_value : Ex_result)",
])
para("唯一需要护栏的情形是：同一拍有一次 store 合并打到同一 index，数组还是旧值（合并要到拍末才生效），"
     "此时直接把 m1_hit 置 0，退回 M2 路径多停 1 拍，功能仍正确。回填（fill）不需要护栏，因为回填只发生在"
     "行不驻留时，那时 m1_hit 本来就是 0。")
para("这条通路只可能变快、不可能改错语义：store、空拍、未命中、MMIO 一律 m1_load_ok=0，行为与 v14 逐拍相同。")

figure(os.path.join(FIG, "v17_stall_before_after.png"),
       "图 2　停顿拍数去向（前三项为实测计数，末项为按总拍数反推）")

T(["指标（CoreMark 1 次迭代）", "v14", "v15", "变化"], [
    ["总拍数", "468 263", "**440 656**", "**−5.9%**"],
    ["load-use 停拍", "50 339", "**22 681**", "**−55%**"],
    ["MDU 迭代（除法）", "20 868", "20 832", "−0.2%"],
    ["CPI", "1.323", "**1.245**", "−5.9%"],
    ["拍/迭代（上板稳态）", "415 256", "**388 148**", "−6.5%"],
    ["iter/s（上板）", "120.41", "**128.82**", "**+6.9%**"],
], [5.4, 3.6, 3.6, 3.8], align=["l", "r", "r", "r"], fs=8.5,
    caption="表 12　load-use 改进的实测收益")

T(["代价项", "v14", "v15", "说明"], [
    ["WNS / WHS", "1.187 / 0.007 ns", "0.645 / 0.015 ns", "余量少 0.54 ns，50 MHz 仍成立"],
    ["Slice LUTs", "—", "36 990（69.5%）", "两个新读口的 256:1 多路器"],
    ["Slice Registers", "—", "34 047（32.0%）", "不变：没有新增状态"],
    ["Block RAM Tile", "66.5", "66.5", "不变"],
    ["LUT as Memory", "856", "976", "+120（预测器表的组合读）"],
], [3.6, 3.8, 4.2, 4.8], align=["l", "c", "c", "l"], fs=8.5,
    caption="表 13　M1 探测口的代价")

H2("4.4　缺陷修复：一次 MMIO 读被总线发了两次")
para("症状很具体：shell 每读一个字节就吃掉两个，命令 l 3f 被解析成 l3，LED 写成 3。探针显示一次 "
     "lw 0x1000_0008 会让 perip_ren 出现两个脉冲，相隔约 20 拍。")
para("根因不是「同一地址读两次」这么简单。真正的问题在接线窗口上：")
code([
    "cpu_en       = LSU_mem_ren_pipe | lsu_bus_wen      // 本拍（M2 电平）",
    "cache_rd_req = cpu_en_r & ~cpu_wen_r & ~line_resident & ~mem_req_r   // 上一拍",
])
para("mem_req_r 在数据返回那一拍就被清掉，而 cpu_en_r 要等这条 load 离开 M2 才掉——中间那一拍 "
     "cache_rd_req 又为 1，于是同一条已服务完的请求又对总线打了一次读。")
para("只比地址修不了这个问题（while(!(RXSTAT&1)); 这类同地址轮询会读到旧值），必须有一个「这是一条新请求」"
     "的令牌。于是 LSU 增加输出 req_seq：每推进一条 M2 指令翻转一位，翻转条件与流水线推进条件逐字一致。"
     "DCache 侧用 req_seq_r 与 cpu_addr_r 同沿采样，并用粘滞位 unc_busy 记录「本请求已发过 uncacheable 读」，"
     "只允许在 seq 变化时清除。")
T(["判据", "修前", "修后"], [
    ["RXDATA 读次数 : 出队次数", "26 : 13（2:1）", "**13 : 13（1:1）**"],
    ["tb_monitor 自检", "3/4", "**6/6 PASS**"],
    ["CoreMark 拍/迭代", "415 905", "415 905（修复不改性能）"],
    ["tb_dcache_unit", "新增判据", "同地址两次 MMIO 读看到不同副作用值 ⇒ PASS"],
], [5.2, 5.2, 6.0], align=["l", "c", "c"], fs=8.5, caption="表 14　P4 缺陷的验收对比")
para("★ 值得一提的是，第一版修法（只用 cpu_adv 清 unc_busy）实测无效，已回滚；"
     "直到加上「请求身份证」才真正生效。这个弯路写进了检查点文档，避免下一个人重走。")

H2("4.5　串口 shell：命令表驱动")
T(["命令", "作用", "命令", "作用"], [
    ["h / help", "帮助（由命令表自动生成）", "m / cmp", "比较两块内存，打印首个不同"],
    ["d / dump", "dump n 个字（默认 8，上限 256）", "k / cksum", "djb2 校验和；k 20000 即读自己的代码"],
    ["p / peek", "读一个字", "u / uptime", "开机时长（mtime@500 kHz → s.mmm）"],
    ["w / poke", "写一个字（外设寄存器同路）", "i / info", "硬件/镜像信息（含 BTB 256 / GHR 8）"],
    ["c / csr", "dump 关键 CSR", "e / echo", "回显（链路测试）"],
    ["l / led", "写 LED 低 7 位", "b / boot", "重新进入引导器"],
    ["f / fill", "填 n 个字", "r / run", "跳转到 IROM 中刚写入的代码"],
    ["L / load", "从串口把 hex 字流写入 IROM 窗口", "D / data", "把数据写到 DRAM（.rodata/.data）"],
], [2.4, 5.8, 2.4, 5.8], align=["l", "l", "l", "l"], fs=8, caption="表 15　shell 的 16 条命令")
para("行编辑支持退格、^U 删整行、^C 取消、↑/↓ 历史 4 条（相同命令不重复存）、CR 后紧跟的 LF 被吞掉"
     "（宿主发 CRLF 时不再多一个空提示符）。数字默认十六进制以兼容旧脚本，0x 前缀十六进制、0d 前缀十进制。")

H2("4.6　load-and-run：软件写代码区并执行")
para("把 IROM 变成可写之后，「改程序要重新综合」这条约束就消失了。实现只用了三条命令与两个链接脚本，"
     "没有一个字的 RTL 新逻辑：")
T(["组件", "作用"], [
    ["L <addr>", "接收连续十六进制流（每 8 位一个字，CR/LF/空格忽略），写入 IROM 窗口；上限 1024 字"],
    ["D <addr>", "同一套解析，但直接写目标地址（DRAM/MMIO），用于 .rodata/.data；拒绝写 IROM 窗口；上限 2048 字"],
    ["r <addr>", "等 UART 真正空闲 → fence.i → jalr 跳转"],
    ["link_app.ld", ".text 从 IROM_APP_MIN 起 48 KB；.rodata/.data/.bss 放 DRAM 0x1_0000；ENTRY(main)，无 crt0"],
    ["IROM_APP_MIN", "= align4k(_etext)，由链接器给出——下界不许硬编码"],
], [3.0, 13.4], align=["l", "l"], fs=8.5, caption="表 16　load-and-run 的组成")
para("L 的解析刻意不依赖换行：RX FIFO 只有 8 深，宿主的换行会被挤掉，按行解析会把两行粘成 16 位。"
     "上板实测（380 字节的 C 应用）：")
code([
    "[load] 95 words (380 bytes) @irom 0x4000   ->  loaded 380 bytes @irom 0x00004000",
    "[data] 9 words @dram 0x10000              ->  stored 36 bytes @0x00010000",
    "[run ] entry 0x4034",
    "      HELLO-APP from IROM 0x4000 acc=15  returned to shell",
])
para("HELLO-APP 来自 DRAM 里的 .rodata，acc=15 说明 .bss 清过、.data 可写——代码、常量、数据三段全部走了"
     "这条新通路，而且应用正常返回了 shell。")

callout("两个必须记住的坑",
        ["① 安全下界不能硬编码：monitor 加了两条命令后 .text 涨过 12 KB，原先固定的 0x3000 会自己踩自己。"
         "现在由 _etext 算出 IROM_APP_MIN，第一次 L 3000 直接被拒并提示「use >= 0x00004000」。",
         "② 跳转前要等 UART 真的空：putc 只在写之前查 busy，最后一个换行还在移位寄存器里（115200 下 87 µs），"
         "应用第一件事往往就是写 TXDATA，而发送器忙时丢弃——实测症状是「应用跑了，它的第一个字符不见了」。"
         "修法：r 命令在跳转前等 TXSTAT.bit0 清零。"])

# ================================================================== 5
H1("5　性能评估")

H2("5.1　CoreMark 1.0 上板成绩")
para("报告口径一律使用真实硅片结果。下表为 v15 比特流、ITER=1400 的官方跑分（迭代次数经两次上调："
     "核变快之后 1200 次只剩不到 10 s，会被 CoreMark 直接判 ERROR）：")
code([
    "Total ticks      : 543407157        （388 148 拍/迭代）",
    "Total time (secs): 10.868143",
    "Iterations/Sec   : 128.816853       ->  2.576 CoreMark/MHz @ 50 MHz",
    "Iterations       : 1400",
    "[0]crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a",
    "Correct operation validated.",
    "CoreMark 1.0 : 128.816853 / GCC13.2.0 -O2 -march=rv32im -mabi=ilp32 / STACK",
])
T(["项", "值", "说明"], [
    ["iter/s", "**128.816853**", "官方公式的直接输出"],
    ["CoreMark/MHz", "**2.576**", "iter/s ÷ 50 MHz，便于跨频率比较"],
    ["拍/迭代", "388 148", "543 407 157 ÷ 1400"],
    ["仿真对照", "388 944 拍/迭代", "含预测器冷启动，比上板稳态高 0.2%——方向正确"],
    ["CRC", "e714 / 1fd7 / 8e3a", "与官方参考值一致，证明功能正确"],
], [3.2, 4.6, 8.6], align=["l", "c", "l"], fs=8.5, caption="表 17　CoreMark 报分（v15 比特流，ITER=1400）")
para("★ 说明：2.576 的成绩是在 v15 比特流上实测的。v16 相对 v15 只改了 IROM 端口 B 的写使能来源"
     "（引导器 / CPU store 二选一），数据通路未变，因此性能不受影响，但本报告不把「未复测」写成「已复测」"
     "——复测已列入路线图 P1。")

figure(os.path.join(FIG, "v17_coremark_trend.png"), "图 3　CoreMark 成绩演进与累计收益")

H2("5.2　CPI 与停顿分解")
para("单次迭代 440 656 拍、退休 353 882 条指令，CPI = 1.245（v14 为 1.323）。下表是这一版的停顿普查，"
     "前三行是 +perf 直接计数，最后一行按总拍数反推——五行相加恰好等于 cyc，可以逐拍对账：")
T(["类别", "拍数", "占比", "来源与说明"], [
    ["有效退休", "353 882", "80.3%", "minstret；稳态 1 IPC 的部分"],
    ["分支误预测重填", "≈38 718", "8.8%", "**反推**：7 753 次误预测 × 约 5 拍/次"],
    ["load-use 重放", "22 681", "5.1%", "实测计数；M1 命中即前递，未命中退回 M2"],
    ["MDU 迭代（除法）", "20 832", "4.7%", "实测计数；约 1 225 次除法 × 17 拍"],
    ["DCache hold", "4 543", "1.0%", "实测计数；行不驻留时停一拍回填"],
    ["**合计**", "**440 656**", "**100%**", "等于 +perf 的 cyc（440 656）"],
], [4.4, 3.0, 2.2, 6.8], align=["l", "r", "c", "l"], fs=8.5,
    caption="表 18　停顿普查（CoreMark 1 次迭代，五项互斥且可对账）")

para("★ 这里要纠正一个容易读错的口径：+perf 里的 ifu_stall 不是「取指等待」，它是 "
     "load_use_stall | mdu_busy（rtl/Control.sv:486），也就是与表中第三、四行重复计数的并集"
     "（v15 实测 43 505 ≈ 22 681 + 20 832）。拿它当独立项会把 9.9% 的占比记到「取指」头上，"
     "并虚报一个「−39% 的取指改善」。本表按互斥口径重列，误预测重填只能反推，因为 Counter 里没有单独统计它。")

H2("5.3　横向定位")
T(["维度", "本核 v17", "单发射 RV32 软核的常见量级", "判断"], [
    ["CoreMark/MHz", "2.576", "约 2.0 – 3.0（公开资料量级）", "主流区间内"],
    ["流水线深度", "物理 8 级", "5 – 6 级", "深 2–3 级：每级余量大、频率潜力低"],
    ["运行频率（FPGA）", "50 MHz（Fmax ≈ 50.1）", "50 – 150 MHz", "偏低，受组合锥限制"],
    ["分支预测", "gshare + BTB/PHT 256 + RAS 8", "无，或 BTB 16–256", "中上"],
    ["数据缓存", "256 行写直达 + M1 探测口", "无，或 64–256 行", "中上"],
    ["调试能力", "串口 shell + ILA", "多数提供 JTAG DTM / GDB", "明显落后"],
    ["存储容量", "片内 192 KB", "64 KB – 数 MB（可外挂）", "中等，受片内 BRAM 限制"],
], [3.2, 4.8, 5.2, 3.2], align=["l", "l", "l", "l"], fs=8.5, caption="表 19　横向定位")
para("上表「常见量级」一列为公开资料的粗略区间，不是同一工具链下的实测对比，仅用于判断所处档位；"
     "真正可比的只有本报告内部的版本序列（同板、同工具链、同迭代参数）。")

# ================================================================== 6
H1("6　资源与时序")

H2("6.1　资源占用（Vivado 2025.2，xc7z020clg484-1，post-route）")
T(["资源", "用量", "可用", "占比"], [
    ["Slice LUTs", "36 150", "53 200", "67.95%"],
    ["　其中 LUT as Logic", "35 174", "53 200", "66.12%"],
    ["　其中 LUT as Memory", "976", "17 400", "5.61%"],
    ["Slice Registers", "34 058", "106 400", "32.01%"],
    ["F7 / F8 Muxes", "5 044 / 2 264", "26 600 / 13 300", "18.96% / 17.02%"],
    ["Block RAM Tile", "66.5（RAMB36×66 + RAMB18×1）", "140", "47.50%"],
    ["DSP48E1", "4", "220", "1.82%"],
    ["Bonded IOB", "12", "200", "6.00%"],
], [4.6, 6.4, 3.2, 2.2], align=["l", "l", "r", "r"], fs=8.5, caption="表 20　资源占用")
para("只有 12 个引脚：sys_clk、复位、UART 收/发、LED×7、心跳。相比 v9 时代的 201 个引脚（4 个 32 位计数器"
     "直出顶层），这一版把所有观测量放进片内 ILA，引脚压力基本消失。")

H2("6.2　时序")
T(["项", "值", "说明"], [
    ["CPU 时钟域", "clk_sys_unbuf，20.000 ns / 50 MHz", "板上 100 MHz 输入经 MMCM ÷2 派生"],
    ["WNS（setup）", "**+0.048 ns**", "全部约束满足（All constraints met）"],
    ["WHS（hold）", "+0.015 ns", "全部约束满足"],
    ["推算 Fmax", "≈ 50.1 MHz", "1 / (20 − 0.048) ns"],
], [3.6, 6.0, 6.8], align=["l", "c", "l"], fs=8.5, caption="表 21　时序结果（post-route）")

callout("⚠ 时序余量已经贴线，这是本版本最大的工程风险",
        ["WNS 从 v14 的 1.187 ns 掉到 v15 的 0.645 ns，再掉到 v16 的 0.048 ns。v16 相对 v15 只多了一个"
         "写使能多路选择器，却吃掉了约 0.6 ns——大概率是布局布线噪声，但也说明这条路径已经很紧。",
         "下一次改 RTL 之前必须先跑 report_timing 看关键路径，不要再往 perip_addr / perip_wen 的扇出锥"
         "（它们同时驱动 MMIO 译码、DRAM 与 IROM 端口 B 三处）上加逻辑。"],
        fill="FDF1E7", edge="C55A11")

H2("6.3　版本对比")
T(["版本", "核心改动", "LUT", "WNS", "BRAM", "CoreMark/MHz"], [
    ["v13.5", "基线（BTB 64 / GHR 6 / load-use 2 拍）", "—", "—", "66.5", "2.335"],
    ["v14", "BTB 256 + GHR 8 + IROM 双读口 + P4 修复", "—", "1.187", "66.5", "2.408"],
    ["v15", "+ DCache M1 探测口（load-use 1 拍）", "36 990", "0.645", "66.5", "2.576"],
    ["v16", "+ 代码区可写（load-and-run）", "36 150", "0.048", "66.5", "未复测"],
], [2.0, 6.4, 2.2, 1.8, 1.8, 2.2], align=["c", "l", "r", "r", "r", "r"], fs=8.5,
    caption="表 22　资源/时序/性能的版本序列")
para("BRAM 始终是 66.5 tile：双读口是把原来的两个独立端口用满，而不是新占一块存储器——这是本轮"
     "「零 BRAM 代价」结论的来源。")

# ================================================================== 7
H1("7　质量保证与验收")

H2("7.1　三层验证")
T(["层", "手段", "覆盖", "结果"], [
    ["L1 回归", "iverilog（38 项）", "7 个测试程序 ×{正常, 严格} + DCache 单元 + IROM 窗口 + 引导扫描 + monitor 自检", "38/38 PASS"],
    ["L2 交叉", "Verilator 5.020（全 RTL + 真实 board_top）", "CoreMark、dptest、fenceitest、tb_monitor", "全过"],
    ["L3 硅片", "EES-331（xc7z020）+ COM9", "S1 横幅 / S2 代码窗 / S3 主机对拍 / S4 回显 / S5 CoreMark / S6 fence.i", "6/6 PASS"],
    ["Lint", "Verilator lint（top=board_top）+ iverilog 精化", "0 error", "PASS"],
], [2.0, 5.0, 6.6, 2.8], align=["l", "l", "l", "c"], fs=8, caption="表 23　三层验证")
para("「严格模式」的含义：额外加 +no_wbu_force +raw_rf，即不使用测试台的任何兜底手段（不强制写回级暂停、"
     "不预清寄存器堆），用于验证 RTL 自身是否干净；两种模式结果一致。")

H2("7.2　关键判据（都是可复跑的）")
T(["判据", "修前", "修后", "证据来源"], [
    ["一次 MMIO 读对应一次出队", "26 : 13", "13 : 13", "tb_monitor 的 [COUNT] 行"],
    ["shell 自检", "3/4", "6/6", "tb_monitor 的 [MONITOR-SELFCHECK]"],
    ["板上代码区与主机 hex 一致", "不可测", "0xf7b9ad39 = 主机 djb2", "board_smoke S3 主机侧对拍"],
    ["IROM 窗口 4 项自检", "—", "D1–D4 全 0", "sw/run_dptest.sh（Verilator 全 RTL）"],
    ["load-use 停拍", "50 339", "22 681", "+perf 统计"],
    ["fence.i 可用性", "曾被误判为缺陷", "4 项场景全过", "sw/fenceitest.c + 板上 S6"],
], [4.6, 3.4, 4.2, 4.2], align=["l", "c", "c", "l"], fs=8.5, caption="表 24　关键判据")

H2("7.3　本轮修复与更正")
T(["事件", "影响", "处置", "状态"], [
    ["P4：一次 MMIO 读被发两次", "shell 每读一字节吃掉两个，命令被改坏", "req_seq 请求身份证 + unc_busy 粘滞位", "已修并回归"],
    ["load-use 2 拍「下界」结论", "判断过保守，少拿 6.9% 性能", "DCache 加 M1 探测口，2 拍→1 拍", "已解决"],
    ["fence.i「会让 CPU 停住」", "结论错误，一度准备当缺陷修", "真因是测试台时序：RX FIFO 8 深，命令发太快被挤掉；fenceitest 证明可用", "已更正"],
    ["shell 下界硬编码 0x3000", "monitor 一长就自己踩自己", "_etext + align4k 自动算 IROM_APP_MIN", "已修"],
    ["跳转丢首字符", "应用第一个字符消失", "r 命令先等 TXSTAT 空闲", "已修"],
], [4.2, 4.2, 5.6, 2.4], align=["l", "l", "l", "c"], fs=8, caption="表 25　本轮修复与更正记录")

H2("7.4　一键复现")
code([
    "# 仿真侧（约 1 分钟）：Verilator 全 RTL 跑 IROM 数据窗口自检",
    "wsl bash -c \"cd /mnt/e/FPGA/v9_vivado_ila && bash sw/run_dptest.sh\"",
    "",
    "# 板上侧（约 90 秒）：编程 + 灌 monitor + 4 项自检（-WithCoreMark / -WithFenceI 可选）",
    "powershell -NoProfile -ExecutionPolicy Bypass -File _diag\\board_smoke.ps1",
    "",
    "# 全量回归（38 项）",
    "powershell -NoProfile -ExecutionPolicy Bypass -File _diag\\regress.ps1",
])

# ================================================================== 8
H1("8　交付物清单")
T(["目录", "内容", "规模"], [
    ["rtl/", "21 个 CPU 模块（流水线、BP、DCache、MDU、CSR、冒险裁决等）", "4 731 行 SystemVerilog"],
    ["board/", "顶层、双口存储器、引导器、UART 收发、复位同步、ILA 顶层", "10 个模块 / 1 543 行"],
    ["sim/", "16 个自检测试台（含真实 board_top 的监测台）", "—"],
    ["sw/", "shell、测试程序、引导协议、链接脚本与构建脚本", "12 个 C 程序 + 2 个链接脚本 + 19 个脚本"],
    ["_diag/", "编译检查、38 项回归、上板冒烟、load-and-run、Vivado 构建", "26 个脚本（14 PS + 5 SH + 7 PY）"],
    ["docs/", "检查点、实现说明、验证报告、工具链与 RTOS 文档", "17 份文档"],
    ["figures/", "本报告三张图与历史配图", "—"],
    ["_bak/", "可回退的比特流与 LTX 备份（v14 / v15 / v16）", "—"],
], [2.2, 10.0, 4.2], align=["l", "l", "l"], fs=8.5, caption="表 26　交付物")

# ================================================================== 9
H1("9　风险与限制")

T(["编号", "风险", "影响", "现状", "缓解"], [
    ["R1", "时序余量仅 0.048 ns", "再加逻辑可能不收敛", "已量化（post-route 报告）", "先 report_timing 再改 RTL；重构扇出"],
    ["R2", "频率停在 ~50 MHz", "与主流 100 MHz+ 有差距", "受 EXU→Control→DCache 组合锥限制", "结构性改动（见路线图 P0）"],
    ["R3", "无 JTAG 调试子系统", "只能串口 shell + ILA 调试", "设计取舍", "中期补 DTM / 断点"],
    ["R4", "仅 M 模式，无 MMU/PMP", "不能跑通用 OS，缺内存保护", "定位使然", "不作为近期目标"],
    ["R5", "存储全片内 192 KB", "大程序放不下", "参考设计", "中期接片外 SDRAM / Flash"],
    ["R6", "CoreMark 未在 v16 上复测", "最新比特流缺性能数据", "数据通路未变，风险低", "路线图 P1：复测并归档"],
    ["R7", "单板、单工具链", "换器件需重新验证时序", "Vivado 2025.2 + xc7z020", "交付时明确测量条件（附录 B）"],
], [1.2, 4.2, 3.8, 3.6, 3.6], align=["c", "l", "l", "l", "l"], fs=8,
    caption="表 27　风险登记")

callout("四道硬边界（不随版本变化）",
        ["① 不是通用 MCU：没有 U 模式、MMU、PMP，不面向量产流片；",
         "② 跑不了 Linux 一类需要地址翻译的 OS，定位是裸机与轻量 RTOS；",
         "③ 没有硬件断点与 JTAG DTM，调试靠串口 shell 与片内 ILA；",
         "④ 外部中断（MEIP）端口未引出，只有 MSIP 与内部定时器中断。"])

# ================================================================== 10
H1("10　路线图")
para("按「客户可感知收益 ÷ 工作量」排序，全部不需要推翻现有微架构。")
T(["优先级", "项目", "预期收益", "工作量", "风险"], [
    ["P0", "时序收紧：先 report_timing，重构 perip_addr/perip_wen 扇出", "打开 100 MHz 的可能", "中", "中"],
    ["P0", "MDU 乘法/除法快路径扩展", "mdu_busy 占 4.7% 周期，上限 +4~5%", "小", "低"],
    ["P1", "在 v16+ 比特流上复测 CoreMark 并归档", "闭环 R6，报告口径统一", "极小", "低"],
    ["P1", "app_build_run.ps1（build→load→run 一条命令）", "交付体验", "小", "低"],
    ["P2", "BTB/PHT 1024（+1.4%，约 900 LUT）", "小", "小", "中（吃时序）"],
    ["P2", "difftest / SVA 断言 / 覆盖率统计", "把「跑通」升级为「可证明覆盖」", "中", "低"],
    ["P3", "JTAG DTM + 硬件断点", "可用性质变", "大", "中"],
    ["P3", "片外 SDRAM / SPI-Flash 存储子系统", "192 KB → MB 级", "大", "中"],
], [1.4, 7.2, 4.2, 2.0, 1.6], align=["c", "l", "l", "c", "c"], fs=8.5,
    caption="表 28　路线图")

para("一句话路线图：先把「时序余量」和「乘法停顿」两处收干净（P0），再把最新比特流的成绩补齐（P1），"
     "然后才是扩容预测表与补调试子系统——顺序反了会在 0.048 ns 的余量上翻车。")

# ================================================================== 附录
H1("附录 A　术语")
T(["术语", "含义"], [
    ["RV32IM", "32 位整数指令集 + 乘除扩展（M 模式）"],
    ["IPC / CPI", "每周期提交指令数 / 每指令周期数"],
    ["IF/ID/EX/MEM/WB", "经典五级流水：取指/译码/执行/访存/写回"],
    ["ID1/ID2、M1/M2/M3", "本核内部拆出的物理流水级"],
    ["gshare / GHR / PHT / BTB / RAS", "全局历史异或索引预测 / 全局历史寄存器 / 模式历史表 / 分支目标缓冲 / 返回地址栈"],
    ["DCache", "数据缓存（本核 256 行直接映射，写直达）"],
    ["MMIO", "内存映射 I/O（≥0x1000_0000 的不可缓存区间）"],
    ["MDU", "乘除单元（乘法 1 拍，除法 16 拍 radix-4 迭代）"],
    ["WNS / WHS", "最差建立余量 / 最差保持余量（正值表示满足约束）"],
    ["LUTRAM", "用查找表实现的分布式 RAM"],
    ["fence.i", "指令流同步指令；本核支持，用于写完代码区后刷新取指"],
], [4.6, 11.8], align=["l", "l"], fs=8.5, caption="表 29　术语")

H1("附录 B　测量条件")
T(["项", "条件"], [
    ["综合 / 实现", "Vivado 2025.2（win64, build 6299465）"],
    ["器件", "xc7z020clg484-1，速度等级 -1，生产版速度文件 1.12"],
    ["时钟约束", "create_clock -period 10.000 sys_clk（100 MHz 输入）；CPU 域为 MMCM ÷2 的 clk_sys_unbuf（20 ns）"],
    ["额外约束", "setup 不确定性 0.100 ns、hold 0.200 ns（保护带）；复位与 UART/心跳/LED 走 false_path"],
    ["软件工具链", "GCC 13.2.0，-O2 -march=rv32im -mabi=ilp32（CoreMark 官方移植层）"],
    ["CoreMark", "1.0 版，ITER=1400，总时长 10.868 s（官方要求 ≥10 s）"],
    ["仿真工具", "iverilog 12、Verilator 5.020（WSL2）"],
    ["板卡", "EES-331（xc7z020），UART 115200 8N1，COM9"],
], [3.4, 13.0], align=["l", "l"], fs=8.5, caption="表 30　测量条件")
para("本报告的性能与资源数字都依赖上表条件；更换工具版本、器件、温度模型或迭代次数会得到不同结果。")

H1("附录 C　数据溯源")
T(["结论", "证据文件"], [
    ["CoreMark 128.82 iter/s、CRCs", "上板串口日志（board_run.ps1 抓取）；镜像 sw/build/cm_*.hex"],
    ["拍数 / 停顿普查 / 误预测", "sim/tb_cm.sv 的 +perf 输出（cyc、load_use、ifu_stall、mdu_busy、mispred）"],
    ["分支预测扫参、load-use 收益与代价", "docs/CHECKPOINT_v14.md §1 与 §5b；_diag/bp_sweep.sh；_diag/build_boot_v15.log"],
    ["资源与时序", "project_src/util_post_route.boot.rpt、timing_post_route.boot.rpt；_diag/build_boot_v16.log"],
    ["P4 缺陷与修复", "docs/CHECKPOINT_v14.md §4；tb_monitor 的 [COUNT]/[RD] 轨迹"],
    ["IROM 窗口自检 / load-and-run", "sw/run_dptest.sh；板上 board_smoke.ps1 的 S3；_diag/load_app.ps1 日志"],
    ["fence.i 更正与 38 项回归", "docs/CHECKPOINT_v14.md §8「★ 更正」；sw/fenceitest.c；_diag/regress.ps1"],
], [4.4, 12.0], align=["l", "l"], fs=8.5, caption="表 31　数据溯源")

doc.save(OUT)
print("saved", OUT)
