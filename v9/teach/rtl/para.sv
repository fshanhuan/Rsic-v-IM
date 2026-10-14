/* =============================================================================
 * para.sv — BigBird v9 全局参数与编码约定
 * -----------------------------------------------------------------------------
 * 这里集中定义整颗 CPU 用到的“公共契约”，其它模块只通过宏名互相协作，
 * 避免在 IDU / EXU / ALU 各处散落魔法数字。
 *
 *   1. opcode   ：7 位主操作码，决定指令属于哪一大类。
 *   2. alu_op   ：5 位 ALU/MDU 运算编码，IDU 译码后交给 EXU 解释执行。
 *   3. 汇编器约定：cache / 分支预测 / CSR 的相关参数。
 *
 * 注意：v9 在 v8（RV32I）基础上扩展为 RV32IM：
 *   - 整数基址指令仍走原有 ALU 通路；
 *   - 乘除法新增 MDU，运算编码在 alu_op 高位置 1 区分（见下）。
 * =========================================================================== */
`ifndef PARA_SV
`define PARA_SV

/* ------------------------------- 主操作码 ---------------------------------- */
`define R_opcode   7'b0110011   // R-type：整数寄存器-寄存器运算（含 M 扩展）
`define I0_opcode  7'b0000011   // I-type load：lb/lh/lw/lbu/lhu
`define I1_opcode  7'b0010011   // I-type 立即数运算：addi...
`define I2_opcode  7'b1100111   // jalr
`define S_opcode   7'b0100011   // store：sb/sh/sw
`define B_opcode   7'b1100011   // 分支：beq/bne/blt/bge/bltu/bgeu
`define U0_opcode  7'b0110111   // lui
`define U1_opcode  7'b0010111   // auipc
`define J_opcode   7'b1101111   // jal
`define SYS_opcode 7'b1110011   // 系统：ecall/mret/CSR

/* ------------------------- R 型 funct7 区分位 ------------------------------ */
`define funct7_base 7'b0000000     // 普通 RV32I 整数运算
`define funct7_sub  7'b0100000     // sub/sra
`define funct7_m    7'b0000001     // RV32M 乘除法

/* ------------------------------- ALU 编码 ----------------------------------
 * 5 位编码：[4] 为 1 表示“走 MDU（乘除法）”，否则走普通 ALU 数据通路。
 * 这样 IDU 只需输出一个统一的操作码，EXU 依据最高位选择执行单元即可。
 * ------------------------------------------------------------------------- */
// ---- 基础整数运算（走 ALU）----
`define alu_add                 5'b00000
`define alu_sub                 5'b00001
`define alu_or                  5'b00010
`define alu_and                 5'b00011
`define alu_xor                 5'b00100
`define alu_signed_comparator   5'b00101
`define alu_unsigned_comparator 5'b00110
`define alu_equal               5'b00111
`define alu_sll                 5'b01000
`define alu_srl                 5'b01001
`define alu_sra                 5'b01010

// ---- RV32M 乘除法（走 MDU）----
`define alu_mul                 5'b10000   // 有符号/无符号低 32 位相同
`define alu_mulh                5'b10001   // 有符号 × 有符号，取高 32 位
`define alu_mulhsu              5'b10010   // 有符号 × 无符号，取高 32 位
`define alu_mulhu               5'b10011   // 无符号 × 无符号，取高 32 位
`define alu_div                 5'b10100   // 有符号除法
`define alu_divu                5'b10101   // 无符号除法
`define alu_rem                 5'b10110   // 有符号取余
`define alu_remu                5'b10111   // 无符号取余

/* -------------------------- 访存宽度（funct3） ------------------------------ */
`define mem_f3_sb  3'b000
`define mem_f3_sh  3'b001
`define mem_f3_sw  3'b010
`define mem_f3_lb  3'b000
`define mem_f3_lh  3'b001
`define mem_f3_lw  3'b010
`define mem_f3_lbu 3'b100
`define mem_f3_lhu 3'b101

/* ------------------------------- CSR 地址 ---------------------------------- */
`define CSR_mstatus 12'h300
`define CSR_misa    12'h301
`define CSR_mie     12'h304
`define CSR_mtvec   12'h305
`define CSR_mscratch 12'h340
`define CSR_mepc    12'h341
`define CSR_mcause  12'h342
`define CSR_mtval   12'h343
`define CSR_mip     12'h344
`define CSR_mvendorid 12'hf11
`define CSR_marchid   12'hf12
// 教学用自定义定时器 CSR（标准 mtime/mtimecmp 属 CLINT 内存映射，这里并入 CSR 便于观察）
`define CSR_mtime    12'h7c0
`define CSR_mtimecmp 12'h7c1

/* -------------------- CSR 写使能位（csr_wen 的位映射） -------------------- */
`define CSRW_MEPC     0
`define CSRW_MCAUSE   1
`define CSRW_MSTATUS  2
`define CSRW_MTVEC    3
`define CSRW_MIE      4
`define CSRW_MIP      5
`define CSRW_MSCRATCH 6
`define CSRW_MTIMECMP 7

/* ------------------------------ 中断相关位 -------------------------------- */
// mstatus
`define MSTATUS_MIE   3           // 全局中断使能
`define MSTATUS_MPIE  7           // 中断前的 MIE 备份
// mie / mip
`define IRQ_MSI  0                // 机器软件中断
`define IRQ_MTI  7                // 机器定时器中断
`define IRQ_MEI  11               // 机器外部中断
// mcause：最高位 1 表示中断，0 表示异常
`define MCAUSE_INTR_BIT 31
`define MCAUSE_ECALL_M  11        // ecall from M-mode
`define MCAUSE_MTI      (`MCAUSE_INTR_BIT | `IRQ_MTI)
`define MCAUSE_MSI      (`MCAUSE_INTR_BIT | `IRQ_MSI)
`define MCAUSE_MEI      (`MCAUSE_INTR_BIT | `IRQ_MEI)

/* --------------------------- Cache / 预测器参数 ---------------------------- */
// I-Cache：直接映射，行大小 = 1 个字（教学用，便于观察命中/缺失）
`define ICACHE_INDEX_BITS 6       // 64 行
`define ICACHE_TAG_BITS   (32 - `ICACHE_INDEX_BITS - 2)
`define DCACHE_INDEX_BITS 6       // 64 行
`define DCACHE_TAG_BITS   (32 - `DCACHE_INDEX_BITS - 2)

// 分支预测：gshare（PC 低位 XOR 全局历史 GHR）+ BTB，直接映射
`define BP_INDEX_BITS 6           // 64 项计数表 / BTB
`define BP_TAG_BITS   (32 - `BP_INDEX_BITS - 2)
`define BP_HIST_BITS  6           // 全局历史长度（与索引位宽一致，XOR 后仍为 6 位）

/* ------------------------------ 性能计数开关 ------------------------------ */
`define Performance_Count

// 指令提交时用于调试的 NOP 编码（addi x0,x0,0）
`define NOP 32'h00000013

`endif // PARA_SV
