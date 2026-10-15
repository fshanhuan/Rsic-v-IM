`timescale 1ns / 1ps
`include "para.sv"

/* =============================================================================
 * IFU.sv — 取指级：只做一件事，维护当前 PC，并在顺序执行、暂停、重定向之间切换
 * -----------------------------------------------------------------------------
 * 上游：ICache.sv（irom_data / inst_valid=fetch_align / mem_stall=hold）、
 *       Control.sv（dnpc / dnpc_flag / stall / ready）与分支预测器（pred_taken）。
 * 下游：IDU（inst / snpc / valid）。ICache 若未命中，IFU 灌 `NOP 泡并停拍。
 *
 * ★ 接口契约（改之前必读）：
 *   - valid 必须与取指数据**同拍**，但不能组合直通（要寄存一拍）。
 *   - inst 在 valid=0 时输出 `NOP。
 *   - PC 只在“返回结果属于当前 PC”时才推进（advance_en）。
 *   - ready = 下游这一拍能否**接收**一条新指令；stall = 背压（含 ICache.hold）。
 *
 * ★ 不许改回去的地方（细节与实测证据见 syn/修复史_全量.md）：
 *   - 真实重定向既不看 inst_valid，也不看 ready      → §IFU-1（B4/B7/B9 三次）
 *   - pred_take_en 必须复用 advance_en（含 ~stall）  → §IFU-1（B4）
 *   - valid 必须同拍、不能组合直通                   → §IFU-1（原 mem_stall_r 错相）
 *
 * 参考：docs/模块阅读文档.md、syn/修复史_全量.md
 * ============================================================================= */
module IFU (
    input               clock,
    input               reset,
    input       [31:0]  dnpc,
    input               dnpc_flag,
    input       [31:0]  irom_data,
    input               stall,
    input               mem_stall,
    input               inst_valid,
    input               pred_taken,
    input       [31:0]  pred_target,

    output      [31:0]  snpc,
    output logic [31:0] pc,
    output      [31:0]  inst,

    input               ready,
    output logic        valid
);

    localparam ResetValue = 32'h0;

    assign snpc  = pc + 4;
    assign inst  = valid ? irom_data : `NOP;   // valid=0 的拍必须灌 NOP：
                                               // 否则 IDU 会把停拍/未对齐拍取回的
                                               // 无效数据当成一条真指令

    // ★ 不变量：valid 必须与取指数据**同拍**，但不能组合直通（要寄存一拍）。
    //   原因：同步 BRAM 取指是“请求/响应”两拍交替（见 ICache.sv）——hold=1 的那拍
    //   数据不可用。所以 valid 要按**当拍**的 inst_valid/mem_stall 判定：
    //     valid <= inst_valid & ~mem_stall
    //   （ICache 未命中时返回 `NOP 且 hold=1，所以该式等价于“本拍命中并交付”）。
    //   曾经门控用的是**又打了一拍**的 mem_stall_r，它与 inst_valid 错相，导致
    //   valid=1 的拍恰好都撞在 stall=1 上，前端一条指令都交付不出去。
    //   注意：PC 冻结由 stall 负责，与 valid 无关。
    always_ff @(posedge clock) begin
        if (reset)
            valid <= 1'b0;
        else
            valid <= inst_valid & ~mem_stall;
    end

    // ★ 不变量：PC 只在“返回结果确实属于当前 PC”（inst_valid = ICache.fetch_align）
    //   时才允许推进，否则 PC 会跑到取指数据前面，使 IDU 收到
    //   「下一条地址 + 上一条指令」的错配组合。
    logic advance_en;
    logic pred_take_en;
    assign advance_en  = valid & ready & inst_valid;
    // ★ 不变量：预测跳转必须与顺序推进用同一个“本拍确实接收了这条指令”条件，
    //   即 pred_take_en 复用 advance_en，别把 valid/ready/~stall 省掉。
    //   原因：当前这条指令还没被 IDU 锁存（停拍 / valid=0）时就把 PC 拨到预测目标，
    //   这条指令（很可能正是一条分支）就被丢掉 —— 它本该做出的“预测对不对”的判定
    //   再也没人做；预测器一旦学会 taken，每次撞上取指 hold 就少判一条分支，
    //   循环彻底失控（实测 loop_min 的 x1 涨到 2491，应为 10）。
    //   踩坑史（B4，同一程序在自带测试台上逐位复现）：见 syn/修复史_全量.md §IFU-1
    assign pred_take_en = pred_taken & advance_en & ~stall;

    // PC 更新优先级：reset > dnpc 真实重定向 > 预测跳转 > stall 保持 > 顺序加 4。
    // ★ 不变量：真实重定向既不看 inst_valid，也不看 ready —— 别加回任何一个。
    //   原因：重定向的语义是“放弃当前取指、把 PC 拨到确定目标”（dnpc_flag 同时就是
    //   IDU 的 flush），而 inst_valid/ready 描述的都是“当前这条取指能不能被接收” ——
    //   用它们门控重定向是因果颠倒。且 ecall/mret/fence.i 的 dnpc_flag **只有一拍宽**，
    //   被吃掉不会重发（Control 里只有分支误预测建了挂起重发）。
    //   踩坑史（B4/B7/B9 三次，含上板 ILA 逐拍证据）：见 syn/修复史_全量.md §IFU-1
    always_ff @(posedge clock) begin
        if (reset)
            pc <= ResetValue;
        else if (dnpc_flag)
            pc <= dnpc;
        else if (pred_take_en & ready)
            pc <= pred_target;
        else if (stall & valid & ready)
            pc <= pc;
        else if (advance_en)
            pc <= snpc;
    end

endmodule
