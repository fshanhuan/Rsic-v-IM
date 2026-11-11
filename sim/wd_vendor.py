#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wd_vendor.py —— 从两个波形工具里抠出渲染引擎（wavedrom 3.5.0 + 皮肤），
放到 sim/wavedrom/vendor/{gui,plugin}/，好让离屏出图用**工具自己的**那份引擎。

两个工具都是"单文件 HTML，引擎内联在 <script> 里"：
  wavedrom-gui.html                                  → script[0]=default 皮肤, [1]=narrow 皮肤, [2]=wavedrom 核心
  wavedrom-kodbox-plugin/.../static/app/editor.html  → 同上（同一份 GUI，换了宿主桥接）

用法：
  python sim/wd_vendor.py
  python sim/wd_vendor.py --gui <path> --plugin <path>     # 工具不在默认下载目录时
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEF_GUI = os.path.join(os.path.expanduser("~"), "Downloads", "wavedrom-gui.html")
DEF_PLUGIN = os.path.join(os.path.expanduser("~"), "Downloads", "wavedrom-kodbox-plugin",
                          "wavedrom", "static", "app", "editor.html")
NAMES = ["skin-default.js", "skin-narrow.js", "wavedrom-3.5.0.js"]


def extract(html_path, out_dir, tag):
    with open(html_path, encoding="utf-8") as f:
        src = f.read()
    scripts = re.findall(r"(?s)<script[^>]*>(.*?)</script>", src)
    if len(scripts) < 3:
        sys.exit("%s 里只找到 %d 段 <script>，不是预期的 wavedrom-gui 单文件页" % (html_path, len(scripts)))
    os.makedirs(out_dir, exist_ok=True)
    sizes = []
    for i, name in enumerate(NAMES):
        body = scripts[i]
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            f.write(body)
        sizes.append(len(body))
    ver = re.search(r"wavedrom (\d+\.\d+\.\d+)", "".join(scripts[:3]))
    print("  %-7s ← %s  (%s, %d+%d+%d 字节)"
          % (tag, os.path.basename(html_path), ("wavedrom " + ver.group(1)) if ver else "版本未标注", *sizes))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gui", default=DEF_GUI)
    ap.add_argument("--plugin", default=DEF_PLUGIN)
    ap.add_argument("--out", default=os.path.join(ROOT, "sim", "wavedrom", "vendor"))
    a = ap.parse_args()
    for tag, path in (("gui", a.gui), ("plugin", a.plugin)):
        if not os.path.exists(path):
            print("  %-7s 跳过：找不到 %s" % (tag, path))
            continue
        extract(path, os.path.join(a.out, tag), tag)


if __name__ == "__main__":
    main()
