#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_ps_image.py — 把 RISC-V 的 ELF 变成 PS 程序能直接吃的数据头。

背景（双核协同 第 1 步）：
    PS 要把 RISC-V 的镜像灌进 DRAM，但它能看到的只有自己 ELF 里的常量。
    于是构建时把 monitor.elf 的三段（.text / .rodata / .bss 的**地址+字数**）
    烘成 `sw/ps/app_image.h`，PS 程序 `#include` 它就能：
        1) 把 .text 写到 DRAM 0xA000（stage-0 stub 再从那儿抄进 IMEM）
        2) 把 .rodata 写回它链接时的地址
        3) 把 .bss 清零（板上 BRAM 上电本来是 0，但重新装载时必须显式清）

为什么直接读 ELF 而不是先 objcopy：
    一次解析就拿到 VMA/size，不用在 Windows 上再装一个 binutils；
    `.bss` 在 objcopy 出来的 bin 里根本不存在，但装载器必须知道它。

用法：
    python tools/gen_ps_image.py sw/build/monitor.elf sw/ps/app_image.h
"""
import os
import struct
import sys

EXPECT = (".text", ".rodata", ".data", ".bss")


def parse_elf(path):
    d = open(path, "rb").read()
    e_entry = struct.unpack_from("<I", d, 24)[0]
    shoff = struct.unpack_from("<I", d, 32)[0]
    shentsz = struct.unpack_from("<H", d, 46)[0]
    shnum = struct.unpack_from("<H", d, 48)[0]
    shstrndx = struct.unpack_from("<H", d, 50)[0]
    sh = [struct.unpack_from("<IIIIIIIIII", d, shoff + i * shentsz) for i in range(shnum)]
    strtab = sh[shstrndx]
    names = d[strtab[4]:strtab[4] + strtab[5]]

    secs = {}
    for s in sh:
        name = names[s[0]:names.find(b"\0", s[0])].decode()
        if name in EXPECT:
            # 字段：name,type,flags,addr,offset,size,...
            secs[name] = {"addr": s[3], "off": s[4], "size": s[5]}
    return e_entry, d, secs


def words(d, sec):
    n = sec["size"] // 4
    out = []
    for i in range(n):
        out.append(struct.unpack_from("<I", d, sec["off"] + i * 4)[0])
    return out


def emit_array(f, cname, vals, per_line=8):
    f.write("static const unsigned %s[%d] = {\n" % (cname, len(vals) if vals else 1))
    if not vals:
        f.write("    0u\n")
    for i in range(0, len(vals), per_line):
        chunk = vals[i:i + per_line]
        f.write("    " + ", ".join("0x%08xu" % v for v in chunk) + ",\n")
    f.write("};\n")


def main(argv):
    if len(argv) < 3:
        print("usage: gen_ps_image.py <monitor.elf> <app_image.h>")
        return 2
    elf, out = argv[1], argv[2]
    entry, data, secs = parse_elf(elf)
    if ".text" not in secs:
        print("!! %s 里没有 .text" % elf)
        return 1

    text = secs[".text"]
    rodata = secs.get(".rodata", {"addr": 0, "off": 0, "size": 0})
    bss = secs.get(".bss", {"addr": 0, "off": 0, "size": 0})
    data_sec = secs.get(".data", {"addr": 0, "off": 0, "size": 0})

    text_w = words(data, text)
    ro_w = words(data, rodata)

    # 头文件保护名按输出文件名区分：一个工程里会有多份（monitor / pstest），
    # 用同一个 guard 会让"先包含的那份赢"，第二份静默失效。
    guard = "PS_APP_IMAGE_" + os.path.basename(out).upper().replace(".", "_") + "_H"

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* =============================================================================\n")
        f.write(" * sw/ps/app_image.h — RISC-V 镜像（**自动生成，不要手改**）\n")
        f.write(" * -----------------------------------------------------------------------------\n")
        f.write(" * 来源：%s\n" % os.path.basename(elf))
        f.write(" * 生成：python tools/gen_ps_image.py %s %s\n" % (elf, out))
        f.write(" *\n")
        f.write(" * 装载约定（与 sw/ps/stub.S 一一对应）：\n")
        f.write(" *   DRAM[0xA000]      = RISC_IMG_WORDS\n")
        f.write(" *   DRAM[0xA004..]    = risc_img[]      (.text，由 stub 抄进 IMEM 代码窗口)\n")
        f.write(" *   DRAM[RODATA_ADDR] = risc_rodata[]   (.rodata，链接地址就是运行地址)\n")
        f.write(" *   DRAM[BSS_ADDR]    = 全 0          (.bss，必须显式清零)\n")
        f.write(" * ============================================================================= */\n")
        f.write("#ifndef %s\n#define %s\n\n" % (guard, guard))
        f.write("#define RISC_ENTRY_WORD   %du\n" % (entry // 4))
        f.write("#define RISC_IMG_WORDS    %du\n" % len(text_w))
        f.write("#define RISC_IMG_DRAM     0x0000A000u\n")
        f.write("#define RISC_RODATA_ADDR  %du\n" % rodata["addr"])
        f.write("#define RISC_RODATA_WORDS %du\n" % len(ro_w))
        f.write("#define RISC_DATA_ADDR    %du\n" % data_sec["addr"])
        f.write("#define RISC_DATA_WORDS   %du\n" % (data_sec["size"] // 4))
        f.write("#define RISC_BSS_ADDR     %du\n" % bss["addr"])
        f.write("#define RISC_BSS_WORDS    %du\n\n" % (bss["size"] // 4))
        emit_array(f, "risc_img", text_w)
        f.write("\n")
        emit_array(f, "risc_rodata", ro_w)
        f.write("\n#endif /* %s */\n" % guard)
    print("wrote %s: text=%d words, rodata=%d words, bss=%d words, entry=0x%x"
          % (out, len(text_w), len(ro_w), bss["size"] // 4, entry))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
