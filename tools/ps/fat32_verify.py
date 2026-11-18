#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fat32_verify.py -- 独立校验板上（或 PC 上）生成的 FAT32 卷，不依赖程序自报的结果

为什么要有这一步
----------------
程序自测是"自己写、自己读回来、比校验和"。这只能证明读写一致，
不能证明**目录项/簇链/FAT 的字节布局符合 FAT32 规范**。所以这里用 Python
按规范把镜像重新解析一遍，重建文件内容，再和"应该是什么"
（按同一公式生成的 CSV）逐字节比对。

同时检查 Windows 认不认这个卷的几个硬条件：
  · 跳转指令 0xEB、介质字节 0xF8、0x55AA 签名、FS 类型串 "FAT32   "
  · 簇数 >= 65525（Windows 只认簇数够多的卷为 FAT32）
  · 每份 FAT 的条目容量 >= 簇数 + 2
  · reserved > 1 时 FSInfo 三个签名对；reserved > 6 时备份引导扇区与主引导扇区一致

用法：
    python tools/ps/fat32_verify.py sim/build/sd/host_64mb.img
    python tools/ps/fat32_verify.py sim/build/sd/ramdisk.bin
    python tools/ps/fat32_verify.py <img> --size 899        # 期望文件长度
    python tools/ps/fat32_verify.py <img> --samples 100     # 期望 CSV 样本数

几何参数不再写死：全部从引导扇区里读出来，所以同一份脚本既能验板上的
"小几何"（128 扇区 / reserved=2 / fat=1），也能验真卡的 64 MB 几何
（reserved=32 / fat=1024）。
"""
import sys
import struct

SEC = 512


def djb2(b):
    h = 5381
    for c in b:
        h = ((h << 5) + h + c) & 0xFFFFFFFF
    return h


def expected_csv(n=100):
    out = bytearray(b"idx,adc\r\n")
    for i in range(n):
        v = (0x800 + 7 * i) & 0xFFF
        out += ("%d,%d\r\n" % (i, v)).encode()
    return bytes(out)


def main(path, want_size=None, nsamp=100):
    img = open(path, "rb").read()
    print("image: %s  (%d bytes, %.2f MB, %d sectors)" %
          (path, len(img), len(img) / (1024.0 * 1024.0), len(img) // SEC))
    if len(img) < 8 * SEC:
        print("FAIL: image too small")
        return 1

    ok = True
    def check(cond, msg):
        nonlocal ok
        if not cond:
            print("FAIL: " + msg)
            ok = False

    # --- 引导扇区 ---
    bs = img[0:SEC]
    bps = struct.unpack_from("<H", bs, 11)[0]
    spc = bs[13]
    rsv = struct.unpack_from("<H", bs, 14)[0]
    nfat = bs[16]
    root_ent = struct.unpack_from("<H", bs, 17)[0]
    media = bs[21]
    fatsec = struct.unpack_from("<I", bs, 36)[0]
    tot32 = struct.unpack_from("<I", bs, 32)[0]
    root_clus = struct.unpack_from("<I", bs, 44)[0]
    fsinfo_sec = struct.unpack_from("<H", bs, 48)[0]
    backup_sec = struct.unpack_from("<H", bs, 50)[0]
    sig = struct.unpack_from("<H", bs, 510)[0]
    label = bs[71:82].decode("ascii", "replace")
    fstype = bs[82:90].decode("ascii", "replace")

    print("BPB: bps=%d spc=%d reserved=%d nfats=%d root_ent=%d media=0x%02X" %
          (bps, spc, rsv, nfat, root_ent, media))
    print("     total=%d fatsec=%d root_clus=%d fsinfo=%d backup=%d" %
          (tot32, fatsec, root_clus, fsinfo_sec, backup_sec))
    print("     label='%s' fstype='%s' signature=0x%04X jmp=0x%02X" %
          (label, fstype, sig, bs[0]))

    check(bps == SEC, "bytes per sector != 512")
    check(spc > 0 and (spc & (spc - 1)) == 0, "sectors/cluster not a power of two")
    check(nfat >= 1, "no FAT")
    check(bs[0] == 0xEB, "missing 0xEB jump")
    check(media == 0xF8, "media byte != 0xF8")
    check(sig == 0xAA55, "missing 0x55AA")
    check(fstype == "FAT32   ", "fs type string")
    check(root_clus == 2, "root cluster != 2")

    # --- 簇数与 FAT 容量（Windows 认 FAT32 的硬条件） ---
    clusters = tot32 - rsv - nfat * fatsec
    fat_cap = fatsec * (SEC // 4)
    print("clusters=%d  fat entries capacity=%d (need %d)" %
          (clusters, fat_cap, clusters + 2))
    check(fat_cap >= clusters + 2, "FAT too small for cluster count")
    if len(img) >= 8 * 1024 * 1024:
        check(clusters >= 65525, "clusters < 65525 -> Windows would call it FAT16/12")
    else:
        print("NOTE: image is small (test harness geometry) -> clusters>=65525 not enforced")

    # --- 备份引导扇区 / FSInfo ---
    if rsv > 6 and backup_sec + 1 <= len(img) // SEC:
        bak = img[backup_sec * SEC:(backup_sec + 1) * SEC]
        check(bak == bs, "backup boot sector differs from main boot sector")
        print("backup boot sector @%d: %s" % (backup_sec, "identical" if bak == bs else "DIFFERS"))
    if rsv > 1 and fsinfo_sec + 1 <= len(img) // SEC:
        fi = img[fsinfo_sec * SEC:(fsinfo_sec + 1) * SEC]
        s0 = struct.unpack_from("<I", fi, 0)[0]
        s1 = struct.unpack_from("<I", fi, 484)[0]
        s3 = struct.unpack_from("<I", fi, 508)[0]
        print("FSInfo @%d: 0x%08X 0x%08X 0x%08X" % (fsinfo_sec, s0, s1, s3))
        check(s0 == 0x41615252 and s1 == 0x61417272 and s3 == 0xAA550000,
              "FSInfo signatures")

    # --- FAT ---
    fat_lba = rsv
    fat = img[fat_lba * SEC:(fat_lba + fatsec) * SEC]
    e = [struct.unpack_from("<I", fat, i * 4)[0] for i in range(6)]
    print("FAT[0..5] = %s" % " ".join("0x%08X" % x for x in e))
    check(e[0] == 0x0FFFFFF8, "FAT[0] media/EOC marker")
    check((e[root_clus] & 0x0FFFFFFF) == 0x0FFFFFFF, "root cluster not EOC")

    # --- 根目录项 ---
    root_lba = rsv + nfat * fatsec
    root = img[root_lba * SEC:(root_lba + 1) * SEC]
    de = root[0:32]
    name = de[0:11].decode("ascii", "replace")
    attr = de[11]
    clus = (struct.unpack_from("<H", de, 20)[0] << 16) | struct.unpack_from("<H", de, 26)[0]
    size = struct.unpack_from("<I", de, 28)[0]
    print("dirent: name='%s' attr=0x%02X first_clus=%d size=%d" % (name, attr, clus, size))

    check(name == "REC     CSV", "file name")
    check(attr == 0x20, "file attribute should be 0x20 (archive)")

    # --- 沿簇链读文件 ---
    data = bytearray()
    c = clus
    guard = 0
    while guard < 4096:
        guard += 1
        lba = rsv + nfat * fatsec + (c - 2) * spc
        data += img[lba * SEC:(lba + spc) * SEC]
        nxt = struct.unpack_from("<I", fat, c * 4)[0] & 0x0FFFFFFF
        if nxt >= 0x0FFFFFF8:
            break
        c = nxt
    got = bytes(data[:size])
    print("chain: %d clusters, file bytes=%d" % (guard, len(got)))

    exp = expected_csv(nsamp)
    print("expected: %d bytes, djb2=0x%08X" % (len(exp), djb2(exp)))
    print("got     : %d bytes, djb2=0x%08X" % (len(got), djb2(got)))
    if want_size is not None:
        check(size == want_size, "declared size != %d" % want_size)
    check(got == exp, "content mismatch")
    if got != exp:
        for i in range(min(len(got), len(exp))):
            if got[i] != exp[i]:
                print("  first diff at %d: got 0x%02X exp 0x%02X" % (i, got[i], exp[i]))
                break

    print("RESULT %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    p = "sim/build/sd/ramdisk.bin"
    size = None
    nsamp = 100
    a = sys.argv[1:]
    i = 0
    while i < len(a):
        if a[i] == "--size" and i + 1 < len(a):
            size = int(a[i + 1]); i += 2
        elif a[i] == "--samples" and i + 1 < len(a):
            nsamp = int(a[i + 1]); i += 2
        else:
            p = a[i]; i += 1
    sys.exit(main(p, size, nsamp))
