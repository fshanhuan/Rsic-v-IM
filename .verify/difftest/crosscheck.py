"""交叉验证：把同一批程序放到工程自带的 tb_iverilog.sv 上跑，看是否复现同样的错值。

自带测试台用 ecall 收尾，所以这里跑的是 <name>_ecall.hex 变体
（正文 + 24 条 NOP + ecall）。期望值由参考模型在同一份程序上算出。
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32 import RefISS

ABI = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2', 's0', 's1', 'a0', 'a1',
       'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 's2', 's3', 's4', 's5', 's6', 's7',
       's8', 's9', 's10', 's11', 't3', 't4', 't5', 't6']


def ref_on_ecall_variant(path):
    words = [int(l, 16) for l in open(path) if l.strip()]
    ref = RefISS()
    ref.code_bytes = 4 * len(words)
    for i, w in enumerate(words):
        for b in range(4):
            ref.mem[4 * i + b] = (w >> (8 * b)) & 0xFF
    try:
        while True:
            ref.step()
    except ValueError:
        pass                      # ecall（0x73）参考模型不实现，遇到即停
    return ref.r, ref.steps


def parse_measured(text):
    regs = {}
    for m in re.finditer(r'^\s*x(\d+)\s*=\s*0x([0-9a-fA-Fx]+)', text, re.M):
        regs[int(m.group(1))] = m.group(2).lower()
    return regs


def main():
    names = sys.argv[1:]
    bad_total = 0
    for name in names:
        path = 'tests/%s_ecall.hex' % name
        log = 'logs/cc_%s.log' % name
        with open(log, 'w') as f:
            subprocess.run(['vvp', 'tb_proj.vvp', '+prog=' + path, '+prog_id=3',
                            '+vcd=logs/cc.vcd'], stdout=f, stderr=subprocess.STDOUT)
        text = open(log, errors='replace').read()
        expect, steps = ref_on_ecall_variant(path)
        got = parse_measured(text)
        bad = []
        for i in range(32):
            want = '%08x' % (expect[i] & 0xFFFFFFFF)
            g = got.get(i)
            if g is None:
                bad.append('x%-2d(%s) 自带台没打印' % (i, ABI[i]))
            elif g != want:
                bad.append('x%-2d(%-4s) 自带台=%-8s 参考=%-8s' % (i, ABI[i], g, want))
        if bad:
            bad_total += len(bad)
            print('FAIL %-10s (自带测试台, 参考步数=%d)' % (name, steps))
            for b in bad:
                print('     ' + b)
        else:
            print('PASS %-10s (自带测试台与参考一致)' % name)
    print('交叉验证不一致处数: %d' % bad_total)
    return 1 if bad_total else 0


if __name__ == '__main__':
    sys.exit(main())
