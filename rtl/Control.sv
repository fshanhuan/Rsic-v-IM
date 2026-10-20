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
    // 控制流（IDU 的"非法指令副作用清零"仍生效）。
    // ★ v10 变更：默认值由 0 改为 **1**（异常体系补全）。原来默认关掉的原因是
    //   "TRAP_ENABLE=1 时 prog_loop 仍复现 B4 症状"，而 B4 的真正根因是前端把误预测的
    //   重定向脉冲吞在 icache_hold 里（PC 冻结期间 ready=0）。v10 把 I-Cache 改成
    //   全流水、未命中零停顿之后，这条吞脉冲的路径整体消失，7 个整机程序 + 3 个异常
    //   专项程序在 TRAP_ENABLE=1 下全部通过（证据见 docs/IMPLEMENTATION_v10.md）。
    //   开关仍然保留：置 0 可整块量化异常逻辑的面积/Fmax 代价。
    parameter TRAP_ENABLE = 1
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
    // v15：MEM 级 load 数据本拍可用（DCache 的 M1 探测口命中）→ 免停 + 可前递
    input MEM_m1_ok,
    input MEM_PIPE_mem_ren,
    input fence_i_flag,
    input [4:0] IDU_rs1,
    input [4:0] IDU_rs2,
    input IDU_valid,
input IDU_ready,          // ★ v13.2（P0）：ID 级被下游接收 = EXU_ready & ~IFU_stall
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
    // ★ v10 新增（C10）：EX 级的 CSR 写使能位图。CSR 写最终在 WB 级才生效，而 mret 在
    //   译码级就要读 mepc —— 这根线给 4 深影子链当输入，用来做 CSR RAW 前递。
    input [15:0] EXU_csr_wen,
    // ★ v10.2 新增：CSR 读口的 RAW 前递（读密-写松，两者天然差三级）。
    //   IDU_csr_sel = 本拍要读的 CSR 独热码；csr_rd_fwd(_en) = 最新一次在途写的值。
    input [15:0] IDU_csr_sel,
    output logic [31:0] csr_rd_fwd,
    output logic        csr_rd_fwd_en,
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

    // C4 统一异常通道：trap_take（单拍）既触发 CSR 登记 mepc/mcause/mtval，也当拍把
    //   重定向送到 mtvec。trap_cause 是 `EXC_* 独热码，fault_addr/fault_inst/fault_pc 是
    //   mepc/mtval 的取值来源。
    // ★ v10 变更：原来的两拍 pair（trap_take + trap_take_q 补发）已**整体废除**。
    //   它存在的唯一理由是"旧前端在 ready=0 时会丢掉重定向脉冲"。v10 的 IFU 里
    //   `if (dnpc_flag) pc <= dnpc;` 是**无条件**的（不看 ready/valid/队列深度），
    //   所以补发不但没必要，还有害：补发那一拍 EX 级已经没有异常了，trap_cause=0000，
    //   会把刚写好的 mcause 覆盖成 0（实测 exc_illegal：cyc14 mcause=2 → cyc15 mcause=0）。
    output logic        trap_take,
    output logic [ 3:0] trap_cause,
    output logic [31:0] fault_addr,
    output logic [31:0] fault_inst,
    output logic [31:0] fault_pc,
    // 当前 EX 级是否处于同步异常态（供波形/断言观察）
    output logic        exc_pending,
    // ★★ v13.2（P0）新增：ID 级"系统指令（ecall/mret）确实会提交"的许可，直通给 IDU，
    //   用来门控 CSR 的副作用。见下面 sys_commit_ok 的定义与 IDU.sv 的端口注释。
    output logic        sys_commit_ok,
    // ★ v12（B）新增：系统重定向观察口（mret/ecall/fence.i/trap_redirect，**不含**分支
    //   预测失败）。它就是下面那根内部网的直通，纯观察，不参与任何逻辑。
    //   为什么需要：板上只看 dnpc_flag 分不清"重定向是异常/系统指令引起的"还是"分支预测
    //   失败引起的"—— 前者意味着程序跑飞，后者是流水线正常行为，两者判读完全相反。
    output logic        system_redirect_dbg
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
    // ★ v10 修复（C12）：load / store 非对齐必须按**指令的 opcode** 区分，不能只看 funct3。
    //   原因：`lw` 和 `sw` 的 funct3 都是 010，`lh` 和 `sh` 都是 001 —— funct3 里根本
    //   没有"这是读还是写"的信息。原实现靠 `funct3[2]`（只有 lbu/lhu 是 1xx）猜，
    //   于是 lw 非对齐被判成 **store** 非对齐（mcause 报 6，应为 4）。
    //   实测 exc_misalign：`lw` at 0x24 的 mcause 报 6，测试期望 4。
    //   出错指令编码本来就在手（fault_inst = IDU_inst_d，与异常标志同拍锁存），
    //   直接看 opcode[6:0] 即可，既准确又不需要新增端口。
    logic fault_is_store;
    assign fault_is_store = (EXU_fault_inst[6:0] == `S_opcode);
    assign exc_load_mis  = EXU_mem_misalign_exc & ~fault_is_store;
    assign exc_store_mis = EXU_mem_misalign_exc &  fault_is_store;
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
    // ★ v10 修复（C9）：分支的"出错地址"必须是**跳转目标**，不是 Ex_result。
    //   对 jal/jalr，Ex_result 就是目标地址；但对条件分支，Ex_result 是**比较结果**
    //   （bit0 为方向），拿它写 mtval 会把 0/1 当成地址 —— 只在条件分支目标非对齐时
    //   才暴露。actual_target 正好是 `jump_flag ? Ex_result : branch_pc`，即真实目标。
    //   对 load/store，Ex_result 仍是有效地址，保持不变。
    assign fault_inst = EXU_fault_inst;
    assign fault_addr = (branch_flag | jump_flag) ? actual_target : Ex_result;
    // ★ v10 新增（C9）：mepc 用的"出错指令 PC"。异常是在 **EX 级**判出来的，而 CSR 的
    //   pc 端口接的是**译码级**PC —— 两者差两条指令。原来直接用译码级 PC 写 mepc，
    //   实测 exc_illegal：出错指令在 0x1c，写进 mepc 的却是 0x20，mret 直接跑飞。
    assign fault_pc   = EXU_pc;
    // 在异常指令位于 EX 级的那一拍认定一次异常。★ v10：去掉了原来的
    //   `& ~trap_take_q_r` 去重寄存器 —— EXU 在 trap_take 那一拍就把异常标志清掉
    //   （EXU.sv 的 `if (reset | trap_take)`），所以 exc_pending 天然只有一拍宽。
    assign trap_take = exc_pending;
    // 重定向脉冲：与 bp_mispredict 同语义的**单拍**命令（v10：不再有补发拍）
    assign trap_redirect = trap_take;

    logic bp_misp_det;                       // 判定条件为真（不受 mem_stall 影响）
    // ★ 不变量：误预测判定必须排除 intr_take|trap_redirect（这两个源各自会清掉 EX 级
    //   那条指令并给出自己的有效 dnpc，不排除就会同拍抢 dnpc_flag：脉冲发了、PC
    //   却按另一个源走），且**只能被推后、不能被丢弃**（原实现把判定压成 0，误预测永远没人
    //   处理）。§CONTROL-2/§CONTROL-3
    //   注意 bp_hold_exu 里必须含当拍的 bp_misp_det：挂起标志要到判定那一拍的时钟沿才置位，
    //   只送挂起标志会晚一拍，挡不住正好在判定拍进入 EX 的那条错路径指令（B7）。
    //
    // ★★ v12（C）修复（v12-BUG-1）：原来的屏蔽项里还有 **system_redirect**，那是**错的**。
    //   `system_redirect = mret_flag | ecall_flag | fence_i_flag | trap_redirect` 里前三个
    //   都是 **IDU（译码级）** 的译码标志 —— 属于**更年轻**的指令，它们既不产生自己的
    //   分支判定，也**不会**清掉 EX 级那条（EXU_inst_clear 里没有这三个）。
    //   把它们并进屏蔽项，就变成"更年轻的 mret 把更老的分支的误预测**吞掉**"。
    //
    //   实测（sim/brsel_h.hex，中断处理程序里）：
    //     0x31c  bne x24, x0, hx      ← EX 级，实际 not-taken
    //     0x320  addi x6, x6, 1       ← 正确路径（永远没执行）
    //     0x324  mret                 ← 预测 taken 取来的是它
    //   抓到的现场（cyc=100022）：
    //     EXU_pc=0x31c（bne 在 EX）· IDU_pc=0x324（mret 在译码 → sysred=1）
    //     → bp_misp_det 被 sysred 屏蔽成 0 → 没有重定向 → 直接执行了 mret，
    //     0x320 被永久跳过。handler 每进一次就丢一条指令，而且**不报错**。
    //   优先级链本来就已经是 intr_take > trap_redirect > bp_mispredict > system_redirect
    //   （见下面 dnpc 的三元链），所以"老的分支先重定向、mret 之后重新取"是正确语义 ——
    //   屏蔽项里不需要 system_redirect。
    assign bp_misp_det = EXU_ctrl_valid & ~(intr_take | trap_redirect) &
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
    //
    // ★★ v13.2（P0）修复：**系统指令必须"确实会提交"才算数**。
    //   为什么：ecall/mret 的 CSR 副作用（mstatus/mepc/mcause）在 ID 级组合提交，
    //   而 ecall_flag/mret_flag 是纯译码电平 —— 只要那条指令还在 ID 就恒为 1。
    //   于是两种情况下它"错路径也生效"：
    //     ① 更老的误预测分支在 EX 同拍成立 → dnpc 按优先级取 bp_redir_target、
    //        并 flush 掉 ID；那条 ecall 被冲掉了，却已经把 mstatus 改了；
    //     ② ID 被下游压住（!IDU_ready，load-use / mem_stall / MDU）→ 同一拍里
    //        每个周期都提交一次（原来的 8 拍 trap_blank 只是把窗口缩小）。
    //   实测（FreeRTOS 空闲任务的 taskYIELD，pc=0x2d8，docs/CHECKPOINT_v13.md §7）：
    //   同一条 ecall 提交三次 → mstatus 0x1888 → 0x1880 → 0x1800，
    //   MPIE 被写成 0，mret 之后 MIE 永久为 0，tick 只来一次。
    //   修法：ecall/mret 的"提交许可"= ID 级有指令 且 被接收 且 本拍没有更老的重定向。
    //   重定向本身也用同一个许可（否则"提交了但重定向被丢"又会重复提交）。
    //   ★ 不变量：许可里三项都不许删；fence.i 不在此列（它来自 EX，天然不年轻）。
    assign sys_commit_ok = IDU_valid & IDU_ready
                         & ~(intr_take | trap_redirect | bp_mispredict);

    assign system_redirect = ((mret_flag | ecall_flag) & sys_commit_ok)
                           | fence_i_flag | trap_redirect;

    // v12（B）：观察口直通（纯 assign，无逻辑，不改变原有行为）
    assign system_redirect_dbg = system_redirect;

    // 中断接收判定（精确中断）：只在执行级没有会重定向的分支/跳转/fence、当前译码指令不是
    //   ecall/mret、且没有 load-use/MDU 停顿时才接受，保证 mepc 指向真正被中断的指令；入口
    //   固定为 mtvec。★ 不变量：intr_safe 的每一项都不许删（IDU_valid=确实有指令可记为 mepc；
    //   ~(branch|jump|fence_i)=让改 PC 的指令先走完；~mret/~ecall=系统指令不插队；~IFU_stall=
    //   译码级那条还没被接收；~mdu_busy=MDU 迭代期 EX 级一直占着）。
    // ★ v10 修复（C8）：补上 ~trap_redirect。原来漏了它，于是"同步异常"与"中断"可以同拍
    //   成立：trap_take 让 CSR 登记 mcause=异常码/mepc=异常指令，而 dnpc_flag 的仲裁优先级
    //   intr_take > trap_redirect 又把 PC 送去了 mtvec —— 两者目标恰好相同（都是 mtvec），
    //   所以现象不是跑飞，而是 **mepc 被中断覆盖成错的 PC**（mret 回不到出错指令），
    //   或者 mepc 被同拍写两次（CSR 里两个写使能同时置位，结果取决于书写顺序）。
    //   这类"目标相同、现场被踩"的 bug 没有报错，只有异常嵌套时才暴露。
    logic intr_safe;
    assign intr_safe = IDU_valid
                     & ~(branch_flag | jump_flag | fence_i_flag)
                     & ~mret_flag & ~ecall_flag & ~IFU_stall & ~mdu_busy
                     & ~trap_redirect;
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

    /* ---- v10 新增（C10）：CSR 写影子流水 + mret 目标前递 ------------------- */
    // 问题：CSR 写是**精确提交**的（走到 WB 级才落寄存器），而 `mret` 在**译码级**就必须
    //   读出 mepc 去改 PC —— 两者相隔 5 级，中间没有任何前递。于是
    //       csrw mepc, x21        ; handler 把 mepc 改成"出错指令+4"
    //       mret                  ; 紧隔一条
    //   里 mret 读到的是**旧** mepc。实测 exc_illegal：handler 明明写好了 0x20，
    //   mret 还是回到 0x1c 的非法指令 → 无限陷入（23 次 / 400 拍）。
    // 方案：把 EX 级的 CSR 写事件（地址位图 + 写数据）打一条 4 深影子链，在译码级前递：
    //     sh[0]=M1  sh[1]=M2  sh[2]=M3  sh[3]=WB
    //   写数据在流水里就是各级的 Ex_result（csrrw -> rs1+0；csrrs -> csrs|rs1），
    //   所以不需要新数据通路，只要位图 + 一份延迟副本。深度 4 正好覆盖到 WB 那一拍，
    //   之后寄存器已经落盘（mepc_out 本身就对），不必再前递。
    // ★ 不变量：只在 `EXU_valid & ~EXU_inst_clear` 那拍吸收 —— 被冲刷的指令不会真的写
    //   CSR，吸进来就会前递一份"根本没发生"的写。
    localparam CSRF_D = 4;
    logic [15:0] csrwen_sh [0:CSRF_D-1];
    logic [31:0] csrval_sh [0:CSRF_D-1];
    // ★ 不变量：**EX 级本身也要参与前递**（这是距离 1 的那一档：mret 在译码级时，
    //   它前面那条 csrw 正好就在 EX 级）。影子链 sh[0] 是"上一拍在 EX 的那条"，
    //   也就是这一拍在 M1 的那条 —— 只前递影子链会漏掉最近的这一档。
    logic [15:0] csrwen_now;
    assign csrwen_now = (EXU_valid & ~EXU_inst_clear) ? EXU_csr_wen : 16'b0;

    // ★ v10.3：影子链里必须存**掩码后**的写值，而不是 ALU 原始结果 Ex_result。
    //   Ex_result 是"ALU 算出来的新值"，而寄存器落盘时还要过一遍 WARL 写掩码
    //   （mip 只有 MSIP 可写、mstatus 的 MPP 恒 3、mtvec/mepc 低 2 位恒 0 …）。
    //   若链里存原始值，"csrw 紧跟 csrr"（走前递）与"隔几条再 csrr"（读寄存器）
    //   会对同一个 CSR 给出两个不同的答案 —— v10.3 加掩码时就是这么暴露的：
    //   `csrw mip,0xFFFFFFFF` 紧跟 `csrr x18,mip` 读回 0xFFFFFFFF，寄存器里却只有 1。
    //   掩码与强制位取自 para.sv 的 `CSR_WMASK_* / `CSR_FORCE_*，与 CSR.sv 共用同一组宏，
    //   ★ 不变量：这两个宏在 CSR.sv 与这里必须成对使用，改一处必须改两处。
    logic [31:0] fwd_wmask;
    logic [31:0] fwd_force;
    logic [31:0] csrval_now;
    always_comb begin
        fwd_wmask = `CSR_WMASK_ALL;
        fwd_force = 32'b0;
        if (csrwen_now[`CSRW_MIP])      fwd_wmask = `CSR_WMASK_MIP;
        if (csrwen_now[`CSRW_MIE])      fwd_wmask = `CSR_WMASK_MIE;
        if (csrwen_now[`CSRW_MTVEC])    fwd_wmask = `CSR_WMASK_MTVEC;
        if (csrwen_now[`CSRW_MEPC])     fwd_wmask = `CSR_WMASK_MEPC;
        if (csrwen_now[`CSRW_MSTATUS]) begin
            fwd_wmask = `CSR_WMASK_MSTATUS;
            fwd_force = `CSR_FORCE_MSTATUS;
        end
    end
    assign csrval_now = (Ex_result & fwd_wmask) | fwd_force;

    integer ci;
    always_ff @(posedge clock) begin
        if (reset) begin
            for (ci = 0; ci < CSRF_D; ci = ci + 1) begin
                csrwen_sh[ci] <= 16'b0;
                csrval_sh[ci] <= 32'b0;
            end
        end else begin
            csrwen_sh[0] <= csrwen_now;
            csrval_sh[0] <= csrval_now;
            for (ci = 1; ci < CSRF_D; ci = ci + 1) begin
                csrwen_sh[ci] <= csrwen_sh[ci-1];
                csrval_sh[ci] <= csrval_sh[ci-1];
            end
        end
    end

    // mepc 的前递读：从最老往最新覆盖，最后一次赋值生效 ⇒ **最新**的在途写优先
    //   优先级（新→旧）：EX 级（距离 1）> sh[0]=M1 > sh[1]=M2 > sh[2]=M3 > sh[3]=WB > 寄存器本体
    logic [31:0] mepc_fwd;
    integer cj;
    always_comb begin
        mepc_fwd = mepc_out;
        for (cj = CSRF_D-1; cj >= 0; cj = cj - 1)
            if (csrwen_sh[cj][`CSRW_MEPC]) mepc_fwd = csrval_sh[cj];
        if (csrwen_now[`CSRW_MEPC]) mepc_fwd = csrval_now;
    end

    /* ---- v10.2 新增：CSR 读口的通用 RAW 前递 ------------------------------
     * 上面那条链原本只服务 mret 读 mepc 这一个场景。同一份在途写信息可以服务**所有** CSR
     * 读：IDU 把"本拍要读哪个 CSR"的独热码（IDU_csr_sel）送过来，这里按
     * "EX 级 > sh[0..3] > 寄存器本体"的优先级挑出最新一次在途写的值。
     * ★ 不变量：命中判据是 `|(在途位图 & 读选通)`，用的是**写位图**而不是写使能标记
     *   （bit8）—— 纯读的 CSRR* 也带 bit8 标记位，用它判命中会把"读"当成"写"。
     * ★ 不变量：多档同时命中时**最新的赢**，与 mepc_fwd 的覆盖顺序严格一致（只改读值，
     *   不改变"写在哪一级落盘"的事实）。
     */
    logic csr_hit_now;
    logic [CSRF_D-1:0] csr_hit_sh;
    assign csr_hit_now = |(csrwen_now   & IDU_csr_sel);
    assign csr_hit_sh[0] = |(csrwen_sh[0] & IDU_csr_sel);
    assign csr_hit_sh[1] = |(csrwen_sh[1] & IDU_csr_sel);
    assign csr_hit_sh[2] = |(csrwen_sh[2] & IDU_csr_sel);
    assign csr_hit_sh[3] = |(csrwen_sh[3] & IDU_csr_sel);

    integer ck;
    always_comb begin
        csr_rd_fwd    = 32'b0;
        csr_rd_fwd_en = 1'b0;
        for (ck = CSRF_D-1; ck >= 0; ck = ck - 1)
            if (csr_hit_sh[ck]) begin
                csr_rd_fwd    = csrval_sh[ck];
                csr_rd_fwd_en = 1'b1;
            end
        if (csr_hit_now) begin
            csr_rd_fwd    = csrval_now;
            csr_rd_fwd_en = 1'b1;
        end
    end
    // mdu_busy 并入前端暂停。★ 不变量：它只能进 IFU_stall，不能进上面 load-use 项（否则
    //   打断 M 自己的向后 valid，乘除结果直接丢失）。
    assign IFU_stall      = load_use_stall | mdu_busy;


    assign icache_clr = fence_i_flag & EXU_valid;


    // dnpc 统一承载控制流重定向（来源与 dnpc_flag 的优先级一一对应）：中断取 mtvec_out；
    //   误预测取 bp_redir_target（不跳转回退 pc+4，挂起时优先 bp_pend_target）；
    //   **fence.i 取自己的 PC+4**（v10.2 修复，见下）；mret 取 mepc（前递后的 mepc_fwd，
    //   见上面 C10），ecall/同步异常入口取 mtvec_out。
    //   ★ 不变量：这条链的顺序必须与 dnpc_flag 的或项顺序一致，否则"请求来自 A、目标取自 B"。
    //   ★ v10.2 修复：fence.i 原来落到最后那个 `mtvec_out` 分支 —— 于是 `fence.i` 不是
    //     "清 I-Cache 后继续往下执行"，而是**跳进异常处理程序**（mtvec 默认为 0 → 整机
    //     重启）。程序中只要出现一条 fence.i，后面的代码就永远跑不到。fence.i 的语义是
    //     "顺序继续"，目标必须是它自己后面的那条指令；fence_i_flag 来自 EX 级
    //     （EXU_fence_i_flag），EXU_pc 正是这条 fence.i 的 PC。
    //     排序上它必须排在 bp_mispredict 之后（挂起的误预测先来先服务）、并且独立于
    //     mret_flag（两者分属 EX/ID 级，不可能同拍）。
    assign dnpc = intr_take      ? mtvec_out
                : bp_mispredict  ? bp_redir_target
                : fence_i_flag   ? (EXU_pc + 32'd4)
                : (mret_flag     ? mepc_fwd : mtvec_out);



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
    .MEM_m1_ok      (MEM_m1_ok),
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
