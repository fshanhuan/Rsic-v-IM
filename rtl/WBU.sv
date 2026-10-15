/* verilator lint_off UNUSEDSIGNAL */
// signal not use
`include "para.sv"
/* =============================================================================
 * WBU.sv — 写回级：整条数据通路的最终收束点（LSU 之后、RegisterFile/CSR 之前）
 * 无论结果源头是 ALU、访存、跳转 link 地址还是 CSR 读值，都在这里统一选成 rd_value_next。
 *
 * ★ 接口契约：valid_next = valid_reg（纯延迟级，既不产生也不吞 valid）；ready 恒 1'b1，WBU 从不背压（myCPU.sv 据此把 stall 接 1'b0）；MEM_Rdata_in 是**原始整字**，字节/半字必须靠 offset_in + funct3_in 现场选道，不能假设上游已对齐。
 * ★ 不许改回去的地方：stall 必须被确定驱动 → §WBU-2；R_wen_next 必须 & valid_reg → §WBU-3；读数据必须先按 offset_in 选道、再按 funct3 符号扩展（B1）→ §WBU-1。
 * 参考：docs/模块阅读文档.md、syn/修复史_全量.md、LSU.sv（上游 *_wb 一组信号）
 * ============================================================================= */
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

  // 先把来自 LSU 末拍的所有候选结果锁存住，确保最终提交时序稳定：这一级维护的就是"一条指令的写回上下文"—— 结果候选（MEM_Rdata_reg / Ex_result_reg / rd_value_reg）、目标与使能（rd_reg / R_wen_reg / csr_wen_reg / mem_ren_reg）、重定向与调试位（jump_flag_reg / pc_reg / valid_reg）。
  // ★ 不变量：stall 端口**必须被确定驱动**（myCPU.sv 现接 1'b0），绝对不能悬空。
  //   原因：悬空时 iverilog 把 `else if (!stall)` 的 stall 算成 x，条件"未知"→ 整个 else 分支不执行 → **一条写回都出不来**（写回寄存器永远停在复位值，现象是 PC 在走、寄存器全 0）；FPGA/Verilator 是 2 态仿真，x 退化成 0/1，恰好看不出来 —— 只有 iverilog 回归能暴露。历史：WBU 加 stall 端口时在 myCPU.sv 里漏接。
  //   踩坑史 + 实测现象：见 syn/修复史_全量.md §WBU-2
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

  // pc_out 就是这条指令的 PC（myCPU.sv 里 debug_wb_pc ← WBU_pc）；valid_next 原样延迟一拍，不做任何门控。
  logic [31:0] rdata_8i;
  logic [31:0] rdata_16i;
  logic [31:0] rdata_8u;
  logic [31:0] rdata_16u;
  logic [31:0] rdata_wb;

  // ★ 不变量（v9 修复 B1）：load 的字节/半字必须**先按 addr[1:0]（offset_in）选道，再按 funct3 符号扩展**。
  //   原因：读口返回的是该地址所在**整字**的原始数据，偏移只存在于地址里；直接取 [7:0]/[15:0] 等于把 lb/lh 的第 1/2/3 字节全读成第 0 字节。选道口径必须与 LSU 抽取、DCache store 合并、sync_mem mask 写**完全一致**，否则同一字节在读侧与写侧错位。写回级才是最终写回值的来源 —— 只修 LSU 不改这里，写回值仍然是错的。
  //   踩坑史 + 实测现象：见 syn/修复史_全量.md §WBU-1
  logic [31:0] MEM_Rdata_sel;
  always @(*) begin
    if (funct3_reg == 3'b000 || funct3_reg == 3'b100) begin          // lb / lbu：4 选 1 个字节
        case (offset_reg)
          2'b00:   MEM_Rdata_sel = MEM_Rdata_reg;
          2'b01:   MEM_Rdata_sel = {8'd0,  MEM_Rdata_reg[31:8]};
          2'b10:   MEM_Rdata_sel = {16'd0, MEM_Rdata_reg[31:16]};
          default: MEM_Rdata_sel = {24'd0, MEM_Rdata_reg[31:24]};
        endcase
    end else if (funct3_reg == 3'b001 || funct3_reg == 3'b101) begin  // lh / lhu：按 offset_in[1] 选低/高半字
        MEM_Rdata_sel = offset_reg[1] ? {16'd0, MEM_Rdata_reg[31:16]} : MEM_Rdata_reg;
    end else begin                                                    // lw：整字不动
        MEM_Rdata_sel = MEM_Rdata_reg;
    end
  end

  // 上面只做"选道"，还没有符号扩展；lbu/lhu 不走 sext 实例，直接高位补 0（与 lb/lh 在最后的 case 里分流）。
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

  // 第二段：按 funct3 选最终宽度结果 —— 000 lb / 001 lh / 010 lw / 100 lbu / 101 lhu；default（011/110/111 等非法编码）给 0，避免 x 传播进 rd。
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

  // 最终写回选择优先级：jump/CSR 用提前准备好的 rd_value_reg；load 用访存返回值；其余普通算术逻辑指令用 Ex_result_reg。
  //   为什么是这个顺序（三者互斥由上游保证，这里只是"最特殊者优先"）：jump/CSR 写进 rd 的是**link 地址 / CSR 读值**，早在 IDU/EXU 就算好并随流水传下来（myCPU.sv 的 IDU_rd_value），此时 Ex_result 是别的中间量；load 时 Ex_result 只是**有效地址**，必须换成选道后的读数据；其余指令 Ex_result 就是 ALU 结果本身。csr_wen 用按位或归约判非零，因为它是 16 位 CSR 地址译码而不是单根使能。
  // ★ 不变量：三选一里的 mem_ren 那一档不能删；否则 load 会把地址当数据写回 rd。
  logic wb_sel_jmp_csr;
  assign wb_sel_jmp_csr = jump_flag_reg | (|csr_wen_reg);
  assign rd_value_next = wb_sel_jmp_csr ? rd_value_reg : (mem_ren_reg ? rdata_wb : Ex_result_reg);
  assign csrd          = Ex_result_reg;      // CSR 写数据 = ALU 结果（csrrw/csrrs/csrrc 的源操作数经 ALU 后就是它），配合 csr_wen_next 送 CSR 模块
  assign csr_wen_next  = csr_wen_reg;        // CSR 写使能随流水原样下传，这里**没有** & valid_reg（与 R_wen 不同）：改之前先确认上游在气泡拍是否已把 csr_wen 清 0
  // ★ 不变量：R_wen_next 必须 & valid_reg（细节见 syn/修复史_全量.md §WBU-3）。原因：rd_next = rd_reg 是无条件下传的，气泡/无效拍上 rd_reg 里是上一拍的残留（或 x），只有把写使能按 valid 门掉，RegisterFile 才不会把残值写进 rd —— 删掉 & valid_reg 会在停拍/重定向后污染寄存器。
  assign R_wen_next    = R_wen_reg & valid_reg;
  assign rd_next       = rd_reg;
  assign ready         = 1'b1;               // 本模块没有任何 stall 逻辑，恒可接收：WBU 不产生背压

endmodule  //WBU
