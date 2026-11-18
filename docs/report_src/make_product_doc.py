# -*- coding: utf-8 -*-
"""
make_product_doc.py — 把 docs/产品手册_v18.md 排成一份可交付的 Word 手册。

排版包含：封面、文档信息页、自动目录（TOC 域）、页面页脚、章节分页、
表格（表头重复 + 固定列宽）、代码块、引用块、配图与图注。

用法：
    python docs/report_src/make_product_doc.py
    python docs/report_src/make_product_doc.py --md docs/xxx.md --out docs/xxx.docx
"""
import argparse
import os
import re

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

TITLE = "BigBird RV32IM SoC v18 产品手册"
SUBTITLE = [
    "单时钟域 50 MHz · 稳态 1 IPC · 2.58 CoreMark/MHz",
    "总线化 SoC + PLIC/CLINT + AXI4-Lite + Zynq PS 双核协同",
]
DOC_NO = "BB-RV32-SOC-MAN-018"
VERSION = "v18"
DATE = "2026-11-11"
DEVICE = "Xilinx Zynq-7020  xc7z020clg484-1"
ORG = "BigBird RV32 项目组"

FONT_H = "微软雅黑"
FONT_B = "宋体"
FONT_L = "Times New Roman"
FONT_M = "Consolas"

ACCENT = RGBColor(0x1F, 0x3B, 0x63)
ACCENT2 = RGBColor(0x24, 0x4A, 0x77)
GREY = RGBColor(0x5A, 0x62, 0x70)
CODE_RED = RGBColor(0x8B, 0x2E, 0x2E)

BODY_W = 16.6  # cm，正文可用宽度
BREAK_BEFORE_CHAPTER = False  # True = 每章另起一页（页数多、章末留白多）


# ----------------------------------------------------------------- 底层工具
def set_run(run, cjk=FONT_B, latin=FONT_L, size=None, bold=None, italic=None,
            color=None, mono=False):
    if mono:
        cjk = latin = FONT_M
    run.font.name = latin
    rpr = run._element.get_or_add_rPr()
    rf = rpr.find(qn("w:rFonts"))
    if rf is None:
        rf = OxmlElement("w:rFonts")
        rpr.append(rf)
    rf.set(qn("w:ascii"), latin)
    rf.set(qn("w:hAnsi"), latin)
    rf.set(qn("w:eastAsia"), cjk)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.font.bold = bold
    if italic is not None:
        run.font.italic = italic
    if color is not None:
        run.font.color.rgb = color


def shade_el(el, prop_tag, fill):
    pr = el.find(qn(prop_tag))
    if pr is None:
        pr = OxmlElement(prop_tag)
        el.append(pr)
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    pr.append(shd)


def para_shade(p, fill):
    shade_el(p._p.get_or_add_pPr(), "w:pPr", fill)


def cell_shade(cell, fill):
    shade_el(cell._tc.get_or_add_tcPr(), "w:tcPr", fill)


def para_border(p, edges=("left",), color="1F3B63", sz="12"):
    ppr = p._p.get_or_add_pPr()
    pbdr = OxmlElement("w:pBdr")
    for e in edges:
        el = OxmlElement("w:" + e)
        el.set(qn("w:val"), "single")
        el.set(qn("w:sz"), sz)
        el.set(qn("w:space"), "6")
        el.set(qn("w:color"), color)
        pbdr.append(el)
    ppr.append(pbdr)


def repeat_header(row):
    trpr = row._tr.get_or_add_trPr()
    th = OxmlElement("w:tblHeader")
    th.set(qn("w:val"), "true")
    trpr.append(th)
    cs = OxmlElement("w:cantSplit")
    trpr.append(cs)


def fixed_layout(table):
    tblpr = table._tbl.tblPr
    lay = OxmlElement("w:tblLayout")
    lay.set(qn("w:type"), "fixed")
    tblpr.append(lay)


def add_field(paragraph, instr, placeholder="1"):
    fld = OxmlElement("w:fldSimple")
    fld.set(qn("w:instr"), instr)
    r = OxmlElement("w:r")
    rpr = OxmlElement("w:rPr")
    sz = OxmlElement("w:sz")
    sz.set(qn("w:val"), "18")
    rpr.append(sz)
    r.append(rpr)
    t = OxmlElement("w:t")
    t.text = placeholder
    r.append(t)
    fld.append(r)
    paragraph._p.append(fld)


# ----------------------------------------------------------------- 解析 MD
INLINE = re.compile(r"(\*\*.+?\*\*|`[^`]+`)")


def add_inline(paragraph, text, size=10.5, cjk=FONT_B, color=None, bold=False,
               depth=0):
    for tok in INLINE.split(text):
        if not tok:
            continue
        if tok.startswith("**") and tok.endswith("**") and len(tok) > 4:
            add_inline(paragraph, tok[2:-2], size=size, cjk=FONT_H,
                       color=color or ACCENT, bold=True, depth=depth + 1)
        elif tok.startswith("`") and tok.endswith("`") and len(tok) > 2:
            r = paragraph.add_run(tok[1:-1])
            set_run(r, size=size - 0.5, mono=True, bold=bold, color=CODE_RED)
        else:
            r = paragraph.add_run(tok)
            set_run(r, cjk=cjk, size=size, bold=bold, color=color)


def parse(md_text):
    lines = md_text.splitlines()
    blocks, i = [], 0
    while i < len(lines):
        s = lines[i].strip()
        if not s:
            i += 1
            continue
        if s.startswith("```"):
            buf = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            blocks.append(("code", buf))
            continue
        if re.fullmatch(r"-{3,}", s):
            blocks.append(("hr", None))
            i += 1
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", s)
        if m:
            blocks.append((f"h{len(m.group(1))}", m.group(2).strip()))
            i += 1
            continue
        if s.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(lines[i].strip())
                i += 1
            blocks.append(("table", rows))
            continue
        if s.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip().lstrip(">").strip())
                i += 1
            blocks.append(("quote", buf))
            continue
        m = re.match(r"^!\[(.*?)\]\((.*?)\)$", s)
        if m:
            blocks.append(("img", (m.group(1), m.group(2))))
            i += 1
            continue
        if re.match(r"^[-*]\s+", s):
            buf = []
            while i < len(lines) and re.match(r"^[-*]\s+", lines[i].strip()):
                buf.append(re.sub(r"^[-*]\s+", "", lines[i].strip()))
                i += 1
            blocks.append(("ul", buf))
            continue
        if re.match(r"^\d+\.\s+", s):
            buf = []
            while i < len(lines) and re.match(r"^\d+\.\s+", lines[i].strip()):
                buf.append(re.sub(r"^\d+\.\s+", "", lines[i].strip()))
                i += 1
            blocks.append(("ol", buf))
            continue
        buf = [s]
        i += 1
        while i < len(lines):
            nx = lines[i].strip()
            if (not nx or nx.startswith(("#", "|", ">", "```"))
                    or re.match(r"^[-*]\s+", nx) or re.match(r"^\d+\.\s+", nx)
                    or re.fullmatch(r"-{3,}", nx)
                    or re.match(r"^!\[.*?\]\(.*?\)$", nx)):
                break
            buf.append(nx)
            i += 1
        blocks.append(("p", " ".join(buf)))
    return blocks


def split_table(rows):
    out = []
    for r in rows:
        if re.fullmatch(r"\|[\s:|-]+\|", r):
            continue
        body = r.strip()
        if body.startswith("|"):
            body = body[1:]
        if body.endswith("|"):
            body = body[:-1]
        # 单元格里的 `\|` 是转义的竖线，不参与分列
        out.append([c.strip().replace("\\|", "|")
                    for c in re.split(r"(?<!\\)\|", body)])
    return out


def text_width(s, size):
    """粗略估算显示宽度（中文按 1 个 em，ASCII 按 0.55 em）。"""
    w = 0.0
    for ch in s:
        w += 1.0 if ord(ch) > 0x2E80 else 0.55
    return w * size


# ----------------------------------------------------------------- 文档骨架
def setup_doc():
    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
    sec.left_margin = sec.right_margin = Cm(2.2)
    sec.top_margin = Cm(2.2)
    sec.bottom_margin = Cm(2.0)
    sec.header_distance = Cm(1.2)
    sec.footer_distance = Cm(1.1)
    sec.different_first_page_header_footer = True

    # 去掉文档网格：否则 Word 会把每行吸附到 18pt 行距，正文被拉成两倍行高
    for grid in sec._sectPr.findall(qn("w:docGrid")):
        sec._sectPr.remove(grid)

    normal = doc.styles["Normal"]
    normal.font.size = Pt(10.5)
    normal.font.name = FONT_L
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), FONT_B)
    pf = normal.paragraph_format
    pf.line_spacing = 1.4
    pf.space_after = Pt(4)
    ppr = normal.element.get_or_add_pPr()
    snap = OxmlElement("w:snapToGrid")
    snap.set(qn("w:val"), "0")
    ppr.append(snap)

    for name, size, color, before, after in [
            ("Heading 1", 17, ACCENT, 6, 12),
            ("Heading 2", 13, ACCENT2, 12, 6),
            ("Heading 3", 11.5, RGBColor(0x33, 0x40, 0x55), 10, 4)]:
        st = doc.styles[name]
        st.font.size = Pt(size)
        st.font.name = FONT_H
        st.font.bold = True
        st.font.color.rgb = color
        try:
            st.element.rPr.rFonts.set(qn("w:eastAsia"), FONT_H)
        except Exception:
            rpr = st.element.get_or_add_rPr()
            rf = OxmlElement("w:rFonts")
            rf.set(qn("w:eastAsia"), FONT_H)
            rpr.append(rf)
        st.paragraph_format.space_before = Pt(before)
        st.paragraph_format.space_after = Pt(after)
        st.paragraph_format.keep_with_next = True
        st.paragraph_format.line_spacing = 1.2

    # 页眉（从第 2 页起）
    hp = sec.header.paragraphs[0]
    hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    r = hp.add_run(TITLE)
    set_run(r, cjk=FONT_H, size=8.5, color=GREY)
    para_border(hp, ("bottom",), "C9D2E0", "6")

    # 页脚：第 X 页 / 共 Y 页
    fp = sec.footer.paragraphs[0]
    fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = fp.add_run("第 ")
    set_run(r, size=8.5, color=GREY)
    add_field(fp, " PAGE ", "1")
    r = fp.add_run(" 页 / 共 ")
    set_run(r, size=8.5, color=GREY)
    add_field(fp, " NUMPAGES ", "1")
    r = fp.add_run(" 页")
    set_run(r, size=8.5, color=GREY)
    return doc


def page_break(doc):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(0)
    p.add_run().add_break(WD_BREAK.PAGE)


def cover(doc, subtitle_lines, meta_lines):
    doc.add_paragraph()

    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(2)
    r = p.add_run("PRODUCT MANUAL")
    set_run(r, cjk=FONT_H, size=10, color=ACCENT, bold=True)

    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.1
    r = p.add_run(TITLE)
    set_run(r, cjk=FONT_H, latin=FONT_H, size=26, bold=True, color=ACCENT)

    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(10)
    p.paragraph_format.space_before = Pt(0)
    para_border(p, ("bottom",), "1F3B63", "14")
    p.paragraph_format.line_spacing = 1.0
    r = p.add_run("")
    set_run(r, size=1)

    for ln in subtitle_lines:
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.line_spacing = 1.3
        r = p.add_run(ln)
        set_run(r, cjk=FONT_H, latin=FONT_H, size=11, color=GREY)

    for _ in range(3):
        doc.add_paragraph()

    rows = [("文档编号", DOC_NO), ("版本", VERSION), ("发布日期", DATE),
            ("目标器件", DEVICE), ("适用工具", "Vivado 2025.2 / riscv64-elf-gcc 13.2")]
    table = doc.add_table(rows=0, cols=2)
    table.autofit = False
    fixed_layout(table)
    for k, v in rows:
        row = table.add_row()
        row.cells[0].width = Cm(3.8)
        row.cells[1].width = Cm(11.2)
        c0, c1 = row.cells
        p0 = c0.paragraphs[0]
        p0.paragraph_format.space_after = Pt(2)
        p0.paragraph_format.line_spacing = 1.2
        r = p0.add_run(k)
        set_run(r, cjk=FONT_H, size=9.5, color=GREY)
        p1 = c1.paragraphs[0]
        p1.paragraph_format.space_after = Pt(2)
        p1.paragraph_format.line_spacing = 1.2
        r = p1.add_run(v)
        set_run(r, size=9.5, bold=True, color=ACCENT2)

    for _ in range(4):
        doc.add_paragraph()
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(2)
    r = p.add_run(ORG)
    set_run(r, cjk=FONT_H, size=12, bold=True, color=ACCENT)
    p = doc.add_paragraph()
    p.paragraph_format.line_spacing = 1.3
    r = p.add_run("本手册中的全部性能、资源与时序数字均取自本仓库实测报告，可用第 7 章的命令复现。")
    set_run(r, size=9, color=GREY)


def info_page(doc):
    page_break(doc)
    p = doc.add_paragraph()
    r = p.add_run("文档信息")
    set_run(r, cjk=FONT_H, size=15, bold=True, color=ACCENT)
    p.paragraph_format.space_after = Pt(10)

    body = [
        ("文档目的", "向选型、集成与二次开发人员说明 BigBird RV32IM SoC v18 的架构、规格、寄存器、"
                     "启动流程、软件栈、验证结论与使用限制。"),
        ("适用读者", "FPGA / SoC 系统设计者、嵌入式软件工程师、教学与科研平台的选型与验收人员。"),
        ("版本对应", "对应源码状态：2026-11-11 的 rtl/ 与 board/；回归 53 项全过；"
                     "构建产物 v9_boot（纯 RISC-V）与 ps_bd（PS 双核）。"),
        ("数字口径", "所有性能/资源/时序数字均为实测值，未做估算填充；未测项（功耗、扫频上限）"
                     "在正文中明确标注为“未做”。"),
        ("阅读建议", "选型看第 1、3 章；集成看第 2、4、5 章；写软件看第 6 章；验收看第 7、8 章；"
                     "上手前必读第 9 章限制。"),
        ("文档约定", "地址与寄存器一律十六进制；`0x` 前缀省略时仍为十六进制；"
                     "“板级设计”指含 ILA 的 v18 构建，“PS 双核设计”指 soc_ps_wrapper。"),
    ]
    table = doc.add_table(rows=0, cols=2)
    table.style = "Table Grid"
    table.autofit = False
    fixed_layout(table)
    for k, v in body:
        row = table.add_row()
        row.cells[0].width = Cm(3.2)
        row.cells[1].width = Cm(13.4)
        cell_shade(row.cells[0], "E8EFF8")
        p0 = row.cells[0].paragraphs[0]
        p0.paragraph_format.space_after = Pt(2)
        r = p0.add_run(k)
        set_run(r, cjk=FONT_H, size=9.5, bold=True, color=ACCENT)
        p1 = row.cells[1].paragraphs[0]
        p1.paragraph_format.space_after = Pt(2)
        add_inline(p1, v, size=9.5)

    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(16)
    r = p.add_run("目录")
    set_run(r, cjk=FONT_H, size=15, bold=True, color=ACCENT)
    p.paragraph_format.space_after = Pt(8)

    p = doc.add_paragraph()
    add_field(p, ' TOC \\o "1-2" \\h \\z \\u ', "打开文档后按 F9 更新目录")
    for r in p.runs:
        set_run(r, size=10)
    page_break(doc)


# ----------------------------------------------------------------- 主流程
def build(md_path, out_path):
    with open(md_path, encoding="utf-8") as fh:
        blocks = parse(fh.read())

    doc = setup_doc()

    # 封面副标题：取 H1 之后第一个引用块
    if blocks and blocks[0][0] == "h1":
        blocks = blocks[1:]
    meta_lines = []
    if blocks and blocks[0][0] == "quote":
        kind, payload = blocks.pop(0)
        txt = " ".join(payload)
        meta_lines = [part.strip() for part in re.split(r"[｜|]", txt) if part.strip()]
    while blocks and blocks[0][0] == "hr":
        blocks.pop(0)

    cover(doc, SUBTITLE, meta_lines)
    info_page(doc)

    first_h2 = True
    for kind, payload in blocks:
        if kind == "h2":
            if BREAK_BEFORE_CHAPTER and not first_h2:
                page_break(doc)
            first_h2 = False
            p = doc.add_paragraph(style="Heading 1")
            if not BREAK_BEFORE_CHAPTER:
                p.paragraph_format.space_before = Pt(20)
            add_inline(p, payload, size=17, cjk=FONT_H, color=ACCENT, bold=True)
            para_border(p, ("bottom",), "D5DCE8", "8")
            continue
        if kind == "h1":
            p = doc.add_paragraph(style="Heading 1")
            add_inline(p, payload, size=17, cjk=FONT_H, color=ACCENT, bold=True)
            continue
        if kind in ("h3", "h4"):
            p = doc.add_paragraph(style="Heading 2" if kind == "h3" else "Heading 3")
            size = 13 if kind == "h3" else 11.5
            col = ACCENT2 if kind == "h3" else RGBColor(0x33, 0x40, 0x55)
            add_inline(p, payload, size=size, cjk=FONT_H, color=col, bold=True)
            continue
        if kind == "p":
            p = doc.add_paragraph()
            p.paragraph_format.first_line_indent = Pt(0)
            add_inline(p, payload)
            continue
        if kind == "ul":
            for item in payload:
                p = doc.add_paragraph(style="List Bullet")
                p.paragraph_format.space_after = Pt(2)
                p.paragraph_format.line_spacing = 1.35
                add_inline(p, item)
            continue
        if kind == "ol":
            for idx, item in enumerate(payload, 1):
                p = doc.add_paragraph()
                p.paragraph_format.left_indent = Cm(0.9)
                p.paragraph_format.first_line_indent = Cm(-0.9)
                p.paragraph_format.space_after = Pt(2)
                r = p.add_run("%d. " % idx)
                set_run(r, size=10.5, bold=True, color=ACCENT2)
                add_inline(p, item)
            continue
        if kind == "quote":
            for item in payload:
                p = doc.add_paragraph()
                p.paragraph_format.left_indent = Cm(0.3)
                p.paragraph_format.space_after = Pt(2)
                p.paragraph_format.line_spacing = 1.35
                para_shade(p, "F4F6FA")
                para_border(p, ("left",), "7A93B8", "12")
                add_inline(p, item, size=10, color=RGBColor(0x33, 0x3D, 0x4D))
            continue
        if kind == "code":
            for item in payload:
                p = doc.add_paragraph()
                pf = p.paragraph_format
                pf.space_after = Pt(0)
                pf.space_before = Pt(0)
                pf.left_indent = Cm(0.3)
                pf.line_spacing = 1.0
                para_shade(p, "F5F5F5")
                r = p.add_run(item if item else " ")
                set_run(r, size=8.5, mono=True, color=RGBColor(0x1A, 0x1A, 0x1A))
            tail = doc.add_paragraph()
            tail.paragraph_format.space_after = Pt(6)
            continue
        if kind == "img":
            alt, path = payload
            full = os.path.normpath(os.path.join(os.path.dirname(md_path), path))
            if not os.path.exists(full):
                print("WARN missing image:", full)
                continue
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(6)
            p.paragraph_format.space_after = Pt(3)
            p.paragraph_format.line_spacing = 1.0
            p.paragraph_format.keep_with_next = True
            p.add_run().add_picture(full, width=Cm(16.0))
            cap = doc.add_paragraph()
            cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
            cap.paragraph_format.space_after = Pt(10)
            r = cap.add_run(alt)
            set_run(r, cjk=FONT_H, size=9, color=GREY, italic=True)
            continue
        if kind == "table":
            rows = split_table(payload)
            if not rows:
                continue
            ncol = max(len(r) for r in rows)
            if any(len(r) != ncol for r in rows):
                print("WARN ragged table near:", rows[0][:2])
            rows = [r + [""] * (ncol - len(r)) for r in rows]

            # 列宽：先保证每列容得下表头，再把剩余宽度按需求分配
            mins, wants = [], []
            for ci in range(ncol):
                head_cm = text_width(rows[0][ci], 9) * 1.05 * 0.0353 + 0.42
                body = max((text_width(r[ci], 9) for r in rows[1:]), default=0.0)
                body_cm = min(body, 420.0) * 0.0353 + 0.42
                mins.append(head_cm)
                wants.append(max(head_cm, body_cm))

            total_min = sum(mins)
            if total_min > BODY_W:
                widths = [m * BODY_W / total_min for m in mins]
            else:
                extra = BODY_W - total_min
                demand = [w - m for w, m in zip(wants, mins)]
                sd = sum(demand)
                if sd <= extra:
                    left = extra - sd
                    sw = sum(wants)
                    widths = [w + left * w / sw for w in wants]
                else:
                    widths = [m + extra * d / sd for m, d in zip(mins, demand)]

            table = doc.add_table(rows=0, cols=ncol)
            table.style = "Table Grid"
            table.alignment = WD_TABLE_ALIGNMENT.CENTER
            table.autofit = False
            fixed_layout(table)
            keep_together = len(rows) <= 10
            for ri, cells in enumerate(rows):
                row = table.add_row()
                if ri == 0:
                    repeat_header(row)
                for ci in range(ncol):
                    cell = row.cells[ci]
                    cell.width = Cm(widths[ci])
                    cell.text = ""
                    p = cell.paragraphs[0]
                    pf = p.paragraph_format
                    pf.space_after = Pt(1)
                    pf.space_before = Pt(1)
                    p.paragraph_format.line_spacing = 1.15
                    if keep_together and ri < len(rows) - 1:
                        p.paragraph_format.keep_with_next = True
                    if ri == 0:
                        cell_shade(cell, "E8EFF8")
                        pf.keep_with_next = True
                        add_inline(p, cells[ci], size=9, cjk=FONT_H,
                                   color=ACCENT, bold=True)
                    else:
                        add_inline(p, cells[ci], size=9)
            spacer = doc.add_paragraph()
            spacer.paragraph_format.space_after = Pt(6)
            continue
        if kind == "hr":
            # 章节之间已有标题分隔线，Markdown 里剩下的分隔线只留一点空隙
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            r = p.add_run("")
            set_run(r, size=2)
            continue

    doc.save(out_path)
    print("saved:", out_path)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", default=os.path.join(ROOT, "docs", "产品手册_v18.md"))
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "产品手册_v18.docx"))
    a = ap.parse_args()
    build(a.md, a.out)
