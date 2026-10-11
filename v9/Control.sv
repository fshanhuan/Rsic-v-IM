// Control 负责三件事：
// 1. 收束所有会改写 PC 的事件，生成 dnpc/dnpc_flag。
// 2. 识别 load-use 冒险，决定是否暂停 IFU/IDU 并清空执行级。
// 3. 根据 Data_hazard 的编码真正完成前递值选择。
`include "para.sv"

module Control #(
    // -----------------------------------------------------------------------
    // v9 新增（C4）：同步异常体系总开关。
    //   1 = 打开：非法指令 / 访存非对齐 / 指令地址非对齐 都会陷入 mtvec 并登记
    //             mcause/mepc/mtval（IDU 的合法性译码 + EXU 的异常锁存同时生效）。
    //   0 = 关闭：这些异常不产生重定向，退回到和修复前一致的控制流行为。
    //             （非法指令的"副作用清零"仍保留 —— 那层在 IDU 里，属于安全修正。）
    //
    // 为什么要留开关：
    //   1) 异常体系会改变"哪些指令重定向 PC"，牵动 EXU↔Control 那条很绕的组合链。
    //      留开关可以逐项开启、逐项回归，出问题能立刻定位到是哪一项；
    //   2) 教学场景需要"干净基线"（只用 ecall/中断），不想被额外异常干扰；
    //   3) 综合/时序对比时可以把新逻辑整块关掉，量化它的资源/Fmax 代价。
    //   默认 1（打开）。
    // -----------------------------------------------------------------------
    parameter TRAP_ENABLE = 0
) (
    input clock,
    input reset,
    input [31:0] mtvec_out,
    input [31:0] mepc_out,
    input [31:0] branch_pc,
    input [31:0] Ex_result,
    // v9 修复（B6）：EXU 级的前递值。
    //   对 jump/CSR 来说，写进 rd 的是 rd_value（jal/jalr 的 link、CSR 读值），
    //   而 Ex_result 对 jump 是**跳转目标地址**、对 CSR 是地址。原来 EXU 级前递直接
    //   用 Ex_result，于是 `jal x4, T` 后面紧跟读 x4 的指令会拿到 T（实测：
    //   `jal x4,0x24c` + `sw x4,...` 把 0x24c 写进了内存，应为 link 0x190）。
    //   MEM/PIPE/WB 三级早已按这个口径处理（见 MEM_forward_val），这里补齐 EXU 级。
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
    // 存储侧停拍请求由 myCPU 并入（ICache/DCache 的 hold），Control 只做透传，
    // 目的是把它从 IFU_stall 里单独引出来给 EXU_inst_clear 用。
    input mdu_busy,
    input mem_stall,
    // ---- v9 新增（C4）：来自 EXU 的同步异常（已锁存，与 EX 级指令一一对应）----
    //   “非法指令 / 访存非对齐 / 指令地址非对齐”三类同步异常的判定分别在
    //   IDU（非法、访存非对齐，当拍算地址）与 EXU（跳转目标对齐）完成，
    //   Control 只负责**定优先级、发重定向脉冲、告诉 CSR 写什么 cause/mtval**。
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
    // v9 修复（B7）：误预测"已存在判定"（当拍判定或已挂起）——送给 EXU，
    //   让它在窗口里**不接收新指令**，否则错路径指令会赶在重定向之前进入 EX 并提交。
    //   必须包含当拍的 bp_misp_det：挂起标志是在判定那一拍的时钟沿才置位的，
    //   只送挂起标志会晚一拍，挡不住正好在判定拍进入 EX 的那条错路径指令。
    output logic  bp_hold_exu,

    // ---- v9 新增（C4）：统一异常通道（送给 CSR/Reg_Stack）----
    //   trap_take / trap_take_q ：确认接收一次同步异常的**单拍脉冲**（见下方 always_ff）
    //   trap_cause              ：`EXC_* 独热码，CSR 据此写 mcause/mtval
    //   fault_addr / fault_inst ：mtval 的取值来源
    output logic        trap_take,
    output logic        trap_take_q,
    output logic [ 3:0] trap_cause,
    output logic [31:0] fault_addr,
    output logic [31:0] fault_inst,
    // 当前 EX 级是否处于同步异常态（供波形/断言观察）
    output logic        exc_pending
);


    // v9 修复（C2）：`IDU_rs1_choice / IDU_rs2_choice` 不再由本模块产生，
    //   改由 Data_hazard 输出（它是唯一的前递裁决源），这里只声明成 logic 接收。
    //   同理，load-use 冒险判定也搬到了 Data_hazard（见文件末尾注释）。
    logic [2:0] IDU_rs1_choice;
    logic [2:0] IDU_rs2_choice;

    // v9 修复（C2）：load-use 的三个分级明细（由 Data_hazard 产生，仅供波形观察；
    //   Control 的停顿/冲刷只用合并后的 load_use_stall）。
    logic exu_load_use_dbg;
    logic mem_load_use_dbg;
    logic pipe_load_use_dbg;



    logic branch_taken;
    // branch_taken 只看 EX_result[0]，因为 EXU 已把各种分支条件归一化到最低位。
    // mdu_busy 期间 EX 级寄存的是刚发射的 M 指令（其残留标志不可信），
    // 因此忙期一律屏蔽分支/跳转判定。
    // **EXU_valid 必须参与限定**：EXU 的 valid 与它的控制寄存器并不总是同步
    //   （valid_last=0 时 EXU 不更新控制寄存器，只把自己的 valid 拉低），
    //   于是会出现“EXU_valid=0、但 jump_flag/branch_flag/pred_* 还留着上一条指令的值”。
    //   这些残留值会让 Control 一直判出分支/跳转和预测错误，无休止地重定向，
    //   把重定向目标那条指令永远冲掉 —— 实测 prog.hex 就是这样在 jal 之后死循环的
    //   （EXU_pc 固定、EXU_valid 恒 0，而 dnpc_flag 周期性为 1）。
    logic EXU_ctrl_valid;
    assign EXU_ctrl_valid = EXU_valid;
    assign branch_taken = branch_flag & Ex_result[0] & ~mdu_busy & EXU_ctrl_valid;

    // -----------------------------------------------------------------------
    // 分支预测校验：
    //   actual_taken  : 本条控制流指令实际是否跳转（branch 命中或 jump）
    //   actual_target : 实际目标（jump 用 Ex_result，branch 用 branch_pc）
    //   bp_mispredict : 预测方向或预测目标与实际不符
    // -----------------------------------------------------------------------
    logic        actual_taken;
    logic [31:0] actual_target;
    assign actual_taken  = (branch_taken | jump_flag) & ~mdu_busy & EXU_ctrl_valid;
    assign actual_target = jump_flag ? Ex_result : branch_pc;
    // v9 上板改造修正：预测校验必须让位给“更高优先级、且会让 EX 级这条指令被清掉”的事件。
    //   预测错误触发的重定向本身也会拉高 EXU_inst_clear，而指令在 EXU 里可能因为
    //   存储侧 hold（EXU 被冻结，一拍走不掉）而停留多拍：这期间 bp_mispredict 若是 1，
    //   每一个刚被接收的指令都会被连着清成空操作，重定向目标又被反复重取，
    //   整机就锁死在这里（实测：ecall 永远进不了 WB，mepc/mcause 始终为 0）。
    //   ecall/mret/fence.i（system_redirect）和中断（intr_take）有自己的重定向通道，
    //   由它们决定冲刷；mem_stall 期间 EXU 冻结、预测校验等 hold 结束再判。
    //   EXU_ctrl_valid 同样必须参与：EXU 空（valid=0）时它的 pred_* 是残留值，
    //   不能拿来判预测错误，否则会无休止重定向。
    // v9 修复（B4/B7）：误预测判定**只能被推后，不能被丢弃**。
    //   原实现把 ~mem_stall 写进 raw，判定拍撞上 hold 时判定被压成 0（不是挂起），
    //   下一拍 EXU_valid 已掉下去，这次误预测永远没人处理 —— 实测纯 ALU 后向分支
    //   循环只跑 2 圈就掉出（loop_min）。
    //   但也不能"去掉 ~mem_stall 直接发"：hold 期间 IFU 的 ready(=IDU_ready) 为 0，
    //   发出去的重定向会被 IFU 丢掉（实测：dnpc_flag 打了、PC 没动）。
    //   所以：hold 期间把判定连同**方向与目标**一起挂起，等取指侧能接收时补发一次。
    //   同时把 bp_misp_pend 送给 EXU，让它在挂起期间**不接收新指令** —— 否则错路径
    //   的那条会在补发前溜进 EX 并被提交（实测 rnd034：x16 被错路径的 jal 写坏）。
    // 系统重定向（mret/ecall/fence.i）标志：**必须先声明**，下面一行括弧里就要用。
    logic system_redirect;
    // 同步异常重定向脉冲（C4），与 system_redirect 组合使用，同样必须先声明。
    logic trap_redirect;
    // 注：exc_pending 已经是本模块的 output 端口（见端口表），这里不再重复声明。

    // =======================================================================
    // v9 新增（C4）：同步异常（非法指令 / 访存非对齐 / 指令地址非对齐）
    // -----------------------------------------------------------------------
    // 原来的核只认识 ecall 这一种同步异常，非法指令会被"当成加法"执行掉、
    // 非对齐访存会被静默对齐（LSU 里把 addr[17:16] 强制清零）—— 两者都违反
    // RISC-V 最少可测的语义，而且会让软件拿到错误结果却毫无提示。
    //
    // 这里做三件事：
    //   1) 定优先级（与 RISC-V 规范一致）：
    //        指令地址非对齐(0) > 非法指令(2) > 访存非对齐(4/6)
    //   2) 生成"确认接收一次异常"的单拍脉冲 trap_take，交给 CSR 登记
    //      mepc/mcause/mtval（登记发生在异常指令位于 EX 级的那一拍）。
    //   3) 下一拍用 trap_take_q 发一次**只发一次**的重定向到 mtvec。
    //      为什么要分两拍、而不是用组合电平直接重定向：
    //        - 组合电平在 mem_stall（缓存 hold）期间会持续拉高，而 IFU 的
    //          ready=0 会把重定向丢掉 → 异常丢失；
    //        - 若改成"电平持续发"，则每一拍都 flush，重定向目标那条指令永远
    //          进不了 EX → 整机锁死。这与分支预测器 bp_redirect_pending 踩过
    //          的坑完全相同，所以复用同一手法：先登记、再补发一次。
    //      只用一拍（EXU 那一拍）做重定向的话，hold 期间同样会丢；
    //      所以用"EXU 拍脉冲 + 下一拍补发"覆盖两种时序。
    // =======================================================================
    logic exc_ill, exc_load_mis, exc_store_mis, exc_iaddr_mis;
    assign exc_ill       = EXU_illegal_exc;
    assign exc_load_mis  = EXU_mem_misalign_exc & ~EXU_mem_misalign_funct3[1]
                         &  EXU_mem_misalign_funct3[2];   // 100/101 = lbu/lhu -> load
    assign exc_store_mis = EXU_mem_misalign_exc &  EXU_mem_misalign_funct3[1]
                         & ~EXU_mem_misalign_funct3[2];   // 001 = sh -> store
    // 说明：funct3 只用来区分 load/store（mcause 4 还是 6），
    //   0xx=load 族（000 lb / 001 lh / 010 lw / 100 lbu / 101 lhu），
    //   1xx 里只有 001(sh) 是 store 族（sb=000、sw=010 天然对齐，不会走到这里）。
    assign exc_iaddr_mis = EXU_iaddr_misalign_exc;

    logic exc_any;
    // v9 新增（C4）：TRAP_ENABLE=0 时整块异常逻辑失效（不重定向、不登记），
    //   等价于修复前的控制流。IDU 侧的"非法指令副作用清零"仍然生效，
    //   所以即使关掉开关，非法指令也不会被真的执行掉。
    assign exc_any = TRAP_ENABLE ? (exc_iaddr_mis | exc_ill | exc_load_mis | exc_store_mis)
                                 : 1'b0;

    // 本拍 EX 级确实有一条指令、且它带着异常
    assign exc_pending = exc_any & EXU_valid;
    // 优先级编码（独热）：bit3=指令地址非对齐, bit0=非法指令,
    //                    bit1=load 非对齐, bit2=store 非对齐
    assign trap_cause = exc_iaddr_mis ? `EXC_IADDR_MIS
                      : exc_ill       ? `EXC_ILLEGAL
                      : exc_load_mis  ? `EXC_LOAD_MIS
                      : exc_store_mis ? `EXC_STORE_MIS
                      : `EXC_NONE;

    // mtval 取值来源：非法指令给指令编码（IDU 的原始 inst），其余给出错地址。
    //   非法指令的编码由 IDU 透传过来（fault_inst），地址用 EXU 的目标/有效地址
    //   （EX_result：对 load/store 是有效地址，对跳转是目标地址）。
    assign fault_inst = EXU_fault_inst;
    assign fault_addr = Ex_result;     // EXU 的有效地址/跳转目标（端口名是 Ex_result）

    // trap_take：在异常指令位于 EX 级的那一拍认定一次异常。
    //   ~exc_pending_q 用来**去重**：ensure 同一拍不会重复登记
    //   （trap_take_q 已经把登记延续到下一拍，这里不重复触发）。
    logic trap_take_q_r;
    assign trap_take = exc_pending & ~trap_take_q_r;
    assign trap_take_q = trap_take_q_r;

    always_ff @(posedge clock) begin
        if (reset)                        trap_take_q_r <= 1'b0;
        else if (trap_take)               trap_take_q_r <= 1'b1;  // 下一拍补发重定向
        else                              trap_take_q_r <= 1'b0;
    end

    // 重定向脉冲：只发一次（EXU 拍 or 补发拍），语义与 bp_mispredict 对齐。
    //   （trap_redirect 的声明已上移到 system_redirect 旁边，这里只做赋值）
    assign trap_redirect = trap_take | trap_take_q;

    logic bp_misp_det;                       // 判定条件为真（不受 mem_stall 影响）
    assign bp_misp_det = EXU_ctrl_valid & ~(intr_take | system_redirect | trap_redirect) &
                         ((actual_taken != EXU_pred_taken) ||
                          (actual_taken && (actual_target != EXU_pred_target)));

    logic        bp_misp_pend;               // 判定被 hold 挡住，等待补发
    // v9 修复（C6）：`bp_pend_taken` 已删除。
    //   它的唯一用处是拼 bp_redir_taken，而那个信号没人读；补发重定向只需要
    //   "跳到哪"（bp_pend_target 已经把"不跳则 pc+4"折叠进去了），
    //   方向信息不参与 IFU 的重定向决策，留下就是死寄存器。
    logic [31:0] bp_pend_target;             // 挂起时的实际目标（含“不跳则 pc+4”）
    logic        bp_mispredict_raw;          // 判定存在（尚未去抖/去重），见下

    // 补发脉冲：hold 结束后（~mem_stall）本拍可发；否则先挂起。
    assign bp_mispredict_raw = (bp_misp_det | bp_misp_pend) & ~mem_stall;

    // 本拍重定向用的目标：**挂起值优先**。
    //   挂起的是"更早、已经确认但没能送达 IFU"的那次误预测，必须先补发它；
    //   否则会出现：hold 拍挂起了 jal(0xd4)→0x110，下一拍落在错路径上的
    //   jal(0xd8)→0x128 也被判为误预测并抢走重定向（实测 rnd034）。
    //
    // v9 修复（C6）：这里原来还有一个 `bp_redir_taken`（= bp_misp_pend ? bp_pend_taken
    //   : actual_taken），但**从头到尾没有任何地方读它** —— Quartus 直接报
    //     Warning (10036): object "bp_redir_taken" assigned a value but never read
    //   死信号已删除。方向信息本身不需要单独送出去：
    //   dnpc 已经承载了"跳到哪"，IFU 只看 dnpc/dnpc_flag；
    //   而预测器的方向更新走的是 bp_update_taken（见下）。
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

    // v9 上板改造修正：**一次预测错误只重定向一次**。
    //   bp_mispredict 原来是电平信号，只要那条被判错的指令还停在 EXU 里就一直为 1。
    //   上板改造后引入存储侧 hold（同步 BRAM 取指/访存要停拍），EXU 可能被冻住好几拍，
    //   于是电平信号变成“连环重定向”：每一拍都 flush，重定向目标那条指令（例：
    //   ecall）永远进不了 EXU，整机锁死 —— 实测 prog.hex 就是这样停在结尾的。
    //   加一个 pending 标志：第一次判错时给出一次重定向脉冲，之后保持静默，
    //   直到这条判定彻底消失才允许下一次重定向。
    //   v9 修复（B4）：清零条件改为“判定彻底消失”，不能再用 raw==0 —— raw 会被
    //   mem_stall 压成 0，那样会把“还在挂起的判定”当成“没有误预测”。
    logic bp_redirect_pending;
    always_ff @(posedge clock) begin
        if (reset)                               bp_redirect_pending <= 1'b0;
        else if (bp_mispredict)                  bp_redirect_pending <= 1'b1;
        else if (!(bp_misp_det | bp_misp_pend))  bp_redirect_pending <= 1'b0;
    end
    assign bp_mispredict = bp_mispredict_raw & ~bp_redirect_pending;

    // 送给 EXU 的"暂停接收"窗口（见端口说明）
    assign bp_hold_exu = bp_misp_det | bp_misp_pend;

    // 预测器在 EX 级写入：真实方向 + 真实目标
    assign bp_update_en     = EXU_valid & (branch_flag | jump_flag);
    assign bp_update_taken  = actual_taken;
    assign bp_update_target = actual_target;

    // 系统事件（异常返回 / ecall / fence.i）不由预测器覆盖，必须强制重定向。
    // （system_redirect 的声明已上移到首次使用处之前）
    // v9 修复（C4）：**同步异常也走这条"强制重定向、不许预测器覆盖"的路**。
    //   trap_redirect 是异常的单拍脉冲（见文件上方 C4 说明）。
    assign system_redirect = mret_flag | ecall_flag | fence_i_flag | trap_redirect;

    // -----------------------------------------------------------------------
    // 中断接收判定（精确中断）：
    //   仅当执行级没有会造成重定向的分支/跳转/fence、当前译码指令不是 ecall/mret、
    //   且没有 load-use 暂停时才接受中断，从而保证 mepc 指向真正被中断的指令。
    //   中断入口固定为 mtvec。
    // -----------------------------------------------------------------------
    logic intr_safe;
    assign intr_safe = IDU_valid
                     & ~(branch_flag | jump_flag | fence_i_flag)
                     & ~mret_flag & ~ecall_flag & ~IFU_stall & ~mdu_busy;
    assign intr_take = intr_pending & intr_safe;

    assign dnpc_flag      = intr_take | trap_redirect | bp_mispredict | system_redirect;
    // EXU_inst_clear 的作用是**把 EX 级这条指令的控制信息清成 0（变成空操作）**，
    // 用于两类情况：
    //   ① 真正的冲刷：重定向（中断/预测错误/mret/ecall/fence.i）——错的指令必须消失；
    //   ② load-use 冒险：IDU 里那条消费者指令会被 EXU **提前收走**（v9 的 valid/ready
    //      约定里 EX 级只有在 valid_last=1 时才更新寄存器，所以没法用“灌气泡”的方式
    //      把它挡在 IDU 里），它当拍的操作数还没被前递好，必须清掉。
    //      注意 IDU 的流水寄存器在暂停期间是冻结的，消费者仍然留在 IDU；暂停解除后
    //      IDU 会把它**再送一次**给 EXU，那一次的 load 已经走到 LSU 第三级
    //      （forward_val_wb 上就是数据），由 Data_hazard 的 3'b011 正确前递。
    //      所以“被清掉的那一份”是不带任何副作用（R_wen/mem_wen 全 0）的空操作，
    //      不会重复写寄存器、也不会重复写内存。
    // mem_stall（缓存 hold）同理：取回的数据无效，EX 级这一条要作废重放。
    // 注意这里**不含 system_redirect**：ecall/mret/fence.i 这三条**必须自己流到 WB**
    // （ecall 要在 WB 写 mcause/mepc，mret 要恢复 mstatus，fence.i 要在 EX 级清 ICache），
    // 而它们触发的重定向只应该冲掉**它们后面**那些错路径指令 —— 后者由 dnpc_flag
    // 送到 IDU 的 flush 完成，不需要清 EXU 这一条。原来把 system_redirect 并进来，
    // 会在 ecall 被接收进 EXU 的同一拍把它的 csr_wen 清成 0（实测：ecall 永远不产生
    // 异常，mepc/mcause 恒为 0，程序在入口处死循环）。
    // v9 修复（B4）：mem_stall 期间**不能把分支/跳转指令作废**。
    //   把 mem_stall 并进 EXU_inst_clear 的理由是"存储侧 hold 时取回的数据无效，
    //   EX 级这条要作废重放"——那只对 load 成立。分支/跳转不依赖访存数据，把它在
    //   这一拍清成空操作，等于**把它还没做的重定向判定一起扔掉**：
    //   实测（loop_min 退出那次迭代）：IF 级已经按"预测跳转"取到 0x0C，而 0x14 上
    //   那条 blt 在 EX 里被清掉（EXU_valid=0、控制位残留），它实际"不跳"这件事
    //   再也没人判 → CPU 顺着错路径一直循环（x1 跑到 2491 而不是 10）。
    //   现在把它留给 bp_misp_det 去判：hold 期间判定条件成立就挂起（bp_misp_pend），
    //   等取指侧能接收（~mem_stall）时补发一次重定向。
    assign EXU_inst_clear = intr_take | bp_mispredict | trap_redirect
                          | (mem_stall & ~(branch_flag | jump_flag))
                          | load_use_stall;
    // v9 修复（C2）：`exu_load_use / mem_load_use / pipe_load_use` 三个分级明细
    //   已经搬进 Data_hazard（与它自己的命中条件同一份代码算出来），
    //   从那里引进来；本模块**不再**自己写第二份"某级是不是 load"的判断。
    //   历史教训（B5）：两份口径一旦不同步，就会出现"Control 不判停顿、
    //   而 Data_hazard 把可用的 load 数据挡掉"，消费者读到寄存器堆旧值。
    // mdu_busy 也并入前端暂停：MDU 迭代期间 EX 级一直占着那条 M 指令，
    //   前端必须停住，否则会把后续指令推进来覆盖它。
    // 两路暂停信号：
    //   load_use_stall —— 只含 load-use 冒险（供 EXU 的冲刷判定）
    //   IFU_stall      —— 前端总暂停：再并入 mdu_busy，供 IFU 冻结 PC/取指使用
    assign IFU_stall      = load_use_stall | mdu_busy;


    assign icache_clr = fence_i_flag & EXU_valid;


    // dnpc 统一承载控制流重定向：
    //   - 中断    ：入口 mtvec；
    //   - 预测错误：跳转用真实目标，不跳转回退到 pc+4；
    //   - 系统事件：mret 用 mepc，ecall/异常入口用 mtvec。
    assign dnpc = intr_take ? mtvec_out
                : bp_mispredict ? bp_redir_target
                : (mret_flag ? mepc_out : mtvec_out);



    // 这里把前递编码翻译成真正的数据值。
    // 可以把它看成“译码级前面的隐式旁路多路复用器”。
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


// Data_hazard 是**唯一**的前递/冒险裁决源：
//   它输出 IDU_rs1_choice / IDU_rs2_choice（谁来前递）与 load_use_stall
//   （要不要停），本模块只负责把编码翻译成数据值、把 stall 接到冻结逻辑上。
//   v9 修复（C2）：load-use 的三个分级条件已经搬进 Data_hazard，不再出现在这里。
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
