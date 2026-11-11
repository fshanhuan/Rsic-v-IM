#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bin2iromhex.py — 把 RISC-V 裸二进制转成 `$readmemh` 能吃的 IROM 文本。

为什么需要：
    Vivado 的 `sync_mem_dp(INIT_FILE=...)` 用 `$readmemh`，要求**每行一个字**的
    十六进制文本（和 sw/build/monitor_irom.hex 同格式）。而 objcopy 出来的是
    小端二进制。这个脚本做两件事：小端拼字 + 补零到整片 IROM。

用法：
    python tools/bin2iromhex.py sw/build/stub.bin sw/build/ps_stub.hex [WORDS]
    默认 WORDS = 16384（64 KB IROM）

为什么补零而不是只写有效行：
    `$readmemh` 对"没写到的地址"在 Vivado 里是 0，但**仿真器之间不一致**
    （iverilog/xsim 有差异）。整片写满就不会有"这片内存从来没被赋值"的 X。
"""
import os
import sys

WORDS_DEFAULT = 16384
LINE_WORDS = 16          # 每行输出多少个字（纯排版，readmemh 不关心）


def main(argv):
    if len(argv) < 3:
        print("usage: bin2iromhex.py <in.bin> <out.hex> [words]")
        return 2
    src, dst = argv[1], argv[2]
    words = int(argv[3]) if len(argv) > 3 else WORDS_DEFAULT

    blob = open(src, "rb").read()
    n = (len(blob) + 3) // 4
    if n > words:
        print("!! %s 有 %d 字，超过 IROM 的 %d 字" % (src, n, words))
        return 1
    blob = blob + b"\x00" * (words * 4 - len(blob))

    out = []
    for i in range(words):
        w = int.from_bytes(blob[i * 4:i * 4 + 4], "little")
        out.append("%08x" % w)
        if (i + 1) % LINE_WORDS == 0:
            out.append("\n")
        else:
            out.append("\n")          # 一行一个字，和 monitor_irom.hex 一致

    with open(dst, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(out))
    print("wrote %s  (%d words used of %d)" % (dst, n, words))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
