import sys, os
sys.path.insert(0, '/home/shane/difftest')
from rv32 import RefISS, sext
import gen

MN = {}
for k,(f7,f3) in gen.RTYPE.items(): MN.setdefault((0x33,f3,f7&0x20),k)
for k,f3 in gen.ITYPE_ALU.items(): MN.setdefault((0x13,f3,0),k)
for k,f3 in gen.LOADS.items(): MN.setdefault((0x03,f3,0),k)
for k,f3 in gen.STORES.items(): MN.setdefault((0x23,f3,0),k)
for k,f3 in gen.BRANCHES.items(): MN.setdefault((0x63,f3,0),k)

def dis(inst):
    op = inst & 0x7f
    f3 = (inst>>12)&7
    rd = (inst>>7)&0x1f
    rs1 = (inst>>15)&0x1f
    rs2 = (inst>>20)&0x1f
    f7 = (inst>>25)&0x7f
    if op == 0x13 and f3 in (1,5):
        return '%s x%d,x%d,%d' % (MN.get((op,f3,0),'?'), rd, rs1, rs2)
    m = MN.get((op,f3,f7&0x20)) or MN.get((op,f3,0))
    if op == 0x33: return '%s x%d,x%d,x%d' % (m, rd, rs1, rs2)
    if op == 0x13: return '%s x%d,x%d,%d' % (m, rd, rs1, sext(inst>>20,12))
    if op == 0x03: return '%s x%d,%d(x%d)' % (m, rd, sext(inst>>20,12), rs1)
    if op == 0x23: return '%s x%d,%d(x%d)' % (m, rs2, sext(((inst>>25)<<5)|((inst>>7)&0x1f),12), rs1)
    if op == 0x63: return '%s x%d,x%d,off' % (m, rs1, rs2)
    if op == 0x6f: return 'jal x%d' % rd
    if op == 0x67: return 'jalr x%d,x%d,%d' % (rd, rs1, sext(inst>>20,12))
    if op == 0x37: return 'lui x%d,0x%x' % (rd, inst>>12)
    if op == 0x17: return 'auipc x%d,0x%x' % (rd, inst>>12)
    return 'op=0x%02x f3=%d' % (op,f3)

def trace(words, limit=60):
    ref = RefISS()
    for i,w in enumerate(words):
        for b in range(4): ref.mem[4*i+b] = (w>>(8*b))&0xff
    for n in range(limit):
        inst = ref.ld(ref.pc,4)
        print('  %3d pc=%04x inst=%08x  %s' % (n, ref.pc, inst, dis(inst)))
        ref.step()
        if ref.magic_seen:
            print('  -> magic store hit at step', n); return True
    return False

for name, fn in gen.DIRECTED:
    words = gen.with_terminator(fn().assemble())
    ref = RefISS()
    for i,w in enumerate(words):
        for b in range(4): ref.mem[4*i+b] = (w>>(8*b))&0xff
    try:
        ref.run()
        print('%-10s OK steps=%d' % (name, ref.steps))
    except Exception as e:
        print('%-10s FAIL %s' % (name, e))
        trace(words, 40)
        break
