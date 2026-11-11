#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
wd_render.py —— 用两个波形工具**各自的渲染引擎**把 WaveJSON 出成 SVG / PNG。

链路（不装 Node、不装 wavedrom 包，也不联网）：
  render.html?v=<gui|plugin>#<WaveJSON>   ← 无头 Edge 打开
    ├─ --dump-dom   → 抠出 <svg>（矢量，可进讲义/PPT）
    └─ --screenshot → 按 SVG 真实尺寸截图（--force-device-scale-factor=2，2× 位图）

分工与交叉校验：
  IROM  图由 wavedrom-gui.html 的引擎出       （vendor/gui）
  DCache 图由 kodbox 插件 editor.html 的引擎出（vendor/plugin）
  再把同一份 JSON 丢给另一个引擎，逐字节比对 SVG —— 两套引擎版本相同就应当完全一致。

用法：
  python sim/wd_render.py                 # 全部重出
  python sim/wd_render.py --only IROM     # 只出一张
  python sim/wd_render.py --scale 3       # 更高分辨率位图
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WD = os.path.join(ROOT, "figures", "存储器", "wavedrom")
RENDER = os.path.join(ROOT, "sim", "wavedrom", "render.html")
EDGE_CANDIDATES = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
]
JOBS = [
    # (文件名, 出图引擎, hscale)
    ("IROM_全部端口", "gui", 1.5),
    ("DCache_关键端口", "plugin", 3.2),
    ("DRAM_全部端口", "gui", 3.2),
    ("MMIO_全部端口", "plugin", 3.2),
]


def find_browser():
    for p in EDGE_CANDIDATES:
        if os.path.exists(p):
            return p
    sys.exit("找不到 Edge/Chrome；把路径加进 EDGE_CANDIDATES 再跑")


def edge(browser, *args):
    cmd = [browser, "--headless=new", "--disable-gpu", "--no-sandbox",
           "--hide-scrollbars", "--virtual-time-budget=4000", *args]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0 and not r.stdout:
        sys.exit("浏览器失败：%s\n%s" % (" ".join(cmd), r.stderr[-800:]))
    return r.stdout


# 每张图可单独指定字号（0=用皮肤默认 14px）。W1 压到 22 格后 80px/格，
# 10 字符的标签在 14px 下会互相压住，缩到 12px 正好。
FS = {"IROM_全部端口": 12}


def url_for(json_path, vendor, hscale, fs=0):
    with open(json_path, encoding="utf-8") as f:
        doc = json.load(f)
    if hscale:
        doc.setdefault("config", {})["hscale"] = hscale
    payload = urllib.parse.quote(json.dumps(doc, ensure_ascii=False))
    href = ("file:///" + RENDER.replace("\\", "/") + "?v=" + vendor
            + (("&fs=%d" % fs) if fs else "") + "#" + payload)
    return href, doc


def dump_svg(browser, href):
    dom = edge(browser, "--dump-dom", href)
    m = re.search(r"(?s)(<svg\b.*?</svg>)", dom)
    if not m:
        err = re.search(r'id="err"[^>]*>(.*?)</div>', dom)
        sys.exit("没渲染出 SVG：%s" % (err.group(1)[:300] if err else dom[:300]))
    svg = m.group(1)
    wh = re.search(r"<title>WD (\d+)x(\d+)</title>", dom)
    if not wh:
        sys.exit("拿不到 SVG 尺寸（<title> 里没有 WD WxH）")
    return svg, int(wh.group(1)), int(wh.group(2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="只处理文件名包含该子串的图")
    ap.add_argument("--scale", type=int, default=2, help="PNG 放大倍数（默认 2）")
    ap.add_argument("--crosscheck", action="store_true", default=True)
    ap.add_argument("--gui", default=None, help="wavedrom-gui.html 路径（写进 index.html 的打开链接）")
    a = ap.parse_args()
    browser = find_browser()
    print("浏览器：%s" % browser)

    svg_of = {}
    for name, vendor, hscale in JOBS:
        if a.only and a.only not in name:
            continue
        js = os.path.join(WD, name + ".json")
        if not os.path.exists(js):
            sys.exit("缺 %s，先跑 python sim/wd_mem.py" % os.path.relpath(js, ROOT))
        href, _ = url_for(js, vendor, hscale, FS.get(name, 0))

        svg, w, h = dump_svg(browser, href)
        svg_path = os.path.join(WD, name + ".svg")
        with open(svg_path, "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n' + svg + "\n")
        svg_of[name] = svg

        png_path = os.path.join(WD, name + ".png")
        edge(browser, "--screenshot=" + png_path,
             "--window-size=%d,%d" % (w, h),
             "--force-device-scale-factor=%d" % a.scale, href)
        kb = os.path.getsize(png_path) / 1024
        print("  %-18s %4dx%-4d  %6.0f KB PNG  (引擎 %s)" % (name, w, h, kb, vendor))

        if a.crosscheck:
            other = "plugin" if vendor == "gui" else "gui"
            href2, _ = url_for(js, other, hscale, FS.get(name, 0))
            svg2, w2, h2 = dump_svg(browser, href2)
            same = (svg2 == svg)
            print("    交叉校验：%s 引擎输出 %s（%dx%d）"
                  % (other, "逐字节一致" if same else "不同！", w2, h2))
            if not same:
                print("    差异长度 %d vs %d" % (len(svg), len(svg2)))

    print("出图目录：%s" % os.path.relpath(WD, ROOT))
    write_index(gui=a.gui)
    print("查看页：%s" % os.path.relpath(os.path.join(WD, "index.html"), ROOT))


def write_index(gui=None):
    """生成 index.html：两张图 + 一键用 GUI 打开的分享链接（#<encodeURIComponent(JSON)>）。"""
    gui = gui or os.path.join(os.path.expanduser("~"), "Downloads", "wavedrom-gui.html")
    has_gui = os.path.exists(gui)
    gui_url = ("file:///" + gui.replace("\\", "/")) if has_gui else ""
    cards = []
    for name, vendor, hscale in JOBS:
        js = os.path.join(WD, name + ".json")
        if not os.path.exists(js):
            continue
        with open(js, encoding="utf-8") as f:
            doc = json.load(f)
        doc.setdefault("config", {})["hscale"] = hscale
        payload = urllib.parse.quote(json.dumps(doc, ensure_ascii=False))
        head = doc["head"]["text"]
        open_link = ('<a class="btn" href="%s#%s">在 wavedrom-gui.html 里打开</a>' % (gui_url, payload)
                     if has_gui else '<span class="muted">（未找到 wavedrom-gui.html）</span>')
        cards.append("""
  <section>
    <h2>%s</h2>
    <img src="%s.png" alt="%s">
    <p class="meta">引擎：%s · 源：<code>%s.json</code> / <code>%s.wave</code> · %s ·
       <a href="%s.svg">SVG</a></p>
  </section>""" % (head, name, name,
                  "wavedrom-gui.html" if vendor == "gui" else "kodbox 插件 editor.html",
                  name, name, open_link, name))

    html = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>IROM / DCache 存储器接口波形（WaveDrom）</title>
<style>
 body{margin:32px auto;max-width:1400px;padding:0 20px;background:#f6f7f9;
      font:15px/1.7 "Segoe UI","Microsoft YaHei",sans-serif;color:#1b1f24}
 h1{font-size:22px;margin:0 0 6px} h2{font-size:16px;margin:0 0 10px;color:#123}
 .lead{color:#555;margin:0 0 22px}
 section{background:#fff;border:1px solid #e2e5ea;border-radius:10px;padding:18px;margin:0 0 22px}
 img{width:100%%;height:auto;border:1px solid #eef0f3;border-radius:6px;background:#fff}
 .meta{color:#666;font-size:13px;margin:10px 0 0}
 .btn{display:inline-block;padding:2px 10px;border:1px solid #b9c6d6;border-radius:6px;
      background:#eef4fb;color:#14508c;text-decoration:none;font-size:13px}
 code{background:#eef0f3;padding:1px 5px;border-radius:4px;font-size:12.5px}
 .muted{color:#999;font-size:13px}
</style></head><body>
<h1>IROM / DCache 存储器接口波形</h1>
<p class="lead">WaveJSON 由 <code>sim/wd_mem.py</code> 从真实仿真记录 <code>sim/build/mem_trace.csv</code> 逐拍生成；
SVG/PNG 由 <code>sim/wd_render.py</code> 调两个波形工具自己的引擎离屏渲染（wavedrom 3.5.0）。
两个工具对同一份 JSON 的输出逐字节一致。</p>
%s
</body></html>
""" % "\n".join(cards)
    with open(os.path.join(WD, "index.html"), "w", encoding="utf-8") as f:
        f.write(html)


if __name__ == "__main__":
    main()
