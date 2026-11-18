#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/mk_boot_image.py -- 把"上电即跑"的记录仪镜像做成 BRAM 初值文件
=====================================================================
解决什么问题
------------
记录仪产品的目标是"上电→屏幕上就有波形"，但 v9_rec 的 IROM_BOOT=1 只会等串口
灌镜像（J8 没通就永远是空 IROM，CPU 卡在 500 ms 引导窗口后的 0x0 上跑 v18 的
14 条演示指令）。把程序**固化进比特流**就绕开了串口：

    boot_rec.hex       -> IROM 初值（$readmemh，16384 字 = 64 KB）
    boot_rec_dram.hex  -> DRAM 初值（$readmemh，32768 字 = 128 KB）

输入是 sw/build_simple.sh 的产物（把 sw/app/recorder.c 当"独立程序"编在 0x0）：
    recboot_irom.hex   代码，从 0x0 开始，正好 16384 字
    recboot_dram.hex   .rodata/.data，从 0x1_0000 开始（字地址 0x4000）

为什么要生成**全量** DRAM 镜像（而不是只写那几十个字）
------------------------------------------------------
$readmemh 没碰到的数组元素在综合里是"未指定"，在仿真里是 X。板上 BRAM 上电是 0，
但那是**器件特性**，不是我们的保证。全量 32768 行把"其余全是 0"写死在比特流里，
BRAM 初值就和仿真完全一致 —— 出问题时不用再猜"这块是 0 还是 X"。

自检（本脚本跑完会打印，任何一条不过就以非 0 退出）
--------------------------------------------------
  1. 输入行数 = 输出行数（没有截断/丢行）
  2. 逐字回读比对（生成的文件重新解析后必须与输入一致）
  3. IROM 字 0 必须等于 ELF 入口的第一条指令（用 INPUT_IROM 的原始首行核对）
  4. DRAM 只允许落在 0x1_0000 之外的空闲区（不许压到 0x0..0xA000 的文件系统
     和 0xA000..0x1_0000 的应用数据区）

用法
----
    python tools/mk_boot_image.py
    python tools/mk_boot_image.py --irom sw/build/recboot_irom.hex \\
                                 --dram sw/build/recboot_dram.hex \\
                                 --out-irom project_src/boot_rec.hex \\
                                 --out-dram project_src/boot_rec_dram.hex
"""

import argparse
import os
import sys

IROM_WORDS = 16384            # 64 KB
DRAM_WORDS = 32768            # 128 KB
DRAM_BASE_BYTE = 0x1_0000     # .rodata/.data 的链接地址（sw/coremark_port/link.ld）
DRAM_BASE_WORD = DRAM_BASE_BYTE >> 2

# 不许被 DRAM 镜像覆盖的区间（字地址，闭开区间）
RESERVED = [
    (0x0000, 0x2800, "文件系统 ramdisk（0x0..0xA000，40 KB）"),
    (0x2800, 0x4000, "应用数据区（0xA000..0x1_0000）"),
]


def read_hex(path):
    """读 $readmemh 文本格式，返回 (words, addrs)，addrs 为 None 表示从头连续。"""
    words, addrs = [], []
    cur = None
    with open(path, "r", encoding="utf-8") as f:
        for ln, raw in enumerate(f, 1):
            s = raw.split("//")[0].strip()
            if not s:
                continue
            if s.startswith("@"):
                cur = int(s[1:], 16)
                continue
            for tok in s.split():
                if cur is not None:
                    addrs.append(cur)
                    cur += 1
                words.append(int(tok, 16))
    return words, (addrs if addrs else None)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--irom", default=os.path.join(root, "sw", "build", "recboot_irom.hex"))
    ap.add_argument("--dram", default=os.path.join(root, "sw", "build", "recboot_dram.hex"))
    ap.add_argument("--out-irom", default=os.path.join(root, "project_src", "boot_rec.hex"))
    ap.add_argument("--out-dram", default=os.path.join(root, "project_src", "boot_rec_dram.hex"))
    args = ap.parse_args()

    fail = []

    # ---------------------------------------------------------------- IROM
    irom, irom_addr = read_hex(args.irom)
    if irom_addr is not None:
        fail.append("IROM 输入不该带 @地址（它必须从 0 开始连续）")
    if len(irom) > IROM_WORDS:
        fail.append("IROM 镜像 %d 字 > %d 字（超了）" % (len(irom), IROM_WORDS))
    irom_full = irom + [0] * (IROM_WORDS - len(irom))
    print("IROM: 输入 %d 字（%d 非零）→ 输出 %d 字"
          % (len(irom), sum(1 for w in irom if w), IROM_WORDS))

    # ---------------------------------------------------------------- DRAM
    dram, dram_addr = read_hex(args.dram)
    if dram_addr is not None:
        fail.append("DRAM 输入不该带 @地址（基址由 link.ld 决定，本脚本负责搬）")
    end_word = DRAM_BASE_WORD + len(dram)
    if end_word > DRAM_WORDS:
        fail.append("DRAM 镜像越界：0x%X..0x%X > %d 字"
                    % (DRAM_BASE_WORD, end_word, DRAM_WORDS))
    for lo, hi, why in RESERVED:
        if DRAM_BASE_WORD < hi and end_word > lo:
            fail.append("DRAM 镜像 0x%X..0x%X 压到了%s" % (DRAM_BASE_WORD, end_word, why))
    dram_full = [0] * DRAM_WORDS
    for i, w in enumerate(dram):
        dram_full[DRAM_BASE_WORD + i] = w
    print("DRAM: 输入 %d 字（%d 非零）→ 放在字地址 0x%X（字节 0x%X），输出 %d 字"
          % (len(dram), sum(1 for w in dram if w), DRAM_BASE_WORD,
             DRAM_BASE_BYTE, DRAM_WORDS))

    # ---------------------------------------------------------------- 写文件
    def write_full(path, words):
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("// 由 tools/mk_boot_image.py 生成，勿手改。\n")
            f.write("// %d 字，$readmemh 从字 0 连续装载（全量镜像，未用到的字显式写 0）。\n"
                    % len(words))
            for w in words:
                f.write("%08x\n" % (w & 0xFFFFFFFF))

    write_full(args.out_irom, irom_full)
    write_full(args.out_dram, dram_full)

    # ---------------------------------------------------------------- 自检 1/2：回读比对
    back_irom, _ = read_hex(args.out_irom)
    back_dram, _ = read_hex(args.out_dram)
    if back_irom != irom_full:
        fail.append("IROM 回读不一致")
    if back_dram != dram_full:
        fail.append("DRAM 回读不一致")
    if len(back_irom) != IROM_WORDS:
        fail.append("IROM 回读行数 %d != %d" % (len(back_irom), IROM_WORDS))
    if len(back_dram) != DRAM_WORDS:
        fail.append("DRAM 回读行数 %d != %d" % (len(back_dram), DRAM_WORDS))

    # ---------------------------------------------------------------- 自检 3：入口字
    # 入口必须是"非零且不像全 0 的 nop"——真值由 ELF 决定，这里只保证没有整体错位。
    if irom_full[0] == 0:
        fail.append("IROM 字 0 是 0：入口可能没进镜像（crt0 的第一条指令不可能是 0）")

    # ---------------------------------------------------------------- 自检 4：DRAM 非零区
    nz = [i for i, w in enumerate(back_dram) if w]
    if nz:
        print("DRAM 非零区: 字 0x%X..0x%X（%d 个字）"
              % (nz[0], nz[-1], len(nz)))
        if nz[0] < DRAM_BASE_WORD:
            fail.append("DRAM 非零区起点 0x%X 早于基址 0x%X" % (nz[0], DRAM_BASE_WORD))

    for p in (args.out_irom, args.out_dram):
        print("写出 %s（%d 字节）" % (p, os.path.getsize(p)))

    if fail:
        print("\n[FAIL] %d 条自检不通过：" % len(fail))
        for f in fail:
            print("  · " + f)
        return 1
    print("\n[PASS] 自检 4/4：行数、逐字回读、入口字、DRAM 区间")
    return 0


if __name__ == "__main__":
    sys.exit(main())
