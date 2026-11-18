# -*- coding: utf-8 -*-
"""docs/_add_status_headers.py -- 给每份文档标题下插入一行"状态"，解决"不知道是什么时候、什么情况下写的"

一次性工具，跑完可以留着（幂等：已有 `> **状态**` 行就跳过）。
用法：python docs/_add_status_headers.py
"""
import io
import os
import sys

DOCS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STATUS = {
    # ---- 处理器本体（v9~v17 时代） ----
    "模块说明.md":
        "历史（2026-10-20，v9~v13 时期）｜仍有效：部分｜**已被取代**：模块速查_v17.md（更准）、产品手册_v18.md（对外口径）",
    "模块速查_v17.md":
        "基础文档（2026-10-22，v17）｜仍有效：处理器/存储器各模块；**缺 v18 新增**（soc_map / soc_bus / plic_lite / clint / 记录仪外设），那部分看产品手册_v18.md",
    "数据通路分析.md":
        "历史分析（2026-10-20，v9 / 50 MHz 基线）｜仍有效：关键路径的分析方法；**具体数字已被 v17/v18 取代**",
    "CPU优化评审.md":
        "历史评审（2026-10-20，v9 基线）｜仍有效：优化思路与性价比判断；结论未全部实施",
    "开发记录.md":
        "基础文档（2026-10-20，v14~v17 开发总账）｜仍有效：**查「为什么这样设计」看这里**，含没做成的部分与原因",
    "C_工具链与RTOS.md":
        "基础文档（2026-10-20，v13 起）｜仍有效：rv32 gcc 13.2 工具链、CoreMark、FreeRTOS",
    "串口与console.md":
        "基础文档（2026-10-20）｜仍有效：**PL 侧**串口/console/GPIO｜**不适用于**记录仪的 PS UART1（那个见 记录仪_HDMI_方案.md §38）",
    "DCache_接口详解.md":
        "基础文档（2026-10-22）｜仍有效：`rtl/DCache.sv` 25 个端口",
    "DRAM_接口详解.md":
        "基础文档（2026-10-22）｜仍有效：`dram_inst` 9 个端口（原配套波形图已丢失，正文够用）",
    "MMIO_接口详解.md":
        "基础文档（2026-10-22，**7 个寄存器时代**）｜仍有效：译码与握手｜**注意 v18 已扩到 64 个索引**，地址以 地址表.md 为准",
    "IROM两段式布局_代码清单.md":
        "基础文档（2026-10-23）｜仍有效：5 个文件的原文与三条命令",
    # ---- SoC 化阶段（2026-11-09 ~ 11-13） ----
    "总线化_A1.md":
        "阶段报告（2026-11-09，A1）｜**已实装**，保留设计推导与三条不变量",
    "中断_A2.md":
        "阶段报告（2026-11-09，A2）｜**已实装**（`rtl/plic_lite.sv`）",
    "CLINT_A3.md":
        "阶段报告（2026-11-09，A3）｜**已实装**（`mtime/mtimecmp`）",
    "AXI_总线化_6_7.md":
        "阶段报告（2026-11-11，#6/#7 AXI4-Lite + Zynq PS 接入）｜**记录仪 PS 接入的前身，仍有效**",
    "SoC_验收报告.md":
        "阶段报告（2026-11-11，SoC 化 A1~A4 + 软件段）｜**就当前项目而言已被取代**：记录仪_验收报告.md",
    "ROADMAP_SoC.md":
        "路线图（2026-11-11）｜**进度已过时**（表中 A3/A4/软件多步后来都做了），仅保留当时的计划意图",
    "P0_完成报告.md":
        "阶段报告（2026-11-11 修订，内容截至 11-10，P0 五项）｜与 P0P1_完成报告.md 是**同一批工作的两份报告**，别当成两次",
    "P0P1_完成报告.md":
        "阶段报告（2026-11-10，P0/P1）｜同上，两份报告内容有重叠",
    "存储器汇报.md":
        "汇报材料（2026-11-12）｜可直接讲：5 个存储器逐根信号 + 10 分钟提纲",
    "双核应用方案.md":
        "方案（2026-11-13）｜**记录仪项目的起源文档**（「XADC 硬件触发采集」就是这条线的起点）；四个方案里只实施了第二个",
    # ---- 记录仪产品线（2026-11-14 之后） ----
    "记录仪_HDMI_方案.md":
        "**当前**（2026-11-14 起持续追加，现 §46）｜设计推导 + 每次失败与修复的实测记录。**这是主文档**，改 RTL/软件之前必读",
    "记录仪_验收报告.md":
        "**当前**（2026-11-18）｜一页纸验收材料：每阶段做了什么、证据在哪、还缺什么",
    "记录仪_上板操作手册.md":
        "**当前**（2026-11-18）｜接线、逐步命令、期望值、38 条踩过的坑、关键数字速查",
    "记录仪_SD插卡操作单.md":
        "**当前**（2026-11-18）｜手机上看的一页：插卡 → 断电 → 一条命令 → 看判定表",
    "产品手册_v18.md":
        "**当前**（2026-11-18）｜对外产品手册（另有 .docx）；数字出处见其附录对照表",
    "地址表.md":
        None,   # 自动生成，已有说明，不加状态行
}


def main():
    changed, skipped, missing = [], [], []
    for name, text in STATUS.items():
        path = os.path.join(DOCS, name)
        if not os.path.exists(path):
            missing.append(name)
            continue
        if text is None:
            skipped.append(name + " (explicitly skipped)")
            continue
        with io.open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        if any(l.startswith("> **状态**") for l in lines[:8]):
            skipped.append(name + " (already has status)")
            continue
        ins = None
        for i, l in enumerate(lines[:20]):
            if l.startswith("# "):
                ins = i + 1
                break
        if ins is None:
            skipped.append(name + " (no H1)")
            continue
        lines.insert(ins, "> **状态**：" + text + "\n\n")
        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.writelines(lines)
        changed.append(name)

    print("changed %d:" % len(changed))
    for c in changed:
        print("  " + c)
    if skipped:
        print("skipped %d:" % len(skipped))
        for s in skipped:
            print("  " + s)
    if missing:
        print("MISSING %d:" % len(missing))
        for m in missing:
            print("  " + m)
    return 0


if __name__ == "__main__":
    sys.exit(main())
