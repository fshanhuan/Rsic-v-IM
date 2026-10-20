#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_boot_stream.py -- 把 irom/dram 镜像拼成"宿主会发出去的字节流"

为什么要这个脚本：
  _diag/load_uart.ps1 发的是一串**没有帧同步头保护**的字节流：'B' 帧 + 'C' 帧 + ('G')。
  板上的 boot_loader 在 S_IDLE 里**逐字节扫描** magic，而载荷（指令/数据）里天然会
  出现 0x42/0x43/0x47 这些"看起来像 magic"的字节。于是"FPGA 配置完成的瞬间宿主正
  发到哪儿"就决定了引导成败 —— 这是一个必须在仿真里复现、在 RTL 里修掉的问题。

  本脚本输出的就是**逐字节**的十六进制（每行一个字节），供 sim/tb_boot_scan.sv 用
  $readmemh 读入，然后从任意偏移开始喂给 boot_loader，等价于"配置落在流的中间"。

用法：
  python sw/gen_boot_stream.py sw/build/cm_irom.hex sw/build/cm_dram.hex \
      sim/cm_stream.hex --sessions 2
  python sw/gen_boot_stream.py ... --sessions 2 --go      # 末尾带 'G'
"""
import argparse
import io
import os
import sys


def read_words(path):
    """hex 文件：每行一个 32 位字（无 0x 前缀）。"""
    words = []
    with io.open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            words.append(int(s, 16) & 0xFFFFFFFF)
    return words


def frame(magic, words):
    out = bytearray()
    out.append(magic)
    n = len(words)
    out += n.to_bytes(4, "big")
    cks = 0
    for w in words:
        out += w.to_bytes(4, "big")
        cks = (cks + w) & 0xFFFFFFFF
    out += cks.to_bytes(4, "big")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("irom")
    ap.add_argument("dram")
    ap.add_argument("out")
    ap.add_argument("--sessions", type=int, default=2)
    ap.add_argument("--go", action="store_true", help="append the 'G' byte")
    ap.add_argument("--trim", action="store_true", help="drop trailing zero words")
    args = ap.parse_args()

    irom = read_words(args.irom)
    dram = read_words(args.dram)
    if args.trim:
        while irom and irom[-1] == 0:
            irom.pop()
        while dram and dram[-1] == 0:
            dram.pop()

    session = bytearray()
    session += frame(0x42, irom)
    if dram:
        session += frame(0x43, dram)
    if args.go:
        session.append(0x47)

    stream = bytearray()
    for _ in range(args.sessions):
        stream += session

    with io.open(args.out, "w", encoding="ascii", newline="\n") as f:
        for b in stream:
            f.write("%02x\n" % b)

    n47 = sum(1 for b in session if b == 0x47)
    n42 = sum(1 for b in session if b == 0x42)
    n43 = sum(1 for b in session if b == 0x43)
    print("[stream] irom=%d words dram=%d words  session=%d bytes  stream=%d bytes"
          % (len(irom), len(dram), len(session), len(stream)))
    print("[stream] magic-like bytes inside ONE session: "
          "'B'=%d  'C'=%d  'G'=%d" % (n42, n43, n47))
    print("[stream] -> %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
