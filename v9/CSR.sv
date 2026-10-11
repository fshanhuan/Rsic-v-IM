`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * CSR.sv — 机器模式控制状态寄存器与中断控制器（v9 扩展）
 * -----------------------------------------------------------------------------
 * 维护的寄存器：
 *   mstatus : MIE(bit3) / MPIE(bit7)
 *   mie     : MSIE(0) / MTIE(7) / MEIE(11)
 *   mip     : MSIP(0) 软件可写；MTIP(7) 由内部定时器硬件驱动；MEIP(11) 外部
 *   mtvec / mepc / mcause / mscratch / mtval（保留）
 *   mtime / mtimecmp：教学用内部定时器（自定义 CSR 0x7C0/0x7C1）
 *
 * 陷入来源：
 *   - ecall          ：同步异常，mcause=11，入口 mtvec
 *   - intr_take      ：异步中断，mcause=0x8000_0000|cause，入口 mtvec
 *   - mret           ：返回，mstatus.MIE<=MPIE，pc<=mepc（PC 重定向在 Control 中）
 *
 * 设计要点：
 *   - 陷入/返回的 CSR 更新都在“译码级”完成（ecall/mret/intr_take 均由 ID 级发起），
 *     与软件 CSR 写（在 WB 级生效）分离；
 *   - 中断优先级：MEI(11) > MSI(0) > MTI(7)；
 *   - 中断是否真正被接收由 Control 结合流水线安全性决定，本模块只给出
 *     “待处理且全局使能”的 intr_pending。
 * =========================================================================== */
module CSR #(
    parameter CSR_WIDTH = 32,
    parameter RESET_VAL = 0
) (
    input  logic        clock,
    input  logic        reset,

    input  logic [31:0] pc,          // 被陷入指令的 PC（来自译码级）
    input  logic        ecall_flag,
    input  logic        mret_flag,
    input  logic        intr_take,   // Control 判定“本拍接收中断”

    // ---- v9 新增（C4）：统一异常通道 ----
    //   trap_take / trap_take_q 是 Control 发出的"确认接收一次异常"的单拍脉冲
    //   （trap_take 在异常指令位于 EX 级时拉高，trap_take_q 在下一拍照原补发，
    //    两条合并起来保证"一次异常只登记一次"，与 bp_misp_predict 的
    //    pending 机制同一思路）。
    //   cause ID 见 para.sv 的 `EXC_* 宏；**必须是独热编码**，这里用
    //   mcause_mux / mtval_mux 把它翻译成 mcause 码与 mtval 值。
    input  logic        trap_take,
    input  logic        trap_take_q,
    input  logic [ 3:0] trap_cause,
    input  logic [31:0] fault_addr,  // 非对齐/非法目标地址（EX_result）
    input  logic [31:0] fault_inst,  // 非法指令的编码（IDU_inst）

    input  logic [31:0] csrd,        // 软件写入数据
    input  logic [15:0] csr_wen,     // 各 CSR 写使能（见 para.sv 位映射）

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
    assign mvendorid_out = 32'h79737978;
    assign marchid_out   = 32'h16FBCBD;

    /* --------------------------- mtime / mtimecmp ------------------------ */
    // v9 修复（C7）：mtime 原来是**每拍 +1**。在 100MHz 下 1 拍 = 10ns，
    //   也就是 mtime 比真实时间快 1000 万倍，"用它算时间/延时"没有任何意义。
    //   现在改成带分频的递减计数器（decrementer）：
    //     MTIME_DIV = 1   -> 每拍 +1（与旧行为完全一致，回归脚本可用）
    //     MTIME_DIV = 100 -> 100MHz/100 = 1MHz，即每 1us 加 1
    //   分频计数器只占 $\log_2(DIV)$ 个触发器，代价很小。
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
    assign mtip = (mtime_reg >= mtimecmp_reg);
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
    // 优先级：外部(11) > 软件(0) > 定时器(7)
    assign intr_cause = pending[`IRQ_MEI] ? 4'd11 :
                        pending[`IRQ_MSI] ? 4'd0  : 4'd7;
    // 注：intr_pending 依赖 mstatus_reg，放在 mstatus 声明之后再赋值（见下）

    /* ------------------------------ mstatus ------------------------------ */
    logic [31:0] mstatus_reg;
    logic [31:0] mstatus_nxt;
    logic        mstatus_wen;
    // v9 修复（C4）：异常（trap_take / trap_take_q）与中断/ecall/mret 一样会改 mstatus
    //   —— 陷入时 MPIE<=MIE、MIE<=0。原来这里只有 intr_take|ecall_flag|mret_flag，
    //   非法指令/非对齐访存这类同步异常不会关中断，语义是错的。
    assign mstatus_wen = csr_wen[`CSRW_MSTATUS] | intr_take | ecall_flag | mret_flag
                       | trap_take | trap_take_q;

    // 统一的"本拍在登记一次陷入"条件（中断/ecall/同步异常都算）
    logic trap_commit;
    assign trap_commit = intr_take | ecall_flag | trap_take | trap_take_q;

    always_comb begin
        if (trap_commit) begin
            // 陷入：MPIE <= MIE，MIE <= 0
            mstatus_nxt = {mstatus_reg[31:8], mstatus_reg[`MSTATUS_MIE],
                           mstatus_reg[6:4], 1'b0, mstatus_reg[2:0]};
        end else if (mret_flag) begin
            // 返回：MIE <= MPIE，MPIE <= 1
            mstatus_nxt = {mstatus_reg[31:8], 1'b1,
                           mstatus_reg[6:4], mstatus_reg[`MSTATUS_MPIE], mstatus_reg[2:0]};
        end else begin
            mstatus_nxt = csrd;
        end
    end

    always_ff @(posedge clock) begin
        if (reset)              mstatus_reg <= 32'h0000_1800;  // MPP=M
        else if (mstatus_wen)   mstatus_reg <= mstatus_nxt;
    end
    assign mstatus_out = mstatus_reg;
    assign intr_pending = mstatus_reg[`MSTATUS_MIE] & (|pending);

    /* -------------------------------- mepc ------------------------------- */
    logic [31:0] mepc_reg;
    logic        mepc_wen;
    assign mepc_wen = csr_wen[`CSRW_MEPC] | intr_take | ecall_flag | trap_take | trap_take_q;
    always_ff @(posedge clock) begin
        if (reset)            mepc_reg <= RESET_VAL;
        else if (mepc_wen)    mepc_reg <= trap_commit ? pc : csrd;
    end
    assign mepc_out = mepc_reg;

    /* ------------------------------- mcause ------------------------------ */
    // v9 修复（C4）：mcause 原来只认"中断"与"ecall"两种来源，非法指令/非对齐访存
    //   无处登记。现在多了一条同步异常通道，用 trap_cause（`EXC_* 独热码）翻译。
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
    // v9 修复（C4）：mtval_reg 原来是个**死寄存器**（只复位、从不写），
    //   非法指令/非对齐访存本应把"出错指令编码 / 出错地址"放进去，软件没法定位。
    //   RISC-V 语义：
    //     非法指令        -> mtval = 出错指令编码
    //     取指/访存非对齐  -> mtval = 出错的有效地址
    //     中断/ecall/断点  -> mtval = 0
    logic [31:0] mtval_reg;
    logic        mtval_wen;
    logic [31:0] exc_mtval;
    always_comb begin
        exc_mtval = trap_cause[0] ? fault_inst      // 非法指令：出错指令编码
                  : (trap_cause[3] | trap_cause[1] | trap_cause[2]) ? fault_addr  // 非对齐：出错地址
                  : 32'd0;
    end
    // 软件可写（CSRW_MTVAL 已并入位图低 4 位之外的位置，这里用一个自由位）
    assign mtval_wen = intr_take | trap_take | trap_take_q;
    always_ff @(posedge clock) begin
        if (reset)                 mtval_reg <= RESET_VAL;
        else if (mtval_wen) begin
            if (intr_take)         mtval_reg <= 32'd0;      // 中断：mtval 清零
            else                   mtval_reg <= exc_mtval;  // 同步异常：写指令或地址
        end
    end

    /* ------------------------------- mtvec ------------------------------- */
    logic [31:0] mtvec_reg;
    always_ff @(posedge clock) begin
        if (reset)                       mtvec_reg <= RESET_VAL;
        else if (csr_wen[`CSRW_MTVEC])   mtvec_reg <= csrd;
    end
    assign mtvec_out = mtvec_reg;

    /* ------------------------------ mscratch ----------------------------- */
    logic [31:0] mscratch_reg;
    always_ff @(posedge clock) begin
        if (reset)                        mscratch_reg <= RESET_VAL;
        else if (csr_wen[`CSRW_MSCRATCH]) mscratch_reg <= csrd;
    end
    assign mscratch_out = mscratch_reg;

    // 注：mtval_reg 的声明与写入已经上移到"mcause/mtval"一节（C4 修复），
    //   这里不再重复声明 —— 原来的 `always_ff` 只做复位、从不写入，
    //   是个彻底的死寄存器，会让"软件读 mtval 定位异常"这条路完全失效。

endmodule
