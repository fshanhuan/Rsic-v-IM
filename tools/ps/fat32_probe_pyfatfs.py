#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fat32_probe_pyfatfs.py -- 用**第三方 FAT 实现**打开我们生成的镜像

为什么要这一步
--------------
前面两个检查里，`sw/ps/fat32.c` 是"自己写的"，`tools/ps/fat32_verify.py` 是
"自己按规范解析的"——两者都由我写，仍然可能共享同一个错误理解。
`pyfatfs` 是一个独立的、公开的 FAT/FAT32 驱动实现（PyPI 上的 pyfatfs 1.1.0），
它去读同一个镜像就是**第三方交叉验证**：如果它能列出目录、读出文件、字节与
预期一致，那"这个卷符合 FAT32 规范"就不是我一个人说了算。

这也是"PC 能打开"这一验收条件的离线近似：真卡插到 PC 上是 Windows 的驱动在读，
这里换成一个别人写的驱动在读。

用法：
    python tools/ps/fat32_probe_pyfatfs.py sim/build/sd/host_64mb.img
    python tools/ps/fat32_probe_pyfatfs.py sim/build/sd/cardimage.bin   # 板上 dump 的
    python tools/ps/fat32_probe_pyfatfs.py <img> --name /REC.CSV --samples 100

环境说明：
    pyfatfs 依赖 PyFilesystem2（fs），而 fs 在导入时 `import pkg_resources`
    （setuptools 的东西）。本机 Python 3.14 没有 setuptools，所以这里给一个
    最小 shim —— 只用它声明命名空间，不影响 FAT 逻辑。
"""
import sys
import types


def _shim_pkg_resources():
    try:
        import pkg_resources  # noqa: F401
        return
    except Exception:
        pass
    m = types.ModuleType("pkg_resources")
    m.declare_namespace = lambda name: None
    sys.modules["pkg_resources"] = m


def djb2(b):
    h = 5381
    for c in b:
        h = ((h << 5) + h + c) & 0xFFFFFFFF
    return h


def expected_csv(n):
    out = bytearray(b"idx,adc\r\n")
    for i in range(n):
        out += ("%d,%d\r\n" % (i, (0x800 + 7 * i) & 0xFFF)).encode()
    return bytes(out)


def main(path, name, nsamp):
    _shim_pkg_resources()
    try:
        from pyfatfs.PyFatFS import PyFatFS
    except Exception as e:
        print("SKIP: pyfatfs not importable (%s)" % e)
        return 0

    print("probe: %s  (third-party FAT driver: pyfatfs)" % path)
    try:
        fs = PyFatFS(path)
    except Exception as e:
        print("FAIL: pyfatfs could not open the volume: %s" % e)
        return 1

    ok = True
    try:
        listing = fs.listdir("/")
        print("root listing: %s" % listing)
        if name.lstrip("/") not in listing:
            print("FAIL: %s not in root listing" % name)
            ok = False
        else:
            with fs.open(name, "rb") as f:
                got = f.read()
            exp = expected_csv(nsamp)
            print("read: %d bytes, djb2=0x%08X" % (len(got), djb2(got)))
            print("exp : %d bytes, djb2=0x%08X" % (len(exp), djb2(exp)))
            if got != exp:
                print("FAIL: content mismatch")
                for i in range(min(len(got), len(exp))):
                    if got[i] != exp[i]:
                        print("  first diff at %d: got 0x%02X exp 0x%02X"
                              % (i, got[i], exp[i]))
                        break
                ok = False
    finally:
        try:
            fs.close()
        except Exception:
            pass

    print("RESULT %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else "sim/build/sd/host_64mb.img"
    n = "/REC.CSV"
    s = 100
    a = sys.argv[2:]
    i = 0
    while i < len(a):
        if a[i] == "--name" and i + 1 < len(a):
            n = a[i + 1]; i += 2
        elif a[i] == "--samples" and i + 1 < len(a):
            s = int(a[i + 1]); i += 2
        else:
            i += 1
    sys.exit(main(p, n, s))
