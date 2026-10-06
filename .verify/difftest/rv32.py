"""RV32IM 指令编码器 + 独立参考模型（差分测试用）。

设计要点：
  * 编码器按标准 RISC-V 手册实现，并已用工程里人工核对过的 prog.hex
    逐条校准（lui/addi/add/mul/sw/lw/beq/jal/ori/ecall 全部一致）。
  * 参考模型完全独立于 RTL：按字节寻址的 64KB 小端存储器，
    与测试台 DRAM 的 perip_addr[15:2]/[1:0] 解码等价（地址 & 0xFFFF）。
"""

M32 = 0xFFFFFFFF


def u32(x):
    return x & M32


def s32(x):
    x &= M32
    return x - (1 << 32) if (x & 0x80000000) else x


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if (v & (1 << (bits - 1))) else v


# --------------------------------------------------------------------------
# 编码器
# --------------------------------------------------------------------------
def enc_r(f7, rs2, rs1, f3, rd):
    return u32((f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33)


def enc_i(imm, rs1, f3, rd, op=0x13):
    return u32(((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op)


def enc_s(imm, rs2, rs1, f3):
    im = imm & 0xFFF
    return u32(((im >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
               ((im & 0x1F) << 7) | 0x23)


def enc_b(imm, rs2, rs1, f3):
    im = imm & 0x1FFF
    b12 = (im >> 12) & 1
    b11 = (im >> 11) & 1
    b10_5 = (im >> 5) & 0x3F
    b4_1 = (im >> 1) & 0xF
    return u32((b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) |
               (f3 << 12) | (b4_1 << 8) | (b11 << 7) | 0x63)


def enc_u(imm20, rd, op):
    return u32(((imm20 & 0xFFFFF) << 12) | (rd << 7) | op)


def enc_j(imm, rd):
    im = imm & 0x1FFFFF
    b20 = (im >> 20) & 1
    b19_12 = (im >> 12) & 0xFF
    b11 = (im >> 11) & 1
    b10_1 = (im >> 1) & 0x3FF
    return u32((b20 << 31) | (b19_12 << 12) | (b11 << 20) | (b10_1 << 21) |
               (rd << 7) | 0x6F)


# --------------------------------------------------------------------------
# 参考模型
# --------------------------------------------------------------------------
class RefISS:
    """RV32IM 参考实现。只实现整数 + M 扩展，不含 CSR/异常（差分测试不用）。"""

    MAGIC_ADDR = 0x3FFC
    MAGIC_VAL = 0x123

    def __init__(self):
        self.r = [0] * 32
        self.mem = bytearray(1 << 16)
        self.pc = 0
        self.steps = 0
        self.magic_seen = False
        # 程序代码占用的字节数：RTL 里代码在独立 IROM、数据在 DRAM，
        # 参考模型只有一块内存，所以比对时要排除代码区，否则全是假阳。
        self.code_bytes = 0

    # -- 小端按字节访问，地址按 16 位环绕（与 RTL 的 [15:2]+[1:0] 解码等价）
    def ld(self, a, n):
        v = 0
        for i in range(n):
            v |= self.mem[(a + i) & 0xFFFF] << (8 * i)
        return v

    def st(self, a, n, v):
        for i in range(n):
            self.mem[(a + i) & 0xFFFF] = (v >> (8 * i)) & 0xFF

    def wr(self, rd, v):
        if rd:
            self.r[rd] = u32(v)

    def step(self):
        inst = self.ld(self.pc, 4)
        op = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        f3 = (inst >> 12) & 0x7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        f7 = (inst >> 25) & 0x7F
        A = self.r[rs1]
        B = self.r[rs2]
        npc = u32(self.pc + 4)
        imm_i = sext(inst >> 20, 12)

        if op == 0x37:                      # lui
            self.wr(rd, inst & 0xFFFFF000)
        elif op == 0x17:                    # auipc
            self.wr(rd, u32(self.pc + (inst & 0xFFFFF000)))
        elif op == 0x6F:                    # jal
            imm = sext(((inst >> 31) << 20) | (((inst >> 12) & 0xFF) << 12) |
                       (((inst >> 20) & 1) << 11) | (((inst >> 21) & 0x3FF) << 1), 21)
            self.wr(rd, npc)
            npc = u32(self.pc + imm)
        elif op == 0x67:                    # jalr
            t = u32(A + imm_i)
            self.wr(rd, npc)
            npc = t & ~1
        elif op == 0x63:                    # branch
            imm = sext(((inst >> 31) << 12) | (((inst >> 7) & 1) << 11) |
                       (((inst >> 25) & 0x3F) << 5) | (((inst >> 8) & 0xF) << 1), 13)
            take = {
                0b000: A == B, 0b001: A != B,
                0b100: s32(A) < s32(B), 0b101: s32(A) >= s32(B),
                0b110: A < B, 0b111: A >= B,
            }.get(f3, False)
            if take:
                npc = u32(self.pc + imm)
        elif op == 0x03:                    # load
            a = u32(A + imm_i)
            if f3 == 0b000:
                self.wr(rd, sext(self.ld(a, 1), 8))
            elif f3 == 0b001:
                self.wr(rd, sext(self.ld(a, 2), 16))
            elif f3 == 0b010:
                self.wr(rd, self.ld(a, 4))
            elif f3 == 0b100:
                self.wr(rd, self.ld(a, 1))
            elif f3 == 0b101:
                self.wr(rd, self.ld(a, 2))
            else:
                raise ValueError("bad load f3 %d" % f3)
        elif op == 0x23:                    # store
            imm = sext(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12)
            a = u32(A + imm)
            if f3 == 0b000:
                self.st(a, 1, B)
            elif f3 == 0b001:
                self.st(a, 2, B)
            elif f3 == 0b010:
                self.st(a, 4, B)
            else:
                raise ValueError("bad store f3 %d" % f3)
            if (a & 0xFFFF) == self.MAGIC_ADDR and u32(B) == self.MAGIC_VAL:
                self.magic_seen = True
        elif op == 0x13:                    # OP-IMM
            sh = rs2 & 0x1F
            if f3 == 0b000:
                self.wr(rd, A + imm_i)
            elif f3 == 0b010:
                self.wr(rd, 1 if s32(A) < imm_i else 0)
            elif f3 == 0b011:
                self.wr(rd, 1 if A < (imm_i & M32) else 0)
            elif f3 == 0b100:
                self.wr(rd, A ^ (imm_i & M32))
            elif f3 == 0b110:
                self.wr(rd, A | (imm_i & M32))
            elif f3 == 0b111:
                self.wr(rd, A & (imm_i & M32))
            elif f3 == 0b001:
                self.wr(rd, A << sh)
            elif f3 == 0b101:
                if (inst >> 25) & 0x20:
                    self.wr(rd, s32(A) >> sh)
                else:
                    self.wr(rd, A >> sh)
            else:
                raise ValueError("bad op-imm f3 %d" % f3)
        elif op == 0x33:                    # OP / M
            if f7 == 0x01:
                if f3 == 0b000:
                    self.wr(rd, s32(A) * s32(B))
                elif f3 == 0b001:
                    self.wr(rd, (s32(A) * s32(B)) >> 32)
                elif f3 == 0b010:
                    self.wr(rd, (s32(A) * B) >> 32)
                elif f3 == 0b011:
                    self.wr(rd, (A * B) >> 32)
                elif f3 in (0b100, 0b110):          # div / rem
                    if B == 0:
                        q, rm = M32, A
                    elif s32(A) == -(1 << 31) and s32(B) == -1:
                        q, rm = A, 0
                    else:
                        q = abs(s32(A)) // abs(s32(B))
                        if (s32(A) < 0) != (s32(B) < 0):
                            q = -q
                        rm = s32(A) - q * s32(B)
                        q, rm = u32(q), u32(rm)
                    self.wr(rd, q if f3 == 0b100 else rm)
                elif f3 in (0b101, 0b111):          # divu / remu
                    if B == 0:
                        q, rm = M32, A
                    else:
                        q, rm = A // B, A % B
                    self.wr(rd, q if f3 == 0b101 else rm)
                else:
                    raise ValueError("bad m f3 %d" % f3)
            else:
                if f3 == 0b000:
                    self.wr(rd, A - B if (f7 & 0x20) else A + B)
                elif f3 == 0b001:
                    self.wr(rd, A << (B & 0x1F))
                elif f3 == 0b010:
                    self.wr(rd, 1 if s32(A) < s32(B) else 0)
                elif f3 == 0b011:
                    self.wr(rd, 1 if A < B else 0)
                elif f3 == 0b100:
                    self.wr(rd, A ^ B)
                elif f3 == 0b101:
                    self.wr(rd, s32(A) >> (B & 0x1F) if (f7 & 0x20) else A >> (B & 0x1F))
                elif f3 == 0b110:
                    self.wr(rd, A | B)
                elif f3 == 0b111:
                    self.wr(rd, A & B)
                else:
                    raise ValueError("bad op f3 %d" % f3)
        else:
            raise ValueError("illegal opcode 0x%02x at pc=0x%x (inst=0x%08x)" %
                             (op, self.pc, inst))

        self.pc = npc
        self.steps += 1

    def run(self, max_steps=200000):
        while not self.magic_seen:
            if self.steps > max_steps:
                raise RuntimeError("reference model: step limit exceeded "
                                   "(magic store never executed)")
            self.step()
        return self

    def snapshot(self):
        """返回 (寄存器数组, 非零字地址->值)，排除程序代码区。"""
        mem = {}
        for i in range(1 << 14):
            a = 4 * i
            if a < self.code_bytes:
                continue
            w = int.from_bytes(self.mem[a:a + 4], "little")
            if w:
                mem[a] = w
        return list(self.r), mem
