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

    output logic        intr_pending // = mstatus.MIE & |(mie & mip)
);

    /* ----------------------------- 常量 ID ------------------------------- */
    assign mvendorid_out = 32'h79737978;
    assign marchid_out   = 32'h16FBCBD;

    /* --------------------------- mtime / mtimecmp ------------------------ */
    logic [31:0] mtime_reg;
    always_ff @(posedge clock) begin
        if (reset) mtime_reg <= 32'b0;
        else       mtime_reg <= mtime_reg + 32'd1;
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
    assign mstatus_wen = csr_wen[`CSRW_MSTATUS] | intr_take | ecall_flag | mret_flag;

    always_comb begin
        if (intr_take || ecall_flag) begin
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
    assign mepc_wen = csr_wen[`CSRW_MEPC] | intr_take | ecall_flag;
    always_ff @(posedge clock) begin
        if (reset)            mepc_reg <= RESET_VAL;
        else if (mepc_wen)    mepc_reg <= (intr_take | ecall_flag) ? pc : csrd;
    end
    assign mepc_out = mepc_reg;

    /* ------------------------------- mcause ------------------------------ */
    logic [31:0] mcause_reg;
    logic        mcause_wen;
    assign mcause_wen = csr_wen[`CSRW_MCAUSE] | intr_take | ecall_flag;
    always_ff @(posedge clock) begin
        if (reset)            mcause_reg <= RESET_VAL;
        else if (mcause_wen) begin
            if (intr_take)      mcause_reg <= {1'b1, 27'b0, intr_cause};  // 中断
            else if (ecall_flag) mcause_reg <= `MCAUSE_ECALL_M;            // 异常
            else                mcause_reg <= csrd;
        end
    end
    assign mcause_out = mcause_reg;

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

    /* --------------------------- mtval（保留） --------------------------- */
    logic [31:0] mtval_reg;
    always_ff @(posedge clock) begin
        if (reset) mtval_reg <= RESET_VAL;
    end

endmodule
