"""比对 RTL 仿真输出与参考模型快照。用法：compare.py <rtl_out.txt> <test.exp>"""

import json
import re
import sys

ABI = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2', 's0', 's1', 'a0', 'a1',
       'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 's2', 's3', 's4', 's5', 's6', 's7',
       's8', 's9', 's10', 's11', 't3', 't4', 't5', 't6']


def parse_rtl(path):
    regs, mem = {}, {}
    magic, total, timeout = None, None, False
    inside = False
    with open(path, errors='replace') as f:
        for line in f:
            line = line.strip()
            if line == 'DIFFTEST_BEGIN':
                inside = True
                continue
            if line == 'DIFFTEST_END':
                inside = False
                continue
            if not inside:
                continue
            if line == 'TIMEOUT':
                timeout = True
                continue
            m = re.match(r'^GPR (\d+) (\S+)$', line)
            if m:
                regs[int(m.group(1))] = m.group(2)
                continue
            m = re.match(r'^MEMW ([0-9a-fA-F]{8}) (\S+)$', line)
            if m:
                mem[int(m.group(1), 16)] = m.group(2)
                continue
            m = re.match(r'^MAGIC_CYC (\d+)$', line)
            if m:
                magic = int(m.group(1))
                continue
            m = re.match(r'^TOTAL_CYC (\d+)$', line)
            if m:
                total = int(m.group(1))
    return regs, mem, magic, total, timeout


def main():
    rtl_path, exp_path = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else exp_path
    exp = json.load(open(exp_path))
    regs, mem, magic, total, timeout = parse_rtl(rtl_path)

    fails = []
    if timeout or magic is None:
        fails.append('TIMEOUT: 没等到 magic store（程序没跑完或跑飞）')

    for i in range(32):
        want = '%08x' % (exp['regs'][i] & 0xFFFFFFFF)
        got = regs.get(i)
        if got is None:
            fails.append('x%-2d(%s): RTL 没导出' % (i, ABI[i]))
        elif got.lower() != want:
            fails.append('x%-2d(%-4s): rtl=%s ref=%s' % (i, ABI[i], got, want))

    emem = {int(k): ('%08x' % (v & 0xFFFFFFFF)) for k, v in exp['mem'].items()}
    for a in sorted(set(emem) | set(mem)):
        got = mem.get(a)
        want = emem.get(a)
        if got is None:
            fails.append('mem[%08x]: RTL 缺（ref=%s）' % (a, want))
        elif want is None:
            fails.append('mem[%08x]: RTL 多出 %s' % (a, got))
        elif got.lower() != want:
            fails.append('mem[%08x]: rtl=%s ref=%s' % (a, got, want))

    if fails:
        print('FAIL %s  (%d 处不一致, magic_cyc=%s total_cyc=%s)'
              % (name, len(fails), magic, total))
        for f in fails[:25]:
            print('   ' + f)
        if len(fails) > 25:
            print('   ... 还有 %d 处' % (len(fails) - 25))
        return 1
    print('PASS %s  (magic_cyc=%s total_cyc=%s, %d 个非零内存字)'
          % (name, magic, total, len(emem)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
