# -*- coding: utf-8 -*-
"""
make_product_figs_v18.py — 产品手册 v18 的配图（只依赖 Pillow）。

产出（figures/）：
  v18_arch.png       整机架构总览（CPU / soc_bus / 存储 / MMIO / AXI / PS）
  v18_dualcore.png   双核协同三步的数据流与控制流
  v18_resource.png   资源占用（两块实测设计 vs xc7z020 容量）
  v18_boot.png       三种启动路径的时间线

所有数字都来自仓库内实测报告；改数字前先改报告，别只改图。
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIG = os.path.join(ROOT, "figures")
os.makedirs(FIG, exist_ok=True)

FONTS = [
    (r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\msyh.ttc"),
    (r"C:\Windows\Fonts\simhei.ttf", r"C:\Windows\Fonts\simhei.ttf"),
    (r"C:\Windows\Fonts\simsun.ttc", r"C:\Windows\Fonts\simsun.ttc"),
]

INK = (26, 38, 58)
GREY = (104, 114, 130)
LINE = (150, 160, 175)
PIPE_F, PIPE_E = (232, 241, 251), (47, 111, 181)
CPU_F, CPU_E = (247, 250, 254), (47, 111, 181)
MEM_F, MEM_E = (243, 247, 238), (111, 155, 79)
MMIO_F, MMIO_E = (253, 243, 229), (200, 127, 42)
AXI_F, AXI_E = (241, 239, 249), (110, 90, 160)
PS_F, PS_E = (236, 241, 246), (90, 105, 125)
DBG_F, DBG_E = (245, 246, 248), (140, 148, 160)
RED = (176, 58, 58)
BLUE = (34, 78, 140)


def _load(size, bold):
    for bold_path, reg_path in FONTS:
        path = bold_path if bold else reg_path
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size, index=0)
            except Exception:
                continue
    return ImageFont.load_default()


class C:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("RGB", (w, h), (255, 255, 255))
        self.d = ImageDraw.Draw(self.img)

    def t(self, x, y, s, size=28, bold=False, color=INK, anchor="la"):
        f = _load(size, bold)
        self.d.text((x, y), s, font=f, fill=color, anchor=anchor)

    def tw(self, s, size=28, bold=False):
        f = _load(size, bold)
        bb = self.d.textbbox((0, 0), s, font=f)
        return bb[2] - bb[0]

    def tc(self, cx, y, s, size=28, bold=False, color=INK):
        f = _load(size, bold)
        bb = self.d.textbbox((0, 0), s, font=f)
        self.d.text((cx - (bb[2] - bb[0]) / 2.0, y), s, font=f, fill=color)

    def box(self, x, y, w, h, title="", lines=(), fill=MEM_F, edge=MEM_E,
            ts=30, ls=24, r=12, tcolor=INK):
        self.d.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=fill,
                                 outline=edge, width=3)
        cy = y + 10
        if title:
            f = _load(ts, True)
            bb = self.d.textbbox((0, 0), title, font=f)
            self.d.text((x + (w - (bb[2] - bb[0])) / 2.0, cy), title, font=f,
                        fill=tcolor)
            cy += ts + 8
        for ln in lines:
            f = _load(ls, False)
            bb = self.d.textbbox((0, 0), ln, font=f)
            self.d.text((x + (w - (bb[2] - bb[0])) / 2.0, cy), ln, font=f,
                        fill=(76, 86, 100))
            cy += ls + 7

    def arrow(self, p1, p2, color=LINE, width=3, head=10):
        self.d.line([p1, p2], fill=color, width=width)
        ang = math.atan2(p2[1] - p1[1], p2[0] - p1[0])
        pts = [(p2[0] + head * math.cos(ang + math.radians(a)),
                p2[1] + head * math.sin(ang + math.radians(a)))
               for a in (150, -150)]
        self.d.polygon([p2] + pts, fill=color)

    def dashes(self, p1, p2, color=LINE, width=2):
        total = math.hypot(p2[0] - p1[0], p2[1] - p1[1])
        if total == 0:
            return
        ux, uy = (p2[0] - p1[0]) / total, (p2[1] - p1[1]) / total
        t = 0.0
        while t < total:
            e = min(t + 9, total)
            self.d.line([(p1[0] + ux * t, p1[1] + uy * t),
                         (p1[0] + ux * e, p1[1] + uy * e)], fill=color, width=width)
            t = e + 6

    def chain(self, y, items, h=112, width=250, gap=40, x0=None, ts=23, ls=20,
              arrow_color=None):
        n = len(items)
        total = n * width + (n - 1) * gap
        x0 = x0 if x0 is not None else (self.w - total) / 2.0
        for i, (title, lines, fill, edge) in enumerate(items):
            x = x0 + i * (width + gap)
            self.box(x, y, width, h, title, lines, fill, edge, ts=ts, ls=ls, r=10)
            if i:
                self.arrow((x - gap + 4, y + h / 2), (x - 4, y + h / 2),
                           arrow_color or edge, 3, 9)

    def save(self, name):
        path = os.path.join(FIG, name)
        self.img.save(path)
        print("OK:", path)


# =============================================================== 图 1 架构
def fig_arch():
    c = C(1500, 1090)
    c.t(36, 22, "BigBird RV32IM SoC v18 整机架构", 46, True)
    c.t(38, 84, "单时钟域 50 MHz（FCLK_CLK0）· 哈佛取指/数据双口 · 单点地址译码 · 可选 AXI4-Lite 主机口",
        24, False, GREY)

    # ---- CPU ----
    c.box(30, 128, 950, 292, "", (), CPU_F, CPU_E, r=14)
    c.t(48, 138, "CPU 核  myCPU（RV32IM + Zicsr + Zifencei，功能 5 级 / 物理 8 级）", 28, True, BLUE)
    xs, bw, gap = 50, 172, 13
    names = [("IF 取指", ["IFU 维护 PC", "预测 / 重定向"]),
             ("ID 译码", ["IDU 两级译码", "读寄存器堆"]),
             ("EX 执行", ["ALU / MDU", "分支判定"]),
             ("MEM 访存", ["LSU 三级", "DCache 直通"]),
             ("WB 写回", ["WBU 归一", "写 RF / CSR"])]
    for i, (t, ls) in enumerate(names):
        c.box(xs + i * (bw + gap), 178, bw, 96, t, ls, PIPE_F, PIPE_E, ts=26, ls=20)
        if i:
            c.arrow((xs + i * (bw + gap) - gap, 226), (xs + i * (bw + gap) - 2, 226),
                    PIPE_E, 3, 8)
    sup = [("BPU", ["256×2b BHT", "+ 256 项 BTB"]),
           ("CSR + CLINT", ["M 模式 CSR", "mtime 500 kHz"]),
           ("ALU + MDU", ["mul 1 拍", "div 17 拍"]),
           ("Control", ["前递 5 点", "冒险唯一裁决"]),
           ("DCache", ["256 行直映", "写直达 + 可失效"])]
    for i, (t, ls) in enumerate(sup):
        c.box(xs + i * (bw + gap), 292, bw, 106, t, ls, (255, 255, 255), PIPE_E,
              ts=24, ls=19)
        c.dashes((xs + i * (bw + gap) + bw / 2, 276),
                 (xs + i * (bw + gap) + bw / 2, 290), PIPE_E, 2)

    # ---- 观测口 ----
    c.box(1000, 128, 470, 292, "调试 / 观测口（不占引脚）",
          ["提交级：debug_wb_pc / reg / value",
           "异常现场：mcause / mepc / mtval",
           "计数器：ICache·DCache hit/miss",
           "停顿状态字 + mcycle（ILA 探针）",
           "串口 shell 亦可读 CSR / 内存"],
          DBG_F, DBG_E, ts=26, ls=21)

    # ---- soc_bus ----
    c.box(30, 448, 1440, 74, "", (), (232, 238, 248), (70, 100, 145), r=10)
    c.tc(750, 462, "soc_bus · 单点地址译码（DRAM 128 KB / 代码窗口 64 KB / MMIO 32 KB）· CPU 与 AXI 主机共用",
         26, True, (40, 62, 100))
    c.arrow((505, 420), (505, 446), (70, 100, 145), 3, 9)

    # ---- 存储与外设 ----
    c.box(30, 550, 300, 200, "IMEM 64 KB", ["取指口 0x0000_0000", "1 拍同步读", "无 I-Cache（旁路）"],
          MEM_F, MEM_E, ts=26, ls=21)
    c.box(350, 550, 300, 200, "DRAM 128 KB", ["0x0000_0000 起", "32 768 字", "引导器 / PS 可写"],
          MEM_F, MEM_E, ts=26, ls=21)
    c.box(670, 550, 300, 200, "代码窗口 64 KB", ["0x0002_0000 起", "IMEM 第二读口", "可读写（自举/自改）"],
          MEM_F, MEM_E, ts=26, ls=21)
    c.box(990, 550, 480, 200, "MMIO 32 KB · 0x1000_0000", [], MMIO_F, MMIO_E, ts=26)
    for i, s in enumerate(["UART TX/RX 115200 8N1", "LED[6:0] / BOOTREQ",
                           "PLIC 8 源 → MEIP", "CLINT mtime/mtimecmp",
                           "CTL：DCache 失效 / irq_ps / ALIVE"]):
        c.t(1008, 592 + i * 30, "· " + s, 21)
    c.arrow((180, 524), (180, 548), MEM_E, 3, 8)
    c.arrow((500, 524), (500, 548), MEM_E, 3, 8)
    c.arrow((820, 524), (820, 548), MEM_E, 3, 8)
    c.arrow((1230, 524), (1230, 548), MMIO_E, 3, 8)

    # ---- AXI ----
    c.box(30, 790, 920, 200, "", (), AXI_F, AXI_E, r=14)
    c.t(48, 800, "AXI4-Lite 主机口（AXIL_EN=1，与 CPU 同频同源，无跨时钟域）", 26, True, (78, 62, 120))
    c.box(50, 842, 270, 128, "axil_slave", ["AW/W/AR 分通道", "请求-授权握手", "→ 简单总线"], (255, 255, 255), AXI_E, ts=24, ls=20)
    c.box(340, 842, 270, 128, "dram_shared", ["CPU 优先", "AXI 借 CPU 空拍", "128 KB 双口"], (255, 255, 255), AXI_E, ts=24, ls=20)
    c.box(630, 842, 300, 128, "ps_ctrl", ["0x4002_0000 CTRL", "0x4002_0004 STATUS", "0x4002_0008 SCRATCH"], (255, 255, 255), AXI_E, ts=24, ls=19)
    for x in (320, 610):
        c.arrow((x, 906), (x + 20, 906), AXI_E, 3, 8)

    c.box(990, 790, 480, 200, "Zynq-7020 PS7 · ARM Cortex-A9",
          ["M_AXI_GP0 → 0x4000_0000（256 KB 窗口）",
           "FCLK_CLK0 50 MHz 供电 CPU 与 AXI",
           "IRQ_F2P ← irq_ps（GIC SPI 61..68）",
           "PS 侧：ps7_init + 裸机 ELF（COM13）"],
          PS_F, PS_E, ts=26, ls=20)
    c.arrow((972, 890), (988, 890), PS_E, 3, 9)
    c.arrow((988, 962), (972, 962), PS_E, 3, 9)

    c.t(36, 1012, "复位：btn_rst_n → reset_sync（异步置位 / 同步释放）+ 引导期 boot_busy + PS 的 ps_hold，"
                  "三者或成 cpu_rst_eff", 21, False, GREY)
    c.t(36, 1042, "存储：IMEM/DRAM 均为同步 BRAM（读 1 拍返回）；MMIO 在 DCache 里恒判为不可缓存（UNCACHE_MASK）",
        21, False, GREY)
    c.save("v18_arch.png")


# ============================================================ 图 2 双核三步
def fig_dualcore():
    c = C(1500, 1180)
    c.t(36, 22, "双核协同三步：PS 装载 → 一致性 → 双向中断", 46, True)
    c.t(38, 84, "全部在 50 MHz 单时钟域内完成；PS 与 RISC-V 之间只有 AXI4-Lite 寄存器窗口 + 128 KB 共享 DRAM",
        24, False, GREY)

    # ---------------- 第 1 步 ----------------
    c.t(40, 132, "第 1 步 · PS 把镜像灌进 DRAM，CPU 由 HOLD 按住直到放行", 30, True, BLUE)
    c.chain(180, [
        ("PS 写 CTRL.HOLD", ["复位值已是 1", "CPU 被按在复位"], PS_F, PS_E),
        ("AXI 灌 DRAM", ["5 114 字 text", "1 063 字 rodata"], AXI_F, AXI_E),
        ("DRAM 就位", ["共 6 365 字", "0x0A000 / 0x10000"], MEM_F, MEM_E),
        ("stub 搬运", ["DRAM → 0x2_0000", "fence.i 后跳转"], CPU_F, CPU_E),
        ("CPU 跑应用", ["写 CTL bit2", "STATUS.ALIVE=1"], CPU_F, CPU_E),
    ])
    c.t(40, 306, "实测：STATUS 0xb1550009（HOLD=1）→ PS 写 HOLD=0 → 0xb1550040（ALIVE=1）；"
                 "同一时刻 COM9 的 shell 横幅完整可读", 21, False, GREY)

    # ---------------- 第 2 步 ----------------
    c.t(40, 376, "第 2 步 · 一致性：PS 改了 DRAM，CPU 的 DCache 旧副本必须作废", 30, True, BLUE)
    c.chain(424, [
        ("PS 改写 DRAM", ["任意字/块", "CPU 不知情"], PS_F, PS_E),
        ("DCache 旧副本", ["读命中 → 旧值", "写直达不救读"], MEM_F, MEM_E),
        ("写 MMIO CTL bit0", ["0x1000_001C", "一拍脉冲"], CPU_F, CPU_E),
        ("DCache 全表清零", ["valid ← 0", "四个命中项加 ~inval"], CPU_F, CPU_E),
        ("重新 load", ["读到 0x2222", "（旧值 0x1111）"], CPU_F, CPU_E),
    ])
    c.t(40, 550, "证据：仿真 tb_dcache_stale 先复现陈旧读（S2 = 0x1111），再验证失效后转正（S3 = 0x2222），4/4 通过；"
                 "真板未单独留这一步的日志", 21, False, GREY)

    # ---------------- 第 3 步 ----------------
    c.t(40, 620, "第 3 步 · 双向中断：CPU 敲 PS 走 GIC SPI，PS 敲 CPU 走 PLIC 源 4", 30, True, BLUE)
    c.t(40, 668, "① CPU → PS（电平 irq_ps，PS 负责清零）", 23, True, (78, 62, 120))
    c.chain(700, [
        ("CPU 写 CTL bit1", ["0x1000_001C", "irq_ps = 1"], CPU_F, CPU_E),
        ("GIC SPI 61..68", ["IRQ_F2P 进 PS", "电平敏感"], PS_F, PS_E),
        ("PS ISR", ["读 SH_MSG", "回写 SH_ACK"], PS_F, PS_E),
    ], width=380, gap=90, h=112)
    c.t(40, 852, "② PS → CPU（电平 ps_irq，CPU claim 后由 PS 清）", 23, True, (78, 62, 120))
    c.chain(884, [
        ("PS 写 CTRL.bit1", ["0x4002_0000", "ps_irq = 1"], PS_F, PS_E),
        ("PLIC 源 4", ["→ CSR.mip.MEIP", "8 源优先级"], AXI_F, AXI_E),
        ("CPU 进 ISR", ["claim → 清 pending", "mret 返回"], CPU_F, CPU_E),
    ], width=380, gap=90, h=112)
    c.t(40, 1032, "实测：SH_MSG = 0xDEADBEEF、SH_ACK = 0x0000ACED、SH_NIRQ = 2950；"
                  "电平源不屏蔽时会反复打断（见 §9 限制 L4）", 21, False, GREY)
    c.t(40, 1080, "注：第 2 步的 MMIO 位与 stub 用的是同一个寄存器（bit0 失效 / bit1 irq_ps / bit2 ALIVE），互不干扰。",
        21, False, GREY)
    c.save("v18_dualcore.png")


# ============================================================== 图 3 资源
def fig_resource():
    W, H = 1500, 720
    c = C(W, H)
    c.t(36, 22, "资源占用：两块实测设计相对 xc7z020clg484-1 的容量", 44, True)
    c.t(38, 82, "数据来自 reports/util_v18_final.rpt（board_top_gui_boot）与 reports/util_ps_final.rpt（soc_ps_wrapper）",
        23, False, GREY)

    items = [("Slice LUT", 68.12, 68.12, "36 241 / 53 200"),
             ("Slice FF", 32.01, 26.83, "34 054 / 28 543"),
             ("Block RAM", 47.50, 34.29, "66.5 / 48（共 140）"),
             ("DSP", 1.82, 1.82, "4 / 4（共 220）")]
    left, right, top, bottom = 210, W - 90, 220, 590
    vmax = 90.0

    def yv(v):
        return bottom - (bottom - top) * min(v, vmax) / vmax

    for gv in range(0, 91, 10):
        y = yv(gv)
        c.d.line([(left, y), (right, y)], fill=(231, 235, 241), width=1)
        c.t(left - 74, y - 12, f"{gv}%", 20, False, (150, 158, 170))
    c.d.line([(left, top), (right, top)], fill=(200, 90, 90), width=2)
    c.t(right - 6, top - 32, "器件上限 100%", 20, False, (176, 58, 58), anchor="ra")

    slot = (right - left) / len(items)
    bw = 74
    for i, (name, a, b, note) in enumerate(items):
        cx = left + slot * (i + 0.5)
        close = abs(a - b) < 6
        for k, (v, colr, tcol) in enumerate([(a, (58, 106, 176), (30, 60, 120)),
                                             (b, (150, 178, 210), (60, 80, 110))]):
            x = cx + (k - 0.5) * (bw + 8) - bw / 2 + 8
            y = yv(v)
            c.d.rounded_rectangle([x, y, x + bw, bottom], radius=5, fill=colr)
            ly = y - 32 - (28 if (close and k == 0) else 0)
            c.tc(x + bw / 2, ly, f"{v:.2f}%", 22, True, tcol)
        c.tc(cx, bottom + 16, name, 24, True, (50, 62, 82))
        c.tc(cx, bottom + 50, note, 20, False, (110, 120, 136))

    c.d.rounded_rectangle([left, 148, left + 26, 168], radius=4, fill=(58, 106, 176))
    c.t(left + 36, 142, "v18 独立板级设计（含 ILA 采集）", 22)
    c.d.rounded_rectangle([left + 470, 148, left + 496, 168], radius=4, fill=(150, 178, 210))
    c.t(left + 506, 142, "PS 双核设计（无 ILA）", 22)

    c.t(38, 668, "两块设计 Slice LUT 恰好都是 36 241；差异集中在 FF 与 BRAM —— ILA 的采集缓冲用 FF/BRAM，不用额外 LUT。",
        21, False, GREY)
    c.save("v18_resource.png")


# ============================================================ 图 4 启动路径
def fig_boot():
    c = C(1500, 780)
    c.t(36, 22, "三种启动路径（IROM_BOOT 参数）", 44, True)
    c.t(38, 82, "同一份 RTL，只改一个参数：0 = ROM 固化，1 = 串口引导，2 = PS 装载（双核设计默认）",
        23, False, GREY)

    SB, OR, PU, GR = (236, 241, 246), (253, 243, 229), (241, 239, 249), (232, 241, 251)
    rows = [
        ("0 · ROM 固化",
         ["综合时 $readmemh 固化", "改程序 = 重跑综合"],
         [(0.00, 0.30, "上电 / 复位", SB), (0.32, 1.00, "CPU 直接从 IROM 取指（无引导器）", GR)]),
        ("1 · 串口引导",
         ["主机发帧灌 IROM", "改程序约 1 s"],
         [(0.00, 0.13, "复位", SB), (0.14, 0.40, "等 magic（5 s 超时）", OR),
          (0.41, 0.78, "灌 64 KB 镜像 + 校验", PU), (0.79, 1.00, "跑", GR)]),
        ("2 · PS 装载",
         ["PS 经 AXI 写 DRAM", "CPU 由 ps_hold 按住"],
         [(0.00, 0.16, "HOLD=1\nCPU 复位", SB), (0.17, 0.43, "PS 经 AXI 灌 DRAM", PU),
          (0.44, 0.54, "HOLD=0", OR), (0.55, 0.77, "stub 搬运", GR),
          (0.78, 1.00, "跳转 + ALIVE", GR)]),
    ]
    x0, x1 = 440, 1470
    for r, (name, desc, segs) in enumerate(rows):
        y = 150 + r * 195
        c.t(40, y + 6, name, 27, True, BLUE)
        for k, ln in enumerate(desc):
            c.t(40, y + 46 + k * 30, ln, 20, False, GREY)
        for (a, b, txt, fill) in segs:
            xa, xb = x0 + (x1 - x0) * a, x0 + (x1 - x0) * b
            c.d.rounded_rectangle([xa, y, xb, y + 92], radius=8, fill=fill,
                                  outline=(170, 178, 190), width=2)
            parts = txt.split("\n")
            for k, p in enumerate(parts):
                c.tc((xa + xb) / 2, y + 26 + k * 30 - (len(parts) - 1) * 8, p, 20, False, (40, 52, 72))

    c.t(38, 742, "判据：模式 0/1/2 的选择不改 CPU RTL；模式 2 下若没有主机放行，CPU 永远停在复位 —— 有意为之的安全默认。",
        21, False, GREY)
    c.save("v18_boot.png")


if __name__ == "__main__":
    fig_arch()
    fig_dualcore()
    fig_resource()
    fig_boot()
