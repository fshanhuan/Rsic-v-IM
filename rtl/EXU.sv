`include "para.sv"

/* =============================================================================
 * EXU.sv — 执行级（EX）：锁存操作数/控制位，算结果、判分支、汇总异常标志
 * -----------------------------------------------------------------------------
 * IDU → **EXU** → LSU / WBU / Control。分支看 ALU 结果最低位；跳转/CSR 把结果继续送往最终
 * 收束点；乘除法交给 MDU_pipelined（单拍乘、多拍除），本级只做多拍握手与结果锁存。
 * ★ 接口契约：数据/控制寄存器只在 `valid_last & ready_next & ~mdu_stall & ~bp_pend` 这拍
 *   更新，valid_next 必须与它们**同一口径冻结**；异常输出一律 `<标志>_reg & valid_next`；
 *   mdu_stall 期间本级与前端/LSU 必须同一口径冻结。
 * ★ 不许改回去（细节与实测证据见 syn/修复史_全量.md）：异常标志清除独立于握手(§EXU-1)、
 *   bp_pend 只挡接收(§EXU-2)、mdu_issued 与 mdu_res_vld 防重复发射/早解冻(§EXU-3)、
 *   mdu_res 先声明(§EXU-4)、~ready_next 也冻结 valid_next(§EXU-5)
 * ============================================================================= */
module EXU (
    input clock,
    input reset,

    input EXU_inst_clr,
    input [15:0] csr_wen,
    input R_wen,
    input mem_wen,
    input mem_ren,
    input [4:0] rd,
    input [2:0] funct3,
    input [31:0] pc,

    input [4:0] alu_opcode,
    input inv_flag,
    input jump_flag,
    input branch_flag,
    input fetch_i_flag,

    input [31:0] branch_pc,
    input [31:0] rs2_value,
    input [31:0] add1,
    input [31:0] add2,
    input [31:0] rd_value,
    input        pred_taken_in,
    input [31:0] pred_target_in,
    input [`BP_INDEX_BITS-1:0] pred_index_in,

    // ---- 异常输入（v9 新增 C4）：全由 IDU 与 IDU_* 控制位**同源同拍**给出，本级只做"锁存 + 汇总"
    //      （定优先级是 Control 的事）：illegal_in=编码不认识，mem_misalign_in=访存有效地址非对齐 ----
    input        illegal_in,
    input        mem_misalign_in,
    input [2:0]  mem_misalign_funct3_in,
    // fault_inst_in：本拍 ID 级指令的原始编码（= IDU 当前译码的 inst_d），非法指令用它写 mtval，
    //   **必须与 illegal_in 同源同拍** —— 接错就会把别的指令写进 mtval，异常现场反而误导人。
    input [31:0] fault_inst_in,

    output [31:0] branch_pc_next,
    output [31:0] rd_value_next,
    output fetch_i_flag_next,
    output branch_flag_next,
    output jump_flag_next,
    output [2:0] funct3_next,
    output [31:0] rs2_value_next,
    output [4:0] rd_next,
    output [15:0] csr_wen_next,
    output R_wen_next,
    output mem_wen_next,
    output mem_ren_next,
    output [31:0] EX_result,
    output logic [31:0] pc_out,
    output        pred_taken_next,
    output [31:0] pred_target_next,
    output [`BP_INDEX_BITS-1:0] pred_index_next,

    input valid_last,
    output ready_last,


    input ready_next,
    output logic valid_next,

    // ---- 时序化 MDU 握手（v9 上板改造，实现见 MDU_pipelined.sv）：mul* 单拍出结果（busy 恒 0），
    //      div* 多拍迭代（busy 期间整机冻结）；mdu_busy 同时送给前端与 LSU ----
    output logic mdu_busy,
    output logic mdu_done,

    // ★ 不变量（v9 修复 B7）：bp_pend（误预测已确认、重定向还没送达 IFU）期间只挡"接收"，
    //   **不挡清空/放行** —— 被判错那条仍要在重定向当拍正常交给 LSU（jal 的 link 写回靠这拍）。
    //   原因：收下新指令会让错路径那条赶在补发之前进 EX 并被提交。实测证据见 §EXU-2
    input  logic bp_pend,

    // H1（v9 修复）：上游 IDU 当前处于**冻结（hold）**状态。IFU_stall（= load-use | MDU 忙 |
    //   icache_hold | dcache_hold）期间 IDU 保持它送出的 valid/inst 不变，而本级的 ready_last
    //   只含 `ready_next & ~mdu_stall`、**不含** IFU_stall —— 于是同一条指令被连续接收两拍、
    //   交给 LSU 两次，官方差分第一条 addi 就 desync（实测）。
    // ★ 不变量：接收门控必须用这根独立的 up_stall，**不许**改成把 stall 并进 ready_last 或
    //   valid_last：并进 ready_last 会连"放行"一起掐掉（被 bp_pend 挡下的那条仍要在当拍交给
    //   LSU，jal 的 link 写回靠这拍，见 §EXU-2）；并进 valid_last 会破坏 EXU_inst_clr 的清空
    //   路径、留下陈旧控制寄存器（实测只有 40/47）。
    //   实测证据与踩坑史：见 syn/修复史_全量.md §EXU-11
    input  logic up_stall,

    // 异常被**确认接收**那一拍的单拍脉冲（v9 新增 C4，来自 Control 的 trap_take）。
    // ★ 不变量：异常标志只能用这根线（+ reset）清，**不参与** EXU_inst_clr —— 后者在主冲刷那拍
    //   会持续拉低 valid_next 直到排空，挂上去就成了"清不掉又推不出"的僵局。详见 §EXU-1
    input  logic trap_take,

    // ---- 异常输出（v9 新增 C4，已锁存，与 EX 级当前指令一一对应）：优先级由 Control 的
    //      trap_cause 决定（指令地址非对齐 > 非法指令 > 访存非对齐）；iaddr 判**实际**目标 ----
    output logic illegal_exc,
    output logic mem_misalign_exc,
    output logic [2:0] mem_misalign_funct3_exc,
    output logic iaddr_misalign_exc,
    // 出错指令的原始编码（随流水锁存），送去 Control 写 mtval（见文件末尾 assign 处的说明）
    output logic [31:0] fault_inst_exc
);



    logic [31: 0] branch_pc_reg;
    logic [15: 0] csr_wen_reg;
    logic R_wen_reg;
    logic mem_wen_reg;
    logic mem_ren_reg;
    logic [4: 0] rd_reg;
    logic [2: 0] funct3_reg;


    logic [4: 0] alu_opcode_reg;
    logic inv_flag_reg;
    logic jump_flag_reg;
    logic branch_flag_reg;
    logic pred_taken_reg;
    logic [31:0] pred_target_reg;
    logic [`BP_INDEX_BITS-1:0] pred_index_reg;

    logic [31: 0] rs2_value_reg;

    logic [31: 0] add1_reg;
    logic [31: 0] add2_reg;

    logic [31: 0] rd_value_reg;
    logic fetch_i_reg;

    // ---- 异常状态寄存器（v9 新增 C4）：与 EX 级当前指令一一对应 ----
    //   illegal/mem_misalign/mem_misalign_f3/fault_inst **必须在同一个 always_ff、同一拍锁存**
    //   （源是同拍的 illegal_in/mem_misalign_in/funct3_in/fault_inst_in）：拆开就会出现"非法指令
    //   没带 mtval"或"funct3 属于上一条指令"，Control 编出的 mcause/mtval 与出错指令对不上。
    logic        illegal_reg;
    logic        mem_misalign_reg;
    logic [2:0]  mem_misalign_f3_reg;
    logic        iaddr_misalign_reg;
    logic [31:0] fault_inst_reg;

    // EX 级**实际**跳转/分支目标的低 2 位：branch/jal 在 IDU 里都映射成 add1+add2（PC+imm），
    //   jalr 的目标 bit0 被硬件清零。**必须具名**：SV 不允许对表达式结果直接位选 `(a+b)[1:0]`
    logic [1:0]  branch_target_low2;
    assign branch_target_low2 = (add1_reg + add2_reg) & 32'h3;

    // —— 时序化 MDU 的“等结果”握手：操作数在 T 沿锁存、结果 T+1 沿之后才上 res（除法还要 32 拍
    //    迭代），这拍若放行，下游会把**还没更新的 EX_result 旧值**当成运算结果采走。
    // ★ 不变量①：清除/转移条件都不能含 ready_next —— 它由本模块 mdu_stall 派生，会成组合环。
    // ★ 不变量②：不能在结果窗口那拍解冻 —— done 只高 1 拍，LSU 是它之后那拍才采走 EX_result，
    //    早一拍解冻会让同一条 M 指令被重复发射、结果被覆盖。实测证据见 §EXU-3
    localparam MDU_IDLE = 2'd0;
    localparam MDU_WAIT = 2'd1;

    logic [1:0] mdu_state;
    logic       mdu_start;      // 本拍送出一条 M 指令
    logic       mdu_stall;      // 冻结条件
    logic       mdu_done_i;     // MDU 结果本拍有效（结果窗口）
    logic [31:0] mdu_res_reg;   // 结果窗口锁存下来的 MDU 结果
    logic       mdu_issued;     // v9 修复（B3）：当前 EX 级这条 M 指令**已经**发给 MDU
    logic       mdu_res_vld;    // v9 修复（B3）：当前 EX 级这条 M 指令的结果已锁存
    logic       mdu_busy_i;     // MDU 自己的 busy（仅用于观察，不再直接驱动互锁）

    assign mdu_done_i = mdu_done;
    // ★ 不变量：触发点用**已锁存**的 alu_opcode_reg[4]，不能用端口 alu_opcode —— 端口属于"下一条
    //   将要进 EX 的指令"，会比操作数（add1_reg/add2_reg）早一拍进 WAIT → done 永不来，死锁(§EXU-6)
    // ★ 不变量（v9 修复 B3）：mdu_start 必须带 ~mdu_issued（"这条已经发射过"）。
    //   原因：只看 (state==IDLE)&opcode_reg[4] 会在回 IDLE 那拍用**还没换掉的旧 M 操作码**再发一次
    //   （操作数寄存器已换成下一条），MDU 把上一条重算一遍、锁成下一条的结果。实测见 §EXU-3
    assign mdu_start  = (mdu_state == MDU_IDLE) & alu_opcode_reg[4] & ~mdu_issued;
    // ★ 不变量（v9 修复 B3）：冻结只看 `alu_opcode_reg[4] & ~mdu_res_vld`，**不许**改回看状态机
    //   WAIT/DONE —— 那样结果窗口结束那拍就解冻，而 EX 已换指令、mdu_res_reg 还是上一条的结果。
    assign mdu_stall  = alu_opcode_reg[4] & ~mdu_res_vld;
    // mdu_busy 的口径就是 mdu_stall：下游（LSU 的 lsu_freeze）与前端（Control 的 IFU_stall）必须一起停
    assign mdu_busy   = mdu_stall;


    // valid_next = 本级向后级送出一条有效指令。
    // ★ 不变量：它必须与数据/控制寄存器**同一口径冻结** —— mdu_stall 与 ~ready_next 两个条件下
    //   都不许清 0。① mdu_stall：否则结果没回来就把 M 指令放行（wb_value 错或为 0）。
    //   ② 上板改造修正：同步 BRAM 多了 mem_hold、LSU 整条冻结时 ready_next=0；原来这拍会走到最后
    //   一个 else 清 valid，而 payload 是冻结保持的 → 指令被 LSU 收下时 valid=0、写回被 WBU 的
    //   R_wen & valid 掐掉。实测 lw 后紧跟的 add 写不回 x7（§EXU-5）
    always_ff @(posedge clock) begin
        if(reset)
            valid_next <= 1'b0;
        else if(mdu_stall | ~ready_next)
            valid_next <= valid_next;           // 冻住（MDU 忙 / 下游未就绪）
        else if(ready_last & valid_last & EXU_inst_clr )
            valid_next <= 1'b0;
        // H1：能走到这里说明 ready_next=1（下游本拍就会把手上这条收走），所以 up_stall 期间把
        //   valid_next 置 0 是"已交付 + 本拍不收新的"，**不是**丢指令 —— 真正"下游收不走"的情况
        //   已经在上面那条 ~ready_next 分支里冻住了。
        else if(ready_last & valid_last & ~up_stall)
            valid_next <= 1'b1;
        else
            valid_next <= 1'b0;
    end

    // MDU 结果总线。★ 不变量：**必须先声明**再用 —— 否则按 Verilog 隐式网络规则被当成 1 位隐式
    //   wire（ModelSim vlog-2730 硬报错；iverilog 宽容通过但语义不可移植），乘除结果整体失真
    logic [31:0] mdu_res;

    // —— EX 级 MDU 握手状态（本级私有：这条 M 指令发没发、结果锁没锁；两态，见 §EXU-3）——
    always_ff @(posedge clock) begin
        if(reset) begin
            mdu_state   <= MDU_IDLE;
            mdu_res_reg <= 32'b0;
            mdu_issued  <= 1'b0;
            mdu_res_vld <= 1'b0;
        end else begin
            case (mdu_state)
                MDU_IDLE: if (mdu_start)  mdu_state <= MDU_WAIT;
                MDU_WAIT: if (mdu_done_i) mdu_state <= MDU_IDLE;
                default:                  mdu_state <= MDU_IDLE;
            endcase

            // 每条 M 指令只发射一次：发射后置位，直到这条指令离开 EX 才清（B3）
            if (mdu_start) mdu_issued <= 1'b1;

            // 在结果窗口把 MDU 结果**锁存**：res 只在 done 那拍有效、之后不再保持（mul 会被下一次
            //   start 清 mul_stb，div 的 div_hold 也会撤销）。
            if (mdu_done_i) begin
                mdu_res_reg <= mdu_res;
                mdu_res_vld <= 1'b1;
            end

            // 离开 EX（被下一级收下）时清发射/结果标志，供**下一条** M 指令重走握手。
            // ★ 必须带 ~mdu_stall，与上面的结果窗口互斥：done 那拍 mdu_stall 仍为 1。
            if (valid_last & ready_next & ~mdu_stall) begin
                mdu_issued  <= 1'b0;
                mdu_res_vld <= 1'b0;
            end
        end
    end

    // —— EX 级数据寄存器（funct3/rd/opcode/rs2/add1/add2/rd_value/branch_pc/pc_out）：只在"被下一级收下"那拍更新，冻结条件与 valid_next 同口径 ——
    always_ff @(posedge clock) begin
        if(reset)begin
            funct3_reg      <= 0;
            rd_reg          <= 0;
            alu_opcode_reg  <= 0;
            inv_flag_reg    <= 0;
            rs2_value_reg   <= 0;
            add1_reg        <= 0;
            add2_reg        <= 0;
            rd_value_reg    <= 0;
            branch_pc_reg   <= 0;
            pc_out <= 0;
        end
        else if(valid_last & ready_next & ~mdu_stall & ~bp_pend & ~up_stall)
        begin
            funct3_reg      <= funct3       ;
            rd_reg          <= rd;
            alu_opcode_reg  <= alu_opcode   ;
            inv_flag_reg    <= inv_flag     ;
            rs2_value_reg   <= rs2_value;
            add1_reg        <= add1     ;
            add2_reg        <= add2     ;
            rd_value_reg    <= rd_value     ;
            branch_pc_reg   <= branch_pc;
            pc_out <= pc;
        end
    end

// —— EX 级"是否允许产生副作用"类控制寄存器：与数据寄存器分开写；if/else 链的**顺序就是优先级**
//    （EXU_inst_clr 清空 > 正常锁存 > 保持），换序会让被冲刷的指令把副作用位写下去 ——
always_ff @(posedge clock) begin
    if(reset)begin
        mem_ren_reg     <= 0;
        csr_wen_reg     <= 0;
        R_wen_reg       <= 0;
        mem_wen_reg     <= 0;
        jump_flag_reg   <= 0;
        branch_flag_reg <= 0;
        fetch_i_reg <= 0;
        pred_taken_reg  <= 0;
        pred_target_reg <= 0;
        pred_index_reg  <= {`BP_INDEX_BITS{1'b0}};
    end
    else if(valid_last & ready_next & EXU_inst_clr & ~mdu_stall)begin
        mem_ren_reg     <= 0;
        csr_wen_reg     <= 0;
        R_wen_reg       <= 0;
        mem_wen_reg     <= 0;
        jump_flag_reg   <= 0;
        branch_flag_reg <= 0;
        fetch_i_reg <= 0;
        pred_taken_reg  <= 0;
        pred_target_reg <= 0;
        pred_index_reg  <= {`BP_INDEX_BITS{1'b0}};
    end
    else if(valid_last & ready_next & ~mdu_stall & ~bp_pend & ~up_stall) begin
        mem_ren_reg     <= mem_ren;
        csr_wen_reg     <= csr_wen;
        R_wen_reg       <= R_wen;
        mem_wen_reg     <= mem_wen;
        jump_flag_reg   <= jump_flag;
        branch_flag_reg <= branch_flag;
        fetch_i_reg     <= fetch_i_flag;
        pred_taken_reg  <= pred_taken_in;
        pred_target_reg <= pred_target_in;
        pred_index_reg  <= pred_index_in;
    end
end

// ★ 不变量（v9 修复 C4）：这组异常标志只能由 reset 与 trap_take 单拍脉冲清，**不能**改回挂在
//   `valid_last & ready_next & EXU_inst_clr` 这类握手条件上。
//   原因：trap 那拍之后本级 valid_next 被清 0 → 下游 valid_reg=0 → LSU_ready=0 → ready_next=0，
//   清除分支永不成立，记录分支又要求 valid_last（此时也是 0）—— 标志**卡死在 1**：exc_pending
//   每拍成立、trap_take/trap_redirect 每拍都发，PC 被反复重定向回 mtvec，处理程序第一条都跑不完。
//   异常标志是"跟着指令走的一次性状态"，指令被作废就要立刻清、不等任何握手；清零优先于锁存。
//   踩坑史 + 实测现象：见 syn/修复史_全量.md §EXU-1
// —— EX 级异常标志寄存器（与当前指令一一对应的"一次性"状态）——
always_ff @(posedge clock) begin
    if (reset | trap_take) begin
        illegal_reg         <= 1'b0;
        mem_misalign_reg    <= 1'b0;
        mem_misalign_f3_reg <= 3'b0;
        iaddr_misalign_reg  <= 1'b0;
        fault_inst_reg      <= 32'b0;
    end else if (valid_last & ready_next & ~mdu_stall & ~bp_pend & ~up_stall) begin
        illegal_reg         <= illegal_in;
        mem_misalign_reg    <= mem_misalign_in;
        mem_misalign_f3_reg <= mem_misalign_funct3_in;
        fault_inst_reg      <= fault_inst_in;
        // 指令地址非对齐：**实际**目标要 2 字节对齐 —— branch=PC+imm_B、jal=PC+imm_J、jalr 的 bit0
        //   被硬件清零天然对齐，所以统一判 branch_target_low2。
        // ★ 不变量：判据只用**已锁存**的 add1_reg/add2_reg/branch_flag_reg/jump_flag_reg，**不许**
        //   改用组合的 exec_res（掺了 inv_flag/MDU 选择，且是后置声明）—— 给跨级关键路径减负。
        iaddr_misalign_reg  <= ((branch_flag_reg | jump_flag_reg)
                                & (branch_target_low2 != 2'b00));
    end
end


    logic [31:0] alu_res;
    logic [31:0] exec_res;
    

    assign jump_flag_next              = jump_flag_reg;
    assign funct3_next                 = funct3_reg;
    assign rd_next                     = rd_reg;
    assign rd_value_next               = rd_value_reg;
    assign csr_wen_next                = csr_wen_reg;
    assign R_wen_next                  = R_wen_reg;
    assign mem_wen_next                = mem_wen_reg;
    assign mem_ren_next                = mem_ren_reg;
    // inv_flag_reg 统一处理分支取反，Control 只需读 EX_result[0] 就能判跳转。
    // alu_opcode_reg[4]=1 表示 RV32M 乘除法，结果改由 MDU 产生。
    assign exec_res                    = alu_opcode_reg[4] ? mdu_res_reg : alu_res;
    assign EX_result                   = {exec_res[31:1], exec_res[0] ^ inv_flag_reg};
    assign rs2_value_next              = rs2_value_reg;
    assign branch_flag_next            = branch_flag_reg;
    assign pred_taken_next             = pred_taken_reg;
    assign pred_target_next            = pred_target_reg;
    assign pred_index_next             = pred_index_reg;
    // ★ ready_last = ready_next & ~mdu_stall：mdu_stall 期间把"上一级可推进"拉低，配合 LSU 的同步冻结，避免把陈旧值一级级推下去
    assign ready_last                  = ready_next & ~mdu_stall;
    assign fetch_i_flag_next           = fetch_i_reg;
    assign branch_pc_next              = branch_pc_reg;

    // 异常输出的最终门控（v9 新增 C4）。
    // ★ 不变量：三个标志**必须与 valid_next 相与**，别嫌冗余去掉 —— 只要出现一次"指令不在 EX 里、
    //   异常位还留着"的窗口，下游就会在空转期间反复看到 exc_pending、把 PC 反复重定向、整机锁死。
    //   Control 的 `exc_pending = exc_any & EXU_valid` 是第二道同口径兜底；fault_inst_exc 不门控
    //   （纯数据，Control 在 exc_pending 那拍采它写 mtval）。实测证据见 §EXU-7
    assign illegal_exc              = illegal_reg        & valid_next;
    assign mem_misalign_exc         = mem_misalign_reg   & valid_next;
    assign mem_misalign_funct3_exc  = mem_misalign_f3_reg;
    assign iaddr_misalign_exc       = iaddr_misalign_reg & valid_next;
    assign fault_inst_exc           = fault_inst_reg;


/* verilator lint_off PINMISSING */
// ALU 是执行级核心算子：算术逻辑与分支比较都走它（比较结果就是低位的条件真假）。
ALU #(
    .BW(32) 
) ALU_i0 (
    .d1(add1_reg),
    .d2(add2_reg),
    .choice(alu_opcode_reg),
    .res(alu_res) 
);

// MDU 与 ALU 并行，仅当 alu_opcode_reg[4]=1（RV32M）时它的结果被选中（见上面 exec_res 的三目选择）。
// v9 上板改造：换成**时序化**的 MDU_pipelined —— 原 MDU.sv 把 3 个 32x32 乘法器 + 32 级恢复余数
//   除法链全塞进 EX 一级组合逻辑，是整机最长组合路径（综合 2150 LC / 419 CARRY4，见 §EXU-8）。
// ★ 不变量：操作数必须用**已锁存**的 add1_reg/add2_reg，不能用端口 add1/add2（会随流水线变）。
MDU_pipelined MDU_i0 (
    .clk   (clock),
    .reset (reset),
    .start (mdu_start),
    .d1    (add1_reg),
    .d2    (add2_reg),
    .op    (alu_opcode_reg),
    .res   (mdu_res),
    .busy  (mdu_busy_i),
    .done  (mdu_done)
);

endmodule
