#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_rtl_concat.py — 把 CPU 的 RTL 源码拼成**单文件**，方便整份复制给网页 AI。

输出：
    figures/讲解/CPU_RTL合集.sv

要点：
  * 文件清单是**显式写死**的（不靠 glob），避免漏文件 / 顺序错。
  * 包含 `experimental/MDU_pipelined.sv` —— 这才是 EXU 真正例化的 MDU
    （`EXU.sv` 里 `MDU_pipelined MDU_i0 (...)`）。
  * `MDU.sv` 是**未被任何模块例化**的遗留纯组合实现，仍然收进来，
    但 banner 里会标注清楚，免得 AI 拿它当"当前实现"。
  * 不改任何 RTL，只读 + 拼接。

用法：
    python3 sim/gen_rtl_concat.py            # 生成
    python3 sim/gen_rtl_concat.py --check    # 只校验现有合集是否与源码逐字一致
"""
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
OUT = os.path.join(_ROOT, "figures", "讲解", "CPU_RTL合集.sv")

# (相对路径, 角色说明)
FILES = [
    ("para.sv",                          "宏/参数（ICACHE_INDEX_BITS、`NOP 等）"),
    ("add.sv",                           "加法器"),
    ("sext.sv",                          "立即数扩展"),
    ("Reg.sv",                           "通用寄存器单元"),
    ("ALU.sv",                           "算术逻辑单元"),
    ("MDU.sv",                           "**遗留**：纯组合乘除法，当前**无人例化**"),
    ("experimental/MDU_pipelined.sv",    "★当前实现★：时序化乘除法（EXU 里 MDU_i0 就是它）"),
    ("RegisterFile.sv",                  "寄存器堆"),
    ("Reg_Stack.sv",                     "寄存器堆 + 内部前递选择"),
    ("Branch_Predictor.sv",              "gshare 分支预测器（BTB + PHT + GHR）"),
    ("CSR.sv",                           "控制状态寄存器 / 异常入口"),
    ("ICache.sv",                        "指令 Cache（同步读，行大小 1 字）"),
    ("DCache.sv",                        "数据 Cache + 写缓冲"),
    ("Data_hazard.sv",                   "前递/冒险判定"),
    ("Control.sv",                       "控制中心：暂停、重定向、EXU_inst_clear"),
    ("IFU.sv",                           "取指单元（PC、握手、advance_en）"),
    ("IDU.sv",                           "译码单元（ID1 / ID2 两级）"),
    ("EXU.sv",                           "执行单元（含 MDU 握手状态机）"),
    ("LSU.sv",                           "访存单元（M1 / M2 / M3）"),
    ("WBU.sv",                           "写回单元"),
    ("myCPU.sv",                         "★顶层★：把上面全部连起来"),
]

HEADER = """/* ============================================================================
 * CPU RTL 合集（单文件版，方便整份复制给网页 AI）
 * ----------------------------------------------------------------------------
 * 用途：给只看到"波形图"的 AI 补齐"设计原理"。
 * 内容：myCPU 及其全部子模块的 RTL 源码，按 依赖顺序 排列。
 * 生成：python3 sim/gen_rtl_concat.py      （勿手工编辑本文件）
 * 校验：python3 sim/gen_rtl_concat.py --check
 *
 * 文件顺序（共 %(n)d 个）：
%(list)s
 *
 * ⚠️ 两个 MDU 别搞混：
 *   - `experimental/MDU_pipelined.sv` 是**当前实现**，`EXU.sv` 里
 *     `MDU_pipelined MDU_i0 (...)` 例化的就是它（乘单拍、除 32 拍迭代）。
 *   - `MDU.sv` 是**未被例化**的遗留纯组合版，收进来只为对照。
 *
 * 配套阅读：
 *   figures/讲解/波形逐信号说明.md   — 每张波形图的信号含义
 *   figures/讲解/波形变化原因注解.md — 每个信号"为什么会变"
 *   figures/讲解/给AI的上下文.md     — 读图约定 + 关键 RTL 摘录
 *
 * 另有讲解版（改了 EXU 两处，见 teach/README.md）：
 *   teach/rtl/EXU.sv
 * ============================================================================ */
"""

BANNER = """
/* ============================================================================
 * ===== FILE: %s =====
 * %s
 * ============================================================================ */
"""


def build_text():
    chunks = [HEADER % {
        "n": len(FILES),
        "list": "\n".join(" *   %-34s %s" % (p, d) for p, d in FILES),
    }]
    for path, desc in FILES:
        full = os.path.join(_ROOT, path)
        with open(full, encoding="utf-8", errors="replace") as f:
            body = f.read()
        chunks.append(BANNER % (path, desc))
        chunks.append(body if body.endswith("\n") else body + "\n")
    return "".join(chunks)


BANNER_RE = re.compile(r'/\* =+\n \* ===== FILE: (.+?) =====\n(?: \*.*\n)*? \* =+ \*/\n')


def split_concat(txt):
    """把合集切回 [(文件名, 正文)]。"""
    ms = list(BANNER_RE.finditer(txt))
    out = []
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(txt)
        out.append((m.group(1).strip(), txt[m.end():end].strip()))
    return out


def check():
    with open(OUT, encoding="utf-8", errors="replace") as f:
        txt = f.read()
    got = split_concat(txt)
    exp = [p for p, _ in FILES]
    names = [n for n, _ in got]
    bad = 0
    if names != exp:
        print("!! 文件清单不一致")
        print("   合集:", names)
        print("   期望:", exp)
        bad += 1
    for name, body in got:
        full = os.path.join(_ROOT, name)
        if not os.path.exists(full):
            print("!! 合集里有、源码已没了:", name)
            bad += 1
            continue
        with open(full, encoding="utf-8", errors="replace") as f:
            src = f.read().strip()
        if src != body:
            print("!! 内容不一致:", name)
            bad += 1
    print("[check] %s  文件数 %d，行数 %d" %
          ("全部一致 ✔" if bad == 0 else "有 %d 处问题 ✘" % bad,
           len(got), txt.count("\n") + 1))
    return bad


def main():
    if "--check" in sys.argv:
        sys.exit(1 if check() else 0)
    txt = build_text()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(txt)
    print("wrote %s  (%d 个文件, %d 行, %.1f KB)" %
          (OUT, len(FILES), txt.count("\n") + 1, len(txt.encode()) / 1024))
    check()


if __name__ == "__main__":
    main()
