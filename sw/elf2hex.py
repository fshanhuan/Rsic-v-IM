#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/elf2hex.py -- 把 objcopy 出来的平坦 bin 拆成 IROM/DRAM 两个 $readmemh 镜像

本 SoC 的取指口与数据口是两套独立地址空间（哈佛），所以程序镜像要拆两份：
    [0, split)            -> IROM（取指）
    [split, file_end)     -> DRAM（= .rodata/.data，装到 DRAM 字 0）

用法：
    python3 sw/elf2hex.py sw/build/coremark.bin --split 0x10000 \
        --irom sw/build/cm_irom.hex --dram sw/build/cm_dram.hex \
        --irom-words 16384 --dram-words 65536

--irom-words / --dram-words 只用来判断"装不装得下"，超出就直接报错（不静默截断）。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def write_hex(path: Path, words: list[int]) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for w in words:
            f.write(f"{w:08x}\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("binfile")
    ap.add_argument("--split", default="0x10000")
    ap.add_argument("--irom", default=None)
    ap.add_argument("--dram", default=None)
    ap.add_argument("--irom-words", type=int, default=16384)
    ap.add_argument("--dram-words", type=int, default=65536)
    ap.add_argument("--trim", action="store_true",
                    help="去掉镜像末尾的全零字（引导帧会短很多；"
                         "未写入的字在 FPGA 里本来就是 0）")
    args = ap.parse_args()

    split = int(args.split, 0)
    data = Path(args.binfile).read_bytes()
    print(f"  bin: {len(data)} bytes ({len(data)/1024:.1f} KB)")

    if len(data) < split:
        text = data
        dpart = b""
    else:
        text = data[:split]
        dpart = data[split:]

    # 长度补齐到 4 字节
    def pad(b: bytes) -> bytes:
        r = len(b) % 4
        return b if r == 0 else b + b"\x00" * (4 - r)

    text = pad(text)
    dpart = pad(dpart)

    if args.trim:
        def trim_tail(b: bytes) -> bytes:
            words = [int.from_bytes(b[i:i + 4], "little") for i in range(0, len(b), 4)]
            while words and words[-1] == 0:
                words.pop()
            return b"".join(w.to_bytes(4, "little") for w in words)
        n0 = len(text)
        text = trim_tail(text)
        print(f"  trim irom: {n0//1024} KB -> {len(text)/1024:.1f} KB")

    irom_words = len(text) // 4
    dram_words = len(dpart) // 4
    print(f"  irom: {irom_words} words = {irom_words*4/1024:.1f} KB (limit {args.irom_words})")
    print(f"  dram: {dram_words} words = {dram_words*4/1024:.1f} KB (limit {args.dram_words})")

    if irom_words > args.irom_words:
        print(f"!! .text 超出 IROM（{irom_words} > {args.irom_words} 字）", file=sys.stderr)
        return 1
    if dram_words > args.dram_words:
        print(f"!! .rodata+.data 超出 DRAM（{dram_words} > {args.dram_words} 字）", file=sys.stderr)
        return 1

    if args.irom:
        write_hex(Path(args.irom), [int.from_bytes(text[i:i + 4], "little")
                                    for i in range(0, len(text), 4)])
        print(f"  wrote {args.irom}")
    if args.dram:
        write_hex(Path(args.dram), [int.from_bytes(dpart[i:i + 4], "little")
                                    for i in range(0, len(dpart), 4)])
        print(f"  wrote {args.dram}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
