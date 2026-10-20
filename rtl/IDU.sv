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
    // ★★ v13.2（P0）：本拍 ID 级这条系统指令（ecall/mret）**确实会提交**吗？
    //   由 Control 给："ID 级被下游接收(IDU_ready) 且 本拍没有更老的重定向
    //   (intr_take / trap_redirect / bp_mispredict)"。
    //   为什么必须有它：ecall_flag/mret_flag 是**纯译码电平**，只要指令还在 ID 就为 1。
    //   而更老的误预测分支（在 EX）同拍会把 dnpc 指向自己的目标并 flush 掉 ID ——
    //   于是那条 ecall 明明在错路径上，却已经把 mstatus/mepc/mcause 改了。
    //   实测（FreeRTOS 空闲任务的 taskYIELD，pc=0x2d8）：同一条 ecall 提交三次，
    //   mstatus 0x1888 → 0x1880 → 0x1800，MIE 永久丢失、tick 只来一次。
    //   详细证据：docs/CHECKPOINT_v13.md §7。
    input        sys_commit_ok,

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
    //   v10：trap_take_q 删除；新增 fault_pc（= EX 级出错指令的 PC，写 mepc 用）
    input        trap_take,
    input  [3:0] trap_cause,
    input [31:0] fault_addr,
    input [31:0] fault_inst,
    input [31:0] fault_pc,

    // ★ v12（B）新增：Zicntr 支持
    //   retire     ：一条指令真正退休（LSU 的 WB 入口），只给 minstret 当计数使能
    //   mcycle_dbg ：mcycle 的低 32 位，纯观察口（顶层 → ILA probe），不参与任何逻辑
    input         retire,
    output [31:0] mcycle_dbg,

    // ---- v10.2 新增：CSR 读口的 RAW 前递 --------------------------------
    //   csr_sel：本拍要读的 CSR 的独热码（位映射同 csr_wen，只含 bit0..bit7）
    //   csr_rd_fwd_en/value：Control 从 4 深影子链 + EX 级里挑出的**最新一次在途写**的值。
    //   ★ 不变量：这三根线只服务于"读值"，不影响"要不要写"；写使能仍走 csr_wen_next。
    output [15:0] csr_sel,
    input         csr_rd_fwd_en,
    input  [31:0] csr_rd_fwd
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

    // ecall / ebreak / mret / wfi / fence.i：交给 Control 决定是否重定向 PC。
    // ★ 不变量：这几个标志由 inst_d 组合译出、**只有一拍宽**，下游不得用 ready/valid 门控
    //   它们发起的重定向。原因：dnpc_flag 同时就是 IDU 的 flush，请求发出那一拍两级被灌成
    //   NOP → 标志下一拍自动消失；Control 只给分支误预测建了 bp_misp_pend 挂起重发，
    //   ecall/mret/fence.i/trap 没有重发机制，被背压吃掉就永久丢失（B9 真凶）→ §IDU-3
    //
    // ★ v10.2 改写（等价变换，省 5 个 32 位比较器）：原来每条都是 `inst_d == 32'h....`
    //   的**全宽**相等比较（5 条 = 5×32 位）。但这几条指令的 opcode/funct3/rs1/rd 都固定，
    //   真正变化只有 imm[11:0]：把固定字段单独判一次，只比较 12 位。
    //       字段覆盖：opcode[6:0] + funct3[14:12] + rs1[19:15] + rd[11:7] + imm[31:20] = 32 位
    //   所以 `sys_f3_zero & rs1_f & rd_f & (priv_id == …)` 与全宽比较**逐位等价**。
    //   v10.2 首次综合后 WNS 掉了 0.475ns（关键路径换到 MDU 乘法器），这 5 个 32 位比较
    //   是这轮新加的主要组合面积，收窄后面积/拥塞都明显下降（见 IMPLEMENTATION_v10 §11.9）。
    logic [11:0] priv_id;      // inst[31:20]：特权指令的 imm 域
    logic        sys_rs1z;     // rs1 域为 0
    logic        sys_rdz;      // rd  域为 0
    logic        sys_f3_zero;  // opcode=SYS 且 funct3=000
    // ★ v10.3 修（ModelSim 抓到的）：这三根必须**在下面第一次被赋值之前**声明。
    //   原来它们声明在 legal_sys 那一节（本文件 290 行附近），而赋值在 243~250 行 ——
    //   SystemVerilog 对"先用后声明"的标识符会当**隐式 1 位网**创建，
    //   于是后面那行 `logic` 成了"重复声明"。
    //   iverilog 只提示、Verilator 的 IMPLICIT 也没报（它按模块两遍解析），
    //   只有 vlog -sv 直接给 `(vlog-2388) 'ebreak_flag' already declared in this scope` 并**拒绝编译**。
    //   本例三根都是 1 位，功能上侥幸没错，但这正是 v10.2 踩过的同一个坑（csrs_rd 隐式 1 位网）
    //   的变体 —— 那次代价是 tb_exc 三个用例全红。
    //   ★ 不变量：本文件任何 `logic` 声明都必须出现在它的第一处使用之前。
    logic        ebreak_flag;
    logic        wfi_flag;
    logic        sys_priv_ok;
    assign priv_id     = inst_d[31:20];
    assign sys_rs1z    = (inst_d[19:15] == 5'd0);
    assign sys_rdz     = (inst_d[11:7]  == 5'd0);
    assign sys_f3_zero = is_SYS & (funct3 == 3'b000);
    assign ecall_flag  = sys_f3_zero & sys_rs1z & sys_rdz & (priv_id == 12'h000);
    assign mret_flag   = sys_f3_zero & sys_rs1z & sys_rdz & (priv_id == 12'h302);
    // v10.2：ebreak / wfi 也逐条识别。ebreak = 0x00100073 → 走"非法指令"那条陷入通路
    //   （见 illegal_flag），由 CSR 用 fault_inst 把它翻成 mcause=3；
    //   wfi = 0x10500073 → 本核没有低功耗状态可等，按**合法空操作**放过。
    assign ebreak_flag = sys_f3_zero & sys_rs1z & sys_rdz & (priv_id == 12'h001);
    assign wfi_flag    = sys_f3_zero & sys_rs1z & sys_rdz & (priv_id == 12'h105);
    // fence.i = 0x0000100F：opcode=MISC、funct3=001、rs1=rd=imm[31:20]=0
    assign fence_i_flag = (opcode == `MISC_opcode) & (funct3 == 3'b001)
                        & sys_rs1z & sys_rdz & (priv_id == 12'h000);
    // SYS funct3=000 的合法集合。ecall/ebreak/mret/wfi 之外的编码（sret 0x10200073、
    //   dret 之类）在本核都判非法 —— 它们确实"没有实现"。
    assign sys_priv_ok                 = ecall_flag | ebreak_flag | mret_flag | wfi_flag;
 
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
    //   SYSTEM funct3 ∈ {000（仅 ecall/ebreak/mret/wfi）, 001,010,011,101,110,111}
    //          （v10.2：补上 CSR 立即数形式 101/110/111；100 未定义 → 非法；
    //            funct3=000 由 sys_priv_ok 逐条比对，不再"一律合法"）
    logic        op_top7_sub;      // OP: funct7 == 0100000（sub/sra）
    logic        op_imm_top7_sra;  // OP-IMM: bit30 == 1（srai）
    // SYSTEM funct3=000 的四条特权指令编码逐条识别（v10.2）。原来这里有个 sys_is_special
    //   声明**从来没有被驱动过**（也没有任何读者），而合法性判据是"funct3==000 一律合法" ——
    //   于是 ebreak/wfi/sret/任意 SYSTEM 编码都被当合法空操作放过，ebreak 永远不会陷入。
    //   （ebreak_flag / wfi_flag / sys_priv_ok 的声明已上移到第一次赋值之前，见本文件 230 行附近）
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

    // ---- v10.3：CSR 指令子编码 ------------------------------------------------
    //   ★ 位置约束：这一段**必须在 legal_sys 之前**（地址合法性是 legal_sys 的一部分），
    //     而 csr_wen_next/csr_sel 又必须在 no_side_effect 之后（要乘副作用清零）。
    //     所以拆成两段：这里只做"不依赖 no_side_effect"的译码，写使能位图留在下面。
    //   funct3[1:0]：01 = CSRRW/CSRRWI（整字写） 10 = CSRRS/CSRRSI（置位） 11 = CSRRC/CSRRCI（清位）
    //   funct3[2]  ：1 = 立即数形式（rs1 域当 5 位零扩展立即数 uimm）
    // ★ 不变量：CSR 的"读"和"写"是两件独立的事，必须分开判：
    //   · 读：任何 CSRR* 都读，读值 = csrs（**经 RAW 前递**，见 csrs_rd）；
    //   · 写：CSRRW/CSRRWI 恒写；CSRRS/C（含立即数形式）只有"源操作数非零"才写 ——
    //     规范原文（Zicsr §5.1.1）："For both CSRRS and CSRRC, if rs1=x0, then the
    //     instruction will not write to the CSR at all, ... nor raise illegal-instruction
    //     exceptions on accesses to read-only CSRs." 也就是说 csr_wr 这根线**同时**是
    //     "会不会写"和"要不要对只读地址报非法"的判据，两处必须共用，不能各写一份。
    logic        csr_op;      // 本拍是 CSRR* 指令（funct3 != 000 的 SYSTEM）
    logic        csr_imm;     // 立即数形式（rs1 域 = uimm5）
    logic        csr_wr;      // 本拍真的会写 CSR 寄存器
    logic [31:0] csr_src;     // 写数据的源操作数：rs1 前递值 或 零扩展 uimm5
    logic [ 1:0] csr_f3;      // funct3[1:0]：01/10/11
    logic        csr_known;   // 地址落在本核**已实现**的 CSR 集合里
    logic        csr_rdonly;  // 地址落在只读段（csr_addr[11:10] == 2'b11）
    logic        csr_illegal; // 本条 CSR 指令必须陷入非法指令

    assign csr_f3     = funct3[1:0];
    assign csr_op     = is_SYS & (funct3 != 3'b000);   // funct3=000 是 ecall/ebreak/mret/wfi
    assign csr_imm    = csr_op & funct3[2];
    assign csr_src    = csr_imm ? {27'b0, inst_d[19:15]} : EXU_rs1_in;
    assign csr_wr     = csr_op & ((csr_f3 == 2'b01) | (csr_src != 32'b0));

    // 已实现集合 = Reg_Stack 读多路里真正有分支的那 13 个地址 + misa（v10.3 起读常量）。
    //   ★ 不变量：这份名单必须与 Reg_Stack.sv 的 csrs 读多路、以及 CSR.sv 里真正存在的
    //     寄存器**一一对齐**。名单里多一个 → 读到 0 也不报错（假实现）；少一个 → 正常
    //     CSR 反而陷入（直接跑飞）。改动任何一侧都要同步这里。
    //   ★ v10.3b：mimpid/mconfigptr 必须进来 —— 特权规范对 mimpid 的原文是
    //     "This register **must be readable in any implementation**, but a value of 0 can be
    //      returned to indicate that the field is not implemented."（§2.1.1.4）
    //     "不实现"的正确表达是**读 0**，不是报非法。同类"信息寄存器"（mvendorid/marchid/
    //     mhartid）早就在名单里，把 mimpid/mconfigptr 漏在外面是口径不一致。
    assign csr_known  = (csr_addr == `CSR_mstatus)   | (csr_addr == `CSR_misa)
                      | (csr_addr == `CSR_mie)       | (csr_addr == `CSR_mtvec)
                      | (csr_addr == `CSR_mscratch)  | (csr_addr == `CSR_mepc)
                      | (csr_addr == `CSR_mcause)    | (csr_addr == `CSR_mtval)
                      | (csr_addr == `CSR_mip)
                      | (csr_addr == `CSR_mtime)     | (csr_addr == `CSR_mtimecmp)
                      | (csr_addr == `CSR_mvendorid) | (csr_addr == `CSR_marchid)
                      | (csr_addr == `CSR_mimpid)    | (csr_addr == `CSR_mhartid)
                      | (csr_addr == `CSR_mconfigptr)
                      // ★ v12（B）：Zicntr 一套 10 个地址。0xB0x/0xB8x 是 MRW 本体，
                      //   0xC0x/0xC8x 是只读影子 —— 二者都在名单里（读必须合法），
                      //   但只有 0xBxx 能写：0xCxx 的 csr[11:10]=2'b11 会被 csr_rdonly 挡下。
                      | (csr_addr == `CSR_mcycle)    | (csr_addr == `CSR_mcycleh)
                      | (csr_addr == `CSR_minstret)  | (csr_addr == `CSR_minstreth)
                      | (csr_addr == `CSR_cycle)     | (csr_addr == `CSR_cycleh)
                      | (csr_addr == `CSR_instret)   | (csr_addr == `CSR_instreth)
                      | (csr_addr == `CSR_time)      | (csr_addr == `CSR_timeh);
    // 只读判定直接看地址编码，不看具体是哪个寄存器 —— 特权规范 §1.1.1：
    //   "The top two bits (csr[11:10]) indicate whether the register is read/write
    //    (00, 01, or 10) or read-only (11)."
    //   "Attempts to write a read-only register raise illegal-instruction exceptions."
    //   本核的 mvendorid(0xF11)/marchid(0xF12) 正好落在 11 段，所以 `csrw mvendorid, x1`
    //   以前是"写入被静默丢弃"，现在是 mcause=2 的非法指令陷入 —— 二者语义完全不同。
    //   反过来的坑：`csrr x5, mvendorid`（rs1=x0）**不许**陷入，靠 csr_wr=0 挡住。
    assign csr_rdonly = (csr_addr[11:10] == 2'b11);
    // 两条非法条件合并成一根：
    //   ① 访问不存在的 CSR（特权规范 §1.1："Instructions that access a non-existent CSR
    //      are reserved."；本核按惯例报非法指令，顺带覆盖 0x7B0-0x7BF 这类
    //      "机器模式访问 debug-only 寄存器应当报非法"的要求）；
    //   ② 对只读地址**真的发起写**（csr_wr=1）。
    //   ★ 只读 + 纯读（csr_wr=0）合法，这是上面规范原文明确要求的，别把两项写成或。
    assign csr_illegal = csr_op & (~csr_known | (csr_rdonly & csr_wr));

    // SYSTEM：funct3=000 是特权指令（ecall/ebreak/mret/wfi，**逐条**比对编码）；
    //   001/010/011 是 CSR 寄存器形式，101/110/111 是 CSR 立即数形式（v10.2 补全），
    //   100 在规范里未定义 → 非法。
    // ★ v10.2：ecall/ebreak/mret/fence.i 的编码检测本来就写在上面（ecall_flag 等），
    //   这里复用它们，避免"寄存器比较一份、常量判断另一份"的两套口径。
    // ★ v10.3：CSR 分支再叠一条地址合法性（csr_illegal），见上面两条非法条件。
    assign legal_sys = is_SYS && ((funct3 == 3'b000) ? sys_priv_ok
                                                    : ((funct3 != 3'b100) & ~csr_illegal));

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
    // ★ v10.2：ebreak 也并进这一根。它不是非法指令（mcause 由 CSR 按 fault_inst 翻成 3），
    //   但它和非法指令**共用同一条陷入通路**：ID 级判 → no_side_effect 清掉全部副作用
    //   → EX 级锁存 → trap_take 重定向 + 登记 CSR。这样不必新增第 5 个异常位穿过
    //   IDU→EXU→Control→CSR 四层端口。
    assign illegal_flag = ~legal_inst | ebreak_flag;

    // 统一"不得产生任何架构副作用"的条件（v9 新增 C4）：非法指令与非对齐访存都不得写 GPR/
    //   内存/CSR/改 PC；异常自身的登记由 CSR 走独立通道。必须在使用前声明（vlog-2730）。
    logic no_side_effect;
    assign no_side_effect = ~illegal_flag & ~mem_misalign;

    // ---- v10.2：CSR 指令子编码 ------------------------------------------------
    //   funct3[1:0]：01 = CSRRW/CSRRWI（整字写） 10 = CSRRS/CSRRSI（置位） 11 = CSRRC/CSRRCI（清位）
    //   funct3[2]  ：1 = 立即数形式（rs1 域当 5 位零扩展立即数 uimm）
    // ★ 不变量：CSR 的"读"和"写"是两件独立的事，必须分开判：
    //   · 读：任何 CSRR* 都读，读值 = csrs（**经 RAW 前递**，见 csrs_rd）；
    //   · 写：CSRRW/CSRRWI 恒写；CSRRS/C（含立即数形式）只有"源操作数非零"才写 ——
    //     规范如此（rs1=x0 的 csrrs/csrrc 是纯读）。原来一律写，于是
    //     `csrrc mip, x0` 会把 mip 清成 0（新值 = 0 & ~mip = 0），读操作变成了写。
    //   ★ v10.3：csr_op/csr_imm/csr_wr/csr_src/csr_f3 的**声明与驱动**已经上移到
    //     legal_sys 之前（地址合法性要用 csr_wr），这里只留写使能位图与读选择。
    logic [15:0] csr_onehot;  // csr_addr 的独热译码（位映射与 csr_wen 完全一致）
    logic [15:0] csr_wr_mask;
    // ★ 不变量：csrs_rd 必须**显式声明成 32 位**。漏写声明时 Verilog 会按隐式 1 位 wire
    //   处理（iverilog/Vivado 只在 -Wall 下提醒），于是 `rd_value_next = csrs_rd` 只拿到
    //   CSR 读值的 bit0，读 mepc/mcause 恒为 0 且**没有任何报错**。v10.2 第一次改这个
    //   文件时就踩到了：tb_exc 里 `csrrs x21, mepc` 读回 0，handler 于是把 mepc 写成 4。
    logic [31:0] csrs_rd;     // 前递后的 CSR 读值（= CSRR* 的 rd）

    // csr_addr 的独热译码。位号 = `CSRW_*：0 mepc / 1 mcause / 2 mstatus / 3 mtvec /
    //   4 mie / 5 mip / 6 mscratch / 7 mtimecmp / 9 mtval / 10 mtime /
    //   11 mcycle / 12 minstret / 13 mcycleh / 14 minstreth（v12（B）Zicntr）。
    // ★ 不变量：bit8 必须**恒为 0**。bit8 是 `CSRW_OP 标记（由 csr_wen_next 单独置位），
    //   不是"某个 CSR 被选中"；一旦让它进这张表，csr_sel 就会带着 bit8 去和
    //   csrwen_now/sh 做与，命中判据被污染（每条 CSR 指令都会"命中"前一条）。
    // ★ v10.3 新增 bit9/bit10：mtval 与 mtime 变成可写之后，它们必须同时出现在
    //   写使能位图（写）与这张读选择位图（读前递）里，否则 `csrw mtval,x1` 紧跟
    //   `csrr x2,mtval` 会读到旧值 —— 与 v10.2 修的 mscratch 是同一个坑。
    // ★ v12（B）新增 bit11~bit14，同样的道理：`csrw mcycle, x1` 紧跟 `csrr x2, mcycle`
    //   必须读到 x1（前递），否则读到的是旧计数 —— 而计数器每拍都在变，"旧值"连
    //   "差几拍"都算不出来。注意 64 位计数器拆成两个地址，所以是 4 个位而不是 2 个。
    // ★★ 不变量：**别名地址必须映射到同一个位**（`cycle`→bit11 与 `mcycle` 同位，
    //   `instret`→bit12 与 `minstret` 同位，两个高半同理；`time`→bit10 与 `mtime` 同位）。
    //   为什么：影子里存的是"某个计数值"，前递是按位与非零判命中的。若别名不给位，
    //   `csrw mcycle,0` 紧跟 `csrr x,cycle` 会**绕过前递去读寄存器**，而寄存器的写要到
    //   WB 才落盘（ID→WB 有 5 拍）—— 读到的是**复位前的旧计数**。
    //   实测（sys_zicntr）：x11 期望 0，实际 0x29（= 41，恰好是清零前一刻的拍数）。
    //   ★ 给别名位**不会**让"写只读影子"变得合法：`csrw cycle,x1` 在 IDU 就被 csr_illegal
    //     判成非法指令，csr_wen_next 被 no_side_effect 整体清 0，根本到不了写口。
    assign csr_onehot = {
        1'b0,                                                          // bit15：未使用，必须显式写 0
        ((csr_addr == `CSR_minstreth) | (csr_addr == `CSR_instreth)),  // bit14
        ((csr_addr == `CSR_mcycleh)   | (csr_addr == `CSR_cycleh)),    // bit13
        ((csr_addr == `CSR_minstret)  | (csr_addr == `CSR_instret)),   // bit12
        ((csr_addr == `CSR_mcycle)    | (csr_addr == `CSR_cycle)),     // bit11
        ((csr_addr == `CSR_mtime)     | (csr_addr == `CSR_time)),      // bit10
        (csr_addr == `CSR_mtval),        // bit9
        1'b0,                            // bit8：`CSRW_OP 标记位，见上面不变量
        (csr_addr == `CSR_mtimecmp),     // bit7
        (csr_addr == `CSR_mscratch),     // bit6
        (csr_addr == `CSR_mip),          // bit5
        (csr_addr == `CSR_mie),          // bit4
        (csr_addr == `CSR_mtvec),        // bit3
        (csr_addr == `CSR_mstatus),      // bit2
        (csr_addr == `CSR_mcause),       // bit1
        (csr_addr == `CSR_mepc)          // bit0
    };
    // ★ 不变量：这个拼接**必须正好 16 个元素**。少一个（v12（B）第一次就是 15 个，
    //   顶部少了 1'b0）功能上靠零扩展侥幸没错 —— bit15 本来就恒 0 —— 但 Verilator
    //   会报 WIDTHEXPAND（"REPLICATE generates 15 bits"），而且下一个想改位图的人
    //   会因为"注释里的位号和实际长度对不上"而改错位置。
    assign csr_wr_mask = csr_wr ? csr_onehot : 16'b0;

    // CSR 写使能位图（位号见 para.sv `CSRW_*）：bit0 mepc / bit1 mcause / bit2 mstatus / bit3 mtvec
    //   （低 4 位兼容 v8）/ bit4 mie / bit5 mip / bit6 mscratch / bit7 mtimecmp
    //   / bit9 mtval / bit10 mtime（v10.3 新增，特权规范把它们列为可写），每位都带 is_SYS 门控。
    //   bit8 = `CSRW_OP：v10.2 新增的"这是 CSR 指令"标记（读也置位），把"是 CSR 指令"与
    //   "要不要写寄存器"解耦 —— 下游（WBU 的 rd 选择、两级前递）一直用 `|csr_wen` 判前者。
    //   ★ 不变量：整张位图必须与 no_side_effect 相与（非法指令/非对齐访存不得写任何 CSR）→ §IDU-5
    assign csr_wen_next = no_side_effect
                        ? (csr_wr_mask | (csr_op ? (16'b1 << `CSRW_OP) : 16'b0))
                        : 16'b0;

    // CSR 读口的 RAW 前递（v10.2）：读在 ID 级组合取出、写在 WB 级才落盘，两者天然差三级，
    //   `csrw mscratch, x1` 紧跟 `csrr x2, mscratch` 读到的必然是旧值。CSR 写事件本来就有
    //   一条 4 深影子链（v10 的 C10，为 mret 读 mepc 而建），这里把它复用成**通用**前递：
    //   把"本拍要读哪个 CSR"的独热码送给 Control，由它返回最新一次在途写的值。
    // ★ 不变量：csr_sel 不许乘 no_side_effect（它只表示"读哪个"，与合不合法无关），
    //   也不许带上 bit8 标记位（否则前递命中判据被污染）。
    assign csr_sel = is_SYS ? csr_onehot : 16'b0;
    assign csrs_rd = csr_rd_fwd_en ? csr_rd_fwd : csrs;

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

    // rd_value_next：无需再经 ALU/访存加工即可写回的结果（跳转类返回 snpc，系统指令返回
    //   **前递后**的 CSR 读值 —— 用 csrs 原值会在 csrw/csrr 紧邻时读旧值）。
    assign rd_value_next               = jump_flag ? snpc_d :
                                         is_SYS ? csrs_rd :
                                         0;
    assign branch_pc                   = pc_d + imm;
    assign pc_out  = pc_d;

    logic [31:0] add_src1;
    logic [31:0] add_src2;

    // add_src1/add_src2 把不同指令族统一映射为 ALU 双输入，便于执行级只关心运算而不再关心指令格式。
    //   ★ v10.2 CSR 三档（funct3[1:0]）：
    //     01 CSRRW/CSRRWI : src1 = rs1 或 uimm，src2 = 0            → 新值 = src1（add）
    //     10 CSRRS/CSRRSI : src1 = rs1 或 uimm，src2 = 旧值         → 新值 = src1 | 旧值（or）
    //     11 CSRRC/CSRRCI : src1 = rs1 或 uimm，src2 = 旧值         → 新值 = 旧值 & ~src1（bitclr）
    //   原来 11 档既没有 opcode 落到了默认的 add、src2 又错取了 `imm`（= CSR 地址本身），
    //   于是 csrrc 写进 CSR 的是 rs1+csr_addr 这种纯垃圾值；立即数形式 101/110/111 更是
    //   直接判非法。src2 取**旧值**（csrs_rd），不是"写数据"。
    assign add_src1 = is_U0 ? 32'd0 :
                      (is_J || is_U1) ? pc_d :
                      csr_imm ? {27'b0, inst_d[19:15]} :
                      EXU_rs1_in;

    assign add_src2 = (is_R || is_B) ? EXU_rs2_in :
                      (csr_op && csr_f3 == 2'b01) ? 32'd0 :
                      csr_op ? csrs_rd : imm;

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
    logic cond_bitclr;       // v10.2：CSRRC/CSRRCI 的"清位"（旧值 & ~rs1）
    logic cond_and;
    logic cond_sll;
    logic cond_srl;
    logic cond_sra;
    logic cond_sub;
    logic cond_equal;
    assign cond_add = is_S || is_I0 || is_U0 || is_U1 || is_J || is_I2
                 || (is_I1 && funct3 == 3'b000)
                 || (is_R  && funct3 == 3'b000 && oprand[5] == 1'b0)
                 || (is_B  && funct3[2:1] == 2'b01)
                 || (csr_op && csr_f3 == 2'b01);      // CSRRW/CSRRWI：新值 = src1 + 0
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
                || (csr_op && csr_f3 == 2'b10);        // CSRRS/CSRRSI：新值 = src1 | 旧值
    assign cond_bitclr = (csr_op && csr_f3 == 2'b11);    // CSRRC/CSRRCI：新值 = 旧值 & ~src1
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
                        cond_bitclr ? `alu_bitclr :
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

// v12（B）：mcycle 是 64 位 CSR，观察口只取低 32 位（50MHz 下 32 位要 85.9s 才回绕，
//   一次 ILA 抓包远到不了）。★ 不变量：这里**只读不写**，别把 mcycle_dbg 接回任何逻辑。
logic [63:0] mcycle_full;
assign mcycle_dbg = mcycle_full[31:0];

// Reg_Stack = 通用寄存器堆 + CSR 的封装（自身无流水寄存器）：读口在本级组合读出 rs1/rs2 与
//   csrs；写口由 WB 级（WBU）驱动，中间隔 EXU/MEM/WB 三级流水原样携带 → 读写口差三级。
Reg_Stack Reg_Stack_inst0(
    .reset (reset),
    .clock (clock),
    .pc (pc_d),
    // ★ v13.2：只把"确实会提交"的那一拍送进 CSR，错路径上的系统指令不再产生副作用。
    //   注意 IDU 自己的 ecall_flag/mret_flag 输出仍是**原始译码**（Control 要用它做
    //   system_redirect 与 intr_safe 判断），这里只门控送给 CSR 的那一份。
    .ecall_flag (ecall_flag & sys_commit_ok),
    .mret_flag (mret_flag & sys_commit_ok),
    .intr_take (intr_take),

    .rs1 (rs1),
    .rs2 (rs2),
    .rd (rd),
    .rd_value (rd_value),

    .csr_addr (csr_addr),
    .R_wen (R_wen),
    .csr_wen (csr_wen),
    .csrd (csrd),

    // v9 新增（C4）：同步异常通道（v10：trap_take_q → fault_pc）
    .trap_take   (trap_take),
    .trap_cause  (trap_cause),
    .fault_addr  (fault_addr),
    .fault_inst  (fault_inst),
    .fault_pc    (fault_pc),
    .retire      (retire),

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
    .mcycle_out (mcycle_full),
    .minstret_out (),
    .intr_pending (intr_pending)
);





endmodule
