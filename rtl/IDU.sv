`include "para.sv"

/* =============================================================================
 * IDU.sv — 译码级：原始指令 → 数据通路控制 + 控制通路事件 + 系统路径入口
 * 位置：IF→ID 之间，模块内是**两级流水**：第一级接住 IFU 的原始指令，第二级 inst_d 才是
 *   译码本体（立即数拼接、操作数选择、合法性判定都在这里）；两级共用推进条件
 *   (ready_next && !stall)，永远同步冻结。时序：inst_d(T) = IFU_inst(T-2)（差两拍）。
 * 上下游：IFU → 本模块 → EXU/Control；Reg_Stack 提供 ID 级 GPR/CSR 读口与 WB 级写回。
 * ★ 不许改回去：valid_next 不跟 stall 拉低(§IDU-2)、inst_d_out 取 inst_d(§IDU-1)、
 *   非法指令必须清掉全部副作用(§IDU-4)、ecall/mret/fence.i 单拍脉冲不得被吃掉(§IDU-3)。
 * 参考：docs/模块阅读文档.md、syn/修复史_全量.md
 * ============================================================================= */
module IDU(
    input clock,
    input reset,

    input [31:0] inst_in,
    input [31:0] snpc_in,
    input [31:0] pc_in,

    input flush,
    input stall,

    input [31:0] rd_value,
    input [31:0] csrd,
    input [4:0] rd,
    input R_wen,
    input [15:0] csr_wen,
    input        intr_take,

    input [31:0] EXU_rs1_in,
    input [31:0] EXU_rs2_in,

    input        pred_taken_in,
    input [31:0] pred_target_in,
    input [`BP_INDEX_BITS-1:0] pred_index_in,

    output [4:0] rd_next,
    output [2:0] funct3,
    output mret_flag,
    output ecall_flag,
    output fence_i_flag,
    // v9 新增（C4）：illegal_flag = 本拍 ID 级指令非法（→ 清副作用 + mcause=2）；
    //   mem_misalign = 访存非对齐（只看有效地址 rs1+imm，当拍算出，不等 ALU；funct3 供 mcause 分 4/6）。
    output       illegal_flag,
    output       mem_misalign,
    output [2:0] mem_misalign_funct3,

    output [31:0] branch_pc,
    output [31:0] rs1_value,
    output [31:0] rs2_value,
    
    output [31:0] add1_value,
    output [31:0] add2_value,
    output [15:0] csr_wen_next,
    output R_wen_next,
    output [31:0] rd_value_next,

    output        mem_wen,
    output        mem_ren,
    output        inv_flag,
    output        branch_flag,
    output        jump_flag,

    output [4:0] alu_opcode,

    output [4:0] rs1,
    output [4:0] rs2,
    output [31:0] a0_value,
    output [31:0] mepc_out,
    output [31:0] mtvec_out,
    // v9 修复（C4 遗留）：译码级指令本体引出，给 EXU 当 fault_inst_in（→ mtval）。
    // ★ 不变量：必须接 inst_d —— 它要与 illegal_flag 同拍，而 inst_d 与 IFU_inst 差两拍。§IDU-1
    output [31:0] inst_d_out,
    // v9 新增（C4）：mtval（出错指令编码/非对齐地址）、mcause（原因码）观察口，从 CSR 直通上来。
    output [31:0] mtval_out,
    output [31:0] mcause_out,
    output        intr_pending,
    output [31:0] pc_out,
    output        pred_taken,
    output [31:0] pred_target,
    output [`BP_INDEX_BITS-1:0] pred_index,


    input        valid_last,
    output       ready_last,

    input        ready_next,
    output logic valid_next,

    // ---- v9 新增（C4）：异常通道（从 Control 进来，透传给 Reg_Stack 里的 CSR）----
    input        trap_take,
    input        trap_take_q,
    input  [3:0] trap_cause,
    input [31:0] fault_addr,
    input [31:0] fault_inst
);

    logic [31:0] inst;
    logic [31:0] snpc;
    logic [31:0] pc;
    logic        valid;
    logic        pt_s1;          // 第一级流水携带的预测方向
    logic [31:0] ptg_s1;         // 第一级流水携带的预测目标
    logic [`BP_INDEX_BITS-1:0] pi_s1;   // 第一级流水携带的 gshare 索引

    logic [31:0] inst_d;
    logic [31:0] snpc_d;
    logic [31:0] pc_d;
    logic        valid_d;
    logic        pt_d;           // 第二级（译码级）携带的预测方向
    logic [31:0] ptg_d;          // 第二级（译码级）携带的预测目标
    logic [`BP_INDEX_BITS-1:0] pi_d;    // 第二级携带的 gshare 索引

    assign pred_taken  = pt_d;   // 随指令一起送到 EXU
    assign pred_target = ptg_d;
    assign pred_index  = pi_d;

    // ready_last 带 !stall：只有"EXU 这一拍能收"**且**"全局不停拍"，才算接收了上游这条指令。
    assign ready_last = ready_next && !stall;
    // ★ 不变量：valid_next = valid_d，**不能**跟着 stall 一起拉低。
    //   原因：EXU 只在 valid_last=1 时才更新自己的流水寄存器，把 valid_next 打成 0 不会"灌气泡"，
    //   只会让 EXU 永远保持上一条指令（一直占着 load，exu_load_use 恒 1）→ 死锁；load-use 冒险由
    //   Control 的 EXU_inst_clear 把提前收走的那份清成空操作处理。→ §IDU-2
    assign valid_next = valid_d;

    // 第一级流水寄存：接住 IFU 这一拍送来的原始指令与 snpc/pc。flush（= myCPU 的 dnpc_flag）时与
    //   第二级一起灌 NOP（32'h00000013 = addi x0,x0,0）：重定向是"命令下游丢弃"，不看 ready/stall。
    always_ff @(posedge clock) begin
        if (reset || flush) begin
            inst  <= 32'h00000013;
            snpc  <= 0;
            pc    <= 0;
            valid <= 0;
            pt_s1 <= 1'b0;
            ptg_s1 <= 32'b0;
            pi_s1 <= {`BP_INDEX_BITS{1'b0}};
        end else if (ready_next && !stall) begin
            inst  <= inst_in;
            snpc  <= snpc_in;
            pc    <= pc_in;
            valid <= valid_last;
            pt_s1 <= pred_taken_in;
            ptg_s1 <= pred_target_in;
            pi_s1 <= pred_index_in;
        end
    end

    // 第二级译码寄存（ID 级本体）：再稳一拍，给"立即数拼接 + 合法性判定 + 分支目标 + 前递选择 +
    //   读 GPR/CSR"留整拍余量，且译码用的是当拍不会被 IFU 改动的指令副本。
    always_ff @(posedge clock) begin
        if (reset || flush) begin
            inst_d  <= 32'h00000013;
            snpc_d  <= 0;
            pc_d    <= 0;
            valid_d <= 0;
            pt_d    <= 1'b0;
            ptg_d   <= 32'b0;
            pi_d    <= {`BP_INDEX_BITS{1'b0}};
        end else if (ready_next && !stall) begin
            inst_d  <= inst;
            snpc_d  <= snpc;
            pc_d    <= pc;
            valid_d <= valid;
            pt_d    <= pt_s1;
            ptg_d   <= ptg_s1;
            pi_d    <= pi_s1;
        end
    end

    logic [11:0] csr_addr;
    logic [6:0] oprand;
    logic [6:0] opcode;

    logic [31:0] imm_I;
    logic [31:0] imm_U;
    logic [31:0] imm_R;
    logic [31:0] imm_S;
    logic [31:0] imm_B;
    logic [31:0] imm_J;
    logic [31:0] csrs;
    logic [31:0] imm;

    logic is_S;
    logic is_I0;
    logic is_U0;
    logic is_U1;
    logic is_J;
    logic is_I2;
    logic is_I1;
    logic is_R;
    logic is_B;
    logic is_SYS;
    logic is_MEXT;   // RV32M：R 型且 funct7 = 0000001

    // 指令字段切片（一律取 inst_d）：opcode[6:0] / rd[11:7] / funct3[14:12] / rs1[19:15] /
    //   rs2[24:20] / funct7[31:25]（这里叫 oprand）；rd_next 是即将写回的寄存器号。
    assign oprand                      = inst_d[31:25];
    assign opcode                      = inst_d[6:0];
    assign rs1                         = inst_d[19:15];
    assign rs2                         = inst_d[24:20];
    assign funct3                      = inst_d[14:12];
    assign rd_next                     = inst_d[11:7];

    // 指令本体送出：与 illegal_flag / mem_misalign 同拍同源（都由 inst_d 组合译出）→ mtval。
    assign inst_d_out                  = inst_d;

    // ecall / mret / fence.i：右边是它们的完整 32 位编码，交给 Control 决定是否重定向 PC。
    // ★ 不变量：这三个标志由 inst_d 组合译出、**只有一拍宽**，下游不得用 ready/valid 门控
    //   它们发起的重定向。原因：dnpc_flag 同时就是 IDU 的 flush，请求发出那一拍两级被灌成
    //   NOP → 标志下一拍自动消失；Control 只给分支误预测建了 bp_misp_pend 挂起重发，
    //   ecall/mret/fence.i/trap 没有重发机制，被背压吃掉就永久丢失（B9 真凶）→ §IDU-3
    assign ecall_flag                  = (inst_d == 32'b00000000000000000000000001110011);
    assign mret_flag                   = (inst_d == 32'b00110000001000000000000001110011);
    assign fence_i_flag                = (inst_d == 32'b00000000000000000001000000001111);
 
    // 注：`csr_wen_next`（CSR 写使能位图）被移到本文件的"副作用清零"一节，
    //   因为它要乘 `no_side_effect`，而那个信号依赖这里的合法性译码结果。

    assign is_S   = (opcode == `S_opcode);
    assign is_I0  = (opcode == `I0_opcode);
    assign is_U0  = (opcode == `U0_opcode);
    assign is_U1  = (opcode == `U1_opcode);
    assign is_J   = (opcode == `J_opcode);
    assign is_I2  = (opcode == `I2_opcode);
    assign is_I1  = (opcode == `I1_opcode);
    assign is_R   = (opcode == `R_opcode);
    assign is_B   = (opcode == `B_opcode);
    assign is_SYS = (opcode == `SYS_opcode);
    assign is_MEXT = is_R && (oprand == `funct7_m);

    // 非法指令检测：白名单式判定（判据落在下面 legal_inst）。
    // ★ 不变量：任何"落在合法 opcode 下、但 funct3/funct7 不认识"的指令都必须判非法，且
    //   illegal_flag=1 的指令不得有任何架构副作用（见 no_side_effect）。原因：本级译码是
    //   "匹配不上就当加法"的结构（cond_* 全 0 → alu_add、R_wen_next 默认 1），不拦住就会被
    //   当成 add 真的执行掉并写坏 rd。→ §IDU-4
    // 合法子类型（只列本核实现的部分；未实现的合法指令也当非法处理，因为"没实现"意味着
    // 执行它必然产生错误结果，报异常才是正确语义）：
    //   LOAD   funct3 ∈ {000,001,010,100,101}          （无 011/110/111）
    //   OP-IMM funct3 ∈ {000,010,011,100,110,111,001；
    //                    101 且 top7 ∈ {0000000,0100000}}   无 110..111 之外的洞
    //   OP     funct3 ∈ {000 且 top7∈{0,0100000}, 001..111}，
    //          且 funct7==0000001 时 funct3 ∈ {000..111}（RV32M 全部合法）
    //   STORE  funct3 ∈ {000,001,010}
    //   BRANCH funct3 ∈ {000,001,100,101,110,111}      （无 010/011）
    //   JALR   funct3 == 000
    //   MISC-MEM 合法编码只有 fence（funct3=000）与 fence.i（funct3=001）
    //   SYSTEM funct3 == 000 时才允许（ecall/ebreak/mret；CSR 的 001/010/011
    //          由 is_SYS 分支单独处理，这里按 funct3!=000 && funct3>011 判非法）
    logic        op_top7_sub;      // OP: funct7 == 0100000（sub/sra）
    logic        op_imm_top7_sra;  // OP-IMM: bit30 == 1（srai）
    logic        sys_is_special;   // SYSTEM: 特权指令（ecall/ebreak/mret/wfi）
    logic        legal_load;
    logic        legal_store;
    logic        legal_branch;
    logic        legal_op_imm;
    logic        legal_op;
    logic        legal_misc;
    logic        legal_sys;

    assign op_top7_sub     = (oprand == `funct7_sub);
    assign op_imm_top7_sra = oprand[5];
    assign legal_load   = is_I0 && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010
                                 || funct3 == 3'b100 || funct3 == 3'b101);
    assign legal_store  = is_S  && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010);
    assign legal_branch = is_B  && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b100
                                 || funct3 == 3'b101 || funct3 == 3'b110 || funct3 == 3'b111);
    // OP-IMM：先按"移位类"分组再单独校验高 7 位 —— funct3=001(slli) 必须 0000000；
    //   funct3=101(srli/srai) 必须 0000000 或 0100000（与 sub 同值，复用宏）；其余 funct3 无约束。
    logic op_imm_is_shift;
    logic op_top7_sub_srl;
    assign op_imm_is_shift  = (funct3 == 3'b001) || (funct3 == 3'b101);
    assign op_top7_sub_srl  = (oprand == `funct7_sub);
    assign legal_op_imm = is_I1
                       && (op_imm_is_shift ? (oprand == `funct7_base || op_top7_sub_srl) : 1'b1)
                       && ((funct3 == 3'b001) ? ~op_imm_top7_sra : 1'b1);
    // OP（R 型）：funct7 只允许 0000000 / 0100000 / 0000001（RV32M）；0100000 只对 funct3=000/101 有意义。
    assign legal_op = is_R && (oprand == `funct7_base || op_top7_sub || oprand == `funct7_m)
                   && ((op_top7_sub) ? (funct3 == 3'b000 || funct3 == 3'b101) : 1'b1);
    // MISC-MEM：只有 fence (000) 与 fence.i (001) 两个合法编码。
    assign legal_misc = (opcode == `MISC_opcode) && (funct3 == 3'b000 || funct3 == 3'b001);
    // SYSTEM：funct3=000 是特权指令（ecall/ebreak/mret/wfi，由常量比较识别）；001/010/011 是 CSR 指令。
    assign legal_sys = is_SYS && (funct3 == 3'b000 || funct3 == 3'b001
                               || funct3 == 3'b010 || funct3 == 3'b011);

    logic opcode_known;
    assign opcode_known = is_S | is_I0 | is_U0 | is_U1 | is_J | is_I2 | is_I1
                        | is_R | is_B | is_SYS | (opcode == `MISC_opcode);
    logic legal_inst;
    assign legal_inst = opcode_known
                      & (is_I0 ? legal_load   : 1'b1)
                      & (is_S  ? legal_store  : 1'b1)
                      & (is_B  ? legal_branch : 1'b1)
                      & (is_I1 ? legal_op_imm : 1'b1)
                      & (is_R  ? legal_op     : 1'b1)
                      & (is_SYS? legal_sys    : 1'b1)
                      & ((opcode == `MISC_opcode) ? legal_misc : 1'b1);
    // 对外标志：本拍 ID 级指令非法（判据全部取自 inst_d，故与 inst_d_out 恒同拍 → mtval）。
    assign illegal_flag = ~legal_inst;

    // 统一"不得产生任何架构副作用"的条件（v9 新增 C4）：非法指令与非对齐访存都不得写 GPR/
    //   内存/CSR/改 PC；异常自身的登记由 CSR 走独立通道。必须在使用前声明（vlog-2730）。
    logic no_side_effect;
    assign no_side_effect = ~illegal_flag & ~mem_misalign;

    // CSR 写使能位图（位号见 para.sv `CSRW_*）：bit0 mepc / bit1 mcause / bit2 mstatus / bit3 mtvec
    //   （低 4 位兼容 v8）/ bit4 mie / bit5 mip / bit6 mscratch / bit7 mtimecmp，每位都带 is_SYS 门控。
    //   ★ 不变量：整张位图必须与 no_side_effect 相与（非法指令/非对齐访存不得写任何 CSR）→ §IDU-5
    assign csr_wen_next = no_side_effect ? {
        8'b0,
        (is_SYS && csr_addr == `CSR_mtimecmp),
        (is_SYS && csr_addr == `CSR_mscratch),
        (is_SYS && csr_addr == `CSR_mip),
        (is_SYS && csr_addr == `CSR_mie),
        (is_SYS && csr_addr == `CSR_mtvec),
        (is_SYS && csr_addr == `CSR_mstatus),
        (is_SYS && csr_addr == `CSR_mcause),
        (is_SYS && csr_addr == `CSR_mepc)
    } : 16'b0;

    // v9 修复（C4）：非法指令必须没有任何副作用 —— 下面几路是唯一能改架构状态的信号：
    //   R_wen_next/mem_wen/mem_ren 与 no_side_effect 相与，jump/branch/inv_flag 与 legal_inst
    //   相与（否则 EXU 会去算重定向、和异常抢同一个 dnpc）。踩坑史：§IDU-4
    assign R_wen_next                  = no_side_effect & ((is_S || is_B || opcode == 0)? 1'b0:1'b1);
    assign mem_wen                     = no_side_effect & is_S;
    assign mem_ren                     = no_side_effect & is_I0;

    assign jump_flag                   = legal_inst & ((is_I2 || is_J)? 1'b1:1'b0);

    assign inv_flag                    = legal_inst & (is_B && (funct3 == 3'b101 || funct3 == 3'b111 || funct3 == 3'b000 ))? 1'b1:1'b0;
    assign branch_flag                 = legal_inst & is_B;
 
    assign csr_addr                    = imm[11:0];

    // rd_value_next：无需再经 ALU/访存加工即可写回的结果（跳转类返回 snpc，系统指令返回 csrs）。
    assign rd_value_next               = jump_flag ? snpc_d :
                                         is_SYS ? csrs :
                                         0;
    assign branch_pc                   = pc_d + imm;
    assign pc_out  = pc_d;

    logic [31:0] add_src1;
    logic [31:0] add_src2;

    // add_src1/add_src2 把不同指令族统一映射为 ALU 双输入，便于执行级只关心运算而不再关心指令格式。
    //   CSRRS/C 的读改写取 rd_value_next、CSRRW 取 0；CSR 写数据最终由 WB 级 csrd = EX 结果决定。
    assign add_src1 = is_U0 ? 32'd0 :
                      (is_J || is_U1) ? pc_d :
                      EXU_rs1_in;

    assign add_src2 = (is_R || is_B) ? EXU_rs2_in :
                      (is_SYS && funct3 == 3'b010) ? rd_value_next :
                      (is_SYS && funct3 == 3'b001) ? 32'd0 : imm;

    assign add1_value = add_src1;
    assign add2_value = add_src2;

    // 访存非对齐判定（v9 新增 C4）：有效地址 = rs1 + 符号扩展立即数，判定**只看有效地址**，
    //   与 base 是否对齐无关：字节 000/100/101 永远对齐、半字 001 看 addr[0]、字 010 看 addr[1:0]。
    logic [31:0] mem_eff_addr;
    logic        addr_unaligned;
    assign mem_eff_addr  = EXU_rs1_in + imm;
    assign addr_unaligned = (funct3 == 3'b001) ? mem_eff_addr[0]
                          : (funct3 == 3'b010) ? (|mem_eff_addr[1:0])
                          : 1'b0;                      // 3'b000/100/101 都是字节访问
    assign mem_misalign        = legal_inst & (is_I0 | is_S) & addr_unaligned;
    assign mem_misalign_funct3 = funct3;
 

    // 功能译码白名单（全由 inst_d 组合译出）：所有 cond_* 都 0 时 alu_opcode 落到 `alu_add，
    //   所以非法指令必须由 legal_inst 拦住；is_B 与普通算术共用编码，EXU 取结果最低位当条件。
    logic cond_add;
    logic cond_signed_cmp;
    logic cond_unsigned_cmp;
    logic cond_xor;
    logic cond_or;
    logic cond_and;
    logic cond_sll;
    logic cond_srl;
    logic cond_sra;
    logic cond_sub;
    logic cond_equal;
    assign cond_add = is_S || is_I0 || is_U0 || is_U1 || is_J || is_I2
                 || (is_I1 && funct3 == 3'b000)
                 || (is_R  && funct3 == 3'b000 && oprand[5] == 1'b0)
                 || (is_B  && funct3[2:1] == 2'b01);
    assign cond_signed_cmp = (is_I1 && funct3 == 3'b010)
                        || (is_R  && funct3 == 3'b010)
                        || (is_B  && (funct3 == 3'b101 || funct3 == 3'b100));
    assign cond_unsigned_cmp = (is_B  && (funct3 == 3'b110 || funct3 == 3'b111))
                          || (is_I1 && funct3 == 3'b011)
                          || (is_R  && funct3 == 3'b011);
    assign cond_xor = (is_I1 && funct3 == 3'b100)
                 || (is_R  && funct3 == 3'b100);
    assign cond_or = (is_I1 && funct3 == 3'b110)
                || (is_R  && funct3 == 3'b110)
                || (is_SYS  && funct3 == 3'b010);
    assign cond_and = (is_I1 && funct3 == 3'b111)
                 || (is_R  && funct3 == 3'b111);
    assign cond_sll = (is_I1 && funct3 == 3'b001)
                 || (is_R  && funct3 == 3'b001);
    assign cond_srl = (is_I1 && funct3 == 3'b101 && oprand[5] == 1'b0)
                 || (is_R  && funct3 == 3'b101 && oprand[5] == 1'b0);
    assign cond_sra = (is_I1 && funct3 == 3'b101 && oprand[5] == 1'b1)
                 || (is_R  && funct3 == 3'b101 && oprand[5] == 1'b1);
    assign cond_sub = (is_R  && funct3 == 3'b000 && oprand[5] == 1'b1);
    assign cond_equal = (is_B && funct3[2:1] == 2'b00);

    // ALU 操作码选择：RV32M（is_MEXT）优先级最高；分支比较复用同一套编码，EXU 取最低位当条件。
    logic [4:0] m_alu_opcode;
    assign m_alu_opcode = (funct3 == 3'b000) ? `alu_mul    :
                          (funct3 == 3'b001) ? `alu_mulh   :
                          (funct3 == 3'b010) ? `alu_mulhsu :
                          (funct3 == 3'b011) ? `alu_mulhu  :
                          (funct3 == 3'b100) ? `alu_div    :
                          (funct3 == 3'b101) ? `alu_divu   :
                          (funct3 == 3'b110) ? `alu_rem    :
                                               `alu_remu;

    assign alu_opcode = is_MEXT ? m_alu_opcode :
                        cond_add ? `alu_add :
                        cond_signed_cmp ? `alu_signed_comparator :
                        cond_unsigned_cmp ? `alu_unsigned_comparator :
                        cond_xor ? `alu_xor :
                        cond_or ? `alu_or  :
                        cond_and ? `alu_and :
                        cond_sll ? `alu_sll :
                        cond_srl ? `alu_srl :
                        cond_sra ? `alu_sra :
                        cond_sub ? `alu_sub :
                        cond_equal ? `alu_equal : `alu_add;


    // 立即数格式（位序必须严格按规范）：I=inst[31:20] 符号扩展 / U=inst[31:12]<<12 / R 无立即数 /
    //   S=inst[31:25]|inst[11:7]。
    assign imm_I                       = {{20{inst_d[31]}},inst_d[31:20]};
    assign imm_U                       = {inst_d[31:12],12'd0};
    assign imm_R                       = {25'd0,inst_d[31:25]};
    assign imm_S                       = {{20{inst_d[31]}},inst_d[31:25],inst_d[11:7]};
    // B 型立即数：{inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}
    assign imm_B                       = {{19{inst_d[31]}}, inst_d[31], inst_d[7], inst_d[30:25], inst_d[11:8], 1'b0};
    // J 型立即数：{inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}
    assign imm_J                       = {{11{inst_d[31]}}, inst_d[31], inst_d[19:12], inst_d[20], inst_d[30:21], 1'b0};
/* verilator lint_off IMPLICIT */

    // 反例标注：下面第 5、6 档都是 `S_opcode`（第 6 档本意应是 R_opcode），R 型永远选不中 ——
    //   已知遗留，R 型不用立即数所以无行为影响，本次不动代码。
    assign imm = (opcode == `I0_opcode || opcode == `I1_opcode || opcode == `I2_opcode || opcode == `SYS_opcode)? imm_I:
                 (opcode == `U0_opcode || opcode == `U1_opcode)? imm_U:
                 (opcode == `J_opcode)? imm_J:
                 (opcode == `B_opcode)? imm_B:
                 (opcode == `S_opcode)? imm_S: 
                 (opcode == `S_opcode)? imm_R :
                  0;

// Reg_Stack = 通用寄存器堆 + CSR 的封装（自身无流水寄存器）：读口在本级组合读出 rs1/rs2 与
//   csrs；写口由 WB 级（WBU）驱动，中间隔 EXU/MEM/WB 三级流水原样携带 → 读写口差三级。
Reg_Stack Reg_Stack_inst0(
    .reset (reset),
    .clock (clock),
    .pc (pc_d),
    .ecall_flag (ecall_flag),
    .mret_flag (mret_flag),
    .intr_take (intr_take),

    .rs1 (rs1),
    .rs2 (rs2),
    .rd (rd),
    .rd_value (rd_value),

    .csr_addr (csr_addr),
    .R_wen (R_wen),
    .csr_wen (csr_wen),
    .csrd (csrd),

    // v9 新增（C4）：同步异常通道
    .trap_take   (trap_take),
    .trap_take_q (trap_take_q),
    .trap_cause  (trap_cause),
    .fault_addr  (fault_addr),
    .fault_inst  (fault_inst),

    .rs1_value (rs1_value),
    .rs2_value (rs2_value),
    .a0_value (a0_value),
    .csrs (csrs),
    .mepc_out (mepc_out),
    .mtvec_out (mtvec_out),
    .mcause_out (mcause_out),
    .mstatus_out (),
    .mie_out (),
    .mip_out (),
    .mscratch_out (),
    .mtime_out (),
    .mtimecmp_out (),
    .mtval_out (mtval_out),
    .intr_pending (intr_pending)
);





endmodule
