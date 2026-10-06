`include "para.sv"

// =============================================================================
// v9 顶层 myCPU：在 v8（RV32I 六级流水线）基础上扩展为 RV32IM，并加入
// I/D-Cache、动态分支预测、机器模式中断。
// -----------------------------------------------------------------------------
// 顶层的职责只有“接线 + 少数全局协同信号”，具体逻辑都在子模块里：
//   IFU  —— 维护 PC，接受重定向/预测/暂停
//   ICache —— 取指缓存（IFU ↔ IROM 之间）
//   IDU  —— 译码：拆出控制信号、寄存器值、立即数、CSR/系统标志
//   EXU  —— 执行：ALU/MDU，分支判定，跳转目标
//   LSU  —— 访存：多级流水与多级前递观察点
//   DCache —— 数据缓存（LSU ↔ 外设总线之间）
//   WBU  —— 写回收束：统一选择最终提交值
//   Control / Data_hazard —— 前递、暂停、冲刷与重定向
//   Branch_Predictor —— 2 位 BHT + BTB，IF 查/EX 更新
// 观察本文件时可重点抓四条线：
//   1. 最终收束：所有写回结果最后在 WBU 决定。
//   2. 访存/前递：LSU 提供 MEM/MEM_PIPE/MEM2 多级前递点。
//   3. 控制流：分支预测 + 真实重定向（含中断）在 Control 合流。
//   4. 系统路径：ecall/mret/fence.i/中断 共用 dnpc 收束逻辑。
// =============================================================================
module myCPU (
    input cpu_clk,
    input cpu_rst,

    output [31:0] irom_addr,
    input  [31:0] irom_data,

    output [31:0] perip_addr,
    output        perip_wen,
    // v9 修复：把数据侧的读使能引出来。板级同步 BRAM（board/sync_mem.sv）是按 ren
    //   门控的；原来顶层没有这个端口，测试台只能用"自由运行读口"（每拍都读）来近似，
    //   恰好把 DCache 的读握手 off-by-one 掩盖掉了（详见验证报告 B2）。
    output        perip_ren,
    output [ 1:0] perip_mask,
    output [31:0] perip_wdata,
    input  [31:0] perip_rdata,

    output  logic debug_wb_have_inst,
    output  logic [31:0] debug_wb_pc,
    output  logic debug_wb_ena,
    output  logic [4:0] debug_wb_reg,
    output  logic [31:0] debug_wb_value

);

  logic [31:0] IFU_inst;
  logic        IFU_valid;
  logic [31:0] IFU_pc;
  logic [31:0] IFU_snpc;

  /************************* IDU ********************/
  logic [31:0] IDU_pc;
  logic [ 4:0] IDU_rd;
  logic [ 2:0] IDU_funct3;
  logic        IDU_mret_flag;
  logic        IDU_ecall_flag;
  logic [31:0] IDU_rs2_value;
  logic [31:0] IDU_rs1_value;
  logic [15:0] IDU_csr_wen;
  logic        IDU_R_wen;
  logic [31:0] IDU_rd_value;
  logic        IDU_mem_wen;
  logic        IDU_mem_ren;

  logic        IDU_inv_flag;
  logic        IDU_branch_flag;
  logic        IDU_jump_flag;
  logic [31:0] IDU_add1_value;
  logic [31:0] IDU_add2_value;
  logic [ 4:0] IDU_alu_opcode;
  logic [ 4:0] IDU_rs1;
  logic [ 4:0] IDU_rs2;
  logic [31:0] IDU_a0_value;
  logic [31:0] IDU_mepc_out;
  logic [31:0] IDU_mtvec_out;

  logic [31:0] IDU_branch_pc;
  logic        IDU_valid;
  logic        IDU_ready;
  logic        IDU_fence_i_flag;
  /************************* EXU ********************/
  logic [31:0] EXU_branch_pc;
  logic        EXU_jump_flag;
  logic [ 2:0] EXU_funct3;
  logic [31:0] EXU_rs2_value;
  logic [ 4:0] EXU_rd;
  logic [31:0] EXU_rd_value;
  logic [15:0] EXU_csr_wen;
  logic        EXU_R_wen;
  logic        EXU_mem_wen;
  logic        EXU_mem_ren;
  logic [31:0] EXU_pc;
  logic [31:0] EXU_Ex_result;
  logic        EXU_branch_flag;
  logic [31:0] EXU_rs1_in;
  logic [31:0] EXU_rs2_in;
  logic        EXU_fence_i_flag;

  logic        EXU_valid;
  logic        EXU_ready;
  logic        EXU_mdu_busy;
  logic        EXU_mdu_done;
  /************************* LSU ********************/
  logic        LSU_jump_flag;
  logic        LSU_R_wen;
  logic [31:0] LSU_Rdata;
  logic [15:0] LSU_csr_wen;
  logic [31:0] LSU_Ex_result;
  logic [31:0] LSU_rd_value;
  logic [31:0] LSU_pc;

  logic [ 4:0] LSU_rd;
  logic        LSU_mem_ren;
  logic        LSU_ready;

  /************************* WBU ********************/
  logic [31:0] WBU_pc;
  logic [31:0] WBU_rd_value;
  logic [31:0] WBU_csrd;
  logic [ 4:0] WBU_rd;
  logic        WBU_R_wen;
  logic [15:0] WBU_csr_wen;
  logic        WBU_ready;
  logic        WBU_valid;
  logic        LSU_valid;

  // 顶层统一收集控制面额外信号：
  // - dnpc/dnpc_flag: 下一条 PC 及其是否需要重定向
  // - EXU_inst_clear: 执行级指令清空，用于处理跳转/异常/停顿插泡
  // - IFU_stall: 访存相关 load-use 冒险导致的取指暂停
  /*            PERSONAL              */

  logic        dnpc_flag;
  logic        EXU_inst_clear;
  logic [31:0] dnpc;
  logic IFU_stall;
  logic IFU_mem_stall;    // 只含存储侧 hold（参与 IFU.valid）
  logic IFU_stall_ctrl;   // 来自 Control：load-use 冒险等前端暂停请求
  logic load_use_stall;   // 来自 Control：只含 load-use 冒险（供 EXU_inst_clear 使用；引出便于波形观察）
  logic icache_clr;

  // IFU/IDU 共用的暂停请求，三个来源必须同源：
  //   - Control.IFU_stall : load-use 冒险（后端数据还没准备好）
  //   - ICache.hold       : 同步 BRAM 未对齐/未命中，需要停一拍重试
  //   - DCache.hold       : load 未命中，需要停一拍重试
  //   其中只有**存储侧**的 hold 参与 IFU.valid（未就绪的取指数据必须灌泡），
  //   load-use 暂停只冻结 PC（否则会与 IDU 采样点错拍、冲掉该保住的指令）。
  // 注意：这里**只**并入存储侧 hold，绝不把 EXU_inst_clear 并进来 ——
  // 缓存停拍期间 EX 级那条指令是要重放的，清掉就丢了（见 Control.sv）。
  assign IFU_stall     = IFU_stall_ctrl | icache_hold | dcache_hold;
  assign IFU_mem_stall = icache_hold | dcache_hold;

  /* ---------- v9 新增：分支预测器观测与连线 ---------- */
  logic        bp_pred_taken;
  logic [31:0] bp_pred_target;
  logic        bp_update_en;
  logic        bp_update_taken;
  logic [31:0] bp_update_target;
  logic        bp_mispredict;
  logic        bp_hold_exu;       // v9 修复（B7）：误预测判定存在（当拍或挂起）→ 冻结 EXU 接收新指令
  logic [31:0] bp_pred_cnt;
  logic [31:0] bp_hit_cnt;
  logic [31:0] bp_miss_cnt;
  logic        IDU_pred_taken;
  logic [31:0] IDU_pred_target;
  logic        EXU_pred_taken;
  logic [31:0] EXU_pred_target;
  logic [`BP_INDEX_BITS-1:0] bp_pred_index;
  logic [`BP_INDEX_BITS-1:0] IDU_pred_index;
  logic [`BP_INDEX_BITS-1:0] EXU_pred_index;


  /* ---------- v9 新增：中断连线 ---------- */
  logic        IDU_intr_pending;   // 来自 CSR：中断待处理且全局使能
  logic        intr_take;          // Control 判定本拍接收中断

  /* ---------- v9 新增：I-Cache / D-Cache 观测信号（可在波形中查看命中率） ---------- */
  logic [31:0] icache_rdata;
  logic        icache_hit;
  logic        icache_miss;
  logic        icache_hold;
  logic        icache_fetch_align;
  logic        icache_mem_en;
  logic [31:0] icache_hit_cnt;
  logic [31:0] icache_miss_cnt;

  logic [31:0] lsu_bus_addr;
  logic        lsu_bus_wen;
  logic [31:0] lsu_bus_wdata;
  logic [ 1:0] lsu_bus_mask;
  logic [31:0] lsu_bus_rdata;
  logic        dcache_hit;
  logic        dcache_miss;
  logic        dcache_hold;
  logic        dcache_mem_en;
  logic [31:0] dcache_hit_cnt;
  logic [31:0] dcache_miss_cnt;

  // I-Cache 接在 IFU 与 IROM 之间：取指先查缓存，缺失时回填。
  // 上板改造后 IROM 是同步读（固定 1 拍延迟），因此 ICache 未命中时用
  // icache_hold 请求把前端停一拍后重试（见 ICache.sv 头部说明）。
  ICache ICache_inst (
      .clk        (cpu_clk),
      .reset      (cpu_rst),
      .cpu_addr   (IFU_pc),
      .mem_rdata  (irom_data),
      .cpu_rdata  (icache_rdata),
      .mem_addr   (irom_addr),
      .mem_en     (icache_mem_en),
      .fetch_align(icache_fetch_align),
      .hit        (icache_hit),
      .miss       (icache_miss),
      .hold       (icache_hold),
      .hit_cnt    (icache_hit_cnt),
      .miss_cnt   (icache_miss_cnt)
  );

assign debug_wb_have_inst = WBU_valid;
assign debug_wb_pc = WBU_pc;
assign debug_wb_ena = WBU_R_wen;
assign debug_wb_reg = WBU_rd;
assign debug_wb_value = WBU_rd_value;


  IFU IFU_Inst0 (
      .clock    (cpu_clk),
      .reset    (cpu_rst),
      .dnpc     (dnpc),
      .dnpc_flag(dnpc_flag),
      .stall     (IFU_stall),
      .mem_stall (IFU_mem_stall),
      .inst_valid(icache_fetch_align),
      .pred_taken (bp_pred_taken),
      .pred_target(bp_pred_target),
      .pc       (IFU_pc),
      .snpc     (IFU_snpc),
      .inst     (IFU_inst),
      .irom_data(icache_rdata),

      .ready(IDU_ready),
      .valid(IFU_valid)
  );


  // LSU 阶段对外暴露的第一层前递值：
  // 普通算术/地址类指令前递 EX 结果，跳转/CSR 指令前递已经准备好的 rd_value。
  logic [31:0] MEM_forward_val;
  assign MEM_forward_val = (LSU_jump_flag | (|LSU_csr_wen)) ? LSU_rd_value : LSU_Ex_result;

  // v9 修复（B6）：EXU 级前递值。jump/CSR 写进 rd 的是 rd_value（link / CSR 读值），
  //   不是 Ex_result（对 jump 那是跳转目标地址）——口径与下面 MEM 级保持一致。
  logic [31:0] EXU_forward_val;
  assign EXU_forward_val = (EXU_jump_flag | (|EXU_csr_wen)) ? EXU_rd_value : EXU_Ex_result;
  
  logic [31:0] LSU_Rdata_raw;
  logic [2:0] LSU_funct3;
  logic [31:0] LSU_rdata_wb_raw;
  logic [2:0] LSU_funct3_wb;
  logic [1:0] LSU_rdata_offset_wb;   // v9 修复（B1）：写回拍 load 地址低 2 位，送给 WBU 选字节通道
  logic [15:0] LSU_csr_wen_wb;
  logic [31:0] LSU_Ex_result_wb;
  logic [31:0] LSU_rd_value_wb;
  logic [4:0] LSU_rd_wb;
  logic LSU_mem_ren_wb;
  logic LSU_R_wen_wb;
  logic LSU_jump_flag_wb;
  logic [31:0] LSU_forward_val_wb;
  logic LSU_valid_wb;
  logic [31:0] LSU_pc_wb;

  logic [31:0] LSU_Ex_result_pipe;
  logic [4:0] LSU_rd_pipe;
  logic LSU_mem_ren_pipe;
  logic LSU_R_wen_pipe;
  logic LSU_valid_pipe;
  logic [31:0] LSU_forward_val_pipe;

  // Control 是整机协同核心：
  // 它一边决定 dnpc/flush/stall，一边给 IDU 送回最合适的前递操作数。
  Control Control_inst0 (

      .clock    (cpu_clk),
      .reset    (cpu_rst),
      .mtvec_out(IDU_mtvec_out),
      .mepc_out (IDU_mepc_out),

      .branch_pc    (EXU_branch_pc),
      .Ex_result    (EXU_Ex_result),
      .EXU_forward_val(EXU_forward_val),
      .EXU_pc       (EXU_pc),
      .EXU_pred_taken (EXU_pred_taken),
      .EXU_pred_target(EXU_pred_target),
      .MEM_Ex_result(MEM_forward_val),
      .MEM_PIPE_Ex_result(LSU_forward_val_pipe),
      .MEM2_Ex_result(LSU_forward_val_wb),
      .IDU_rs1_value(IDU_rs1_value),
      .IDU_rs2_value(IDU_rs2_value),
      .MEM_Rdata    (LSU_Rdata),

      .branch_flag (EXU_branch_flag),
      .jump_flag   (EXU_jump_flag),
      .mret_flag   (IDU_mret_flag),
      .ecall_flag  (IDU_ecall_flag),
      .fence_i_flag(EXU_fence_i_flag),

      .MEM_mem_ren(LSU_mem_ren),
      .MEM_PIPE_mem_ren(LSU_mem_ren_pipe),

      .IDU_rs1(IDU_rs1),
      .IDU_rs2(IDU_rs2),

      .IDU_valid(IDU_valid),
      .EXU_valid(EXU_valid),
      .MEM_valid(LSU_valid),
      .MEM_PIPE_valid(LSU_valid_pipe),
      .MEM2_valid(LSU_valid_wb),

      .EXU_rd(EXU_rd),
      .MEM_rd(LSU_rd),
      .MEM_PIPE_rd(LSU_rd_pipe),
      .MEM2_rd(LSU_rd_wb),
      .EXU_mem_ren(EXU_mem_ren),
      .EXU_R_Wen(EXU_R_wen),
      .MEM_R_Wen(LSU_R_wen),
      .MEM_PIPE_R_Wen(LSU_R_wen_pipe),
      .MEM2_R_Wen(LSU_R_wen_wb),

      .WB_rd_value(WBU_rd_value),
      .WB_rd(WBU_rd),
      .WB_R_Wen(WBU_R_wen),
      .WB_valid(WBU_valid),

      .IFU_stall      (IFU_stall_ctrl),
      .load_use_stall (load_use_stall),      .mdu_busy       (EXU_mdu_busy),
      .mem_stall      (IFU_mem_stall),
      .EXU_rs1_in    (EXU_rs1_in),
      .EXU_rs2_in    (EXU_rs2_in),
      .dnpc          (dnpc),
      .icache_clr    (icache_clr),
      .EXU_inst_clear(EXU_inst_clear),
      .dnpc_flag     (dnpc_flag),
      .bp_update_en  (bp_update_en),
      .bp_update_taken(bp_update_taken),
      .bp_update_target(bp_update_target),
      .bp_mispredict (bp_mispredict),
      .bp_hold_exu   (bp_hold_exu),
      .intr_pending  (IDU_intr_pending),
      .intr_take     (intr_take)
  );

  // 分支预测器：IF 级查询、EX 级更新。
  Branch_Predictor BPU_inst (
      .clk           (cpu_clk),
      .reset         (cpu_rst),
      .fetch_pc      (IFU_pc),
      .pred_taken    (bp_pred_taken),
      .pred_target   (bp_pred_target),
      .pred_index    (bp_pred_index),
      .update_en     (bp_update_en),
      .update_pc     (EXU_pc),
      .update_index  (EXU_pred_index),
      .update_taken  (bp_update_taken),
      .update_target (bp_update_target),
      .update_correct(~bp_mispredict),
      .pred_cnt      (bp_pred_cnt),
      .hit_cnt       (bp_hit_cnt),
      .miss_cnt      (bp_miss_cnt)
  );




  // IDU 把取回的指令展开为执行所需控制信号，同时接收来自 Control 的前递操作数。
  IDU IDU_Inst0 (
      .clock(cpu_clk),
      .reset(cpu_rst),

      .snpc_in    (IFU_snpc),
      .inst_in    (IFU_inst),
      .pc_in      (IFU_pc),
      .flush      (dnpc_flag),
      .stall      (IFU_stall),

      .rd_value(WBU_rd_value),
      .csrd    (WBU_csrd),
      .rd      (WBU_rd),
      .R_wen   (WBU_R_wen),
      .csr_wen (WBU_csr_wen),

      .EXU_rs1_in  (EXU_rs1_in),
      .EXU_rs2_in  (EXU_rs2_in),
      .pred_taken_in (bp_pred_taken),
      .pred_target_in(bp_pred_target),
      .pred_index_in (bp_pred_index),
      .intr_take   (intr_take),
      .intr_pending(IDU_intr_pending),
      .branch_pc   (IDU_branch_pc),
      .rd_next     (IDU_rd),
      .funct3      (IDU_funct3),
      .mret_flag   (IDU_mret_flag),
      .ecall_flag  (IDU_ecall_flag),
      .fence_i_flag(IDU_fence_i_flag),

      .add2_value   (IDU_add2_value),
      .add1_value   (IDU_add1_value),
      .rs1_value    (IDU_rs1_value),
      .rs2_value    (IDU_rs2_value),
      .csr_wen_next (IDU_csr_wen),
      .R_wen_next   (IDU_R_wen),
      .rd_value_next(IDU_rd_value),

      .mem_wen    (IDU_mem_wen),
      .mem_ren    (IDU_mem_ren),
      .inv_flag   (IDU_inv_flag),
      .branch_flag(IDU_branch_flag),
      .jump_flag  (IDU_jump_flag),
      .alu_opcode (IDU_alu_opcode),

      .pc_out   (IDU_pc),
      .rs1      (IDU_rs1),
      .rs2      (IDU_rs2),
      .a0_value (IDU_a0_value),
      .mepc_out (IDU_mepc_out),
      .mtvec_out(IDU_mtvec_out),
      .pred_taken (IDU_pred_taken),
      .pred_target(IDU_pred_target),
      .pred_index (IDU_pred_index),


      .valid_last(IFU_valid),
      .ready_last(IDU_ready),

      .ready_next(EXU_ready),
      .valid_next(IDU_valid)

  );

  // EXU 产生算术结果、分支判定结果和跳转目标；这些结果会反向影响前端是否重定向。
  EXU EXU_Inst0 (
      .clock       (cpu_clk),
      .reset       (cpu_rst),
      .EXU_inst_clr(EXU_inst_clear),

      .funct3   (IDU_funct3),
      .csr_wen  (IDU_csr_wen),
      .R_wen    (IDU_R_wen),
      .mem_wen  (IDU_mem_wen),
      .mem_ren  (IDU_mem_ren),
      .rd       (IDU_rd),
      .branch_pc(IDU_branch_pc),
      .pc       (IDU_pc),

      .alu_opcode  (IDU_alu_opcode),
      .inv_flag    (IDU_inv_flag),
      .jump_flag   (IDU_jump_flag),
      .branch_flag (IDU_branch_flag),
      .fetch_i_flag(IDU_fence_i_flag),

      .add2     (IDU_add2_value),
      .add1     (IDU_add1_value),
      .rs2_value(EXU_rs2_in),
      .rd_value (IDU_rd_value),
      .pred_taken_in (IDU_pred_taken),
      .pred_target_in(IDU_pred_target),
      .pred_index_in (IDU_pred_index),

      .branch_pc_next   (EXU_branch_pc),
      .branch_flag_next (EXU_branch_flag),
      .jump_flag_next   (EXU_jump_flag),
      .funct3_next      (EXU_funct3),
      .rs2_value_next   (EXU_rs2_value),
      .rd_next          (EXU_rd),
      .rd_value_next    (EXU_rd_value),
      .csr_wen_next     (EXU_csr_wen),
      .R_wen_next       (EXU_R_wen),
      .mem_wen_next     (EXU_mem_wen),
      .mem_ren_next     (EXU_mem_ren),
      .EX_result        (EXU_Ex_result),
      .fetch_i_flag_next(EXU_fence_i_flag),
      .pc_out   (EXU_pc),
      .pred_taken_next (EXU_pred_taken),
      .pred_target_next(EXU_pred_target),
      .pred_index_next (EXU_pred_index),

      .valid_last(IDU_valid),
      .ready_last(EXU_ready),

      .ready_next(LSU_ready),
      .valid_next(EXU_valid),

      .mdu_busy(EXU_mdu_busy),
      .mdu_done(EXU_mdu_done),
      .bp_pend (bp_hold_exu)
  );

  // LSU 既承担真正的访存，也承担“把可用结果尽早释放给后续级做前递”的任务。
  LSU LSU_Inst0 (
      .clock(cpu_clk),
      .reset(cpu_rst),
      // MDU 忙时同步冻结访存流水

      .mem_ren  (EXU_mem_ren),
      .mem_wen  (EXU_mem_wen),
      .R_wen    (EXU_R_wen),
      .csr_wen  (EXU_csr_wen),
      .Ex_result(EXU_Ex_result),
      .rd_value (EXU_rd_value),
      .rd       (EXU_rd),
      .funct3   (EXU_funct3),
      .rs2_value(EXU_rs2_value),
      .jump_flag(EXU_jump_flag),
      .pc       (EXU_pc),

      .R_wen_next    (LSU_R_wen),
      .LSU_Rdata     (LSU_Rdata),
      .LSU_Rdata_raw (LSU_Rdata_raw),
      .funct3_next   (LSU_funct3),
      .csr_wen_next  (LSU_csr_wen),
      .Ex_result_next(LSU_Ex_result),
      .rd_value_next (LSU_rd_value),
      .rd_next       (LSU_rd),
      .mem_ren_next  (LSU_mem_ren),
      .jump_flag_next(LSU_jump_flag),

      .pc_out(LSU_pc),
      .pc_wb(LSU_pc_wb),
      .addr (lsu_bus_addr),
      .wen  (lsu_bus_wen),
      .wdata(lsu_bus_wdata),
      .mask (lsu_bus_mask),
      .rdata(lsu_bus_rdata),
      .mem_hold(dcache_hold),
      .mdu_busy(EXU_mdu_busy),

      .rdata_wb_raw(LSU_rdata_wb_raw),
      .funct3_wb(LSU_funct3_wb),
      .rdata_offset_wb(LSU_rdata_offset_wb),
      .csr_wen_wb(LSU_csr_wen_wb),
      .Ex_result_wb(LSU_Ex_result_wb),
      .rd_value_wb(LSU_rd_value_wb),
      .rd_wb(LSU_rd_wb),
      .mem_ren_wb(LSU_mem_ren_wb),
      .R_wen_wb(LSU_R_wen_wb),
      .jump_flag_wb(LSU_jump_flag_wb),
      .forward_val_wb(LSU_forward_val_wb),
      .valid_wb(LSU_valid_wb),

      .Ex_result_pipe(LSU_Ex_result_pipe),
      .rd_pipe(LSU_rd_pipe),
      .mem_ren_pipe(LSU_mem_ren_pipe),
      .R_wen_pipe(LSU_R_wen_pipe),
      .valid_pipe(LSU_valid_pipe),
      .forward_val_pipe(LSU_forward_val_pipe),

      .valid_last(EXU_valid),
      .ready_last(LSU_ready),

      .ready_next(WBU_ready),
      .valid_next(LSU_valid)

  );

  // D-Cache 接在 LSU 与外部数据总线之间：load 缺失停一拍重试，store 写直达。
  // 上板改造后 DRAM 是同步读写（固定 1 拍延迟），store 请求由 DCache 内
  // 寄存成单拍脉冲，保证一次 store 只写一次（见 DCache.sv 头部说明）。
  DCache DCache_inst (
      .clk       (cpu_clk),
      .reset     (cpu_rst),
      .cpu_en    (LSU_mem_ren_pipe | lsu_bus_wen),
      .cpu_wen   (lsu_bus_wen),
      .cpu_addr  (lsu_bus_addr),
      .cpu_wdata (lsu_bus_wdata),
      .cpu_mask  (lsu_bus_mask),
      .mem_rdata (perip_rdata),
      .cpu_rdata (lsu_bus_rdata),
      .mem_addr  (perip_addr),
      .mem_en    (dcache_mem_en),
      .mem_wen   (perip_wen),
      .mem_wdata (perip_wdata),
      .mem_mask  (perip_mask),
      .hit       (dcache_hit),
      .miss      (dcache_miss),
      .hold      (dcache_hold),
      .hit_cnt   (dcache_hit_cnt),
      .miss_cnt  (dcache_miss_cnt)
  );

  // WBU 是最终收束点：无论结果来自 ALU、访存还是跳转/CSR，这里统一形成最终写回值。
  assign perip_ren = dcache_mem_en;

  // WBU 的 ready 恒为 1（见 WBU.sv 末），它本来就不该被暂停，因此 stall 常数接 0。
  WBU WBU_inst0 (
      .clock(cpu_clk),
      .reset(cpu_rst),

      .MEM_Rdata_in(LSU_rdata_wb_raw),
      .funct3_in   (LSU_funct3_wb),
      .offset_in   (LSU_rdata_offset_wb),
      .Ex_result_in(LSU_Ex_result_wb),
      .rd_value_in (LSU_rd_value_wb),
      .rd_in       (LSU_rd_wb),
      .csr_wen_in  (LSU_csr_wen_wb),
      .R_wen_in    (LSU_R_wen_wb),
      .mem_ren_in  (LSU_mem_ren_wb),
      .jump_flag_in(LSU_jump_flag_wb),
      .pc_in (LSU_pc_wb),

      .R_wen_next   (WBU_R_wen),
      .csr_wen_next (WBU_csr_wen),
      .csrd         (WBU_csrd),
      .rd_value_next(WBU_rd_value),
      .pc_out(WBU_pc),

      .valid_in(LSU_valid_wb),
      .ready(WBU_ready),
      .stall(1'b0),

      .rd_next   (WBU_rd),
      .valid_next(WBU_valid)
  );

endmodule
