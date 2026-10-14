`timescale 1ns / 1ps
`include "para.sv"

// 取指级只做一件事：维护当前 PC，并在顺序执行、暂停、重定向之间切换。
//
// v9 上板改造（取指契约修正）：
//   - valid 过去恒为 1，停拍期间取回的指令可能被后级误当成有效指令接纳。
//     现在 valid 只在“本拍 irom_data 确实是当前 pc 的取指数据”时为 1，
//     即 inst_valid(& ICache.fetch_align) & ~stall；停拍/未对齐的那一拍
//     向 IDU 灌一个泡（valid=0）。这正是同步 BRAM 取指所要求的握手。
//   - inst 在 valid=0 时输出 para.sv 的 `NOP，避免 IDU 看到无效取指数据。
//   - PC 只在“返回结果属于当前 PC”时才推进（advance_en），否则 PC 会跑到
//     取指数据前面，让 IDU 收到「下一条地址 + 上一条指令」的错配组合。
//   - PC 更新里把 dnpc_flag（真实重定向）放在最前：重定向是控制面已经确认
//     的事实，不能因为同一拍存储侧的暂停请求而丢掉；这一拍 valid 已是 0，
//     被取回的那条指令不会被执行。
//
// v9 新增分支预测：
//   - dnpc_flag 是执行级确认的真实重定向（优先级最高）；
//   - pred_taken/pred_target 是预测器给出的“投机跳转”；
//   - 两者都没有时才顺序取 pc+4。
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
    assign inst  = valid ? irom_data : `NOP;

    // 取指契约（上板改造修正）：valid 必须与取指数据同拍，但不能组合直通。
    //   同步 BRAM 的取指是“请求/响应”两拍交替的（见 ICache.sv）：hold=1 的那拍数据
    //   不可用，命中那一拍 hold=0。原来门控用的是**又打了一拍**的 mem_stall_r，
    //   与 inst_valid 错相，实测 valid=1 的拍恰好都撞在 stall=1 上，前端一条指令都
    //   交付不出去（表现为第一次重定向后 EXU_valid / LSU_valid 恒 0）。
    //   这里改成当拍判定：
    //     valid <= inst_valid & ~mem_stall   （ICache 未命中时返回 `NOP 且 hold=1，
    //   所以该式等价于“本拍命中并交付”）。PC 冻结由 stall 负责，与 valid 无关。
    always_ff @(posedge clock) begin
        if (reset)
            valid <= 1'b0;
        else
            valid <= inst_valid & ~mem_stall;
    end

    // 只有“返回结果确实属于当前 PC”（inst_valid = ICache.fetch_align）时，
    // 才允许推进 PC：否则 PC 会跑到取指数据前面，使 IDU 收到
    // 「下一条地址 + 上一条指令」的错配组合。
    logic advance_en;
    logic pred_take_en;
    assign advance_en  = valid & ready & inst_valid;
    // v9 修复（B4）：**预测跳转必须与顺序推进用同一个“本拍确实接收了这条指令”条件**。
    //   原式 `pred_taken & inst_valid` 少了 valid/ready/~stall：当前这条指令还没被 IDU
    //   锁存（停拍 / valid=0）时就把 PC 拨到预测目标，这条指令（很可能正是一条分支）
    //   就被**丢掉**了 —— 它本该做出的"预测对不对"的判定再也没人做。
    //   预测器一旦学会 taken，于是每次撞上取指 hold 就少判一条分支，循环彻底失控
    //   （实测 loop_min 的 x1 涨到 2491，应为 10；同一程序在自带测试台上逐位复现）。
    //   现在：只有这一拍确实交付并接收了指令，才允许投机拨 PC；否则保持 PC，
    //   等这条指令被接收后再拨（或由 EX 级的真实重定向接管）。
    assign pred_take_en = pred_taken & advance_en & ~stall;

    // PC 更新优先级：
    //   reset > dnpc 真实重定向 > 预测跳转 > stall 保持 > 顺序加 4。
    // v9 修复（B4/B7）：真实重定向**不能**再用 inst_valid 门控。
    //   inst_valid（ICache.fetch_align）表示"本拍取回的数据确实属于当前 PC"——
    //   而重定向本来就是**放弃**当前这次取指、把 PC 拨到确定的目标，与当前取指数据
    //   是否对齐无关。原来要求 inst_valid，于是当重定向恰好落在取指 hold / 未对齐拍
    //   （fetch_align=0）时会被**丢掉**：实测 `jal x2,T` 已经算出并写回了 link，
    //   却发现下一条执行的是 pc+4（顺序路径）而不是 T；分支同理，方向被判对但
    //   重定向没生效，CPU 一路沿错路径提交。
    //   只保留 ready（下游可接收的结构性背压），dnpc/dnpc_flag 是控制面已确认的事实。
    always_ff @(posedge clock) begin
        if (reset)
            pc <= ResetValue;
        else if (dnpc_flag & ready)
            pc <= dnpc;
        else if (pred_take_en & ready)
            pc <= pred_target;
        else if (stall & valid & ready)
            pc <= pc;
        else if (advance_en)
            pc <= snpc;
    end

endmodule
