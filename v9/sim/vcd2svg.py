#!/usr/bin/env python3
"""VCD -> SVG 时序图渲染器（纯标准库，无第三方依赖）。

用法:
    python3 vcd2svg.py <in.vcd> <out.svg> "<标题>" <拍数>

信号用 "<作用域后缀>.<信号名>" 指定，例如 Core_cpu.IFU_pc；
只给信号名时取最短匹配路径。
"""
import sys
from collections import defaultdict

# ============================ VCD 解析 ============================
def parse_vcd(path):
    cur = []
    # (scope, name) -> (id, width)
    table = {}
    # id -> width（值变化用）
    idw = {}
    ev = defaultdict(list)
    t = 0
    with open(path, errors='replace') as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if s.startswith('$scope'):
                cur.append(s.split()[2]); continue
            if s.startswith('$upscope'):
                if cur: cur.pop()
                continue
            if s.startswith('$var'):
                p = s.split()
                # $var <type> <width> <id> <name> [range] $end
                i, nm, w = p[3], p[4], int(p[2])
                table[('.'.join(cur), nm)] = (i, w)
                idw[i] = w
                continue
            if s.startswith('$'):
                continue
            if s[0] == '#':
                t = int(s[1:]); continue
            if s[0] in '01xzXZ':
                # 标量：<值><id>
                ev[t].append((s[1:], s[0]))
            else:
                # 向量：<基><值> <id>   （b=二进制, r=实数, s=字符串）
                p = s.split()
                if len(p) == 2 and p[0][0] in 'bB':
                    ev[t].append((p[1], p[0][1:]))
                elif len(p) == 2:
                    ev[t].append((p[0], p[1]))
    return table, idw, ev

def resolve(table, spec):
    """spec: 'Core_cpu.IFU_pc' 或 'IFU_pc'"""
    hits = []
    for (scope, nm), (i, w) in table.items():
        if spec == nm or spec == f'{scope}.{nm}' or scope.endswith('.' + spec.rsplit('.', 1)[0]) and nm == spec.rsplit('.', 1)[1]:
            hits.append((len(scope), scope, nm, i, w))
    if not hits:
        return None
    hits.sort()
    _, scope, nm, i, w = hits[0]
    return scope, nm, i, w

# ============================ 采样 ============================
def sample(path, specs):
    """按「时钟下降沿」采样：测试台正是在下跳沿读取 debug_wb_* 的。

    返回 (idw, sel, samples, sample_times)
    """
    table, idw, ev = parse_vcd(path)
    sel = {}
    for sp in specs:
        r = resolve(table, sp)
        if r:
            sel[sp] = r
    clk = None
    # v9 上板改造：tb_iverilog.sv 的时钟信号就叫 clk（tb_wave.sv 里是 fpga_clk），
    # 两个名字都试一下，兼容两种测试台产出的 .vcd。
    for cand in ('fpga_clk', 'TOP.fpga_clk', 'clk', 'tb_iverilog.clk'):
        r = resolve(table, cand)
        if r:
            clk = r[2]
            break
    cur = {}
    out, times = [], []
    for t in sorted(ev):
        # t=0 的初值污染直接丢弃（VCD 在第一个 # 之前会先给一遍初值）
        if t == 0:
            continue
        for i, v in ev[t]:
            cur[i] = v
        if clk and any(i == clk for i, _ in ev[t]) and cur.get(clk) == '0':
            out.append(dict(cur))
            times.append(t)
    return idw, sel, out, times

def toint(v, w):
    if v is None: return None
    v = v.replace('x', '0').replace('z', '0')
    try: return int(v, 2)
    except ValueError: return None

# ============================ RV32I/M 反汇编 ============================
def sext(v, b):
    m = 1 << (b - 1)
    return (v ^ m) - m

RN = ['zero','ra','sp','gp','tp','t0','t1','t2','s0','s1','a0','a1','a2','a3','a4','a5',
      'a6','a7','s2','s3','s4','s5','s6','s7','s8','s9','s10','s11','t3','t4','t5','t6']

def decode(w):
    op = w & 0x7f; rd = (w>>7)&0x1f; f3 = (w>>12)&7
    rs1 = (w>>15)&0x1f; rs2 = (w>>20)&0x1f; f7 = (w>>25)&0x7f
    r = lambda i: RN[i]
    ii = lambda: sext((w>>20)&0xfff, 12)
    if w == 0x00000013: return 'nop'
    if op == 0x33:
        if f7 == 1: return {0:'mul',1:'mulh',2:'mulhsu',3:'mulhu',4:'div',5:'divu',6:'rem',7:'remu'}[f3]+f' {r(rd)},{r(rs1)},{r(rs2)}'
        if f7 == 0x20: return ('sub' if f3==0 else 'sra')+f' {r(rd)},{r(rs1)},{r(rs2)}'
        return {0:'add',1:'sll',2:'slt',3:'sltu',4:'xor',5:'srl',6:'or',7:'and'}[f3]+f' {r(rd)},{r(rs1)},{r(rs2)}'
    if op == 0x13:
        if f3 == 1: return f'slli {r(rd)},{r(rs1)},{rs2}'
        if f3 == 5: return ('srai' if f7==0x20 else 'srli')+f' {r(rd)},{r(rs1)},{rs2}'
        return {0:'addi',2:'slti',3:'sltiu',4:'xori',6:'ori',7:'andi'}[f3]+f' {r(rd)},{r(rs1)},{ii()}'
    if op == 0x03: return {0:'lb',1:'lh',2:'lw',4:'lbu',5:'lhu'}[f3]+f' {r(rd)},{ii()}({r(rs1)})'
    if op == 0x23: return {0:'sb',1:'sh',2:'sw'}[f3]+f' {r(rs2)},{sext(((w>>25)<<5)|((w>>7)&0x1f),12)}({r(rs1)})'
    if op == 0x63:
        b = sext(((w>>31)<<12)|(((w>>7)&1)<<11)|(((w>>25)&0x3f)<<5)|(((w>>8)&0xf)<<1),13)
        return {0:'beq',1:'bne',4:'blt',5:'bge',6:'bltu',7:'bgeu'}[f3]+f' {r(rs1)},{r(rs2)},{b:+d}'
    if op == 0x37: return f'lui {r(rd)},0x{w>>12:x}'
    if op == 0x17: return f'auipc {r(rd)},0x{w>>12:x}'
    if op == 0x6f:
        j = sext(((w>>31)<<20)|(((w>>12)&0xff)<<12)|(((w>>20)&1)<<11)|(((w>>21)&0x3ff)<<1),21)
        return f'jal {r(rd)},{j:+d}'
    if op == 0x67: return f'jalr {r(rd)},{ii()}({r(rs1)})'
    if op == 0x73:
        return {0x00000073:'ecall', 0x30200073:'mret'}.get(w, f'csr 0x{w:x}')
    if op == 0x0f: return 'fence.i'
    return f'0x{w:08x}'

# ============================ SVG 渲染 ============================
def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')

COLORS = {'bit':'#1565c0', 'bus':'#2e7d32', 'inst':'#6a1b9a'}

def render(rows, idw, sel, samples, title, subtitle=''):
    n = len(samples)
    CW, LH, LAB, HD = 64, 36, 200, 52
    W = LAB + n*CW + 20
    H = HD + len(rows)*LH + 46
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'font-family="Menlo,Consolas,DejaVu Sans Mono,monospace" font-size="12">',
         f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
         f'<text x="14" y="24" font-size="15" font-weight="bold" fill="#111">{esc(title)}</text>']
    if subtitle:
        o.append(f'<text x="14" y="42" font-size="11.5" fill="#666">{esc(subtitle)}</text>')
    for c in range(n+1):
        x = LAB + c*CW
        o.append(f'<line x1="{x}" y1="{HD-6}" x2="{x}" y2="{H-26}" stroke="#ececec"/>')
    for ri,(label, spec, kind) in enumerate(rows):
        y = HD + ri*LH; yc = y + LH//2
        o.append(f'<rect x="4" y="{y}" width="{LAB-12}" height="{LH-4}" rx="3" fill="#f7f8fa"/>')
        o.append(f'<text x="12" y="{yc+4}" fill="#333">{esc(label)}</text>')
        if spec not in sel:
            o.append(f'<text x="{LAB+8}" y="{yc+4}" fill="#c00">(未找到 {esc(spec)})</text>')
            continue
        _, nm, sid, w = sel[spec]
        vals = [toint(s.get(sid), w) for s in samples]
        col = COLORS['inst'] if kind=='inst' else COLORS[kind]
        if kind == 'bit':
            o.append(f'<line x1="{LAB}" y1="{yc+9}" x2="{LAB+n*CW}" y2="{yc+9}" stroke="#ccc"/>')
            prev = None
            for c,v in enumerate(vals):
                yy = yc-9 if v else yc+9
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
                yy = yc+10
                o.append(f'<path d="M{x1},{yy-11} L{x1+7},{yy} L{x2-7},{yy} L{x2},{yy-11}" '
                         f'fill="none" stroke="{col}" stroke-width="1.5"/>')
                v = vals[c]
                if v is not None:
                    txt = decode(v) if kind=='inst' else f'0x{v:x}'
                    fs = 11 if len(txt) <= 9 else (9.5 if len(txt) <= 13 else 8)
                    o.append(f'<text x="{(x1+x2)/2}" y="{yc-3}" text-anchor="middle" '
                             f'font-size="{fs}" fill="{col}">{esc(txt)}</text>')
                c = c2+1
    ybot = H-26
    o.append(f'<line x1="{LAB}" y1="{ybot}" x2="{LAB+n*CW}" y2="{ybot}" stroke="#999"/>')
    step = 5 if n <= 40 else 10
    for c in range(0, n+1, step):
        x = LAB+c*CW
        o.append(f'<line x1="{x}" y1="{ybot}" x2="{x}" y2="{ybot+5}" stroke="#999"/>')
        o.append(f'<text x="{x}" y="{ybot+18}" text-anchor="middle" font-size="10" fill="#666">{c}</text>')
    o.append(f'<text x="{LAB+n*CW+4}" y="{ybot+18}" font-size="10" fill="#666">拍</text>')
    o.append('</svg>')
    return '\n'.join(o)

# ============================ 主流程 ============================
# 说明（v9 上板改造）：这里原先用的是 tb_wave.sv 的层次名 Core_cpu.*，
# 而本机可用的回归测试台是 sim/tb_iverilog.sv，它把观测点导出成
# tb_iverilog 作用域下的扁平探针 p_*。为了让波形图工具对
# run_iverilog.bat 产出的 .vcd 也能用，下面改用这些探针名
#（resolve() 支持不带层次前缀的名字）。
PIPE_ROWS = [
    ('clk',                 'clk',                            'bit'),
    ('IF 取指 PC',           'p_if_pc',                        'bus'),
    ('IF 指令（译码）',       'p_if_inst',                      'inst'),
    ('ID 译码 PC',           'p_id_pc',                        'bus'),
    ('ID valid',            'p_id_valid',                     'bit'),
    ('EX PC',               'p_ex_pc',                        'bus'),
    ('EX 结果',              'p_ex_res',                       'bus'),
    ('EX valid',            'p_ex_valid',                     'bit'),
    ('MEM valid',           'p_mem_valid',                    'bit'),
    ('WB valid',            'p_wb_valid',                     'bit'),
    ('WB PC',               'p_wb_pc',                        'bus'),
    ('WB 写回寄存器',         'p_wb_rd',                        'bus'),
    ('WB 写回值',            'p_wb_val',                       'bus'),
    ('IFU 暂停',             'p_stall',                        'bit'),
    ('重定向 dnpc_flag',      'p_dnpc_flag',                    'bit'),
    ('分支预测 taken',        'p_pred_taken',                   'bit'),
    ('预测错误',             'p_mispredict',                   'bit'),
]

def main():
    vcd, outsvg = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else 'waveform'
    ncyc = int(sys.argv[4]) if len(sys.argv) > 4 else 24
    specs = [s for _, s, _ in PIPE_ROWS]
    idw, sel, samples, stimes = sample(vcd, specs)
    for k, v in sel.items():
        if k != v[1] + '.' + v[0] if False else False:
            pass
    svg = render(PIPE_ROWS, idw, sel, samples[:ncyc], title,
                 subtitle='Verilator 仿真波形 · 每个时钟沿采样一次 · 上方数值为十六进制 / 已译码指令')
    open(outsvg, 'w', encoding='utf-8').write(svg)
    missing = [s for s in specs if s not in sel]
    print(f"wrote {outsvg}: {min(ncyc,len(samples))}/{len(samples)} 拍, 缺失信号 {missing}")

if __name__ == '__main__':
    main()
