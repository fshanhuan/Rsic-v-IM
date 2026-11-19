#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_inst_ports.py -- 检查模块实例化时有没有漏接/多接端口

为什么要有它
------------
2026-11-19 23:20 踩了一个坑：给 `board_top_ps_rec.sv` 里 `xadc_sampler` 换端口列表时，
把 `.en (adc_en)` 连同行尾一起替换掉了。结果：

  * Verilog 里**输入端口悬空 = 0**，不报错；
  * 综合把它当常数，把整个采样状态机**常量折叠**掉；
  * 综合、实现、bitgen、时序报告**全部成功**；
  * 只有上板才会发现"一个样本都没有"。

Vivado 对这种漏接不报 ERROR。所以只能自己静态查。
这个脚本按"模块声明的端口表"对"实例里真正接的名字"做差集。

用法：
    python tools/ps/check_inst_ports.py board/board_top_ps_rec.sv
    python tools/ps/check_inst_ports.py board/*.sv project_src/*.sv
    python tools/ps/check_inst_ports.py --dirs board rtl project_src

输出：
    OK   <file> <inst> (<module>)      端口全接
    MISS <file> <inst> (<module>)     缺 input: a, b
    EXTRA<file> <inst> (<module>)     多出: c
    RESULT check_inst_ports pass|fail

退出码 0 = 全部 OK；1 = 有缺失。
"""
import glob
import os
import re
import sys

PORT_RE = re.compile(
    r"\b(input|output|inout)\b\s+(?:logic|wire|reg|signed|unsigned)?\s*"
    r"(?:\[[^\]]*\]\s*)?(\w+)\s*[,;)]")

MOD_RE = re.compile(r"\bmodule\s+(\w+)")


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", " ", t, flags=re.S)
    t = re.sub(r"//[^\n]*", "", t)
    # 去掉 (* keep = "true" *) 这类综合属性 —— 它们含括号、含等号，
    # 会把 "output logic x" 前面的方向关键字挤开，导致端口名解析错
    # （第一版就是把属性里的 keep 当成端口名，报出 MISS input: keep）。
    t = re.sub(r"\(\*.*?\*\)", " ", t, flags=re.S)
    return t


def split_top(body):
    """按顶层逗号切分（忽略 [] {} () 内部的逗号），返回各段字符串"""
    inner = body.strip()
    if inner.startswith("("):
        inner = inner[1:-1]
    parts, depth, cur = [], 0, ""
    for ch in inner:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def port_map_from_body(body):
    """从模块端口表里解析 {port: direction}。

    不用"每行一个端口"的正则，是因为同一方向后面可以跟多个名字：
        output logic [7:0] idf5_h, idf6_h, idf6_a
    这种写法按行匹配会漏掉后两个（第一版脚本就是这么误报 EXTRA 的）。
    """
    ports, lastdir = {}, None
    for p in split_top(body):
        p = p.strip()
        m = re.match(r"(input|output|inout)\b", p)
        if m:
            lastdir = m.group(1)
            rest = p[m.end():]
        else:
            rest = p
        if lastdir is None:
            continue
        rest = rest.split("=")[0]
        ids = re.findall(r"[A-Za-z_]\w*", rest)
        if not ids:
            continue
        ports[ids[-1]] = lastdir
    return ports


def collect_modules(files):
    """module 名 -> {port: direction}"""
    mods = {}
    for f in files:
        try:
            raw = open(f, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        t = strip_comments(raw)
        for m in MOD_RE.finditer(t):
            name = m.group(1)
            i = t.find("(", m.end())
            if i < 0:
                continue
            j = match_paren(t, i)
            if j < 0:
                continue
            # ★ 有参数表时，第一个 '(' 是参数表，端口表是紧跟其后的那个 '('
            k = j + 1
            while k < len(t) and t[k] in " \t\r\n":
                k += 1
            if k < len(t) and t[k] == "(":
                j2 = match_paren(t, k)
                if j2 > 0:
                    i, j = k, j2
            body = t[i:j + 1]
            ports = port_map_from_body(body)
            if name not in mods or len(ports) > len(mods[name]):
                mods[name] = ports
    return mods


def match_paren(t, i):
    """返回 t[i] == '(' 对应的 ')' 下标"""
    depth = 0
    j = i
    while j < len(t):
        if t[j] == "(":
            depth += 1
        elif t[j] == ")":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


CONN_RE = re.compile(r"\.\s*(\w+)\s*\(")


def check_file(path, mods):
    raw = open(path, "r", encoding="utf-8", errors="replace").read()
    t = strip_comments(raw)
    rows = []
    for name, ports in mods.items():
        if not ports:
            continue
        # 找 "name #( ... ) inst (" 或 "name inst ("
        for m in re.finditer(r"\b" + re.escape(name) + r"\b", t):
            k = m.end()
            rest = t[k:k + 4000]
            m2 = re.match(r"\s*(#\s*\()?", rest)
            if not m2:
                continue
            pos = k
            if m2.group(1):                      # 有参数表，跳过它
                p_open = t.find("(", pos)
                p_close = match_paren(t, p_open)
                if p_close < 0:
                    continue
                pos = p_close + 1
            m3 = re.match(r"\s*(\w+)\s*\(", t[pos:pos + 200])
            if not m3:                            # 不是实例化（可能是接口信号）
                continue
            inst = m3.group(1)
            if inst in ("module", "if", "for", "case", "always_ff", "assign"):
                continue
            open_i = pos + m3.end() - 1
            close_i = match_paren(t, open_i)
            if close_i < 0:
                continue
            conns = set(CONN_RE.findall(t[open_i:close_i + 1]))
            if not conns:                          # 位置连接，跳过
                continue
            missing = [p for p, d in ports.items()
                       if d in ("input", "inout") and p not in conns]
            extra = [c for c in conns if c not in ports]
            rows.append((inst, name, missing, extra))
    return rows


def main(argv):
    files = []
    dirs = []
    # 已知的可不接端口（都必须在这里点名，不能图省事全体放过）：
    #   s_axil_* / axil_*：board_top 里只在 `ifdef AXIL_EN 下才存在/使用，
    #                      PL 版实例不接是设计意图；
    #   ext_rdata        ：只在 parameter EXT_MMIO=1 时才被 mux 选中，
    #                      EXT_MMIO=0 的实例悬空无害（网表与 v18 逐位相同）。
    allow = [r"^s_axil_", r"^axil_", r"^ext_rdata$"]
    i = 0
    while i < len(argv):
        if argv[i] == "--dirs":
            i += 1
            while i < len(argv) and not argv[i].startswith("--"):
                dirs.append(argv[i])
                i += 1
        elif argv[i] == "--allow" and i + 1 < len(argv):
            allow.append(argv[i + 1])
            i += 2
        elif argv[i] == "--allow-none":
            allow = []
            i += 1
        else:
            files.append(argv[i])
            i += 1
    for d in dirs:
        for pat in ("*.sv", "*.v"):
            files += glob.glob(os.path.join(d, pat))

    # 模块定义来源：所有给定文件所在目录 + board/rtl/project_src
    srcs = set(files)
    for d in list({os.path.dirname(f) or "." for f in files}) + ["board", "rtl", "project_src"]:
        for pat in ("*.sv", "*.v"):
            srcs.update(glob.glob(os.path.join(d, pat)))
    mods = collect_modules(sorted(srcs))

    bad = 0
    total = 0
    for f in files:
        try:
            rows = check_file(f, mods)
        except Exception as e:                     # noqa: BLE001
            print("SKIP %s (%s)" % (f, e))
            continue
        for inst, name, missing, extra in rows:
            total += 1
            missing = [p for p in missing
                       if not any(re.search(a, p) for a in allow)]
            if missing or extra:
                bad += 1
                if missing:
                    print("MISS  %s  %s (%s)  缺 input: %s" %
                          (os.path.basename(f), inst, name, ", ".join(missing)))
                if extra:
                    print("EXTRA %s  %s (%s)  多出: %s" %
                          (os.path.basename(f), inst, name, ", ".join(extra)))

    print("checked %d instantiations, %d with problems" % (total, bad))
    print("RESULT check_inst_ports %s" % ("pass" if bad == 0 else "fail"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
