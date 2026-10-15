`include "para.sv"
`timescale 1ns / 1ps

// Reg_Stack 把整数寄存器堆与 CSR 空间封装在一起。
// 对译码级来说，它相当于系统路径和普通数据路径的共同读入口：
//   - rs1/rs2/a0 -> 通用寄存器组
//   - csr_addr 经地址译码 -> 某个机器模式 CSR
// v9 新增中断相关 CSR（mie/mip/mtime/mtimecmp/mscratch）与 intr_pending 输出。
module Reg_Stack (
    input  logic        reset,
    input  logic        clock,
    input  logic [31:0] pc,
    input  logic        ecall_flag,
    input  logic        mret_flag,
    input  logic        intr_take,

    input  logic [ 4:0] rs1,
    input  logic [ 4:0] rs2,
    input  logic [ 4:0] rd,
    input  logic [31:0] rd_value,

    input  logic [11:0] csr_addr,
    input  logic        R_wen,
    input  logic [15:0] csr_wen,
    input  logic [31:0] csrd,

    output logic [31:0] rs1_value,
    output logic [31:0] rs2_value,
    output logic [31:0] a0_value,
    output logic [31:0] csrs,
    output logic [31:0] mepc_out,
    output logic [31:0] mtvec_out,
    output logic [31:0] mcause_out,
    output logic [31:0] mstatus_out,
    output logic [31:0] mie_out,
    output logic [31:0] mip_out,
    output logic [31:0] mscratch_out,
    output logic [31:0] mtime_out,
    output logic [31:0] mtimecmp_out,
    output logic        intr_pending
);

    logic [31:0] wdata;

    logic [31:0] mvendorid_out;
    logic [31:0] marchid_out;

    // x0 永远保持 0，因此即便上层误传 rd=0，也会被这里钳成 0。
    assign wdata = (rd == 5'd0) ? 32'd0 : rd_value;

    // 读 CSR 时通过地址多路选择把不同系统寄存器并到统一返回口 csrs。
    assign csrs = (csr_addr == `CSR_mepc)      ? mepc_out       :
                  (csr_addr == `CSR_mcause)    ? mcause_out     :
                  (csr_addr == `CSR_mstatus)   ? mstatus_out    :
                  (csr_addr == `CSR_mtvec)     ? mtvec_out      :
                  (csr_addr == `CSR_mie)       ? mie_out        :
                  (csr_addr == `CSR_mip)       ? mip_out        :
                  (csr_addr == `CSR_mscratch)  ? mscratch_out   :
                  (csr_addr == `CSR_mtime)     ? mtime_out      :
                  (csr_addr == `CSR_mtimecmp)  ? mtimecmp_out   :
                  (csr_addr == `CSR_mvendorid) ? mvendorid_out  :
                  (csr_addr == `CSR_marchid)   ? marchid_out    : 32'd0;

    // CSR 子块维护异常/中断/返回相关机器态。
    CSR #(32, 0) CSR_inst (
        .clock        (clock),
        .reset        (reset),
        .pc           (pc),
        .ecall_flag   (ecall_flag),
        .mret_flag    (mret_flag),
        .intr_take    (intr_take),
        .csrd         (csrd),
        .csr_wen      (csr_wen),
        .mvendorid_out(mvendorid_out),
        .marchid_out  (marchid_out),
        .mepc_out     (mepc_out),
        .mcause_out   (mcause_out),
        .mstatus_out  (mstatus_out),
        .mtvec_out    (mtvec_out),
        .mie_out      (mie_out),
        .mip_out      (mip_out),
        .mscratch_out (mscratch_out),
        .mtime_out    (mtime_out),
        .mtimecmp_out (mtimecmp_out),
        .intr_pending (intr_pending)
    );

    // RegisterFile 子块维护通用整数寄存器。
    RegisterFile #(5, 32) Reg_inst (
        .clock    (clock),
        .wdata    (wdata),
        .waddr    (rd),
        .wen      (R_wen),
        .reset    (reset),
        .rs1_addr (rs1),
        .rs2_addr (rs2),
        .rs1_value(rs1_value),
        .rs2_value(rs2_value),
        .a0_value (a0_value)
    );

endmodule
