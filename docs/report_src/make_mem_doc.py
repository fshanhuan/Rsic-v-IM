# -*- coding: utf-8 -*-
"""make_mem_doc.py — 生成《存储器专题研讨》.docx（课堂讲义 + 波形解读）

所有数字来自实测：
  sim/build/mem_trace.csv      每个时钟沿采一次（sim/tb_mem.sv 用 $fwrite 写出）
  sim/analyze_mem.py           统计（620 次取指逐条与镜像核对、脉冲宽度、UART 位宽）
  figures/存储器/*.png          sim/mem_wave.py + sim/mem_map_fig.py 画
资源数字来自 _bak/impl_reports/util_post_route.boot.rpt（Vivado 2025.2 post-route）

用法：python docs/report_src/make_mem_doc.py
"""
import os

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FIG = os.path.join(ROOT, "figures", "存储器")
OUT = os.path.join(ROOT, "docs", "存储器专题_研讨.docx")

NAVY = RGBColor(0x1F, 0x3B, 0x63)
INK = RGBColor(0x1A, 0x1A, 0x1A)
GREY = RGBColor(0x5A, 0x5F, 0x65)
ACCENT = RGBColor(0x9C, 0x27, 0x1B)

TEXT_W = 16.4  # cm

doc = Document()

# ---------------------------------------------------------------- page setup
sec = doc.sections[0]
sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
sec.top_margin, sec.bottom_margin = Cm(2.3), Cm(2.1)
sec.left_margin, sec.right_margin = Cm(2.3), Cm(2.3)
sec.header_distance, sec.footer_distance = Cm(1.2), Cm(1.1)


def set_cn_font(obj, name, size=None, bold=None, color=None):
    f = obj.font
    f.name = name
    if size is not None:
        f.size = Pt(size)
    if bold is not None:
        f.bold = bold
    if color is not None:
        f.color.rgb = color
    el = obj.element if hasattr(obj, "element") else obj._element
    rpr = el.get_or_add_rPr()
    rf = rpr.find(qn("w:rFonts"))
    if rf is None:
        rf = OxmlElement("w:rFonts")
        rpr.append(rf)
    for a in ("w:ascii", "w:hAnsi", "w:eastAsia"):
        rf.set(qn(a), name)


normal = doc.styles["Normal"]
set_cn_font(normal, "宋体", 10.5, False, INK)
normal.paragraph_format.line_spacing = 1.36
normal.paragraph_format.space_after = Pt(4)


def para(text="", size=10.5, bold=False, color=INK, name="宋体", indent=True,
         align=None, before=0, after=4, spacing=1.36, italic=False):
    p = doc.add_paragraph()
    r = p.add_run(text)
    set_cn_font(r, name, size, bold, color)
    r.font.italic = italic
    pf = p.paragraph_format
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    pf.line_spacing = spacing
    if indent:
        pf.first_line_indent = Pt(size * 2)
    if align is not None:
        p.alignment = align
    return p


def rich(parts, size=10.5, indent=True, after=4, before=0):
    """parts = [(text, bold, color_or_None), ...]"""
    p = doc.add_paragraph()
    for t, b, c in parts:
        r = p.add_run(t)
        set_cn_font(r, "宋体", size, b, c or INK)
    pf = p.paragraph_format
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    pf.line_spacing = 1.36
    if indent:
        pf.first_line_indent = Pt(size * 2)
    return p


def bullet(parts, size=10.5):
    p = doc.add_paragraph(style="List Bullet")
    if isinstance(parts, str):
        parts = [(parts, False, None)]
    for t, b, c in parts:
        r = p.add_run(t)
        set_cn_font(r, "宋体", size, b, c or INK)
    pf = p.paragraph_format
    pf.space_after = Pt(2)
    pf.line_spacing = 1.30
    pf.left_indent = Pt(16)
    return p


def h1(num, text):
    p = doc.add_paragraph()
    r = p.add_run("%s　%s" % (num, text))
    set_cn_font(r, "黑体", 14.5, True, NAVY)
    pf = p.paragraph_format
    pf.space_before = Pt(14)
    pf.space_after = Pt(6)
    pf.keep_with_next = True
    # 下划分隔线
    pPr = p._p.get_or_add_pPr()
    bd = OxmlElement("w:pBdr")
    bt = OxmlElement("w:bottom")
    bt.set(qn("w:val"), "single")
    bt.set(qn("w:sz"), "6")
    bt.set(qn("w:space"), "4")
    bt.set(qn("w:color"), "1F3B63")
    bd.append(bt)
    pPr.append(bd)
    return p


def h2(text):
    p = doc.add_paragraph()
    r = p.add_run(text)
    set_cn_font(r, "黑体", 11.5, True, NAVY)
    pf = p.paragraph_format
    pf.space_before = Pt(9)
    pf.space_after = Pt(3)
    pf.keep_with_next = True
    return p


def shade(cell, hexcolor):
    tcPr = cell._tc.get_or_add_tcPr()
    sh = OxmlElement("w:shd")
    sh.set(qn("w:val"), "clear")
    sh.set(qn("w:color"), "auto")
    sh.set(qn("w:fill"), hexcolor)
    tcPr.append(sh)


def set_borders(table, sz=4, color="BFC4CA"):
    tbl = table._tbl
    tblPr = tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement("w:%s" % edge)
        e.set(qn("w:val"), "single")
        e.set(qn("w:sz"), str(sz))
        e.set(qn("w:space"), "0")
        e.set(qn("w:color"), color)
        borders.append(e)
    tblPr.append(borders)


def table(rows, widths, size=9.0, header=True, align_center=None, zebra=True):
    """rows[0] = 表头。widths 单位 cm。"""
    t = doc.add_table(rows=len(rows), cols=len(rows[0]))
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    set_borders(t)
    for i, row in enumerate(rows):
        for j, txt in enumerate(row):
            cell = t.cell(i, j)
            cell.width = Cm(widths[j])
            cell.text = ""
            p = cell.paragraphs[0]
            r = p.add_run(str(txt))
            hdr = header and i == 0
            set_cn_font(r, "宋体", size, hdr, RGBColor(0xFF, 0xFF, 0xFF) if hdr else INK)
            pf = p.paragraph_format
            pf.space_before = Pt(1.6)
            pf.space_after = Pt(1.6)
            pf.line_spacing = 1.12
            pf.first_line_indent = Pt(0)
            if align_center is not None and j in align_center:
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            if hdr:
                shade(cell, "1F3B63")
            elif zebra and i % 2 == 0:
                shade(cell, "F2F5F8")
    # 列宽（需要逐个单元格设，Word 才认）
    for j, w in enumerate(widths):
        for i in range(len(rows)):
            t.cell(i, j).width = Cm(w)
    return t


def caption(text):
    p = doc.add_paragraph()
    r = p.add_run(text)
    set_cn_font(r, "黑体", 8.8, False, GREY)
    pf = p.paragraph_format
    pf.space_before = Pt(2)
    pf.space_after = Pt(8)
    pf.line_spacing = 1.2
    pf.first_line_indent = Pt(0)
    return p


def figure(name, width_cm, note=None):
    path = os.path.join(FIG, name)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(2)
    p.add_run().add_picture(path, width=Cm(width_cm))
    if note:
        caption(note)


# ================================================================= 封面
for _ in range(3):
    doc.add_paragraph()
p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run("存储器专题研讨")
set_cn_font(r, "黑体", 30, True, NAVY)

p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run("存储器在芯片里的位置、用途，以及存储器 I/O 接口的仿真波形")
set_cn_font(r, "黑体", 13.5, False, GREY)
p.paragraph_format.space_before = Pt(10)

for _ in range(2):
    doc.add_paragraph()

p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run("BigBird RV32 v17　·　xc7z020clg484-1　·　50 MHz（20 ns/拍）")
set_cn_font(r, "宋体", 11, False, INK)

p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run("全部波形取自 board_top 的 iverilog 仿真（真 RTL，不是另写的存储器模型）")
set_cn_font(r, "宋体", 9.5, False, GREY)

for _ in range(6):
    doc.add_paragraph()

# 封面小表：本讲要回答的 5 个问题
t = table([
    ["本讲要回答", "在哪一页找"],
    ["存储器在芯片里坐在哪、占了多少资源？", "§1（图 M1）"],
    ["一个地址为什么能同时指到两块不同的存储器？", "§2、§3"],
    ["取指和 lw/sw 对外是几根线、什么时序？", "§4、§5"],
    ["一次 load 未命中到底慢了几拍？", "§5.2（图 M3）、§6"],
    ["改代码区之后为什么能立刻执行？", "§5.6（图 M7）"],
], [12.2, 4.2], size=9.6, align_center=[1])
doc.add_page_break()

# ================================================================= §0
h1("§0", "一页速览")
para("先把结论摆出来，后面每一节都可以顺着这张表往回找证据。所有数字都是这次仿真/综合实测的，"
     "出处写在括号里：file:line 是 RTL 位置，sim/… 是可以自己重跑一遍的脚本。")

table([
    ["问题", "答案（一句话）", "证据"],
    ["存储器有几块？", "IROM 64 KB + DRAM 128 KB + DCache 1 KB + MMIO 7 个寄存器；"
                      "另有寄存器堆 32×32（在 IDU 里，用 LUTRAM）", "§1.1 表 1"],
    ["它们在哪？", "全部在 FPGA 内部：两块 BRAM（xc7z020 共 140 个 BRAM36）+ "
                  "触发器阵列；CPU 本身是逻辑", "图 M1、§1.4"],
    ["占多少资源？", "BRAM 66.5 tile（47.5%）、LUT 36 150（67.95%）、FF 34 058（32.01%）",
     "util_post_route.boot.rpt"],
    ["取指要几拍？", "请求那拍给地址，下一拍数据有效 —— 固定 1 拍延迟，无握手",
     "图 M2；sync_mem_dp.sv:91"],
    ["load 未命中几拍？", "多停 2 拍（hold 2 拍），总线上只发 1 拍读；命中 1 拍完成",
     "图 M3、§6 表 9"],
    ["store 会不会写两次？", "不会：perip_wen 恒为 1 拍脉冲，DRAM 端口也只写 1 次",
     "图 M4、§6"],
    ["MMIO 怎么走？", "地址 ≥ 0x1000_0000 一律不可缓存：读直通外设、写 1 拍直达；"
                     "UART 一位 434 拍 = 115.2 kbit/s", "图 M6、图 M8"],
    ["能改代码区吗？", "能：写 0x0002_0000 窗口 = 直接改 IROM，跳过去就能执行（shell 的 load/run）",
     "图 M7"],
], [3.9, 9.0, 3.5], size=8.8, align_center=[0])

# ================================================================= §1
h1("§1", "存储器在哪里")
h2("1.1　三块存储器 + 一个缓存 + 一个寄存器堆")
para("先把“存储器”这个词拆开。这颗核里能存东西的地方一共五处，性质完全不同：")

table([
    ["名称", "容量", "实现方式", "挂在谁身上", "地址/访问口"],
    ["IROM", "64 KB\n16384 字 × 32 b", "双口 BRAM（2R1W）",
     "board_top.irom_inst", "取指 0x0000_0000；数据窗口 0x0002_0000"],
    ["DRAM", "128 KB\n32768 字 × 32 b", "单口同步 BRAM（1R1W）",
     "board_top.dram_inst", "数据 0x0000_0000..0x0001_FFFF"],
    ["DCache", "1 KB\n256 行 × 1 字", "触发器 + 分布式 RAM",
     "myCPU.DCache_inst（LSU 与外设总线之间）", "对 CPU 透明；看 tag/index 命中"],
    ["MMIO", "7 个 32 位寄存器", "触发器",
     "board_top（uart_tx / rx_fifo / led_reg）", "0x1000_0000..0x1000_0018"],
    ["寄存器堆", "32 × 32 b", "LUTRAM / 分布式 RAM",
     "IDU.Reg_Stack_inst0", "x0..x31，x0 恒 0"],
], [1.9, 3.0, 3.2, 4.1, 4.2], size=8.6, align_center=[1])

caption("表 1　五处“能存东西”的地方。前两处是存储器，中间两处是缓存与外设，最后一处是架构寄存器。")

h2("1.2　位置与连接")
figure("M1_存储器位置与地址空间.png", 15.6)

h2("1.3　模块层次：谁例化谁")
para("板级顶层只做三件事：复位同步、存储译码、把调试口引出来。存储器数组本身在 board/ 下的两个"
     "同步 BRAM 模型里，不在 CPU 里 —— 这一点和“CPU 内部自带存储器”的写法不同，好处是换容量只改参数。")

table([
    ["层次", "文件", "干什么"],
    ["board_top", "board/board_top.sv", "例化 CPU、IROM、DRAM、MMIO，做三路译码；参数 IROM_WORDS / DRAM_WORDS"],
    ["sync_mem_dp", "board/sync_mem_dp.sv", "IROM：两个读口 + 一个写口，写在同一个 always_ff 里才会推成真双口 RAM"],
    ["sync_mem", "board/sync_mem.sv", "DRAM：同步读（ren 门控）+ 按 mask 的字节写"],
    ["myCPU", "rtl/myCPU.sv", "只出 irom_* / perip_* 两组端口，不直接例化数组"],
    ["DCache", "rtl/DCache.sv", "1 KB 直接映射、写直达；UNCACHE_MASK=0x0FFF_FFFF 分界"],
    ["LSU", "rtl/LSU.sv", "三级（M1/M2/M3），M2 那一拍把 addr/wen/wdata/mask 组合出去"],
], [2.6, 4.4, 9.4], size=8.6)

caption("表 2　存储器相关的 6 个文件。想改容量只看 board_top 的两个参数，字地址口径由 $clog2(WORDS) 自己算。")

h2("1.4　代价：一块存储器要吃掉多少 FPGA 资源")
para("这两块存储器是整颗核里最“贵”的部分之一。xc7z020 一共 140 个 BRAM36（每个 36 Kb），"
     "64 KB + 128 KB = 192 KB 就已经用掉一半：")

table([
    ["资源", "用量", "占芯片", "说明"],
    ["Block RAM Tile", "66.5", "47.50%", "RAMB36 66 个 + RAMB18 1 个（Vivado 会把 32 位宽的字打包进 36 Kb）"],
    ["LUT", "36 150", "67.95%", "CPU 逻辑 + DCache 的命中比较 + 译码"],
    ["FF", "34 058", "32.01%", "流水线寄存器、DCache 行、MMIO 寄存器"],
    ["DSP", "4", "1.82%", "MDU 的乘法"],
], [3.6, 2.4, 2.4, 8.0], size=8.8, align_center=[1, 2])

caption("表 3　post-route 资源（Vivado 2025.2，board_top_gui_boot）。容量翻倍会让 BRAM 直接顶到 90% 以上。")

rich([("一句话总结：", True, ACCENT),
      ("这颗核的“存储器”不是 CPU 内部的小数组，而是板上两块独立的 BRAM，通过两组端口线和 CPU 相连 —— "
       "所以“位置”这件事，本质是“端口在哪、地址怎么译”。", False, None)])

# ================================================================= §2
h1("§2", "地址空间与译码")
h2("2.1　两张地址空间，不是一张")
para("哈佛结构的直接后果：取指和访存是两条独立总线，各有各的地址空间。同一个数字地址 0x0000_0010 "
     "在取指口指向 IROM 第 4 个字，在数据口指向 DRAM 第 4 个字 —— 它们没有任何关系。")

table([
    ["总线", "地址区间", "落到哪", "容量", "说明"],
    ["取指 irom_*", "0x0000_0000 – 0x0000_FFFF", "IROM 端口A", "64 KB", "PC 唯一可达区"],
    ["取指 irom_*", "其余", "—", "—", "读到 0（非法指令）"],
    ["数据 perip_*", "0x0000_0000 – 0x0001_FFFF", "DRAM", "128 KB", "可缓存；软件只用 0x1_0000 以上"],
    ["数据 perip_*", "0x0002_0000 – 0x0002_FFFF", "IROM 端口B", "64 KB", "读代码/常量；v16 起可写"],
    ["数据 perip_*", "0x1000_0000 – 0x1000_00FF", "MMIO", "7 寄存器", "不可缓存，写直达外设"],
], [2.8, 5.4, 2.6, 1.8, 3.8], size=8.6, align_center=[2, 3])

caption("表 4　两张地址空间。注意 DRAM 的 0x0–0xFFFF 与取指侧同址，是故意不用的空洞（否则同一地址两个含义，调试时最容易看错）。")

h2("2.2　一根数据总线怎么分成三路")
figure("M9_三路译码.png", 15.6)

para("判定顺序只有三级，写在 board_top.sv:441 和 :546：先看 mmio_sel（addr[31:16]==0x1000 且 addr[15]==0），"
     "再看 irom_win_sel（addr[31:16]==0x0002），其余落 DRAM。三段区间互不重叠，所以不需要优先级仲裁。"
     "图 M9 把这一级译码画成了框图。")
rich([("读", True, None), ("是三选一的 mux；", False, None),
      ("写", True, None), ("必须各自门控 —— 这是唯一一处“少一个与门就出错”的地方："
                          "MMIO 写若不挡住 DRAM，一次 sw 0x10000000 会顺手把 DRAM 第 0 个字改掉。", False, None)])

h2("2.3　三条要背下来的地址约定")
bullet([("0x0000_0000 – 0x0000_FFFF：", True, None),
        ("数据侧是空洞。软件把 .text 放 IROM、.rodata/.data/.bss/栈放到 0x1_0000 以上（sw/link.ld）。", False, None)])
bullet([("0x0002_0000 – 0x0002_FFFF：", True, None),
        ("IROM 的数据窗口。lw 能读自己的代码/常量表；sw 能直接改代码区（写完跳过去就能执行）。", False, None)])
bullet([("0x1000_0000 以上：", True, None),
        ("不可缓存的分界线（DCache.sv:47 的 UNCACHE_MASK）。外设读常有副作用，缓存住就再也读不到真值。", False, None)])

# ================================================================= §3
h1("§3", "每块存储器到底在干什么")
table([
    ["存储器", "谁访问", "典型指令/动作", "在这颗核里的具体用途"],
    ["IROM", "IFU（端口A）", "取指", "固化程序：CoreMark 的 .text 23 KB、C 程序的代码段"],
    ["IROM 窗口", "LSU（端口B）", "lw / sw", "读 rodata、读自己的代码；shell 的 load/run 靠它写代码区"],
    ["DRAM", "LSU（经 DCache）", "lw / sw / lb / sb / lh / sh",
     "全局变量、.rodata 的副本、栈（0x1FFxx 一带）、堆"],
    ["DCache", "LSU 内部", "—", "把 DRAM 的 1 拍同步读叠成“命中即取”；写直达保证一致性"],
    ["MMIO", "LSU 直通", "lw / sw", "串口收发（TXDATA/TXSTAT/RXDATA/RXSTAT/RXPOP）、LED、软件重新引导"],
    ["寄存器堆", "IDU", "所有指令", "x0..x31；x0 恒 0；前递网络绕过它"],
], [2.6, 3.4, 4.0, 6.4], size=8.6)

caption("表 5　用途一览。注意 DCache 不占地址空间 —— 它对软件完全透明，只在波形上看得见。")

h2("3.1　三个“为什么”")
rich([("为什么是哈佛而不是冯·诺依曼？", True, NAVY),
      ("　取指和访存同时发生（每个周期都在取指，同时可能有一条 load 在访存），一条总线根本不够。"
       "代价是两张地址空间、软件侧要约定数据放 0x1_0000 以上。", False, None)])
rich([("为什么 DCache 只有 1 KB？", True, NAVY),
      ("　DRAM 是同步 BRAM，读固定 1 拍；1 KB / 256 行足以把 CoreMark 的热点数组盖住，"
       "而每加一行就是一个 32 位寄存器 + tag + valid。实测 CoreMark 的命中率见 §6。", False, None)])
rich([("为什么 IROM 要第二个读口？", True, NAVY),
      ("　哈佛结构下 lw 读不到代码区，程序没法读常量表、也没法自检自己的代码。"
       "BRAM36 本来就是双口，多用一个口不增加 BRAM 数量，只多一级译码（board_top.sv:135-152）。", False, None)])

# ================================================================= §4
h1("§4", "I/O 接口：六条时序规则")
para("存储器接口最容易错的地方不是“功能”，而是“第几拍有效”。把下面六条当成契约背下来，"
     "看任何一张波形都能对上号。规则全部写在 board/sync_mem.sv 与 sync_mem_dp.sv 的头部注释里。")

table([
    ["#", "规则", "含义", "违反了会怎样"],
    ["1", "同步读，固定 1 拍延迟", "T 拍给 addr 且 ren=1，T+1 拍 rdata 才有效；ren=0 时 rdata 保持旧值",
     "当拍就用 rdata → 拿到上一条请求的数据（load 值整体偏一个 index）"],
    ["2", "读必须门控 by ren", "不是自由运行读口；只在真发请求那拍采地址",
     "自由运行读口会掩盖 DCache 的握手 off-by-one，上板就变 x"],
    ["3", "写是单拍脉冲", "T 拍给 addr/wdata/mask 且 wen=1 同步写入；多给一拍就是多写一次",
     "同一条 store 连写 4 拍（v10.1 实测过）"],
    ["4", "mask 是 funct3[1:0]", "00 字节 / 01 半字 / 10 整字；字节通道由 addr[1:0] 选",
     "sb 写掉整个字"],
    ["5", "同拍读写同址 → 读回旧值", "BRAM 端口读优先于写的结果由综合决定，这里按“读旧值”写模型",
     "回填到缓存行的是新值 → 与存储器不一致"],
    ["6", "reset 不清存储阵列", "只清 rdata 寄存器；IROM 由 $readmemh、DRAM 由程序自己初始化",
     "以为复位后 DRAM 是 0，结果读到垃圾"],
], [0.8, 3.6, 6.6, 5.4], size=8.4, align_center=[0])

caption("表 6　六条接口契约。第 1、3 条是波形的骨架，第 4 条决定 sb/sh 对不对，第 6 条决定仿真与上板是否一致。")

h2("4.1　信号清单")
table([
    ["信号", "方向", "宽度", "谁驱动", "语义"],
    ["irom_en", "CPU→存储器", "1", "IFU（icache_req）", "取指读使能，只在真发一次取指那拍为 1"],
    ["irom_addr", "CPU→存储器", "32", "IFU", "字节地址，字地址 = addr[15:2]"],
    ["irom_data", "存储器→CPU", "32", "sync_mem_dp 端口A", "T+1 拍有效"],
    ["perip_ren", "CPU→存储器", "1", "DCache（mem_en）", "数据读使能，一次 load 只高 1 拍"],
    ["perip_wen", "CPU→存储器", "1", "DCache（store_req_r）", "写使能，1 拍脉冲"],
    ["perip_addr", "CPU→总线", "32", "DCache（cpu_addr_r）", "字节地址；三路译码都看它"],
    ["perip_wdata", "CPU→总线", "32", "DCache", "已按 mask 对齐的写数据"],
    ["perip_mask", "CPU→总线", "2", "LSU（funct3[1:0]）", "字节/半字/整字"],
    ["perip_rdata", "总线→CPU", "32", "三选一 mux", "T+1 拍有效（读）"],
], [2.8, 2.8, 1.4, 4.2, 5.2], size=8.4, align_center=[2])

caption("表 7　两个端口的全部信号。上板时它们在 board_top 里直接连到 BRAM 的端口，中间没有任何缓冲。")
doc.add_page_break()

# ================================================================= §5
h1("§5", "波形逐拍解读")
rich([("下面七张图来自同一次仿真：", False, None),
      ("sim/tb_mem.sv", True, None),
      (" 例化真实的 board_top，跑 sim/mem_demo.hex 这个 34 条指令的小程序，"
       "每个下降沿把存储器接口的全部信号录成 CSV，再画成图。每个格子 = 1 拍 = 20 ns。", False, None)])
para("看波形的方法：先找“谁在请求”（ren/wen 变 1 的那一格），再找“数据在哪一格有效”（下一格），"
     "最后看 CPU 有没有等（hold / stall）。下面每张图都按这三步说。")

h2("5.1　取指：给地址那拍不算数")
figure("M2_取指口_1拍延迟.png", 16.0)
para("第 12 拍 irom_en 拉高、地址 0x00；第 13 拍 rdata 才是 0x000102b7（= lui t0,0x10）。"
     "这不是“慢”，而是 BRAM 的工作方式：地址在时钟沿被采，数据在下一个沿才出来。所以 IFU 里"
     "有一个与它对齐的 resp_valid（= 请求打一拍），取指队列只在那一拍收数据。")
rich([("实测：", True, None),
      ("全程 620 次取指，逐条和 mem_demo.hex 里的镜像核对，", False, None),
      ("620/620 全部一致", True, ACCENT),
      ("（脚本：sim/analyze_mem.py 的“取指口时序”一节）。", False, None)])

h2("5.2　load：未命中多停 2 拍，命中 1 拍完成")
figure("M3_数据口_load_未命中与命中.png", 16.0)
para("第 25 拍 DCache 发现这行不驻留，立刻把 LSU 冻住（hold=1），第 26 拍才真正发出 perip_ren（只高 1 拍），"
     "第 27 拍数据回来、回填缓存行、hold 撤掉，第 28 拍第二条 lw 直接命中 —— 总线上再也看不到第二次读。")
table([
    ["拍", "发生了什么", "信号"],
    ["25", "判定未命中，冻结 LSU", "hold=1，miss=0（还没拿到数据，不算 miss）"],
    ["26", "向 DRAM 发一次读", "perip_ren=1，地址 0x0001_0000"],
    ["27", "数据回来 + 回填", "rdata=5a5aa5a5，miss=1，hold=0"],
    ["28", "第二条 lw 命中", "hit=1，perip_ren=0（总线安静）"],
], [1.2, 6.0, 9.2], size=8.6, align_center=[0])
caption("表 8　一次 miss 的四个拍。注意 miss 是在数据回来那拍才拉高 —— 它统计的是“完成了一次未命中访问”。")

h2("5.3　store：写使能只有一拍")
figure("M4_数据口_store_单拍写.png", 15.4)
para("第 25 拍 perip_wen 高 1 拍，地址、数据、掩码同拍有效，DRAM 端口的 wen 也在同一拍高 1 拍。"
     "如果这里变成高 2 拍，就会写两次 —— 对 RAM 无害，但对 MMIO 就是两次副作用，所以 DCache 里"
     "专门用“这条指令是否真的推进”（cpu_adv）来判一次，而不是用电平（DCache.sv:238）。")

h2("5.4　IROM 数据窗口：一块 BRAM 两个口同时工作")
figure("M5_IROM数据窗口.png", 16.0)
para("图 M5 是全讲的“眼”。同一时刻：上面三行是数据总线在读写 IROM 的端口B（ren 读 IROM[0]、"
     "wen 写 IROM[0x100]），下面两行是端口A 还在正常取指（地址 0x44/0x48/0x54…）。"
     "写的那一拍，DRAM 端口的 wen 必须是 0 —— 否则这次 store 会同时改掉 DRAM 第 0x100 个字。")

h2("5.5　MMIO 与串口：外设寄存器不在存储器里")
figure("M6_MMIO写与UART起始位.png", 15.4)
para("写 0x1000_0000（TXDATA）只有 1 拍，之后 uart_busy 立刻变 1、uart_tx 被拉低 = 起始位。"
     "整帧的位宽不用猜，从波形边沿直接量：")
figure("M8_UART整帧.png", 15.4)
rich([("实测：", True, None),
      ("相邻边沿间隔 434、434、2170（=5 位）、434、434 拍，位宽 434 拍 = 8.68 µs @50 MHz → ", False, None),
      ("115.2 kbit/s", True, ACCENT),
      ("，整帧 10 位 = 4 340 拍 = 86.8 µs。程序里那句轮询 busy 的循环跑了 616 轮读 TXSTAT，"
       "正好等于一帧的时间。", False, None)])

h2("5.6　写代码区然后跳过去执行")
figure("M7_写代码区后跳过去执行.png", 16.0)
para("第 4409、4411 拍，两条 store 经端口B 把 addi a5,zero,0x7b 和 jal x0,0 写进 IROM 的 0x1000/0x1004；"
     "第 4415 拍，跳转之后的取指（端口A）读回来的就是 0x7b00793 —— 刚写进去的那条指令。"
     "这条通路就是 shell 的 load/run，也是“为什么数据口必须能写代码区”的答案。")
rich([("自检：", True, None),
      ("汇编层面 a5 = 0x7B，IROM[0x400] = 0x07B0_0793、IROM[0x401] = 0x0000_006F，"
       "而 IROM[0] 必须仍是 0x0001_02B7（没被顺手写掉）。前两条证明“写进去了、执行了”，"
       "第三条是护栏 —— 见附录 B 的坑一。", False, None)])

# ================================================================= §6
h1("§6", "实测数字汇总")
table([
    ["指标", "实测值", "怎么量的"],
    ["取指次数 / 逐条核对", "620 次，620/620 与镜像一致", "analyze_mem.py 用 mem_demo.hex 逐条比对"],
    ["取指读延迟", "1 拍（固定）", "irom_en 起点 T，rdata 在 T+1"],
    ["数据总线读脉冲", "621 次（其中 616 次是 MMIO 轮询，5 次是真 load）", "perip_ren 的 0→1 起点"],
    ["数据总线写脉冲", "6 次，宽度全部为 1 拍", "perip_wen 的起点 + 宽度分布"],
    ["DRAM 实际写", "1 次（其余 5 次被 MMIO/窗口挡掉）", "dram_inst.wen"],
    ["IROM 窗口读/写", "读 3 次 / 写 3 次，写的那拍 DRAM wen 恒 0", "g_irom_rom.irom_inst.b_ren / b_wen"],
    ["load 未命中代价", "hold 2 拍，总线上 1 拍读", "dcache_hold 宽度分布（全为 2）"],
    ["DCache 命中/未命中", "1 / 5（只统计可缓存访问）", "debug_dcache_hit_cnt / miss_cnt"],
    ["UART 位宽", "434 拍 = 8.68 µs → 115.2 kbit/s；整帧 4 340 拍 = 86.8 µs", "uart_tx 边沿间隔"],
    ["程序规模 / 运行拍数", "34 条指令（0x00–0x84），跑到 4 700 拍（含 4 340 拍串口等待）", "tb_mem.sv +stop=4700"],
], [4.2, 7.0, 5.2], size=8.6)

caption("表 9　本讲用到的全部数字。想自己核对：python sim/analyze_mem.py，它会把这些再打一遍。")

rich([("一个容易混的口径：", True, ACCENT),
      ("debug_dcache_miss_cnt 只有 5，但 DCache 的 miss 端口在波形上拉高了 621 次 —— "
       "因为不可缓存访问（MMIO）永远“不驻留”，端口把它算成 miss，而计数器只数可缓存的"
       "（DCache.sv:428 的 ~uncacheable）。讲波形时别把两个数混着说。", False, None)])

# ================================================================= §7
h1("§7", "课堂上怎么演示（5 分钟版）")
para("全部脚本在工程根目录就能跑，不需要 Vivado。Windows 下用 pwsh，Linux/WSL 用 bash。")

table([
    ["#", "命令", "看到什么"],
    ["0", "pwsh sim/run_mem.ps1　（或 bash sim/run_mem.sh）", "下面 1–5 步一次跑完，最省事"],
    ["1", "python sim/gen_mem_demo.py", "重新生成 sim/mem_demo.hex（34 条指令）"],
    ["2", "iverilog -g2012 -I rtl -o sim/build/tb_mem.vvp <26 个 .sv> sim/tb_mem.sv",
     "编译（约 3 s）；文件清单见 sim/run_mem.sh 里的 RTL 变量"],
    ["3", "vvp sim/build/tb_mem.vvp +stop=4700 +vcd=tb +wave=sim/build/mem_wave_long.vcd",
     "跑完打印 22 条自检 + 生成 CSV 与 VCD"],
    ["4", "python sim/analyze_mem.py", "把数字再打一遍（取指核对、脉冲宽度、UART 位宽）"],
    ["5", "python sim/mem_wave.py && python sim/mem_map_fig.py", "重画 8 张图"],
    ["6", "gtkwave sim/build/mem_wave_long.vcd", "现场拖（可选，装 GTKWave 才有）"],
], [0.8, 8.6, 7.0], size=8.2, align_center=[0])
caption("表 10　复现步骤。第 3 步的 22 条自检里任何一条 FAIL 都不要往下讲。")

h2("7.1　现场改一个数，看波形怎么变")
bullet([("把 0x18 的 lw 改成 lw t4,4(t0)（换一个字）：", True, None),
        ("仍会 miss（不同的行），但地址变成 0x1_0004，图 M3 的地址格会跟着变。", False, None)])
bullet([("把 0x1c 的 lw 去掉：", True, None),
        ("图 M3 的命中那一段消失，总线上只剩一次读 —— 直观看到“缓存省下的是什么”。", False, None)])
bullet([("把 MMIO 写挪到 0x1000_0010（LED）：", True, None),
        ("图 M6 的 uart_tx 不再动，led 输出变化，说明 MMIO 每个地址是独立寄存器。", False, None)])

# ================================================================= §8
h1("§8", "讨论题")
qs = [
    ("如果 IROM 再加一个读口给“调试器”，BRAM 够吗？代价是什么？",
     "BRAM36 是真双口，第三个口要换成 2 块 RAM 复制内容或用 LUT 拼，容量翻倍；"
     "更省的做法是复用端口B（调试时把 CPU 停住）。"),
    ("DRAM 从 128 KB 扩到 256 KB，哪几处要改？",
     "只改 board_top 的 DRAM_WORDS；字地址索引由 $clog2(WORDS) 自己算，"
     "但软件侧 0x2_0000 窗口的边界要重新约定（会和窗口撞车）。"),
    ("为什么把 hold 缩短到 1 拍不行？",
     "同步 BRAM 的读要 1 拍才回来；hold 撤早了 LSU 会把总线上的残留值锁进写回寄存器（v9 踩过）。"),
    ("写直达 + 命中合并，会不会出现“缓存是新的、存储器是旧的”？",
     "会有一拍窗口：store 那拍先合并缓存行，写脉冲在下一拍才发到 DRAM。"
     "但任何 load 都要经过 DCache，而 DCache 已经看到新值，所以软件观察不到。"),
    ("MMIO 读为什么要幂等（peek 不弹）？",
     "DCache 的不可缓存读在 v13 之前会重发一次；读即弹会一次读吃掉两个字节 —— "
     "所以拆成 RXDATA（只看）+ RXPOP（才弹）。"),
    ("如果给这颗核加 DDR（AXI），存储器接口要改哪里？",
     "把 sync_mem 换成 AXI 从机 + 握手（valid/ready），DCache 要加 miss 状态机与写缓冲；"
     "ICache 也要从 ICache.sv 那份参考实现恢复回来。"),
    ("为什么分支预测表用分布式 RAM 而不是 BRAM？",
     "256 项 × 2 位，用 BRAM 反而浪费一个 36 Kb 的块；分布式 RAM 一两个 LUT6 就够，"
     "而且要和 IFU 同拍读，时序更短。"),
    ("这套接口契约里，哪一条最容易被后来的改动破坏？",
     "第 3 条（写单拍脉冲）。一旦把 store 改成可能冻结多拍，MMIO 会重复副作用；"
     "判据要从“电平”改成“能否推进”（DCache.sv:238 的 cpu_adv）。"),
]
for i, (q, a) in enumerate(qs, 1):
    rich([("Q%d　" % i, True, NAVY), (q, False, None)], after=1, before=4)
    rich([("提示　", True, GREY), (a, False, GREY)], size=9.6, after=4)

# ================================================================= 附录
h1("附录 A", "信号 ↔ RTL 对照")
table([
    ["波形上的名字", "RTL 里的位置", "说明"],
    ["FM_en / FM_addr / FM_rdata", "board_top.irom_en / irom_addr / irom_data",
     "取指总线（接到 IROM 端口A）"],
    ["DM_ren / DM_wen / DM_addr", "board_top.perip_ren / perip_wen / perip_addr",
     "数据总线（三路共享）"],
    ["IROM_B_ren / IROM_B_wen", "g_irom_rom.irom_inst.b_ren / b_wen", "IROM 端口B"],
    ["DRAM_ren / DRAM_wen", "dram_inst.ren / wen", "DRAM 端口（ren 未门控）"],
    ["DC_hit / DC_miss / DC_hold", "u_cpu.dcache_hit / dcache_miss / dcache_hold", "DCache 判定结果"],
    ["LSU_M1 / M2 / M3", "u_cpu.LSU_valid / LSU_valid_pipe / LSU_valid_wb", "访存三级"],
    ["DEC_mmio / DEC_win", "board_top.mmio_sel / irom_win_sel", "译码结果"],
], [4.4, 7.6, 4.4], size=8.4)

h1("附录 B", "三个真实踩过的坑")
rich([("坑一：偏移量只有 ±2 KB。", True, ACCENT),
      ("第一版演示程序写的是 sw s2,0x1000(t1)，想写到窗口 +0x1000。但 S 型立即数只有 12 位（±2048），"
       "0x1000 被截成 0 —— 于是写到了 0x2_0000，也就是 IROM 第 0 个字，把第一条指令覆盖了。"
       "程序没崩，反而“a5 莫名其妙等于 0x7B”差点被当成 PASS。修法是先把 0x2_1000 装进寄存器当基址；"
       "并且在自检里加了 IROM[0] 必须不变的断言。", False, None)])
rich([("坑二：改完代码区，流水线里还是旧内容。", True, ACCENT),
      ("写窗口之后立刻 jalr 过去，前几次取指读到的仍是被覆盖前的 0 —— 因为预取队列里已经有旧值。"
       "真实软件要 fence.i；这里靠“写完先 lw 回读一次”把跳转推后几拍，让写一定先落盘。"
       "这也是为什么 v11 之后 fence.i 是个合法空操作：ICache 被旁路了，取指直连 BRAM。", False, None)])
rich([("坑三：MMIO 读有副作用。", True, ACCENT),
      ("0x1000_0008 原来是“读即弹”的 RX FIFO 出口，结果 DCache 的不可缓存读会重发一次，"
       "一次读吃掉两个字节，命令 l 3f 变成 l3。现在 RXDATA 只 peek、RXPOP 才弹"
       "（board_top.sv:481-498 有完整证据链）。", False, None)])

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(14)
r = p.add_run("—— 讲义结束。所有图、脚本、数据都在仓库里，可以逐条重跑核对。")
set_cn_font(r, "宋体", 9.5, False, GREY)
p.alignment = WD_ALIGN_PARAGRAPH.RIGHT

doc.save(OUT)
print("wrote", OUT)
