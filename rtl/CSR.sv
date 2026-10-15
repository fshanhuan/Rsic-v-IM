`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * CSR.sv — 机器模式控制状态寄存器 + 中断判决（v9）· Reg_Stack 的子块
 * -----------------------------------------------------------------------------
 * 上游 ID 级给 ecall/mret/intr_take/trap_take，下游 Reg_Stack 的 csrs 读多路选择。
 * 寄存器：mstatus · mie · mip · mtvec · mepc · mcause · mscratch · mtval ·
 *   mvendorid/marchid(常量) · mtime/mtimecmp(教学定时器 0x7C0/0x7C1)。
 * 陷入入口都是 mtvec（PC 重定向在 Control 中）；中断优先级 MEI(11)>MSI(0)>MTI(7)。
 *
 * ★ 接口契约（改之前必读）：
 *   - 陷入/返回的 CSR 更新都在**译码级**那一拍完成（ecall/mret/intr_take/trap_take
 *     都由 ID 级发起），软件 CSR 写（csr_wen/csrd）在 WB 级生效；两者分离，
 *     同拍相撞时陷入优先 —— 见各 always_ff 里 if 链的顺序。
 *   - RESET_VAL 只给 mepc/mcause/mtvec/mscratch/mtval 用；mstatus/mie/mip 各有自己
 *     的复位常量，mtime/mtimecmp 不受它影响。
 *   - 是否真的在这拍接收中断由 Control 决定，本模块只报 intr_pending。
 *   - 各现场寄存器的写使能口径见下方 ★ 不变量（原编号 C4/C7 保留）。
 * =========================================================================== */
module CSR #(
    parameter CSR_WIDTH = 32,
    // 软件可见现场寄存器（mepc/mcause/mtvec/mscratch/mtval）的复位值
    parameter RESET_VAL = 0
) (
    input  logic        clock,
    input  logic        reset,

    input  logic [31:0] pc,          // 被陷入指令的 PC（译码级，写进 mepc）
    input  logic        ecall_flag,
    input  logic        mret_flag,
    input  logic        intr_take,   // Control 判定“本拍接收中断”

    // ---- v9 新增（C4）：统一异常通道 ----
    // ★ 不变量：trap_take / trap_take_q 是 Control 的“确认接收一次异常”单拍脉冲对
    //   （前者在异常指令位于 EX 级时拉高，后者下一拍照原补发）。凡“登记一次陷入”的
    //   条件（mstatus_wen / trap_commit / mepc_wen / mcause_wen / mtval_wen）都必须
    //   同时含这两根：只认 trap_take 会漏掉补发拍，只认 trap_take_q 会丢掉首拍。
    //   trap_cause 见 para.sv 的 `EXC_*，**必须独热**，由 exc_mcause/exc_mtval 翻译。
    //   细节：syn/修复史_全量.md §CSR-2
    input  logic        trap_take,
    input  logic        trap_take_q,
    input  logic [ 3:0] trap_cause,
    input  logic [31:0] fault_addr,  // 非对齐/非法目标地址（EX_result）
    input  logic [31:0] fault_inst,  // 非法指令的编码（IDU_inst）

    input  logic [31:0] csrd,        // 软件写入数据（WB 级生效）
    // csr_wen 位号 = `CSRW_*，对应 12 位地址 [0]MEPC341 [1]MCAUSE342 [2]MSTATUS300
    //   [3]MTVEC305 [4]MIE304 [5]MIP344 [6]MSCRATCH340 [7]MTIMECMP7c1，[15:8] 未使用
    //   —— **没有 mtval 的写位**（理由见 mtval_wen 一节）
    input  logic [15:0] csr_wen,

    // 读出并到 Reg_Stack 的 csrs 多路选择（软件 csrr* 的返回口），mvendorid/marchid
    //   是常量。只有 mepc/mtvec/mcause/mtval 被 IDU 继续引到 myCPU 的 debug 端口
    //   （顶层/ILA 可观察）；mstatus/mie/mip/mscratch/mtime/mtimecmp 在 IDU 里悬空。
    output logic [31:0] mvendorid_out,
    output logic [31:0] marchid_out,
    output logic [31:0] mepc_out,
    output logic [31:0] mcause_out,
    output logic [31:0] mstatus_out,
    output logic [31:0] mtvec_out,
    output logic [31:0] mie_out,
    output logic [31:0] mip_out,
    output logic [31:0] mscratch_out,
    output logic [31:0] mtime_out,
    output logic [31:0] mtimecmp_out,
    // v9 新增（C4）：mtval 引出（非法指令编码 / 非对齐地址）
    output logic [31:0] mtval_out,

    output logic        intr_pending // = mstatus.MIE & |(mie & mip)
);

    /* ----------------------------- 常量 ID ------------------------------- */
    assign mvendorid_out = 32'h79737978;   // "ysyx"，教学标识；下面 marchid 为示例值，两者只读
    assign marchid_out   = 32'h16FBCBD;

    /* --------------------------- mtime / mtimecmp ------------------------ */
    // ★ 不变量：mtime 是**按 `MTIME_DIV_DEFAULT 分频的递增计数器**，不是“每拍 +1”的
    //   拍计数器（原 C7）。100MHz 下每拍 +1 会让它比真实时间快约 1000 万倍，拿它算
    //   时间/延时没有意义；分频后（默认 100）相当于 1MHz，即每 1us 加 1，置 1 则退回
    //   旧的“每拍 +1”（回归脚本依赖该口径）。代价只有 log2(DIV) 个触发器。
    //   细节：syn/修复史_全量.md §CSR-1
    logic [31:0] mtime_reg;
    logic [31:0] mtime_divcnt;
    logic        mtime_tick;
    always_comb begin
        if (`MTIME_DIV_DEFAULT <= 1) mtime_tick = 1'b1;
        else                         mtime_tick = (mtime_divcnt >= (`MTIME_DIV_DEFAULT - 1));
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            mtime_divcnt <= 32'b0;
            mtime_reg    <= 32'b0;
        end else if (mtime_tick) begin
            mtime_divcnt <= 32'b0;
            mtime_reg    <= mtime_reg + 32'd1;
        end else begin
            mtime_divcnt <= mtime_divcnt + 32'd1;
        end
    end

    logic [31:0] mtimecmp_reg;
    always_ff @(posedge clock) begin
        // mtimecmp 复位成全 1：上电后 mtime 追不上它，不会立刻冒出 MTIP 中断
        if (reset)                              mtimecmp_reg <= 32'hFFFF_FFFF;
        else if (csr_wen[`CSRW_MTIMECMP])        mtimecmp_reg <= csrd;
    end

    assign mtime_out    = mtime_reg;
    assign mtimecmp_out = mtimecmp_reg;

    /* ------------------------------ mie / mip ---------------------------- */
    logic [31:0] mie_reg;
    always_ff @(posedge clock) begin
        if (reset)                        mie_reg <= 32'b0;
        else if (csr_wen[`CSRW_MIE])      mie_reg <= csrd;
    end
    assign mie_out = mie_reg;

    logic [31:0] mip_sw_reg;              // 软件可写部分（MSIP）
    logic        mtip;                    // 定时器中断挂起（硬件）
    logic        meip;
    assign mtip = (mtime_reg >= mtimecmp_reg);  // 无符号比较：mtime 追平即挂起
    assign meip = 1'b0;                   // 预留外部中断输入

    always_ff @(posedge clock) begin
        if (reset)                        mip_sw_reg <= 32'b0;
        else if (csr_wen[`CSRW_MIP])      mip_sw_reg <= csrd & 32'h0000_0001; // 仅 MSIP 可写
    end

    assign mip_out = mip_sw_reg | (mtip ? (32'h1 << `IRQ_MTI) : 32'b0)
                                 | (meip ? (32'h1 << `IRQ_MEI) : 32'b0);

    /* ------------------------------ 中断判决 ----------------------------- */
    logic [31:0] pending;
    logic [ 3:0] intr_cause;
    assign pending    = mie_reg & mip_out;
    // 优先级：外部(11) > 软件(0) > 定时器(7) —— 这是 if/else 链的先后，换序即改语义。
    assign intr_cause = pending[`IRQ_MEI] ? 4'd11 :
                        pending[`IRQ_MSI] ? 4'd0  : 4'd7;
    /* ------------------------------ mstatus ------------------------------ */
    logic [31:0] mstatus_reg;
    logic [31:0] mstatus_nxt;
    logic        mstatus_wen;
    // ★ 不变量：mstatus_wen 必须含 trap_take | trap_take_q —— 同步异常（非法指令/非对齐
    //   访存）与中断/ecall/mret **一样**要改 mstatus（MPIE<=MIE、MIE<=0）。原来只有
    //   intr_take|ecall_flag|mret_flag，同步异常不关中断，语义是错的。§CSR-2
    assign mstatus_wen = csr_wen[`CSRW_MSTATUS] | intr_take | ecall_flag | mret_flag
                       | trap_take | trap_take_q;

    // 统一的"本拍在登记一次陷入"条件（中断/ecall/同步异常都算）
    logic trap_commit;
    assign trap_commit = intr_take | ecall_flag | trap_take | trap_take_q;

    always_comb begin
        if (trap_commit) begin
            // 陷入：MPIE(bit7) <= MIE(bit3)，MIE(bit3) <= 0，其余位原样保留
            mstatus_nxt = {mstatus_reg[31:8], mstatus_reg[`MSTATUS_MIE],
                           mstatus_reg[6:4], 1'b0, mstatus_reg[2:0]};
        end else if (mret_flag) begin
            // 返回：MIE <= MPIE，MPIE <= 1（同样是逐位拼接，不动别的位）
            mstatus_nxt = {mstatus_reg[31:8], 1'b1,
                           mstatus_reg[6:4], mstatus_reg[`MSTATUS_MPIE], mstatus_reg[2:0]};
        end else begin
            mstatus_nxt = csrd;   // 纯软件写：整字覆盖，不做位掩码
        end
    end

    always_ff @(posedge clock) begin
        if (reset)              mstatus_reg <= 32'h0000_1800;  // MPP=M
        else if (mstatus_wen)   mstatus_reg <= mstatus_nxt;
    end
    assign mstatus_out = mstatus_reg;
    assign intr_pending = mstatus_reg[`MSTATUS_MIE] & (|pending);  // 依赖 mstatus_reg，故在此处赋值

    /* -------------------------------- mepc ------------------------------- */
    // ★ 不变量：mepc_wen 必须与 trap_commit 同口径；trap_commit 为真时 mepc 写 pc
    //   （被陷入指令的 PC），否则写软件给的 csrd。使能少一根就丢一次异常现场。
    logic [31:0] mepc_reg;
    logic        mepc_wen;
    assign mepc_wen = csr_wen[`CSRW_MEPC] | intr_take | ecall_flag | trap_take | trap_take_q;
    always_ff @(posedge clock) begin
        if (reset)            mepc_reg <= RESET_VAL;
        else if (mepc_wen)    mepc_reg <= trap_commit ? pc : csrd;
    end
    assign mepc_out = mepc_reg;

    /* ------------------------------- mcause ------------------------------ */
    // v9 修复（C4）：原来 mcause 只认“中断/ecall”，非法指令与非对齐访存无处登记。
    // ★ 不变量：exc_mcause 的位序（bit3 指令地址非对齐优先）必须与 Control 的 trap_cause
    //   编码优先级一致；四路来源的顺序为 中断 > 同步异常 > ecall > 软件写（见下面 if 链）。
    //   细节：syn/修复史_全量.md §CSR-3
    logic [31:0] mcause_reg;
    logic        mcause_wen;
    logic [31:0] exc_mcause;
    always_comb begin
        // 优先级与 Control 的 trap_cause 编码保持一致
        exc_mcause = trap_cause[3] ? `MCAUSE_IADDR_MISALIGN   // bit3 指令地址非对齐 = 0
                   : trap_cause[0] ? `MCAUSE_ILLEGAL_INST      // bit0 非法指令        = 2
                   : trap_cause[1] ? `MCAUSE_LOAD_MISALIGN     // bit1 load 非对齐     = 4
                   : trap_cause[2] ? `MCAUSE_STORE_MISALIGN    // bit2 store 非对齐    = 6
                   : 32'd0;
    end
    assign mcause_wen = csr_wen[`CSRW_MCAUSE] | trap_commit;
    always_ff @(posedge clock) begin
        if (reset)            mcause_reg <= RESET_VAL;
        else if (mcause_wen) begin
            if (intr_take)              mcause_reg <= {1'b1, 27'b0, intr_cause};  // 中断
            else if (trap_take | trap_take_q) mcause_reg <= exc_mcause;           // 同步异常
            else if (ecall_flag)        mcause_reg <= `MCAUSE_ECALL_M;            // 环境调用
            else                        mcause_reg <= csrd;
        end
    end
    assign mcause_out = mcause_reg;

    /* -------------------------------- mtval ------------------------------ */
    // v9 修复（C4）：mtval_reg 原来是个**死寄存器**（只复位、从不写）。RISC-V 语义：
    //   非法指令 -> 出错指令编码；取指/访存非对齐 -> 出错的有效地址；中断/ecall -> 0。
    logic [31:0] mtval_reg;
    logic        mtval_wen;
    logic [31:0] exc_mtval;
    always_comb begin
        exc_mtval = trap_cause[0] ? fault_inst      // 非法指令：出错指令编码
                  : (trap_cause[3] | trap_cause[1] | trap_cause[2]) ? fault_addr  // 非对齐：出错地址
                  : 32'd0;
    end
    // ★ 不变量：mtval_wen = intr_take | trap_take | trap_take_q —— **必须含 trap_take_q**：
    //   trap_take 只覆盖“异常指令在 EX 级”那一拍，trap_take_q 是下一拍的补发确认，少了
    //   它就会出现“进了异常但 mtval 没写”。这里**没有 csr_wen 项**：位图里没有 mtval
    //   写位，软件写不进去，只能由硬件在陷入时填（原注释写“用一个自由位”，与代码不符，
    //   这里按代码口径改正）。细节：syn/修复史_全量.md §CSR-4
    assign mtval_wen = intr_take | trap_take | trap_take_q;
    always_ff @(posedge clock) begin
        if (reset)                 mtval_reg <= RESET_VAL;
        else if (mtval_wen) begin
            if (intr_take)         mtval_reg <= 32'd0;      // 中断：mtval 清零
            else                   mtval_reg <= exc_mtval;  // 同步异常：写指令或地址
        end
    end
    // ★ 不变量：这一行 assign mtval_out **不能删**（原 C4 遗留）—— 以前这里漏了 assign，
    //   mtval_out 成了无驱动的输出网，综合把 mtval_reg 当死寄存器优化掉，顶层
    //   debug_mtval 与 ILA probe11 恒 0，看着像“ILA 没接对”，其实是 RTL 漏驱动。
    //   综合告警原文：syn/修复史_全量.md §CSR-4
    assign mtval_out = mtval_reg;

    /* ------------------------------- mtvec ------------------------------- */
    // 陷入入口基址，纯软件寄存器（硬件只读不改）。
    logic [31:0] mtvec_reg;
    always_ff @(posedge clock) begin
        if (reset)                       mtvec_reg <= RESET_VAL;
        else if (csr_wen[`CSRW_MTVEC])   mtvec_reg <= csrd;
    end
    assign mtvec_out = mtvec_reg;

    /* ------------------------------ mscratch ----------------------------- */
    // 供陷入处理程序自用的暂存，硬件完全不解释其值。
    logic [31:0] mscratch_reg;
    always_ff @(posedge clock) begin
        if (reset)                        mscratch_reg <= RESET_VAL;
        else if (csr_wen[`CSRW_MSCRATCH]) mscratch_reg <= csrd;
    end
    assign mscratch_out = mscratch_reg;

endmodule
