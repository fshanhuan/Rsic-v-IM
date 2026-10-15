# -*- coding: utf-8 -*-
"""
selftest_encoding.py — 证明 check_encoding.py **真的能抓出乱码**

乱码是怎么产生的（本项目实测过的两种）：
  ① `text.encode('utf-8').decode('gbk')`  —— UTF-8 字节被当 GBK 读
     （PowerShell 5.1 的 Get-Content 默认就这么干，得到 `鍙栨寚绾у彧鍋氫竴浠朵簨`）
  ② 反过来 `text.encode('gbk').decode('utf-8')` —— 也可能出现

如果检测器对这种输入还说 OK，那它就是摆设。

用法：python tools/selftest_encoding.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from check_encoding import cjk_chars, COMMON   # noqa: E402

# 一段**正常**的中文技术注释（用本项目原文）
GOOD = ("重定向的语义是放弃当前取指、把 PC 拨到确定目标；"
        "dnpc_flag 同时就是 IDU 的 flush，IDU 在这一拍把译码级全部灌成 NOP。"
        "如果只有一拍宽，被 ready 吃掉之后不会重发，这是 B9 那个 bug 的直接原因。")

# 让它长一点，超过检测器的 50 字门槛
GOOD = GOOD * 4


def mojibake_gbk(s):
    """UTF-8 字节被当 GBK 读（PowerShell Get-Content 的经典行为）"""
    return s.encode("utf-8", errors="replace").decode("gbk", errors="replace")


def mojibake_utf8(s):
    """GBK 字节被当 UTF-8 读"""
    return s.encode("gbk", errors="replace").decode("utf-8", errors="replace")


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    # 用"改动前快照"建立正常字符集（和 check_encoding.py 里一样）
    import glob
    good = set()
    snap = os.path.join(ROOT, "_comment_iter", "before")
    for p in glob.glob(os.path.join(snap, "**", "*.sv"), recursive=True):
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            good |= set(cjk_chars(f.read()))
    print("正常字符集大小 = %d" % len(good))
    print("")

    cases = [
        ("正常原文", GOOD, False),
        ("乱码① UTF8当GBK", mojibake_gbk(GOOD), True),
        ("乱码② GBK当UTF8", mojibake_utf8(GOOD), True),
        ("正常 + 少量新词", GOOD + "另外补上探针映射与触发条件说明。", False),
    ]

    ok = bad = 0
    for name, txt, want_bad in cases:
        chars = cjk_chars(txt)
        if len(chars) < 50:
            print("  %-20s 中文字数不足，跳过" % name)
            continue
        unexpected = [c for c in chars if c not in good]
        frac = len(unexpected) / len(chars)
        n_common = sum(1 for c in COMMON if c in txt)
        got_bad = (frac > 0.15 and len(unexpected) > 40) or n_common == 0
        good_flag = (got_bad == want_bad)
        ok += good_flag
        bad += (not good_flag)
        print("  %-20s 中文字数=%-5d 意外占比=%5.1f%% 常用字=%-3d 判定=%-8s 期望=%-8s %s"
              % (name, len(chars), frac * 100, n_common,
                 "乱码" if got_bad else "正常", "乱码" if want_bad else "正常",
                 "OK" if good_flag else "<<< 失败"))
        if got_bad and not want_bad:
            print("       意外字符样例: %s" % "".join(sorted(set(unexpected))[:30]))

    print("")
    print("自测结果: %d 通过, %d 失败" % (ok, bad))
    if bad == 0:
        print("编码检测器可信：正常文本放行，两种乱码都能抓出来。")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
