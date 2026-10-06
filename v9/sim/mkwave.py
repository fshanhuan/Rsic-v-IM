#!/usr/bin/env python3
"""从 tb_wave.vcd 生成流水线时序图 SVG。"""
import sys
sys.path.insert(0, '/tmp/wave')
from vcd2svg import parse_vcd, resolve, toint, decode, esc

ROWS = [
    ('clk',                'clk',        'bit'),
    ('IF 取指 PC',          'p_if_pc',    'bus'),
    ('IF 指令（译码）',      'p_if_inst',  'inst'),
    ('ID 译码 PC',          'p_id_pc',    'bus'),
    ('ID valid',           'p_id_valid', 'bit'),
    ('EX PC',              'p_ex_pc',    'bus'),
    ('EX 结果',             'p_ex_res',   'bus'),
    ('EX valid',           'p_ex_valid', 'bit'),
    ('MEM valid',          'p_mem_valid','bit'),
    ('MEM 写使能',          'p_mem_wen',  'bit'),
    ('WB valid',           'p_wb_valid', 'bit'),
    ('WB PC',              'p_wb_pc',    'bus'),
    ('WB 写回寄存器',        'p_wb_rd',    'bus'),
    ('WB 写回值',           'p_wb_val',   'bus'),
    ('IFU 暂停(stall)',     'p_stall',    'bit'),
    ('重定向 dnpc_flag',     'p_dnpc_flag','bit'),
    ('分支预测 taken',       'p_pred_taken','bit'),
    ('预测错误',            'p_mispredict','bit'),
    ('reg x1',             'p_r1',       'bus'),
    ('reg x2',             'p_r2',       'bus'),
    ('reg x3',             'p_r3',       'bus'),
    ('reg x4',             'p_r4',       'bus'),
    ('reg x5',             'p_r5',       'bus'),
    ('reg x6',             'p_r6',       'bus'),
    ('reg x7',             'p_r7',       'bus'),
    ('reg x8',             'p_r8',       'bus'),
]

def main():
    vcd, out = sys.argv[1], sys.argv[2]
    ncyc = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    title = sys.argv[4] if len(sys.argv) > 4 else 'BigBird v9 流水线时序'
    table, idw, ev = parse_vcd(vcd)
    sel = {}
    for _, spec, _ in ROWS:
        r = resolve(table, spec)
        if r: sel[spec] = r
    clk = resolve(table, 'clk')[2]
    cur = {}; samples = []
    for t in sorted(ev):
        if t == 0: continue
        for i, v in ev[t]: cur[i] = v
        if any(i == clk for i, _ in ev[t]) and cur.get(clk) == '0':
            samples.append(dict(cur))
    samples = samples[:ncyc]
    n = len(samples)
    CW, LH, LAB, HD = 66, 36, 190, 54
    W = LAB + n*CW + 22; H = HD + len(ROWS)*LH + 48
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'font-family="Menlo,Consolas,DejaVu Sans Mono,monospace" font-size="12">',
         f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
         f'<text x="14" y="24" font-size="15" font-weight="bold" fill="#111">{esc(title)}</text>',
         f'<text x="14" y="43" font-size="11" fill="#666">'
         f'Verilator 仿真 · 每个时钟下降沿采样一拍 · 绿色/紫色为本拍数值（紫色=已译码指令）</text>']
    for c in range(n+1):
        x = LAB + c*CW
        o.append(f'<line x1="{x}" y1="{HD-6}" x2="{x}" y2="{H-28}" stroke="#ededed"/>')
    for ri, (label, spec, kind) in enumerate(ROWS):
        y = HD + ri*LH; yc = y + LH//2
        o.append(f'<rect x="4" y="{y}" width="{LAB-12}" height="{LH-4}" rx="3" fill="#f6f7f9"/>')
        o.append(f'<text x="12" y="{yc+4}" fill="#333">{esc(label)}</text>')
        if spec not in sel:
            o.append(f'<text x="{LAB+8}" y="{yc+4}" fill="#c00">(缺失)</text>'); continue
        _, nm, sid, w = sel[spec]
        vals = [toint(s.get(sid), w) for s in samples]
        col = {'bit':'#1565c0','bus':'#2e7d32','inst':'#7b1fa2'}[kind]
        if kind == 'bit' and spec == 'clk':
            # 时钟：画标准方波（下降沿采样，所以半拍低、半拍高）
            lo, hi = yc+10, yc-10
            for c in range(n):
                x1, x2 = LAB+c*CW, LAB+(c+1)*CW
                xm = (x1+x2)/2
                o.append(f'<path d="M{x1},{lo} L{xm},{lo} L{xm},{hi} L{x2},{hi}" '
                         f'fill="none" stroke="{col}" stroke-width="1.7"/>')
        elif kind == 'bit':
            o.append(f'<line x1="{LAB}" y1="{yc+10}" x2="{LAB+n*CW}" y2="{yc+10}" stroke="#cfcfcf"/>')
            prev = None
            for c, v in enumerate(vals):
                yy = yc-9 if v else yc+10
                x1, x2 = LAB+c*CW, LAB+(c+1)*CW
                o.append(f'<line x1="{x1}" y1="{yy}" x2="{x2}" y2="{yy}" stroke="{col}" stroke-width="1.7"/>')
                if prev is not None and prev != yy:
                    o.append(f'<line x1="{x1}" y1="{prev}" x2="{x1}" y2="{yy}" stroke="{col}" stroke-width="1.7"/>')
                prev = yy
        else:
            c = 0
            while c < n:
                c2 = c
                while c2+1 < n and vals[c2+1] == vals[c]:
                    c2 += 1
                x1, x2 = LAB+c*CW, LAB+(c2+1)*CW
                yy = yc+11
                o.append(f'<path d="M{x1},{yy-12} L{x1+7},{yy} L{x2-7},{yy} L{x2},{yy-12}" '
                         f'fill="none" stroke="{col}" stroke-width="1.5"/>')
                v = vals[c]
                if v is not None:
                    txt = decode(v) if kind=='inst' else f'0x{v:x}'
                    fs = 11.5 if len(txt) <= 8 else (10 if len(txt) <= 12 else 8.5)
                    o.append(f'<text x="{(x1+x2)/2}" y="{yc-3}" text-anchor="middle" '
                             f'font-size="{fs}" fill="{col}">{esc(txt)}</text>')
                c = c2+1
    ybot = H-28
    o.append(f'<line x1="{LAB}" y1="{ybot}" x2="{LAB+n*CW}" y2="{ybot}" stroke="#999"/>')
    step = 2 if n <= 30 else 5
    for c in range(0, n+1, step):
        x = LAB+c*CW
        o.append(f'<line x1="{x}" y1="{ybot}" x2="{x}" y2="{ybot+5}" stroke="#999"/>')
        o.append(f'<text x="{x}" y="{ybot+18}" text-anchor="middle" font-size="10" fill="#666">{c}</text>')
    o.append(f'<text x="{LAB+n*CW+4}" y="{ybot+18}" font-size="10" fill="#666">拍</text>')
    o.append('</svg>')
    open(out, 'w', encoding='utf-8').write('\n'.join(o))
    print(f"wrote {out}: {n} 拍, 缺失 {[s for _,s,_ in ROWS if s not in sel]}")

if __name__ == '__main__':
    main()
