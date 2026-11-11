#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/mkapp.py -- 把 <name>_irom.hex + <name>_dram.hex 打成一个 "可 run 的容器"

为什么需要容器：shell 的 `L`/`D` 是**两条**命令、要人记住"代码放 0x5000、数据放
0xA000"，而且 `run` 无从知道数据在哪。容器把三件事写进 32 B 的头里：

    off  size  字段
    0    4     magic = 'BAPP' (0x50504142, 小端)
    4    4     irom_base   代码装到哪（取指地址）
    8    4     irom_len    代码字节数
    12   4     dram_base   数据装到哪（DRAM 地址）
    16   4     dram_len    数据字节数
    20   4     entry       入口地址（本方案 = irom_base，见 sw/app/start.S）
    24   4     sum         镜像字节的 32 位和（防串口丢字节）
    28   4     hdr_words   头长度，单位字（= 8）
    32   ...   irom 字节 + dram 字节

于是 `run <name>` 一条命令就能完成"装代码 + 装数据 + 跳入口"。

用法：
    python3 sw/mkapp.py --irom sw/build/hello_app_irom.hex \
                        --dram sw/build/hello_app_dram.hex \
                        --irom-base 0x5000 --dram-base 0xA000 --entry 0x5000 \
                        --out sw/build/hello_app.app
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

MAGIC = 0x50504142  # "BAPP" in little endian
HDR_WORDS = 8


def read_hex(path: Path) -> bytes:
    words = []
    for line in path.read_text(encoding="ascii").splitlines():
        line = line.strip()
        if not line:
            continue
        words.append(int(line, 16) & 0xFFFFFFFF)
    return b"".join(struct.pack("<I", w) for w in words)


def trim_zero_words(b: bytes) -> bytes:
    """去掉末尾的全零字（它们本来就不是有效代码/数据）"""
    while len(b) >= 4 and b[-4:] == b"\x00\x00\x00\x00":
        b = b[:-4]
    return b


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--irom", required=True)
    ap.add_argument("--dram", required=True)
    ap.add_argument("--irom-base", default="0x5000")
    ap.add_argument("--dram-base", default="0xA000")
    ap.add_argument("--entry", default="0x5000")
    ap.add_argument("--out", required=True)
    ap.add_argument("--hex", default=None,
                    help="另外写一份 'L' 命令能直接吃的十六进制流（每行一个字）")
    args = ap.parse_args()

    code = trim_zero_words(read_hex(Path(args.irom)))
    data = trim_zero_words(read_hex(Path(args.dram)))

    irom_base = int(args.irom_base, 0)
    dram_base = int(args.dram_base, 0)
    entry = int(args.entry, 0)

    # 入口必须在代码段里，否则 run 一跳就是野地址
    if not (irom_base <= entry < irom_base + len(code)):
        print(f"!! entry 0x{entry:08x} 不在代码段 "
              f"[0x{irom_base:08x}, 0x{irom_base + len(code):08x}) 内")
        return 1

    img = code + data
    chk = sum(img) & 0xFFFFFFFF
    hdr = struct.pack("<8I", MAGIC, irom_base, len(code), dram_base,
                      len(data), entry, chk, HDR_WORDS)
    blob = hdr + img
    if len(blob) % 4:
        blob += b"\x00" * (4 - len(blob) % 4)

    Path(args.out).write_bytes(blob)
    if args.hex:
        words = [int.from_bytes(blob[i:i + 4], "little") for i in range(0, len(blob), 4)]
        Path(args.hex).write_text("".join(f"{w:08x}\n" for w in words), encoding="ascii")
        print(f"  app : wrote {args.hex} ({len(words)} words, feed with 'L 5000')")
    print(f"  app : code {len(code)} B @0x{irom_base:08x}  "
          f"data {len(data)} B @0x{dram_base:08x}")
    print(f"  app : entry 0x{entry:08x}  sum 0x{chk:08x}  "
          f"container {len(blob)} B = {(len(blob) + 3) // 4} words")
    print(f"  app : wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
