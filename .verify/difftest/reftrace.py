"""参考模型逐指令轨迹，与 tb_iverilog 的 [WB] 事件流按指令对齐比对。

用法:
  python3 reftrace.py <name> [--rtl logs/xxx.log]
输出:
  第一条分歧（控制流不同 / 写回值不同），以及分歧前后各若干条指令。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32 import RefISS, sext, s32

M32 = 0xFFFFFFFF


def ref_trace(words):
    """返回参考模型逐条提交记录： (pc, inst, rd, wrote, val)"""
    ref = RefISS()
    ref.code_bytes = 4 * len(words)
    for i, w in enumerate(words):
        for b in range(4):
            ref.mem[4 * i + b] = (w >> (8 * b)) & 0xFF
    out = []
    try:
        while True:
            pc = ref.pc
            inst = ref.ld(pc, 4)
            rd = (inst >> 7) & 0x1F
            before = ref.r[rd] if rd else 0
            ref.step()
            after = ref.r[rd] if rd else 0
            wrote = 1 if (rd and before != after) else 0
            out.append((pc, inst, rd, wrote, after))
    except ValueError:
        pass                       # ecall：参考模型到此为止
    return out


def rtl_trace(path):
    """解析 tb_iverilog 的 [WB] 行 -> (pc, inst, rd, ena, val)"""
    out = []
    for line in open(path, errors='replace'):
        m = re.search(r'\[WB \] cyc=\d+ pc=([0-9a-f]+) inst=([0-9a-f]+) \S+ ena=(\d) reg=x(\d+) val=([0-9a-fx]+)', line)
        if m:
            out.append((int(m.group(1), 16), int(m.group(2), 16),
                        int(m.group(4)), int(m.group(3)), m.group(5)))
    return out


def main():
    name = sys.argv[1]
    rtl_log = 'logs/st_%s.log' % name
    words = [int(l, 16) for l in open('tests/%s_ecall.hex' % name) if l.strip()]
    ref = ref_trace(words)
    rtl = rtl_trace(rtl_log)

    print('参考提交 %d 条 / RTL [WB] %d 条' % (len(ref), len(rtl)))
    n = min(len(ref), len(rtl))
    first = None
    for i in range(n):
        rp, ri, rrd, rw, rv = ref[i]
        tp, ti, trd, tena, tv = rtl[i]
        if rp != tp or ri != ti:
            first = (i, 'PC/指令序列不同')
            break
        # RTL 的 val 对未写回指令无意义；只比“确实写回”的
        tvv = tv.lower()
        if rw and (tvv != '%08x' % (rv & M32)):
            first = (i, '写回值不同: RTL rd=%d val=%s / 参考 rd=%d val=%08x' %
                     (trd, tvv, rrd, rv & M32))
            break
    if first is None:
        print('前 %d 条完全一致' % n)
        return 0
    i, why = first
    print('!! 第 %d 条开始分歧：%s' % (i, why))
    lo = max(0, i - 6)
    hi = min(n, i + 8)
    print('%-4s %-10s %-10s %-16s | %-10s %-10s %-16s' %
          ('idx', 'ref_pc', 'ref_inst', 'ref(rd,wrote,val)', 'rtl_pc', 'rtl_inst', 'rtl(rd,ena,val)'))
    for k in range(lo, hi):
        rp, ri, rrd, rw, rv = ref[k]
        tp, ti, trd, tena, tv = rtl[k]
        mark = ' <<<' if k == i else ''
        print('%-4d %08x   %08x   x%-2d %d %08x | %08x   %08x   x%-2d %d %-10s%s' %
              (k, rp, ri, rrd, rw, rv & M32, tp, ti, trd, tena, tv, mark))
    return 1


if __name__ == '__main__':
    sys.exit(main())
