# -*- coding: utf-8 -*-
"""量一下"原文/改写/漏半句/无关"四种情况下 4-gram 覆盖率到底是多少，用来定阈值。"""
import sys
sys.path.insert(0, "tools")
from check_extract_coverage import ngrams


def ratio(line, ext_g):
    g = ngrams(line)
    if not g:
        return 1.0
    return sum(1 for x in g if x in ext_g) / len(g)


ext = ("重定向的语义是放弃当前取指、把 PC 拨到确定目标；"
       "dnpc_flag 同时就是 IDU 的 flush，IDU 在这一拍把译码级全部灌成 NOP。")

cases = [
    ("原文照抄", "重定向的语义是放弃当前取指、把 PC 拨到确定目标（dnpc_flag 同时就是 IDU 的 flush）"),
    ("轻度改写", "重定向的语义是丢弃当前取指、把 PC 拨到确定的目标，dnpc_flag 同时也是 IDU 的 flush"),
    ("中度改写", "重定向意味着丢掉这次取指并把 PC 拨到确定目标，而 dnpc_flag 就是 IDU 的 flush 信号"),
    ("重度改写", "重定向是放弃当前取指、把程序计数器指向确定目标，这个信号同时也是译码级的冲刷"),
    ("漏掉后半句", "重定向的语义是放弃当前取指、把 PC 拨到确定目标；"),
    ("完全无关", "DCache 的 store 请求必须是单拍脉冲，否则一次 store 会写两次内存"),
    ("同主题不同细节", "重定向请求只有一拍宽，所以丢掉之后不会重发，必须保证当拍生效"),
]

g = ngrams(ext)
print("%-16s %s" % ("情况", "4-gram 覆盖率"))
print("-" * 40)
for name, line in cases:
    print("%-16s %6.1f%%" % (name, ratio(line, g) * 100))

# 再量一个真实的：sync_mem 里一段原文 vs 只抄了前半句
real = ("读：DCache 给 mem_en=1 的那一拍给出 mem_addr，sync_mem 在下一个时钟沿输出 rdata，"
        "正好被 DCache 的 cpu_valid_r 那一拍采走")
print("")
print("真实契约原文单独自比 = %.1f%%" % (ratio(real, ngrams(real)) * 100))
print("真实契约 前 1/3 抄进 extract = %.1f%%"
      % (ratio(real, ngrams(real[:len(real) // 3])) * 100))
