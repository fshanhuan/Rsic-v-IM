"""生成 tb_iverilog.sv 期望值表片段 + 导出新回归程序 hex。

用法: python3 mkcases.py
输出: cases.txt（可直接粘进 tb_iverilog.sv 的 load_expectation）
      并把 tests/<name>_ecall.hex 复制成 <dest>.hex
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32 import RefISS

# (程序名, prog_id, 目标文件名)
CASES = [
    ('lane_min',      3, 'prog_load_lane.hex'),
    ('loaduse',       4, 'prog_load_use.hex'),
    ('loop_min',      5, 'prog_loop.hex'),
    ('div_pair',      6, 'prog_div_pair.hex'),
]

ABI = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2', 's0', 's1', 'a0', 'a1',
       'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 's2', 's3', 's4', 's5', 's6', 's7',
       's8', 's9', 's10', 's11', 't3', 't4', 't5', 't6']


def ref_final(path):
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
        pass
    return ref.r, ref.mem


def main():
    out = []
    for name, pid, dest in CASES:
        src = 'tests/%s_ecall.hex' % name
        regs, mem = ref_final(src)
        # 导出程序
        with open(dest, 'w') as f:
            f.write(open(src).read())
        out.append('                %d: begin   // sim/%s：%s' % (pid, dest, name))
        for i in range(32):
            if regs[i]:
                out.append('                    exp_reg[%d] = 32\'h%08x;   // %s' % (i, regs[i], ABI[i]))
        # 内存里非零且不是代码区的字（挑一个作为可选 dram 检查）
        nz = sorted(a for a in mem if mem[a] and a >= 4 * 4096)
        out.append('                end')
        print('=== %s -> %s (prog_id=%d) 非零寄存器 %d 个' %
              (name, dest, pid, sum(1 for r in regs if r)))
    with open('cases.txt', 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('已写 cases.txt')


if __name__ == '__main__':
    main()
