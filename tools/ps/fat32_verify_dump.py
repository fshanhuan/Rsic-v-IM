#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fat32_verify_dump.py -- 校验板上"证据缓冲区"dump（真卡验证的最后一步）

背景
----
真卡上写的文件不在内存里，JTAG 没法直接 dump 整张卡（64 MB）。所以板上
`sw/ps/sd_dump.c` 只把**校验需要的几个扇区**读进 OCM 的一块"证据缓冲区"，
再用 `mrd -bin -file` 一次 dump 出来。缓冲区格式（板上、PC 上同一份）：

    +0      4 字节 'S','D','C','1'
    +4      u32 n                     扇区个数
    +8      n 个 { u32 lba, u32 off }  off = 该扇区数据在缓冲区里的字节偏移
    +8+8n   扇区数据（每扇区 512 字节）

这个脚本把 dump 重新摊成一张（稀疏的）整盘镜像，再交给 `fat32_verify.py`
按 FAT32 规范复核 —— 于是"卡上文件与 JTAG 导出逐字节一致"可以一条命令验证。

用法：
    python tools/ps/fat32_verify_dump.py sim/build/sd/host_dump.bin
    python tools/ps/fat32_verify_dump.py sim/build/sd/sd_dump.bin     # 板上 dump 的

为什么这个格式现在就要定下来：板上那份 dump 程序**只能在有卡的时候跑**，
但"dump 解析 + 规范复核"这一半今天就能在 PC 上完整跑通（`tools/ps/host/`
的 C 测试会用同一格式写一份 host_dump.bin）。这样卡一到，只剩"读卡"这一步是新的。
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fat32_verify as V  # noqa: E402

SEC = 512
MAGIC = b"SDC1"


def build_image(dump_path, tmp_path):
    b = open(dump_path, "rb").read()
    print("dump: %s (%d bytes)" % (dump_path, len(b)))
    if len(b) < 8 or b[0:4] != MAGIC:
        print("FAIL: bad magic (expected 'SDC1')")
        return None

    n = struct.unpack_from("<I", b, 4)[0]
    if n == 0 or n > 64:
        print("FAIL: implausible sector count %d" % n)
        return None

    ents = []
    for i in range(n):
        lba, off = struct.unpack_from("<II", b, 8 + 8 * i)
        if off + SEC > len(b):
            print("FAIL: entry %d offset %d out of range" % (i, off))
            return None
        ents.append((lba, off))
    print("sectors in dump: %s" % ", ".join(str(l) for l, _ in ents))

    # 全卷大小从引导扇区里读（total sectors, offset 32）
    tot = None
    for lba, off in ents:
        if lba == 0:
            tot = struct.unpack_from("<I", b, off + 32)[0]
    if not tot:
        print("FAIL: dump has no boot sector (lba 0)")
        return None
    print("volume total sectors (from BPB): %d (%.2f MB)" % (tot, tot * SEC / 1048576.0))

    img = bytearray(tot * SEC)
    for lba, off in ents:
        if lba < tot:
            img[lba * SEC:(lba + 1) * SEC] = b[off:off + SEC]

    open(tmp_path, "wb").write(img)
    print("reconstructed sparse image: %s (%d bytes)" % (tmp_path, len(img)))
    return tmp_path


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else "sim/build/sd/host_dump.bin"
    nsamp = 100
    ext = None
    a = sys.argv[2:]
    i = 0
    while i < len(a):
        if a[i] == "--samples" and i + 1 < len(a):
            nsamp = int(a[i + 1]); i += 2
        elif a[i] == "--extract" and i + 1 < len(a):
            ext = a[i + 1]; i += 2
        else:
            i += 1
    tmp = os.path.join("sim", "build", "sd", "from_dump.img")
    os.makedirs(os.path.join("sim", "build", "sd"), exist_ok=True)
    q = build_image(p, tmp)
    if q is None:
        sys.exit(1)
    sys.exit(V.main(q, None, nsamp, ext))
