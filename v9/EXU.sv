`include "para.sv"

// 执行级把译码得到的操作数和控制信号锁存下来，输出算术结果与分支判定结果。
// 对分支而言，ALU 的最低位就是条件真假；对跳转/CSR 而言，重点是把结果继续送往最终收束点。
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

    // ---- v9 新增（C4）：异常输入 ----
    // 都由 IDU 在同一拍给出（与 IDU_* 控制位同源、同拍到），本模块只做"锁存 + 汇总"。
    //   illegal_in     : 本条指令非法（编码不认识）
    //   mem_misalign_in: load/store 有效地址非对齐（地址已在 IDU 算好）
    input        illegal_in,
    input        mem_misalign_in,
    input [2:0]  mem_misalign_funct3_in,
    // 本拍 ID 级指令的原始编码：非法指令异常要用它写 mtval（出错指令编码）。
    //   注意这里用 **IDU 当前译码的 inst_d**，与 illegal_in 同源同拍。
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

    // ---- v9 上板改造：时序化 MDU 握手（MDU_pipelined.sv）----
    // 接入后乘除法不再用一级组合逻辑算完，而是走 MDU_pipelined：
    //   mul*  ：单拍出结果（busy 恒 0）
    //   div*  ：多拍迭代（busy 期间整机冻结）
    output logic mdu_busy,
    output logic mdu_done,

    // v9 修复（B7）：误预测已确认但还没送达 IFU（被取指侧 hold 挡住）。
    //   这段窗口里本级**不能接收新指令**：否则错路径的那条会赶在重定向补发之前
    //   进入 EX 并被下游采走、提交（实测 rnd034：错路径的 jal 把 x16 写坏）。
    //   注意只挡住"接收"，不挡"清空"：正在 EX 里那条被判错的跳转/分支仍然要在
    //   重定向当拍正常交给 LSU（jal 的 link 写回靠的就是这一拍）。
    input  logic bp_pend,

    // v9 新增（C4）：同步异常被**确认接收**的那一拍（单拍脉冲，来自 Control 的
    //   trap_take）。专门用来清异常标志，**不参与** EXU_inst_clr。
    //   为什么要单独一根线：EXU_inst_clear 在主冲刷（trap_redirect / bp_mispredict /
    //   intr_take）那一拍会把持续拉低本级 valid_next 直到流水排空，如果异常标志也
    //   挂在它上面清，就会出现"标志清不掉、而指令又推不出去"的僵局 ——
    //   实测现象是 EXU 卡在出错指令上、后续指令（包括陷阱处理程序）全部进不去。
    //   异常标志是"跟着这条指令走的一次性状态"，用一次性脉冲清最干净。
    input  logic trap_take,

    // ---- v9 新增（C4）：异常输出（已锁存，与 EX 级当前指令一一对应）----
    // 优先级由 Control 决定：非法指令 > 访存非对齐 > 指令地址非对齐。
    //   iaddr_misalign_exc 用**实际**目标地址判定（branch 用 branch_pc_reg，
    //   jal/jalr 用 EX_result)，不是预测目标。
    output logic illegal_exc,
    output logic mem_misalign_exc,
    output logic [2:0] mem_misalign_funct3_exc,
    output logic iaddr_misalign_exc,
    // v9 新增（C4）：出错指令的原始编码（随流水锁存），供 mtval 使用
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

    // ---- v9 新增（C4）：异常状态寄存器（与 EX 级当前指令一一对应）----
    logic        illegal_reg;
    logic        mem_misalign_reg;
    logic [2:0]  mem_misalign_f3_reg;
    logic        iaddr_misalign_reg;
    logic [31:0] fault_inst_reg;

    // v9 新增（C4）：EX 级"实际跳转/分支目标"的低 2 位。
    //   分支与 jal 在 IDU 里都映射成 add1 + add2（PC + imm）的加法，
    //   jalr 的目标 bit0 被硬件清零、天然对齐，所以这里统一用加法结果判断。
    //   提取成一个具名 wire 是必须的：SystemVerilog/Verilog 不允许对表达式结果
    //   直接做位选（`(a+b)[1:0]` 会报 vlog-13069 syntax error）。
    logic [1:0]  branch_target_low2;
    assign branch_target_low2 = (add1_reg + add2_reg) & 32'h3;

    /* ---------------------------------------------------------------------
     * v9 上板改造：时序化 MDU 的“等结果”握手
     * ---------------------------------------------------------------------
     * MDU_pipelined 的操作数在 T 沿锁存，结果要到 T+1 沿之后才出现在 res 上
     *（比原来的纯组合 MDU 晚一拍；除法还要多等 32 拍迭代）。如果这一拍就放行
     * EXU/LSU，下游会把**还没更新的 EX_result 旧值**当成运算结果采走下去。
     *
     * 用三态显式状态机，避免“用信号自己清自己”造成的死锁：
     *   MDU_IDLE ：没有待处理的 M 指令
     *   MDU_WAIT ：已发射，等 MDU 出结果（冻结 EXU/LSU/前端）
     *   MDU_DONE ：结果窗口，结果稳定；仍然冻结，因为 LSU 要**下一个时钟沿**
     *              才把 EX_result 采走
     *   状态转换：IDLE --mdu_start--> WAIT --mdu_done--> DONE --(一拍)--> IDLE
     *
     * 两个必须避开的死锁（都实测踩到过）：
     *   ① 任何清除/转移条件都不能含 ready_next —— ready_next 由本模块的
     *      mdu_stall 派生，会形成组合环，状态机永远出不来。
     *   ② 不能在结果窗口那一拍就解除冻结：done 只高 1 拍，而 LSU 是在它之后
     *      那一拍才采走 EX_result；早一拍解冻会让同一条指令被重复发射，
     *      结果被覆盖（现象：连乘/连除只有第一条对，后续全 0）。
     * ------------------------------------------------------------------- */
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
    // 触发点必须是**已锁存**的 alu_opcode_reg[4]，不能用输入端口 alu_opcode：
    //   输入端口属于“下一条将要进入 EX 的指令”，而 MDU 的操作数是 add1_reg/
    //   add2_reg。若用输入端口触发，状态机会比操作数早一拍进入 WAIT，
    //   结果 operands 还没锁存、MDU 也没收到 start，done 永远不来 → 死锁
    //   （实测：state 卡在 WAIT、res 恒 0）。
    // v9 修复（B3）：再加一层“这条指令已经发射过”的标志。
    //   原式 `(state==IDLE) & opcode_reg[4]` 会在结果窗口结束、回到 IDLE 的那一拍
    //   **用还没被换掉的旧 M 操作码再发射一次**（操作数寄存器在同一沿已经换成下一
    //   条指令了），于是 MDU 把上一条的运算又算了一遍，结果被当成下一条指令的结果
    //   锁进 mdu_res_reg —— 实测 div_pair：`div x4,x2,x2` 期望 1，实际拿到上一条
    //   `div x3,x1,x2` 的 14（错位一条指令，链越长错得越远）。
    assign mdu_start  = (mdu_state == MDU_IDLE) & alu_opcode_reg[4] & ~mdu_issued;
    // v9 修复（B3）：冻结条件改成“EX 级是 M 指令、且**它自己的**结果还没锁存”。
    //   原式只看状态机 WAIT/DONE：结果窗口结束那一拍解冻，而这一拍 EX 已经换成
    //   下一条指令、mdu_res_reg 却还是上一条的结果 → 下游把它采走。
    //   现在只要 EX 里的 M 指令没拿到自己的结果就一直冻结，跨过整个“换指令”的边沿。
    assign mdu_stall  = alu_opcode_reg[4] & ~mdu_res_vld;
    // 下游（LSU）与前端必须和 EXU 用**同一口径**冻结：EXU 在等 MDU 结果时，
    //   LSU 也要停，否则它会在“EX 已换指令、结果还是旧的”那一拍把旧结果采走。
    assign mdu_busy   = mdu_stall;


    // valid_next 体现执行级是否向后级真正送出一条有效指令；
    // 若收到 EXU_inst_clr，则说明该条指令因重定向/停顿需要被清空。
    // mdu_stall 期间必须**冻结 valid**，否则会在结果还没回来时就把这条 M 指令
    // 放行下去（现象：debug_wb_pc 对、debug_wb_value 错或为 0）。
    // v9 上板改造修正：**下游没准备好时也必须冻结 valid**（~ready_next）。
    //   上板改造把访存/取指换成同步 BRAM 后多了 mem_hold，LSU 会被整条冻结，
    //   此时 ready_next(=LSU_ready) 为 0。原来这一拍会走到最后一个 else，
    //   把 valid_next 清 0 —— 但本级的**数据/控制寄存器是冻结保持的**
    //   （它们只在 valid_last & ready_next 时更新），于是出现“payload 还在、
    //   valid 已经掉了”的错配：这条指令随后被 LSU 收下时 valid=0，
    //   写回被 WBU 的 R_wen & valid 掐掉 —— 实测 lw 后面紧跟的 add 就是这样
    //   算出正确结果 0x11 却写不回 x7（x7 恒为 0）。
    //   冻结后行为与数据寄存器一致：hold 结束的这一拍 valid 仍为 1，下游正常收下。
    always_ff @(posedge clock) begin
        if(reset)
            valid_next <= 1'b0;
        else if(mdu_stall | ~ready_next)
            valid_next <= valid_next;           // 冻住（MDU 忙 / 下游未就绪）
        else if(ready_last & valid_last & EXU_inst_clr )
            valid_next <= 1'b0;
        else if(ready_last & valid_last)
            valid_next <= 1'b1;
        else
            valid_next <= 1'b0;
    end

    // MDU 结果总线：**必须先声明**再用。否则按 Verilog 隐式网络规则，
    //   第 206 行的 mdu_res 会被当成 1 位隐式 wire（ModelSim vlog-2730 直接硬报错，
    //   iverilog 宽容通过但语义不可移植）——乘除法结果会整体失真。
    logic [31:0] mdu_res;

    // MDU 状态机（v9 修复 B3 后简化为 IDLE/WAIT 两态）：
    //   IDLE --start--> WAIT --done--> IDLE
    //   “结果窗口再多停一拍”的职责已经由 mdu_stall = opc[4] & ~mdu_res_vld 承担，
    //   不再需要第三个状态（原来 WAIT→DONE→IDLE 的 DONE 拍正是错位的来源）。
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

            // 每条 M 指令只发射一次：发射后置位，直到这条指令离开 EX 才清。
            if (mdu_start) mdu_issued <= 1'b1;

            // 在结果窗口把 MDU 结果**锁存**下来。
            //   为什么要锁：MDU_pipelined 的 res 在结果窗口之后就不再保持
            //   （mul 会被下一次 start 清 mul_stb、div 的 div_hold 也会撤销）。
            if (mdu_done_i) begin
                mdu_res_reg <= mdu_res;
                mdu_res_vld <= 1'b1;
            end

            // 这条指令被下一级收下（离开 EX）时，发射/结果标志一起清，
            // 供**下一条** M 指令重新走一遍握手。
            //   与上面的分支互斥：mdu_done_i 那一拍 mdu_stall=1（结果还没置位），
            //   而这里要求 ~mdu_stall。
            if (valid_last & ready_next & ~mdu_stall) begin
                mdu_issued  <= 1'b0;
                mdu_res_vld <= 1'b0;
            end
        end
    end

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
        else if(valid_last & ready_next & ~mdu_stall & ~bp_pend)
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

// 这组控制寄存器与数据寄存器分开写，便于清楚观察“数据本身”和“是否允许副作用”两类信息。
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
    else if(valid_last & ready_next & ~mdu_stall & ~bp_pend) begin
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

// ---------------------------------------------------------------------------
// v9 修复（C4）：异常标志的清除必须**独立于流水线握手**，单独一个 always_ff。
//
//   踩到的坑（实测把 PC 锁在 mtvec 上）：异常标志原来跟其他控制寄存器写在同一个
//   always_ff 里，清除分支的条件是 `valid_last & ready_next & EXU_inst_clr`。
//   trap 那一拍之后：本级 valid_next 被清 0 → 下游 LSU 的 valid_reg=0 →
//   LSU_ready=0 → ready_next=0，于是"清除分支"永远不成立，而记录分支又要求
//   `valid_last & ~mdu_stall & ~bp_pend`（此时 valid_last 也已经是 0）——
//   异常标志**卡死在 1**：`exc_pending` 每拍都成立，trap_take/trap_redirect
//   每拍都发，PC 被反复重定向回 mtvec，陷入处理程序的第一条都跑不完。
//
//   修法：异常标志是"跟着指令走的一次性状态"，指令一旦被作废（EXU_inst_clr）
//   就必须立刻清掉，不需要等任何握手；其余情况正常跟随输入锁存。
//   清零优先于锁存，且两者互斥，不会出现多驱动。
// ---------------------------------------------------------------------------
always_ff @(posedge clock) begin
    if (reset | trap_take) begin
        illegal_reg         <= 1'b0;
        mem_misalign_reg    <= 1'b0;
        mem_misalign_f3_reg <= 3'b0;
        iaddr_misalign_reg  <= 1'b0;
        fault_inst_reg      <= 32'b0;
    end else if (valid_last & ready_next & ~mdu_stall & ~bp_pend) begin
        illegal_reg         <= illegal_in;
        mem_misalign_reg    <= mem_misalign_in;
        mem_misalign_f3_reg <= mem_misalign_funct3_in;
        fault_inst_reg      <= fault_inst_in;
        // 指令地址非对齐：**实际**目标地址必须 2 字节对齐（基础指令集要求）。
        //   分支：实际目标是 branch_pc = PC + imm_B
        //   jal ：实际目标是 PC + imm_J
        //   jalr：实际目标是 (rs1 + imm) 且 bit0 被硬件清零，天然对齐，不会触发
        // 判据只看"低 2 位是否为 0"，两种情况可以用同一个加法表示 ——
        // 分支与 jal 在 IDU 里都被映射成 add1/add2 的加法（PC + imm），所以直接
        // 用**已锁存**的 add1_reg/add2_reg 算，不引用下面后置声明的 exec_res。
        // 门控用已锁存的 branch_flag_reg/jump_flag_reg，属于 EX 级寄存器边界
        // 之后，不给跨级关键路径添负担。
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
    // 对分支比较类指令，inv_flag_reg 用来统一处理取反条件，
    // 这样 Control 只需读取 EX_result[0] 就能判断是否跳转。
    // alu_opcode_reg[4]=1 表示这是 RV32M 乘除法，改由 MDU 产生结果。
    assign exec_res                    = alu_opcode_reg[4] ? mdu_res_reg : alu_res;
    assign EX_result                   = {exec_res[31:1], exec_res[0] ^ inv_flag_reg};
    assign rs2_value_next              = rs2_value_reg;
    assign branch_flag_next            = branch_flag_reg;
    assign pred_taken_next             = pred_taken_reg;
    assign pred_target_next            = pred_target_reg;
    assign pred_index_next             = pred_index_reg;
    // mdu_stall 期间把下级 ready 拉低，配合 LSU 的同步冻结，
    // 避免把 EXU 保持的陈旧值一级级推下去。
    assign ready_last                  = ready_next & ~mdu_stall;
    assign fetch_i_flag_next           = fetch_i_reg;
    assign branch_pc_next              = branch_pc_reg;

    // v9 新增（C4）：异常输出（已锁存，与 EX 级当前指令一一对应）。
    //   **必须与 valid_next 相与**：只要出现过一次"指令不在 EX 里、但异常位还留着"
    //   的窗口，下游就会在流水线空转期间反复看到 exc_pending，把 PC 反复重定向，
    //   整机锁死。实测就是这么锁死的：非法指令本身正确陷入了
    //   （mcause=2 / mepc=0x20），但异常标志"粘"在 EXU 上，
    //   陷阱处理程序的第一条永远进不去 —— 加这一层后解掉。
    assign illegal_exc              = illegal_reg        & valid_next;
    assign mem_misalign_exc         = mem_misalign_reg   & valid_next;
    assign mem_misalign_funct3_exc  = mem_misalign_f3_reg;
    assign iaddr_misalign_exc       = iaddr_misalign_reg & valid_next;
    assign fault_inst_exc           = fault_inst_reg;


/* verilator lint_off PINMISSING */
// ALU 是执行级核心算子，既负责普通算术逻辑，也负责分支比较。
ALU #(
    .BW(32) 
) ALU_i0 (
    .d1(add1_reg),
    .d2(add2_reg),
    .choice(alu_opcode_reg),
    .res(alu_res) 
);

// MDU 与 ALU 并行工作，仅当编码最高位为 1（RV32M）时其输出被选中。
// v9 上板改造：换成**时序化**的 MDU_pipelined（experimental/MDU_pipelined.sv）。
//   原 MDU.sv 把「3 个 32x32 乘法器 + 32 级恢复余数除法链」全塞进 EX 一级
//   组合逻辑，是整机最长组合路径，FPGA 上很难收敛（综合报告：2150 LC / 419 CARRY4）。
//   时序化后：乘法单拍、除法 32 拍迭代，规模降到约 1/5。
//   操作数用已锁存的 add1_reg/add2_reg（不能用端口 add1/add2，它们会随流水线变），
//   与 MDU_pipelined 头部说明的“必须用锁存值”一致。
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
