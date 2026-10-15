/* =============================================================================
 * Control.sv — 全局协同核心：重定向仲裁 / 暂停与清空 / 前递值选择
 * -----------------------------------------------------------------------------
 * 上游：EXU（分支跳转判定、pred_*、同步异常）、IDU、Data_hazard（唯一前递裁决源）；
 * 下游：IFU（dnpc/dnpc_flag、IFU_stall）、IDU（flush=dnpc_flag、前递后的操作数）、
 * EXU、Branch_Predictor、CSR/ICache。没有"本级数据"，状态只有 bp_misp_pend/
 * bp_pend_target、bp_redirect_pending、trap_take_q_r 三个寄存器。
 * v9 修复编号（B4/B5/B6/B7/C2/C4/C6）是对外索引，不可丢；详见 syn/修复史_全量.md
 * ============================================================================= */
`include "para.sv"

module Control #(
    // C4 总开关：1=非法指令/访存非对齐/指令地址非对齐陷入 mtvec 并登记 CSR；0=退回修复前的
    // 控制流（IDU 的"非法指令副作用清零"仍生效）。★ 不变量：必须留这个开关且默认 0。原因：
    // 新异常会改变"哪些指令重定向 PC"，牵动 EXU↔Control 那条很绕的组合链；留开关才能逐项
    // 开启、逐项回归，也能整块关掉量化资源/Fmax 代价。当前 TRAP_ENABLE=1 时 prog_loop 仍复现
    // B4 症状，故交付默认关。实测：syn/修复史_全量.md §CONTROL-16
    parameter TRAP_ENABLE = 0
) (
    input clock,
    input reset,
    input [31:0] mtvec_out,
    input [31:0] mepc_out,
    input [31:0] branch_pc,
    input [31:0] Ex_result,
    // B6：EXU 级前递值。★ 不变量：EXU 级前递必须用 EXU_forward_val —— 对 jump/CSR 写进 rd 的
    //   是 rd_value（jal/jalr 的 link、CSR 读值），而 Ex_result 对 jump 是**目标地址**、对 CSR
    //   是地址，用它会让 `jal x4,0x24c` 后读 x4 拿到 0x24c。§CONTROL-25
    input [31:0] EXU_forward_val,
    input [31:0] EXU_pc,
    input        EXU_pred_taken,
    input [31:0] EXU_pred_target,
    input [31:0] MEM_Ex_result,
    input [31:0] MEM_PIPE_Ex_result,
    input [31:0] MEM2_Ex_result,
    input [31:0] MEM_Rdata,
    input [31:0] IDU_rs1_value,
    input [31:0] IDU_rs2_value,
    input branch_flag,
    input jump_flag,
    input mret_flag,
    input ecall_flag,
    input intr_pending,
    input MEM_mem_ren,
    input MEM_PIPE_mem_ren,
    input fence_i_flag,
    input [4:0] IDU_rs1,
    input [4:0] IDU_rs2,
    input IDU_valid,
    input EXU_valid,
    input MEM_valid,
    input MEM_PIPE_valid,
    input MEM2_valid,
    input [4:0] EXU_rd,
    input [4:0] MEM_rd,
    input [4:0] MEM_PIPE_rd,
    input [4:0] MEM2_rd,
    input EXU_mem_ren,
    input EXU_R_Wen,
    input MEM_R_Wen,
    input MEM_PIPE_R_Wen,
    input MEM2_R_Wen,
    input [31:0] WB_rd_value,
    input [4:0] WB_rd,
    input WB_R_Wen,
    input WB_valid,
    // 存储侧 hold：由 myCPU 把 ICache/DCache 的停拍并进来，Control 只透传 ——
    // 单独引出是为了给 EXU_inst_clear 用（IFU_stall 里还并了 mdu_busy，两者不能混用）
    input mdu_busy,
    input mem_stall,
    // C4：来自 EXU 的同步异常（已锁存，与 EX 级指令一一对应）。判定分别在 IDU 与
    //   EXU 完成，Control 只负责**定优先级、发重定向脉冲、告诉 CSR 写什么 cause/mtval**。
    input        EXU_illegal_exc,
    input        EXU_mem_misalign_exc,
    input  [2:0] EXU_mem_misalign_funct3,
    input        EXU_iaddr_misalign_exc,
    // 非法指令的原始编码（EXU 随流水锁存后送过来），用于写 mtval
    input [31:0] EXU_fault_inst,
    output IFU_stall,
    output load_use_stall,
    output [31:0] EXU_rs1_in,
    output [31:0] EXU_rs2_in,
    output icache_clr,
    output EXU_inst_clear,
    output [31:0] dnpc,
    output dnpc_flag,
    output        intr_take,
    output        bp_update_en,
    output        bp_update_taken,
    output [31:0] bp_update_target,
    output        bp_mispredict,
    // B7：误预测"已存在判定"（当拍判定或已挂起）→ 让 EXU 在窗口里**不接收新指令**，
    //   否则错路径指令会赶在重定向之前进 EX 并提交。★ 不变量：必须含当拍的 bp_misp_det ——
    //   挂起标志要到判定那一拍的时钟沿才置位，只送挂起标志会晚一拍。§CONTROL-27
    output logic  bp_hold_exu,

    // C4 统一异常通道：两拍分工 —— trap_take（登记拍）触发 CSR 登记 mepc/mcause/mtval；
    //   trap_take_q（下一拍）把"只发一次"的重定向送到 mtvec。trap_cause 是 `EXC_* 独热码，
    //   fault_addr/fault_inst 是 mtval 的取值来源。
    output logic        trap_take,
    output logic        trap_take_q,
    output logic [ 3:0] trap_cause,
    output logic [31:0] fault_addr,
    output logic [31:0] fault_inst,
    // 当前 EX 级是否处于同步异常态（供波形/断言观察）
    output logic        exc_pending
);


    // C2：前递编码由 Data_hazard 输出（唯一裁决源），本模块只声明接收并翻译成数据值
    logic [2:0] IDU_rs1_choice;
    logic [2:0] IDU_rs2_choice;

    // C2：load-use 三个分级明细，仅供波形观察
    logic exu_load_use_dbg;
    logic mem_load_use_dbg;
    logic pipe_load_use_dbg;



    logic branch_taken;
    // 只看 EX_result[0]（EXU 已把分支条件归一化到最低位）；mdu_busy 期屏蔽（残留标志不可信）
    logic EXU_ctrl_valid;
    assign EXU_ctrl_valid = EXU_valid;
    assign branch_taken = branch_flag & Ex_result[0] & ~mdu_busy & EXU_ctrl_valid;

    // ---- 分支预测校验：actual_target=实际目标（jump 用 Ex_result，branch 用 branch_pc）----
    logic        actual_taken;
    logic [31:0] actual_target;
    assign actual_taken  = (branch_taken | jump_flag) & ~mdu_busy & EXU_ctrl_valid;
    assign actual_target = jump_flag ? Ex_result : branch_pc;
    // ★ 不变量：EXU_ctrl_valid（= EXU_valid）必须参与本模块一切"来自 EXU 的控制事实"
    //   （branch_flag/jump_flag/pred_*/异常标志）。原因：EXU 的 valid 与控制寄存器由两个
    //   always_ff 维护，valid_last=0 时只拉低 valid、不更新控制寄存器 → "EXU 空但
    //   jump_flag/pred_* 还是上一条的值" → 无休止重定向 → 死循环。§CONTROL-8
    // 系统重定向（mret/ecall/fence.i）标志：**必须先声明**，下面一行括弧里就要用。
    logic system_redirect;
    // 同步异常重定向脉冲（C4），与 system_redirect 组合使用，同样必须先声明。
    logic trap_redirect;
    // 注：exc_pending 已经是本模块的 output 端口（见端口表），这里不再重复声明。

    // C4：同步异常通路 —— 定优先级（iaddr 0 > ill 2 > 访存非对齐 4/6）、EXU 拍出 trap_take
    //   让 CSR 登记、下一拍出 trap_take_q 补发重定向。必须分两拍：组合电平在 mem_stall 期间
    //   会持续拉高而被 IFU（ready=0）丢掉 → 异常丢失；改成"电平持续发"则每拍都 flush，目标
    //   指令永远进不了 EX → 锁死。判定分段与踩坑史：syn/修复史_全量.md §CONTROL-5/§CONTROL-26
    logic exc_ill, exc_load_mis, exc_store_mis, exc_iaddr_mis;
    assign exc_ill       = EXU_illegal_exc;
    assign exc_load_mis  = EXU_mem_misalign_exc & ~EXU_mem_misalign_funct3[1]
                         &  EXU_mem_misalign_funct3[2];   // 100/101 = lbu/lhu -> load
    assign exc_store_mis = EXU_mem_misalign_exc &  EXU_mem_misalign_funct3[1]
                         & ~EXU_mem_misalign_funct3[2];   // 001 = sh -> store
    // funct3 只用来区分 load/store（mcause 4 还是 6）：0xx=load 族（lb/lh/lw/lbu/lhu），
    //   1xx 里只有 001(sh) 是 store 族（sb=000、sw=010 天然对齐，不会走到这里）。
    assign exc_iaddr_mis = EXU_iaddr_misalign_exc;

    logic exc_any;
    // TRAP_ENABLE=0 → 整块异常逻辑失效（不重定向、不登记），等价于修复前的控制流
    assign exc_any = TRAP_ENABLE ? (exc_iaddr_mis | exc_ill | exc_load_mis | exc_store_mis)
                                 : 1'b0;

    assign exc_pending = exc_any & EXU_valid;      // 本拍 EX 级有指令、且它带着异常
    // 独热码：bit3=指令地址非对齐, bit0=非法指令, bit1=load 非对齐, bit2=store 非对齐
    //   ★ 不变量：优先级链顺序（iaddr→ill→load_mis→store_mis）就是规范要求的
    //   0 > 2 > 4/6，换序会让 mcause 报错种类。详见 syn/修复史_全量.md §CONTROL-31
    assign trap_cause = exc_iaddr_mis ? `EXC_IADDR_MIS
                      : exc_ill       ? `EXC_ILLEGAL
                      : exc_load_mis  ? `EXC_LOAD_MIS
                      : exc_store_mis ? `EXC_STORE_MIS
                      : `EXC_NONE;

    // mtval 取值：非法指令给指令编码（IDU 的原始 inst），其余给出错地址。
    //   地址取 Ex_result（对 load/store 是有效地址，对跳转是目标地址）。
    assign fault_inst = EXU_fault_inst;
    assign fault_addr = Ex_result;     // EXU 的有效地址/跳转目标（端口名是 Ex_result）
    // 在异常指令位于 EX 级的那一拍认定一次异常；去重靠 ~trap_take_q_r
    logic trap_take_q_r;
    assign trap_take = exc_pending & ~trap_take_q_r;
    assign trap_take_q = trap_take_q_r;

    always_ff @(posedge clock) begin
        if (reset)                        trap_take_q_r <= 1'b0;
        else if (trap_take)               trap_take_q_r <= 1'b1;  // 下一拍补发重定向
        else                              trap_take_q_r <= 1'b0;
    end

    // 重定向脉冲：只发一次（EXU 拍 or 补发拍），语义与 bp_mispredict 对齐
    assign trap_redirect = trap_take | trap_take_q;

    logic bp_misp_det;                       // 判定条件为真（不受 mem_stall 影响）
    // ★ 不变量：误预测判定必须排除 intr_take|system_redirect|trap_redirect（这三个源各自会
    //   清掉 EX 级那条指令并给出自己的有效 dnpc，不排除就会同拍抢 dnpc_flag：脉冲发了、PC
    //   却按另一个源走），且**只能被推后、不能被丢弃**（原实现把判定压成 0，误预测永远没人
    //   处理）。§CONTROL-2/§CONTROL-3
    //   注意 bp_hold_exu 里必须含当拍的 bp_misp_det：挂起标志要到判定那一拍的时钟沿才置位，
    //   只送挂起标志会晚一拍，挡不住正好在判定拍进入 EX 的那条错路径指令（B7）。
    assign bp_misp_det = EXU_ctrl_valid & ~(intr_take | system_redirect | trap_redirect) &
                         ((actual_taken != EXU_pred_taken) ||
                          (actual_taken && (actual_target != EXU_pred_target)));

    logic        bp_misp_pend;               // 判定被 hold 挡住，等待补发
    // C6：`bp_pend_taken` 已删除（唯一用处是拼没人读的 bp_redir_taken；补发只需要
    //   "跳到哪"，bp_pend_target 已把"不跳则 pc+4"折叠进去）。详见 §CONTROL-10
    logic [31:0] bp_pend_target;             // 挂起时的实际目标（含"不跳则 pc+4"）
    logic        bp_mispredict_raw;          // 判定存在（尚未去抖/去重），见下

    // 补发脉冲：hold 结束后（~mem_stall）本拍可发；否则先挂起。
    //   ★ 不变量：这一级必须门控 ~mem_stall，不能改成"hold 期间直接发"——hold 期间 IFU 的
    //   ready(=IDU_ready) 为 0，发出的重定向会被 IFU 丢掉（实测：dnpc_flag 打了、PC 没动）。
    assign bp_mispredict_raw = (bp_misp_det | bp_misp_pend) & ~mem_stall;

    // 本拍重定向用的目标：**挂起值优先**。
    //   ★ 不变量：bp_misp_pend=1 时目标必须是 bp_pend_target —— 挂起的是"更早、已确认
    //   但没送达 IFU"的那次误预测，先来先服务，否则错路径上的新判定会抢走重定向
    //   （实测 rnd034）。§CONTROL-4
    // C6：原来这里还有一个 bp_redir_taken，**从头到尾没有任何地方读它**（Quartus 报
    //   Warning 10036: assigned a value but never read），已删除 —— dnpc 已承载"跳到哪"。
    //   详见 §CONTROL-10
    logic [31:0] bp_redir_target;
    assign bp_redir_target = bp_misp_pend ? bp_pend_target
                          : (actual_taken ? actual_target : (EXU_pc + 32'd4));

    always_ff @(posedge clock) begin
        if (reset) begin
            bp_misp_pend   <= 1'b0;
            bp_pend_target <= 32'b0;
        end else if (bp_mispredict) begin
            bp_misp_pend   <= 1'b0;          // 已经补发出去
        end else if (bp_misp_det & ~bp_misp_pend) begin
            // 本拍没能发（否则上一个分支已清）→ 挂起。
            // 已有挂起值时不再覆盖：先来先服务，保证不丢任何一次确认的重定向。
            bp_misp_pend   <= 1'b1;
            bp_pend_target <= actual_taken ? actual_target : (EXU_pc + 32'd4);
        end
    end

    // ★ 不变量：一次预测错误只重定向一次（bp_mispredict 必须是脉冲，不是电平）。上板引入
    //   存储侧 hold 后 EXU 可能被冻住好几拍，电平信号会变成"连环重定向"，每一拍都 flush，
    //   重定向目标那条指令（例：ecall）永远进不了 EXU → 锁死。清零条件必须是"判定彻底
    //   消失" !(bp_misp_det|bp_misp_pend)，**不能**用 raw==0（raw 会被 mem_stall 压成 0，
    //   会把还在挂起的判定当成没有误预测，B4）。实测与踩坑史：syn/修复史_全量.md §CONTROL-6
    logic bp_redirect_pending;
    always_ff @(posedge clock) begin
        if (reset)                               bp_redirect_pending <= 1'b0;
        else if (bp_mispredict)                  bp_redirect_pending <= 1'b1;
        else if (!(bp_misp_det | bp_misp_pend))  bp_redirect_pending <= 1'b0;
    end
    assign bp_mispredict = bp_mispredict_raw & ~bp_redirect_pending;

    // 送给 EXU 的"暂停接收"窗口：只挡"接收新指令"，不挡 EXU 在重定向当拍把 EX 里那条
    //   被判错的跳转正常交给 LSU（jal 的 link 靠这一拍）
    assign bp_hold_exu = bp_misp_det | bp_misp_pend;

    // 预测器在 EX 级写入：真实方向 + 真实目标
    assign bp_update_en     = EXU_valid & (branch_flag | jump_flag);
    assign bp_update_taken  = actual_taken;
    assign bp_update_target = actual_target;

    // 系统事件（异常返回 / ecall / fence.i）不由预测器覆盖，必须强制重定向；
    //   C4：同步异常也走这条"强制重定向、不许预测器覆盖"的路
    assign system_redirect = mret_flag | ecall_flag | fence_i_flag | trap_redirect;

    // 中断接收判定（精确中断）：只在执行级没有会重定向的分支/跳转/fence、当前译码指令不是
    //   ecall/mret、且没有 load-use/MDU 停顿时才接受，保证 mepc 指向真正被中断的指令；入口
    //   固定为 mtvec。★ 不变量：intr_safe 的每一项都不许删（IDU_valid=确实有指令可记为 mepc；
    //   ~(branch|jump|fence_i)=让改 PC 的指令先走完；~mret/~ecall=系统指令不插队；~IFU_stall=
    //   译码级那条还没被接收；~mdu_busy=MDU 迭代期 EX 级一直占着）。
    logic intr_safe;
    assign intr_safe = IDU_valid
                     & ~(branch_flag | jump_flag | fence_i_flag)
                     & ~mret_flag & ~ecall_flag & ~IFU_stall & ~mdu_busy;
    assign intr_take = intr_pending & intr_safe;

    // dnpc_flag：本拍"要重定向 PC"的总请求，同时是 IDU 的 flush。四个源按仲裁优先级：
    //   intr_take > trap_redirect > bp_mispredict > system_redirect
    //   （system_redirect 内部含 trap_redirect；顺序与下面 dnpc 的三元链严格一致）
    //   ★ 不变量：四个源都只能是**一拍宽**的脉冲。原因：dnpc_flag 同时是 IDU 的 flush，
    //   电平式 → 每拍都冲刷、目标指令永远进不了流水；漏一拍 → 错路径指令活着提交。
    //   一次性化手段与踩坑史：syn/修复史_全量.md §CONTROL-1
    assign dnpc_flag      = intr_take | trap_redirect | bp_mispredict | system_redirect;
    // EXU_inst_clear：把 EX 级这条指令的控制信息清成 0（无副作用的空操作）。两类用处：冲刷
    //   （中断/预测错误/异常）与 load-use（消费者被 EXU 提前收走、操作数还没前递好；IDU 暂停
    //   期间冻结、解除后会**再送一次**，那次 load 已到 M3 由 3'b011 正递，所以清掉的那份
    //   R_wen/mem_wen 全 0，不会重复写寄存器/内存）。
    //   ★ 不变量：不含 system_redirect —— ecall/mret/fence.i **必须自己流到 WB**（ecall 写
    //   mcause/mepc，mret 恢复 mstatus，fence.i 在 EX 清 ICache），它们引发的冲刷只针对排在
    //   后面的错路径指令（由 dnpc_flag→IDU.flush 完成）；原来并进来会在 ecall 进 EXU 的同一拍
    //   把 csr_wen 清 0（实测 ecall 永不产生异常）。§CONTROL-7
    //   ★ 不变量（B4）：mem_stall 项必须写成 (mem_stall & ~(branch_flag|jump_flag)) ——
    //   "hold 时数据无效要重放"只对 load 成立，清掉分支/跳转等于把它还没做的重定向判定一起
    //   扔掉（实测 loop_min 的 blt 被清 → x1 跑到 2491），现在交给 bp_misp_det 挂起。§CONTROL-9
    assign EXU_inst_clear = intr_take | bp_mispredict | trap_redirect
                          | (mem_stall & ~(branch_flag | jump_flag))
                          | load_use_stall;
    // C2/B5：load-use 分级判定已搬进 Data_hazard，本模块不再写第二份。§CONTROL-14
    // mdu_busy 并入前端暂停。★ 不变量：它只能进 IFU_stall，不能进上面 load-use 项（否则
    //   打断 M 自己的向后 valid，乘除结果直接丢失）。
    assign IFU_stall      = load_use_stall | mdu_busy;


    assign icache_clr = fence_i_flag & EXU_valid;


    // dnpc 统一承载控制流重定向（来源与 dnpc_flag 的优先级一一对应）：中断取 mtvec_out；
    //   误预测取 bp_redir_target（不跳转回退 pc+4，挂起时优先 bp_pend_target）；mret 取
    //   mepc_out，ecall/同步异常入口取 mtvec_out。
    //   ★ 不变量：这条链的顺序必须与 dnpc_flag 的或项顺序一致，否则"请求来自 A、目标取自 B"。
    assign dnpc = intr_take ? mtvec_out
                : bp_mispredict ? bp_redir_target
                : (mret_flag ? mepc_out : mtvec_out);



    // 把前递编码翻译成真正的数据值（"译码级前面的隐式旁路多路复用器"）。
    //   3'b001=EXU(EXU_forward_val) / 010=M1(MEM_Ex_result) / 101=M2(MEM_PIPE_Ex_result,
    //   对 load 只是地址) / 011=M3(MEM2_Ex_result, load 数据只在这一级) / 100=WB(WB_rd_value)
    assign EXU_rs1_in = (IDU_rs1_choice == 3'b001) ? EXU_forward_val :
                        (IDU_rs1_choice == 3'b010) ? MEM_Ex_result :
                        (IDU_rs1_choice == 3'b101) ? MEM_PIPE_Ex_result :
                        (IDU_rs1_choice == 3'b011) ? MEM2_Ex_result :
                        (IDU_rs1_choice == 3'b100) ? WB_rd_value :
                        IDU_rs1_value;

    assign EXU_rs2_in = (IDU_rs2_choice == 3'b001) ? EXU_forward_val :
                        (IDU_rs2_choice == 3'b010) ? MEM_Ex_result :
                        (IDU_rs2_choice == 3'b101) ? MEM_PIPE_Ex_result :
                        (IDU_rs2_choice == 3'b011) ? MEM2_Ex_result :
                        (IDU_rs2_choice == 3'b100) ? WB_rd_value :
                        IDU_rs2_value;


// Data_hazard 是**唯一**的前递/冒险裁决源：输出谁来前递（IDU_rs1/rs2_choice）与要不要停
//   （load_use_stall），本模块只负责把编码翻译成数据值、把 stall 接到冻结逻辑上。
//   ★ 不变量：本模块不许再出现任何"某级是不是 load / 数据可不可用"的判断。§CONTROL-14
Data_hazard Data_hazard_inst (
    .IDU_rs1        (IDU_rs1),
    .IDU_rs2        (IDU_rs2),
    .EXU_rd         (EXU_rd),
    .MEM_rd         (MEM_rd),
    .MEM_PIPE_rd    (MEM_PIPE_rd),
    .MEM2_rd        (MEM2_rd),
    .WB_rd          (WB_rd),
    .MEM_valid      (MEM_valid),
    .MEM_PIPE_valid (MEM_PIPE_valid),
    .MEM2_valid     (MEM2_valid),
    .EXU_valid      (EXU_valid),
    .IDU_valid      (IDU_valid),
    .WB_valid       (WB_valid),
    .MEM_mem_ren    (MEM_mem_ren),
    .MEM_PIPE_mem_ren(MEM_PIPE_mem_ren),
    .EXU_R_Wen      (EXU_R_Wen),
    .EXU_mem_ren    (EXU_mem_ren),
    .MEM_R_Wen      (MEM_R_Wen),
    .MEM_PIPE_R_Wen (MEM_PIPE_R_Wen),
    .MEM2_R_Wen     (MEM2_R_Wen),
    .WB_R_Wen       (WB_R_Wen),
    .IDU_rs1_choice (IDU_rs1_choice),
    .IDU_rs2_choice (IDU_rs2_choice),
    .load_use_stall (load_use_stall),
    .exu_load_use   (exu_load_use_dbg),
    .mem_load_use   (mem_load_use_dbg),
    .pipe_load_use  (pipe_load_use_dbg)
);

endmodule        //PC_Control
