#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/mkfs.py -- 把一个容器文件预先"烤"进 ramdisk 镜像，供仿真直接装进 DRAM

为什么需要它：`run <name>` 这条路径（容器头解析、校验和、代码写窗口、数据写 DRAM、
入口跳转、返回）在板子上验过了，但**仿真里没法验** —— 要把 540 B 容器逐字节从
串口喂进 shell，光那一串十六进制就要 105 ms 仿真时间（iverilog 下是几十分钟）。

办法：直接生成 DRAM 的内存镜像，把文件系统（超级块 + 目录 + 位图 + 数据块）按
sw/monitor.c 的布局摆好，仿真开始时 `$readmemh(..., mem_ram, 0)` 一把装进去。
于是 tb 里只要一句 `run hello_app`，走的就是真实的 fs_find → 容器解析 → 执行。

布局（与 monitor.c 的 FS 段严格一致，改一边必须改另一边）：
    块 0        超级块：u32 magic 'BFSS' = 0x53534642, u32 nfiles
    块 1..3     目录：32 项 × 24 B = {char name[16]; u16 start; u16 nblk; u32 size;}
    块 4        位图：256 位 = 32 B（bit b 有文件 = 1）
    块 5..159   数据区（256 B/块，从低到高顺序分配）
    FS 共 160 块 = 40 KB = DRAM 0x0000..0x9FFF

用法：
    python3 sw/mkfs.py --file hello_app=sw/build/hello_app.app \
        --out sw/build/tb_fs.hex
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

FS_BLK = 256
FS_NBLK = 160
FS_DIRMAX = 32
FS_MAGIC = 0x53534642  # 'BFSS'
NAME_LEN = 16


def build(files: list[tuple[str, bytes]]) -> bytearray:
    img = bytearray(FS_NBLK * FS_BLK)          # 40 KB，未用部分保持 0

    # 位图：0..4 被元数据占用
    for b in range(5):
        img[4 * FS_BLK + (b >> 3)] |= (1 << (b & 7))

    next_blk = 5
    nfiles = 0
    for name, data in files:
        if len(data) == 0:
            raise SystemExit(f"!! {name}: empty file")
        nb = (len(data) + FS_BLK - 1) // FS_BLK
        if next_blk + nb > FS_NBLK:
            raise SystemExit(f"!! {name}: out of space ({next_blk}+{nb} > {FS_NBLK})")
        if nfiles >= FS_DIRMAX:
            raise SystemExit("!! directory full")
        # 数据块
        off = next_blk * FS_BLK
        img[off:off + len(data)] = data
        for b in range(next_blk, next_blk + nb):
            img[4 * FS_BLK + (b >> 3)] |= (1 << (b & 7))
        # 目录项（24 B，紧跟在块 1 起始处）
        ent = 1 * FS_BLK + nfiles * 24
        nm = name.encode("ascii")[:NAME_LEN - 1]
        img[ent:ent + len(nm)] = nm
        img[ent + len(nm)] = 0                  # name 的 '\0'（必须落在 name[16] 之内）
        struct.pack_into("<HHI", img, ent + 16, next_blk, nb, len(data))
        next_blk += nb
        nfiles += 1

    struct.pack_into("<II", img, 0, FS_MAGIC, nfiles)
    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", action="append", default=[],
                    help="name=path（可重复；name 必须等于 run 时用的名字）")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    files = []
    for spec in args.file:
        if "=" not in spec:
            raise SystemExit(f"!! --file {spec}: expected name=path")
        name, path = spec.split("=", 1)
        files.append((name, Path(path).read_bytes()))

    img = build(files)
    words = [int.from_bytes(img[i:i + 4], "little") for i in range(0, len(img), 4)]
    Path(args.out).write_text("".join(f"{w:08x}\n" for w in words), encoding="ascii")
    print(f"  mkfs: {len(files)} file(s), {len(img)} B = {len(words)} words -> {args.out}")
    for name, data in files:
        print(f"        {name}: {len(data)} B, {(len(data)+FS_BLK-1)//FS_BLK} block(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
