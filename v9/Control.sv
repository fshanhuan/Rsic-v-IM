// Control 负责三件事：
// 1. 收束所有会改写 PC 的事件，生成 dnpc/dnpc_flag。
// 2. 识别 load-use 冒险，决定是否暂停 IFU/IDU 并清空执行级。
// 3. 根据 Data_hazard 的编码真正完成前递值选择。
module Control (
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
    output logic  bp_hold_exu
);


    logic [2:0] IDU_rs1_choice;
    logic [2:0] IDU_rs2_choice;



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

    logic bp_misp_det;                       // 判定条件为真（不受 mem_stall 影响）
    assign bp_misp_det = EXU_ctrl_valid & ~(intr_take | system_redirect) &
                         ((actual_taken != EXU_pred_taken) ||
                          (actual_taken && (actual_target != EXU_pred_target)));

    logic        bp_misp_pend;               // 判定被 hold 挡住，等待补发
    logic        bp_pend_taken;              // 挂起时的实际方向
    logic [31:0] bp_pend_target;             // 挂起时的实际目标（含“不跳则 pc+4”）
    logic        bp_mispredict_raw;          // 判定存在（尚未去抖/去重），见下

    // 补发脉冲：hold 结束后（~mem_stall）本拍可发；否则先挂起。
    assign bp_mispredict_raw = (bp_misp_det | bp_misp_pend) & ~mem_stall;

    // 本拍重定向用的方向/目标：**挂起值优先**。
    //   挂起的是"更早、已经确认但没能送达 IFU"的那次误预测，必须先补发它；
    //   否则会出现：hold 拍挂起了 jal(0xd4)→0x110，下一拍落在错路径上的
    //   jal(0xd8)→0x128 也被判为误预测并抢走重定向（实测 rnd034）。
    logic        bp_redir_taken;
    logic [31:0] bp_redir_target;
    assign bp_redir_taken  = bp_misp_pend ? bp_pend_taken  : actual_taken;
    assign bp_redir_target = bp_misp_pend ? bp_pend_target
                          : (actual_taken ? actual_target : (EXU_pc + 32'd4));

    always_ff @(posedge clock) begin
        if (reset) begin
            bp_misp_pend   <= 1'b0;
            bp_pend_taken  <= 1'b0;
            bp_pend_target <= 32'b0;
        end else if (bp_mispredict) begin
            bp_misp_pend   <= 1'b0;          // 已经补发出去
        end else if (bp_misp_det & ~bp_misp_pend) begin
            // 本拍没能发（否则上一个分支已清）→ 挂起。
            // 已有挂起值时不再覆盖：先来先服务，保证不丢任何一次确认的重定向。
            bp_misp_pend   <= 1'b1;
            bp_pend_taken  <= actual_taken;
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
    assign system_redirect = mret_flag | ecall_flag | fence_i_flag;

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

    assign dnpc_flag      = intr_take | bp_mispredict | system_redirect;
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
    assign EXU_inst_clear = intr_take | bp_mispredict
                          | (mem_stall & ~(branch_flag | jump_flag))
                          | load_use_stall;
    logic exu_load_use;
    logic mem_load_use;
    logic pipe_load_use;
    // load-use 冒险判定必须与 Data_hazard 的前递仲裁**保持同一口径**：
    //   某一级只有在“数据真的可前递”时才算解决冒险，否则要把 IDU 按停。
    //   原来的 exu_load_use 无条件把“EXU 里是 load”当停顿，而 Data_hazard 的
    //   exu_hit 又无条件优先取 EXU，两边口径不一致：消费者会被放行到 EXU，
    //   却从 EXU 拿到了 load 的**旧值/地址**（实测：lw 后紧跟的 add 得到基址）。
    //   现在改成：
    //     - EXU 里是 load      -> 数据不可用，必须停（exu_load_use）
    //     - MEM 里是 load      -> 数据不可用，必须停（mem_load_use）
    //     - MEM_PIPE 里是 load -> 数据不可用，必须停（pipe_load_use）
    //     其余情况数据已就绪，由前递直接给值，不再停。
    //   停顿长度因此自然覆盖到 load 数据可用的那一刻：数据可用的下一拍
    //   三个条件全为 0，消费者被放行并拿到正确的前递值。
    // 三级的“是不是 load 且 rd 与 IDU 的源寄存器相同”判定**不能**再乘 IDU_valid：
    // IDU 在被 stall 的那一拍会把 valid_next 拉低（向下游灌气泡），如果这里要求
    // IDU_valid=1，暂停条件会在同一拍自己消失，消费者被提前放出去。
    // 不用 IDU_valid 也不会误判：IDU 空时 inst_d 是 NOP（rs1=rs2=0），而这里都要求
    // rd != 0，NOP 永远匹配不上；被冻结的 inst_d 保留的正是那条等待中的指令的源寄存器。
    assign exu_load_use  = EXU_mem_ren && (((EXU_rd == IDU_rs1) || (EXU_rd == IDU_rs2)) && (EXU_rd != 0));
    assign mem_load_use  = MEM_mem_ren && MEM_valid && (((MEM_rd == IDU_rs1) || (MEM_rd == IDU_rs2)) && (MEM_rd != 0));
    assign pipe_load_use = MEM_PIPE_mem_ren && MEM_PIPE_valid && (((MEM_PIPE_rd == IDU_rs1) || (MEM_PIPE_rd == IDU_rs2)) && (MEM_PIPE_rd != 0));
    // 三级之后（MEM2 = LSU 第三级）load 数据已经在 LSU_forward_val_wb 里了，
    // 由 Data_hazard 的 3'b011 编码直接前递，不再需要暂停。
    // mdu_busy 也并入前端暂停：MDU 迭代期间 EX 级一直占着那条 M 指令，
    // 前端必须停住，否则会把后续指令推进来覆盖它。
    // 两路暂停信号：
    //   load_use_stall —— 只含 load-use 冒险（供 EXU 的冲刷判定，见下）
    //   IFU_stall      —— 前端总暂停：再并入 mdu_busy，供 IFU 冻结 PC/取指使用
    assign load_use_stall = exu_load_use | mem_load_use | pipe_load_use;
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


// Data_hazard 只产生选择编码，Control 再结合实际数据源输出最终前递结果。
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
    .IDU_rs2_choice (IDU_rs2_choice)
);

endmodule        //PC_Control
