#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_encoding.py — 检测"中文注释变成了乱码"

为什么必须有（这是本项目独有的风险）：
  strip_sv_comments.py 只比较**代码**。而"UTF-8 被当成 GBK 读了一遍"这种损坏
  **只影响注释**（中文全变 `鍙栨寚绾у彧鍋氫竴浠朵簨`），代码却完好无损 ——
  于是所有机械校验都会说"PASS"，但注释已经全废。
  本仓库已经栽过两次（docs 里 `(` 全被写成 `上`；用 Get-Content/Set-Content
  处理 .sv 时把中文注释变成 U+9xxx 区的怪字）。

原理（数据驱动，不靠人肉列黑名单）：
  1. 从"改动前快照"的注释里收集**正常中文字符集** G（这些字是人工写过的，必然正常）；
  2. 对当前文件的注释，统计**不在 G 里**的中文字符占比；
  3. 正常改写只会引入少量新字（探针、触发、不变量…），
     而乱码会引入**成百上千**个 U+9xxx 区的怪字。
  4. 额外做一次"常用字"体检：任何一段正常中文技术文字必然出现
     的/是/不/为/时/与/这/个/中 里的若干字；一个都不出现 = 高度可疑。

用法：
  python tools/check_encoding.py            # 全部文件
  python tools/check_encoding.py --show     # 额外列出"意外字符"TOP20（用于人工判断）
"""
import os
import re
import sys
import collections

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from check_extract_coverage import comment_text, current_path  # noqa: E402

SNAP = os.path.join(ROOT, "_comment_iter", "before")

CJK = re.compile(r"[\u3400-\u4DBF\u4E00-\u9FFF\u3000-\u303F\uFF00-\uFFEF]")
# 正常中文技术文字里几乎必然出现的字
COMMON = "的是不为时与这个中了在上下有和到就都也还只把被从对能会要可以"


def cjk_chars(s):
    return [c for c in s if CJK.match(c)]


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    show = "--show" in sys.argv

    man = os.path.join(ROOT, "_comment_iter", "manifest_before.tsv")
    entries = []
    with open(man, "r", encoding="utf-8-sig") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) >= 2:
                entries.append(p[0].lstrip("\ufeff"))

    # 1) 建立"正常字符集"
    good = set()
    for rel in entries:
        old = os.path.join(SNAP, rel.replace("/", os.sep))
        if os.path.exists(old):
            good |= set(cjk_chars("\n".join(comment_text(old))))
    print("正常中文字符集大小 = %d（来自 %d 个改动前快照）" % (len(good), len(entries)))
    print("")
    print("%-34s %7s %8s %9s %8s %s" % ("文件", "中文字数", "意外字数", "意外占比", "常用字", "判定"))
    print("-" * 88)

    n_bad = 0
    for rel in entries:
        new = current_path(rel)
        if not new or not os.path.exists(new):
            continue
        txt = "\n".join(comment_text(new))
        chars = cjk_chars(txt)
        if len(chars) < 50:          # 注释太少，统计无意义
            continue
        unexpected = [c for c in chars if c not in good]
        frac = len(unexpected) / len(chars)
        n_common = sum(1 for c in COMMON if c in txt)
        bad = (frac > 0.15 and len(unexpected) > 40) or n_common == 0
        n_bad += bad
        print("%-34s %7d %8d %8.1f%% %8d %s"
              % (rel, len(chars), len(unexpected), frac * 100, n_common,
                 "<<<< 疑似乱码" if bad else "OK"))
        if show and unexpected:
            top = collections.Counter(unexpected).most_common(20)
            print("       意外字符 TOP20: %s"
                  % " ".join("%s(%d)" % (c, n) for c, n in top))

    print("-" * 88)
    print("判定：%s" % ("PASS —— 没有检测到注释乱码" if n_bad == 0
                       else "FAIL —— %d 个文件的注释疑似乱码" % n_bad))
    return 0 if n_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
