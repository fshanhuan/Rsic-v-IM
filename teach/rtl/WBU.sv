/* verilator lint_off UNUSEDSIGNAL */
// signal not use
`include "para.sv"
// 写回级是整条数据通路的最终收束点。
// 无论结果源头是 ALU、访存、跳转返回地址还是 CSR 读值，都会在这里统一选择成 rd_value_next。
module WBU (
    input clock,
    input reset,

    input [31:0] MEM_Rdata_in,
    input [2:0]  funct3_in,
    input [1:0]  offset_in,
    input [31:0] Ex_result_in,
    input [31:0] rd_value_in,
    input [4:0] rd_in,
    input [15:0] csr_wen_in,
    input R_wen_in,
    input mem_ren_in,
    input jump_flag_in,
    input [31:0] pc_in,

    input valid_in,
    input stall,
    output logic ready,

    output logic valid_next,
    output logic R_wen_next,
    output [15:0] csr_wen_next,
    output [31:0] csrd,

    output logic [31:0] pc_out,
    output       [31:0] rd_value_next,
    output [4:0] rd_next
);

  logic [31:0] MEM_Rdata_reg;
  logic [2:0]  funct3_reg;
  logic [1:0]  offset_reg;
  logic [31:0] Ex_result_reg;
  logic [31:0] rd_value_reg;
  logic [ 4:0] rd_reg;
  logic [15:0] csr_wen_reg;
  logic        R_wen_reg;
  logic        mem_ren_reg;
  logic        jump_flag_reg;
  logic [31:0] pc_reg;
  logic        valid_reg;

  // 先把来自 LSU 末拍的所有候选结果锁存住，确保最终提交时序稳定。
  always_ff @(posedge clock) begin
    if (reset) begin
        MEM_Rdata_reg <= 0;
        funct3_reg    <= 0;
        offset_reg    <= 0;
        Ex_result_reg <= 0;
        rd_value_reg  <= 0;
        rd_reg        <= 0;
        csr_wen_reg   <= 0;
        R_wen_reg     <= 0;
        mem_ren_reg   <= 0;
        jump_flag_reg <= 0;
        pc_reg        <= 0;
        valid_reg     <= 0;
    end
    else if (!stall) begin
        MEM_Rdata_reg <= MEM_Rdata_in;
        funct3_reg    <= funct3_in;
        offset_reg    <= offset_in;
        Ex_result_reg <= Ex_result_in;
        rd_value_reg  <= rd_value_in;
        rd_reg        <= rd_in;
        csr_wen_reg   <= csr_wen_in;
        R_wen_reg     <= R_wen_in;
        mem_ren_reg   <= mem_ren_in;
        jump_flag_reg <= jump_flag_in;
        pc_reg        <= pc_in;
        valid_reg     <= valid_in;
    end
  end

  assign pc_out        = pc_reg;
  assign valid_next    = valid_reg;

  logic [31:0] rdata_8i;
  logic [31:0] rdata_16i;
  logic [31:0] rdata_8u;
  logic [31:0] rdata_16u;
  logic [31:0] rdata_wb;

  // ---------------------------------------------------------------------------
  // v9 修复（B1）：字节/半字必须先按**地址低 2 位**选道，再按 funct3 做符号扩展。
  //   读口返回的是该地址所在字的原始整字，原来直接取 [7:0]/[15:0]，
  //   会把 lb/lh/lbu/lhu 的第 1/2/3 字节全读成第 0 字节。
  //   选道口径与 LSU 的抽取、DCache 的 store 合并、board/sync_mem 的 mask 写一致。
  // ---------------------------------------------------------------------------
  logic [31:0] MEM_Rdata_sel;
  always @(*) begin
    if (funct3_reg == 3'b000 || funct3_reg == 3'b100) begin          // lb / lbu
        case (offset_reg)
          2'b00:   MEM_Rdata_sel = MEM_Rdata_reg;
          2'b01:   MEM_Rdata_sel = {8'd0,  MEM_Rdata_reg[31:8]};
          2'b10:   MEM_Rdata_sel = {16'd0, MEM_Rdata_reg[31:16]};
          default: MEM_Rdata_sel = {24'd0, MEM_Rdata_reg[31:24]};
        endcase
    end else if (funct3_reg == 3'b001 || funct3_reg == 3'b101) begin  // lh / lhu
        MEM_Rdata_sel = offset_reg[1] ? {16'd0, MEM_Rdata_reg[31:16]} : MEM_Rdata_reg;
    end else begin                                                    // lw
        MEM_Rdata_sel = MEM_Rdata_reg;
    end
  end

  assign rdata_8u  = {24'd0, MEM_Rdata_sel[7:0]};
  assign rdata_16u = {16'd0, MEM_Rdata_sel[15:0]};

  /* verilator lint_off PINMISSING */
  sext #(
      .DATA_WIDTH(8),
      .OUT_WIDTH (32)
  ) sext_i8 (
      .data     (MEM_Rdata_sel[7:0]),
      .sext_data(rdata_8i)
  );

  sext #(
      .DATA_WIDTH(16),
      .OUT_WIDTH (32)
  ) sext_i16 (
      .data     (MEM_Rdata_sel[15:0]),
      .sext_data(rdata_16i)
  );

  always @(*) begin
    case (funct3_reg)
      3'b000:  rdata_wb = rdata_8i;
      3'b001:  rdata_wb = rdata_16i;
      3'b010:  rdata_wb = MEM_Rdata_sel;
      3'b100:  rdata_wb = rdata_8u;
      3'b101:  rdata_wb = rdata_16u;
      default: rdata_wb = 0;
    endcase
  end

  // 最终写回选择优先级：
  // jump/CSR 使用提前准备好的 rd_value_reg；
  // load 使用访存返回值；
  // 其余普通算术逻辑指令使用 Ex_result_reg。
  logic wb_sel_jmp_csr;
  assign wb_sel_jmp_csr = jump_flag_reg | (|csr_wen_reg);
  assign rd_value_next = wb_sel_jmp_csr ? rd_value_reg : (mem_ren_reg ? rdata_wb : Ex_result_reg);
  assign csrd          = Ex_result_reg;
  assign csr_wen_next  = csr_wen_reg;
  assign R_wen_next    = R_wen_reg & valid_reg;
  assign rd_next       = rd_reg;
  assign ready         = 1'b1;

endmodule  //WBU
