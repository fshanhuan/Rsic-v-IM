`include "para.sv"

// =============================================================================
// myCPU.sv — CPU 顶层：RV32I 六级流水线（v9 扩 RV32IM）+ I/D-Cache + 动态分支预测
// -----------------------------------------------------------------------------
// 顶层只做“接线 + 全局协同”：IFU/ICache 取指、IDU 译码、EXU 执行、LSU/DCache 访存、
// WBU 写回收束、Control 前递/暂停/冲刷/重定向、Branch_Predictor 2 位 BHT + BTB。
//
// ★ 接口契约：所有子模块共用一套级间握手命名 —— `valid_last`/`ready_last` 来自上一级，
//   `valid_next`/`ready_next` 交给下一级，只有两者同拍为 1 本级才吃进一条新指令；
//   `ready` 是组合回压（能不能收），`stall` 是冻结请求（不许推进），语义不同不可互替。
//   观察重点四条线：WBU 最终收束 / LSU 的 MEM·MEM_PIPE·MEM2 三级前递 / 分支预测与真实
//   重定向在 Control 合流 / ecall·mret·fence.i·中断共用 dnpc 收束。细节与实测证据见 syn/修复史_全量.md
// =============================================================================
module myCPU (
    // ① 时钟与复位：单时钟域。cpu_rst 来自 board/reset_sync.sv（异步置位、同步释放、高有效）。
    input cpu_clk,
    input cpu_rst,

    // ② 取指侧存储器接口（IROM）：ICache 用 addr/en 出去、data 回来；板级同步读，未命中靠 icache_hold 停拍重试。
    output [31:0] irom_addr,
    input  [31:0] irom_data,
    // ★ 不变量（B8）：irom_en 必须走顶层端口 —— 综合器不认 board_top 的层次化引用
    //   （Quartus Error 10207），Analysis & Synthesis 失败 → 整机上不了板。见 §MYCPU-1
    output        irom_en,

    // ③ 数据侧外设总线（DRAM/MMIO）：DCache 用 addr/wen/ren/mask/wdata 出去、rdata 回来；store 为单拍脉冲。
    output [31:0] perip_addr,
    output        perip_wen,
    // ★ 不变量：perip_ren 必须按“本拍确实发一次读”门控，不许退化成自由运行读口 —— 板级
    //   同步 BRAM 按 ren 门控，自由运行读口会掩盖 DCache 读握手 off-by-one。见 §MYCPU-2
    output        perip_ren,
    output [ 1:0] perip_mask,
    output [31:0] perip_wdata,
    input  [31:0] perip_rdata,

    // ④ 调试观察口（只给 ILA/仿真看，不参与控制逻辑）。mark_debug 让 ILA 综合后按名字找到
    //   这些网；keep 防止它们因“顶层无负载”被优化掉（board_top_ila 不引出 debug_*）；
    //   两者对 iverilog/ModelSim 是透明注释。行尾注释给出每个口的内部来源。
    (* mark_debug = "true", keep = "true" *) output  logic debug_wb_have_inst,   // ← WBU_valid：写回级本拍有没有一条有效指令
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_wb_pc,   // ← WBU_pc：写回级 PC（比 debug_ifu_pc 晚 3~4 拍）
    (* mark_debug = "true", keep = "true" *) output  logic debug_wb_ena,         // ← WBU_R_wen：本拍是否真的写寄存器堆
    (* mark_debug = "true", keep = "true" *) output  logic [4:0] debug_wb_reg,   // ← WBU_rd：目的寄存器号
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_wb_value,// ← WBU_rd_value：最终提交值（ALU/load/CSR/link 已收束）

    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_icache_hit_cnt,  // ← icache_hit_cnt：ICache 命中次数
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_icache_miss_cnt, // ← icache_miss_cnt：ICache 缺失次数
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_dcache_hit_cnt,  // ← dcache_hit_cnt：DCache 命中次数
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_dcache_miss_cnt, // ← dcache_miss_cnt：DCache 缺失次数

    // 异常现场（v9 新增 C4）：原来这 4 个口在 board_top 里是**悬空**的（板上看不到异常）。
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_mcause,    // ← IDU_mcause_out：异常/中断原因码（CSR mcause）
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_mepc,      // ← IDU_mepc_out：陷入时的返回 PC（CSR mepc）
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_mtval,     // ← IDU_mtval_out：出错指令编码/出错地址（CSR mtval）
    (* mark_debug = "true", keep = "true" *) output  logic        debug_trap_take, // ← trap_take：本拍确认接收一次同步异常（单拍脉冲）

    // 重定向诊断三根线（v9 新增 B9）：把“请求 / 背压 / 结果”一起引出来。
    // ★ 不变量：debug_ready 就是下面 IFU_Inst0 的 `.ready(IDU_ready)` 那**同一根网**，
    //   不许换成别的信号，也不许取反/打拍。
    // ★ 不变量：三根必须能**同拍**对齐观察 —— 只看一根分不清"请求没发"还是"发了被门控
    //   吃掉"（dnpc_flag 只有一拍宽，被吃掉不会重发）。踩坑史见 §MYCPU-3
    (* mark_debug = "true", keep = "true" *) output  logic        debug_dnpc_flag, // ← dnpc_flag：重定向的"请求"（1 bit）
    (* mark_debug = "true", keep = "true" *) output  logic        debug_ready,     // ← IDU_ready = EXU_ready & ~IFU_stall：下游"背压"，与 IFU 的 .ready 是同一个网
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_ifu_pc     // ← IFU_pc：重定向的"结果"（取指级 PC 本体，比 debug_wb_pc 早 3~4 拍）

);

  // ===== 流水级内部连线：命名 <级名>_<信号>；IFU*（取指 → IDU）= 指令字 / PC / PC+4 / 有效位 =====
  logic [31:0] IFU_inst;
  logic        IFU_valid;
  logic [31:0] IFU_pc;
  logic [31:0] IFU_snpc;

  /************************* IDU ********************/   // 译码 → EXU：控制位 + 操作数/立即数 + CSR/系统标志
  logic [31:0] IDU_pc;
  // v9 修复（C4 遗留）：译码级指令本体，给 EXU 当 fault_inst_in（非法指令 → mtval）。
  //   ★ 不变量：必须接这一根（译码级 inst_d），不能接 IFU_inst —— inst_d(T)=IFU_inst(T-2)，
  //     接错会把**别的指令**写进 mtval；它还必须显式声明成 32 位。见 §MYCPU-4
  logic [31:0] IDU_inst_d;
  logic [ 4:0] IDU_rd;
  logic [ 2:0] IDU_funct3;
  logic        IDU_mret_flag;
  logic        IDU_ecall_flag;
  logic [31:0] IDU_rs2_value;
  logic [31:0] IDU_rs1_value;
  logic [15:0] IDU_csr_wen;           // CSR 写使能**独热码**：每一位对应一个 CSR（位映射见 para.sv）
  logic        IDU_R_wen;
  logic [31:0] IDU_rd_value;          // 本指令要写的 rd 值（CSR 读值 / link 地址 / 普通结果，已由 Control 前递选好）
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
  logic [31:0] IDU_a0_value;          // a0(x10) 的值：ecall 时给 CSR / 仿真打印用
  logic [31:0] IDU_mepc_out;          // CSR 读出：mepc → Control（mret 的返回目标）
  logic [31:0] IDU_mtvec_out;         // CSR 读出：mtvec → Control（陷入入口地址）

  logic [31:0] IDU_branch_pc;
  logic        IDU_valid;             // → EXU.valid_last：本拍译码级确实有一条有效指令
  logic        IDU_ready;             // ← EXU_ready & ~IFU_stall（即 IDU.ready_last）；它同时就是 IFU 的 ready 输入
  logic        IDU_fence_i_flag;
  /************************* EXU ********************/   // 执行 → LSU：ALU 结果 + 分支/跳转结论 + 访存控制位
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
  logic        EXU_mdu_busy;          // MDU 多拍迭代未完成 → 冻结访存流水与 EXU 接收
  logic        EXU_mdu_done;          // MDU 本拍出结果
  /************************* LSU ********************/   // 访存 → WBU：load 数据 + 地址低 2 位 + 写回控制位
  // 三套并列接口的后缀即流水深度：MEM(LSU_*) / MEM_PIPE(*_pipe) / MEM2·WB(*_wb，直接给 WBU)。
  logic        LSU_jump_flag;
  logic        LSU_R_wen;
  logic [31:0] LSU_Rdata;             // 已按 funct3 对齐/符号扩展的 load 数据（前递给 Control 用）
  logic [15:0] LSU_csr_wen;
  logic [31:0] LSU_Ex_result;
  logic [31:0] LSU_rd_value;
  logic [31:0] LSU_pc;

  logic [ 4:0] LSU_rd;
  logic        LSU_mem_ren;
  logic        LSU_ready;             // ← WBU_ready & ~(stall 条件)；访存级能不能收下一条

  /************************* WBU ********************/   // 写回级（终点）：最终提交值 + 写回寄存器堆所需信息
  logic [31:0] WBU_pc;
  logic [31:0] WBU_rd_value;
  logic [31:0] WBU_csrd;
  logic [ 4:0] WBU_rd;
  logic        WBU_R_wen;
  logic [15:0] WBU_csr_wen;
  logic        WBU_ready;
  logic        WBU_valid;
  logic        LSU_valid;             // 名字是 LSU_ 但声明在 WBU 分组：MEM2/WB 级的有效位（给 Control）

  // ---- 控制面全局协同信号（顶层统一收集）：dnpc/dnpc_flag（dnpc_flag 同时就是 IDU 的 flush）、
  // EXU_inst_clear（作废 EX 级那条）、IFU_stall（load-use 冒险冻结 PC）----
  /*            PERSONAL              */

  logic        dnpc_flag;
  logic        EXU_inst_clear;
  logic [31:0] dnpc;
  logic IFU_stall;
  logic IFU_mem_stall;    // 只含存储侧 hold（参与 IFU.valid）
  logic IFU_stall_ctrl;   // 来自 Control：load-use 冒险等前端暂停请求
  logic load_use_stall;   // 来自 Control：只含 load-use 冒险（供 EXU_inst_clear 使用；引出便于波形观察）
  logic icache_clr;
  // ★ 不变量：存储侧的 hold 必须**先于使用处**声明（否则 Verilog 先按隐式 1 位 wire 建网，
  //   再报重复声明；ModelSim 直接 vlog-2730 硬报错）。踩坑史见 §MYCPU-5
  logic icache_hold;
  logic dcache_hold;

  // ★ 不变量：IFU_stall / IFU_mem_stall 的三个来源必须同源，且**只**并入存储侧 hold，
  //   绝不并入 EXU_inst_clear —— 只有存储侧 hold 参与 IFU.valid 灌泡（load-use 只冻结 PC，
  //   否则与 IDU 采样点错拍）；缓存停拍期间 EX 级那条指令要**重放**，清掉就丢了。
  assign IFU_stall     = IFU_stall_ctrl | icache_hold | dcache_hold;
  assign IFU_mem_stall = icache_hold | dcache_hold;

  /* ---------- v9 新增：分支预测器观测与连线 ---------- */
  // 预测信息跟着指令向前流：bp_* 是 IF 级查询结果，IDU_pred_*/EXU_pred_* 是 ID/EX 级打拍副本。
  logic        bp_pred_taken;
  logic [31:0] bp_pred_target;
  logic        bp_update_en;      // Control → BPU：EX 级这条指令要不要更新 BHT/BTB
  logic        bp_update_taken;
  logic [31:0] bp_update_target;
  logic        bp_mispredict;     // Control → BPU：EX 级真实去向与预测不符（update_correct = ~bp_mispredict）
  logic        bp_hold_exu;       // v9 修复（B7）：误预测判定存在（当拍或挂起）→ 冻结 EXU 接收新指令
  logic [31:0] bp_pred_cnt;       // 以下三个只做观察（顶层未引出），看波形/算命中率用
  logic [31:0] bp_hit_cnt;
  logic [31:0] bp_miss_cnt;
  logic        IDU_pred_taken;    // bp_pred_taken / target / index 在 ID 级的打拍副本
  logic [31:0] IDU_pred_target;
  logic        EXU_pred_taken;    // 同上，在 EX 级的打拍副本（误预测判定的输入）
  logic [31:0] EXU_pred_target;
  logic [`BP_INDEX_BITS-1:0] bp_pred_index;    // BHT/BTB 索引，宽度由 para.sv 的 `BP_INDEX_BITS 决定
  logic [`BP_INDEX_BITS-1:0] IDU_pred_index;
  logic [`BP_INDEX_BITS-1:0] EXU_pred_index;


  /* ---------- v9 新增：中断连线 ---------- */
  logic        IDU_intr_pending;   // 来自 CSR：中断待处理且全局使能
  logic        intr_take;          // Control 判定本拍接收中断

  /* ---------- v9 新增（C4）：异常体系信号 ---------- */
  // 异常链路按流水分四段：① ID 判定（IDU_*）→ ② EX 锁存（EXU_*_exc）→ ③ Control 汇总确认
  //   （trap_take / trap_take_q / trap_cause / fault_*）→ ④ IDU→CSR 登记 + IFU 拨 PC。
  //   ★ 不变量：③ 那一段必须**接到 IDU**，漏接即"陷入次数对、但 mcause 恒 0、mtval 恒 x"。
  logic        IDU_illegal_flag;      // ID 级指令非法
  logic        IDU_mem_misalign;      // load/store 有效地址非对齐
  logic [2:0]  IDU_mem_misalign_funct3;
  logic        EXU_illegal_exc;       // EX 级锁存后的非法指令异常
  logic        EXU_mem_misalign_exc;
  logic [2:0]  EXU_mem_misalign_funct3;
  logic        EXU_iaddr_misalign_exc;
  logic [31:0] EXU_fault_inst;        // 出错指令编码（写 mtval 用）
  logic        trap_take;             // 确认接收一次同步异常（单拍）
  logic        trap_take_q;           // 下一拍补发重定向
  logic [3:0]  trap_cause;            // `EXC_* 独热码
  logic [31:0] fault_addr, fault_inst;   // mtval 取值来源：地址用 EXU 的有效地址/跳转目标，编码用 EXU_fault_inst
  logic        exc_pending;           // Control：EX 级确有一条指令在等异常处理（= exc_any & EXU_valid）
  logic [31:0] IDU_mtval_out;         // 供顶层 debug 端口观察
  logic [31:0] IDU_mcause_out;        // 异常/中断原因码观察

  /* ---------- v9 新增：I-Cache / D-Cache 观测信号（可在波形中查看命中率） ---------- */
  logic [31:0] icache_rdata;          // ICache 返回给 IFU 的指令数据（= IFU.irom_data）
  logic        icache_hit;
  logic        icache_miss;
  logic        icache_fetch_align;    // ICache.fetch_align：本拍 irom_data 确实属于当前 PC；IFU 用它算 valid
  logic        icache_mem_en;         // ICache → IROM 的读使能，顶层直连 irom_en
  logic [31:0] icache_hit_cnt;
  logic [31:0] icache_miss_cnt;

  logic [31:0] lsu_bus_addr;          // LSU 发出的字节地址（= DCache.cpu_addr）
  logic        lsu_bus_wen;           // 写有效（= DCache.cpu_wen；也参与 cpu_en）
  logic [31:0] lsu_bus_wdata;
  logic [ 1:0] lsu_bus_mask;
  logic [31:0] lsu_bus_rdata;         // DCache 返回给 LSU 的读数据
  logic        dcache_hit;
  logic        dcache_miss;
  logic        dcache_mem_en;         // DCache → 外设总线的读使能，顶层直连 perip_ren
  logic [31:0] dcache_hit_cnt;
  logic [31:0] dcache_miss_cnt;

  // ==== ICache_inst —— 取指级（IFU ↔ IROM 之间）：组合查表 + 一拍同步回填，没有 valid/ready 对，
  //   背压反过来 —— 由 ICache 用 hold 停 IFU（hold 汇入 IFU_stall 冻结 PC）。
  //   ★ 容易漏接：`hold`/`fetch_align` 漏接则未命中时前端照跑、IFU 交付早一拍的废数据（无报错）。
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

  // ==== debug 观察口赋值：只做"内部网 → 顶层端口"直连，不插逻辑（加寄存器/与门会失真）====
  // (1) 写回级提交值：直连 WBU 输出，所以看到的就是真实写回口径。
assign debug_wb_have_inst = WBU_valid;
assign debug_wb_pc = WBU_pc;
assign debug_wb_ena = WBU_R_wen;
assign debug_wb_reg = WBU_rd;
assign debug_wb_value = WBU_rd_value;

// (2) 缓存计数器（B8：原来是 board_top 的层次化引用，综合不认，见 §MYCPU-1）
assign debug_icache_hit_cnt  = icache_hit_cnt;
assign debug_icache_miss_cnt = icache_miss_cnt;
assign debug_dcache_hit_cnt  = dcache_hit_cnt;
assign debug_dcache_miss_cnt = dcache_miss_cnt;

// (3) v9 新增（C4）：异常现场观察口（mcause / mepc / mtval / trap_take）
assign debug_mcause    = IDU_mcause_out;
assign debug_mepc      = IDU_mepc_out;
assign debug_mtval     = IDU_mtval_out;
assign debug_trap_take = trap_take;

// (4) v9 新增（B9）：重定向诊断三根线（请求 / 背压 / 结果）。
//   ★ 不变量：debug_ready = IDU_ready = EXU_ready & ~IFU_stall，就是下面 IFU_Inst0 的
//     `.ready(IDU_ready)` 同一根网，不许换信号/取反/打拍（否则板上 probe 与 IFU 内部门控
//     口径不一致，波形作不了证）；三根还必须**同拍**观察，只看一根分不清"请求没发"还是
//     "发了被门控吃掉"（dnpc_flag 只有一拍宽，被吃掉不会重发）。见 §MYCPU-3
assign debug_dnpc_flag = dnpc_flag;
assign debug_ready     = IDU_ready;
assign debug_ifu_pc    = IFU_pc;


  // ==== IFU_Inst0 —— 取指级（IF 级）：valid（→ IDU）与 ready（← IDU_ready）标准握手；
  //   stall 只冻结 PC，mem_stall 额外把 valid 打成 0 灌泡（两者分工不同，不能合并）；
  //   PC 优先级：reset > dnpc 真实重定向 > 预测跳转 > stall 保持 > 顺序 +4。
  //   ★ 不变量（B4/B7/B9）：真实重定向 dnpc_flag **既不看 inst_valid、也不看 ready**，
  //     别把任何门控加回来；原因与逐拍证据见 §MYCPU-3
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


  // ---- 前递值两级口径（都送给 Control 选前递源）----
  // MEM 级：普通算术/地址类前递 EX 结果，跳转/CSR 前递已经准备好的 rd_value（EXU 级同款）。
  logic [31:0] MEM_forward_val;
  assign MEM_forward_val = (LSU_jump_flag | (|LSU_csr_wen)) ? LSU_rd_value : LSU_Ex_result;

  // v9 修复（B6）：★ 不变量：jump / CSR 前递的必须是 rd_value（link 地址 / CSR 读值），不能是
  //   Ex_result（对 jump 那是**跳转目标地址**）；判据是独热码非零 `|csr_wen`，不是 ==1。
  //   踩坑史 + 实测现象：见 §MYCPU-6
  logic [31:0] EXU_forward_val;
  assign EXU_forward_val = (EXU_jump_flag | (|EXU_csr_wen)) ? EXU_rd_value : EXU_Ex_result;
  
  // ---- MEM 级现场（LSU 本级，第 1 级前递点）----
  logic [31:0] LSU_Rdata_raw;         // WBU 收束前的原始读回数据（对齐/符号扩展在 WBU 里做）
  logic [2:0] LSU_funct3;

  // ---- MEM2 / WB 级现场（LSU 输出给 WBU 的整套写回信息）----
  logic [31:0] LSU_rdata_wb_raw;
  logic [2:0] LSU_funct3_wb;
  logic [1:0] LSU_rdata_offset_wb;   // v9 修复（B1）：写回拍 load 地址低 2 位，送给 WBU 选字节通道
  logic [15:0] LSU_csr_wen_wb;
  logic [31:0] LSU_Ex_result_wb;
  logic [31:0] LSU_rd_value_wb;
  logic [4:0] LSU_rd_wb;
  logic LSU_mem_ren_wb;
  logic LSU_R_wen_wb;
  logic LSU_jump_flag_wb;             // WBU 用它（与 csr_wen 一起）决定最终提交 Ex_result 还是 rd_value
  logic [31:0] LSU_forward_val_wb;    // 第 3 级前递值（= Control 的 MEM2_Ex_result）
  logic LSU_valid_wb;
  logic [31:0] LSU_pc_wb;             // 写回拍 PC（= debug_wb_pc 的来源）

  // ---- MEM_PIPE 级现场（LSU 输出的第 2 级前递点；只给 Control，不写寄存器堆）----
  logic [31:0] LSU_Ex_result_pipe;
  logic [4:0] LSU_rd_pipe;
  logic LSU_mem_ren_pipe;
  logic LSU_R_wen_pipe;
  logic LSU_valid_pipe;
  logic [31:0] LSU_forward_val_pipe;

  // ==== Control_inst0 —— 整机协同核心（控制面，不在流水线上）====
  //   决定 dnpc/dnpc_flag(flush)/EXU_inst_clear/IFU_stall，并给 IDU 选前递操作数（EXU/MEM/
  //   MEM_PIPE/MEM2/WB 五档）；输出都是**单拍命令**，不参与 valid/ready 对。
  //   ★ 不变量：IFU_stall_ctrl 不能当 EXU_inst_clear 用（缓存停拍期间 EX 级那条要重放）。
  //   ★ 容易漏接（C4）：那组同步异常端口必须全接 —— 缺 EXU_* 输入则 exc_pending 恒 0，
  //     缺 trap_*/fault_* 输出侧则 CSR 收不到原因码与现场。
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
      .intr_take     (intr_take),

      // v9 新增（C4）：同步异常通道（EX 级锁存 → Control 汇总）
      //   ★ 不变量：这 5 个 EXU_* 输入必须接 —— 漏接则 exc_pending 恒 0（该陷入的指令一路执行）。
      .EXU_illegal_exc          (EXU_illegal_exc),
      .EXU_mem_misalign_exc     (EXU_mem_misalign_exc),
      .EXU_mem_misalign_funct3  (EXU_mem_misalign_funct3),
      .EXU_iaddr_misalign_exc   (EXU_iaddr_misalign_exc),
      .EXU_fault_inst           (EXU_fault_inst),
      .trap_take                (trap_take),
      .trap_take_q              (trap_take_q),
      .trap_cause               (trap_cause),
      .fault_addr               (fault_addr),
      .fault_inst               (fault_inst),
      .exc_pending              (exc_pending)
  );

  // ==== BPU_inst —— 跨 IF/EX 两级的分支预测器（2 位 BHT + BTB）：查询**组合**（fetch_pc →
  //   pred_taken/target/index，当拍随指令进 IDU/EXU），更新**同步**（update_en 那拍写表）。
  //   ★ 不变量：update_index 必须用 EXU_pred_index（EX 级打拍副本），用取指侧索引会把更新写到
  //     别的表项上（命中率上不去且无报错）；update_correct 必须接 `~bp_mispredict`，接反 BHT 学反。
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




  // ==== IDU_Inst0 —— 译码级（ID 级）：valid_last/ready_last 接 IFU，valid_next/ready_next 接 EXU
  //   （IDU_ready = EXU_ready & ~IFU_stall）；★ 不变量：flush 必须接 dnpc_flag —— 真实重定向
  //   **同时就是** IDU 的冲刷信号，别另造一个；fault_inst 用 IDU_inst_d（见 §MYCPU-4）。
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
      // v9 新增（C4）：异常判定结果 + mtval / mtvec 观察口
      .illegal_flag          (IDU_illegal_flag),
      .mem_misalign          (IDU_mem_misalign),
      .mem_misalign_funct3   (IDU_mem_misalign_funct3),
      .mtval_out             (IDU_mtval_out),
      .mcause_out            (IDU_mcause_out),
      .mepc_out (IDU_mepc_out),
      .mtvec_out(IDU_mtvec_out),
      // v9 修复（C4 遗留）：译码级指令本体，给 EXU 的 fault_inst_in（→ mtval）
      .inst_d_out(IDU_inst_d),
      .pred_taken (IDU_pred_taken),
      .pred_target(IDU_pred_target),
      .pred_index (IDU_pred_index),


      .valid_last(IFU_valid),
      .ready_last(IDU_ready),

      .ready_next(EXU_ready),
      .valid_next(IDU_valid),

      // v9 新增（C4）：同步异常通道（Control → IDU → Reg_Stack/CSR）。
      //   ★ 不变量：这五个端口一个都不能漏接 —— trap_take/trap_take_q/trap_cause/fault_addr/
      //     fault_inst 是 Control 已确认的异常，CSR 的 mepc_wen/mcause_wen 全靠它们触发；
      //     悬空成 x 后 mcause/mtval 永远写不进去，实测"陷入次数对、但 mcause 恒 0、mtval 恒 x"，
      //     而工具只给一个 vopt-2718 Missing connection 的 Warning。见 §MYCPU-7
      .trap_take   (trap_take),
      .trap_take_q (trap_take_q),
      .trap_cause  (trap_cause),
      .fault_addr  (fault_addr),
      .fault_inst  (fault_inst)

  );

  // ==== EXU_Inst0 —— 执行级（EX 级）：valid_last/ready_last 接 IDU，valid_next/ready_next 接 LSU；
  //   EXU_inst_clr 是"作废 EX 级这条指令"的单拍通道（跳转/异常/插泡），不能与 IFU_stall 混用。
  //   ★ 不变量：fault_inst_in 必须接 IDU_inst_d，**不是 IFU_inst**（见下面端口处说明）。
  //   ★ 容易漏接：mdu_done / bp_pend / trap_take 漏接会让 EXU 以为 MDU 没算完（永久冻结）、
  //     误预测无法冻结 EXU、或异常标志清不掉。
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
      .bp_pend (bp_hold_exu),
      // H1（v9 修复）：EXU 的"重复接收"门控。IFU_stall 期间 IDU 冻结、保持送出的 valid 不变，
      //   而 EXU 的 ready_last 不含 IFU_stall → 同一条指令被收两拍、执行两次。见 EXU.sv 该端口注释
      .up_stall(IFU_stall),
      // v9 新增（C4）：异常确认脉冲（只清异常标志，不参与 EXU_inst_clr）
      .trap_take (trap_take),

      // v9 新增（C4）：异常输入（来自 IDU，与 IDU_* 控制位同拍）
      .illegal_in               (IDU_illegal_flag),
      .mem_misalign_in          (IDU_mem_misalign),
      .mem_misalign_funct3_in   (IDU_mem_misalign_funct3),
      // v9 修复（C4 遗留）：★ 不变量：**必须接 IDU_inst_d，不是 IFU_inst** —— 它要与同拍的
      //   illegal_in 配对（inst_d(T)=IFU_inst(T-2)），接错会把别的指令写进 mtval。见 §MYCPU-4
      .fault_inst_in            (IDU_inst_d),
      // v9 新增（C4）：异常输出（锁存后与 EX 级指令一一对应）
      .illegal_exc              (EXU_illegal_exc),
      .mem_misalign_exc         (EXU_mem_misalign_exc),
      .mem_misalign_funct3_exc  (EXU_mem_misalign_funct3),
      .iaddr_misalign_exc       (EXU_iaddr_misalign_exc),
      .fault_inst_exc           (EXU_fault_inst)
  );

  // ==== LSU_Inst0 —— 访存级（MEM 级；内部还有 MEM_PIPE / MEM2 两级打拍）：valid_last/ready_last
  //   接 EXU、valid_next/ready_next 接 WBU；mem_hold 是 DCache 反过来的回压（load 未命中冻结访存）。
  //   ★ 容易漏接：`mem_hold` / `mdu_busy` 漏接则 load 未命中 / MDU 忙时流水照常推进，读到上一次
  //     的数据且不报错。
  //   ★ 不变量：三套输出 MEM / MEM_PIPE / MEM2 对应 1/2/3 级前递，给 WBU 那一套必须用 *_wb。
  LSU LSU_Inst0 (
      .clock(cpu_clk),
      .reset(cpu_rst),
      // ↓ 来自 EXU 的整条指令现场（MEM 级输入）
      // （MDU 忙时冻结访存流水的请求在下面 .mdu_busy 处）

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
      .mem_hold(dcache_hold),        // ← DCache：load 未命中 → 冻结访存流水
      .mdu_busy(EXU_mdu_busy),       // ← MDU：多拍乘除未完成 → 冻结访存流水

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

  // ==== DCache_inst —— 访存级（LSU ↔ 外设总线之间）：没有 valid/ready 对 —— 请求方向 cpu_en/
  //   cpu_wen/addr/wdata/mask 出去、cpu_rdata 回来，背压反过来（用 hold 冻结 LSU）。cpu_en =
  //   LSU_mem_ren_pipe | lsu_bus_wen；store 请求由 DCache 寄存成**单拍脉冲**（一次 store 只写一次）。
  //   ★ 容易漏接：`hold` 漏接则 load 缺失时用旧数据继续算，同样不报错。
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

  // 外设总线读使能：直连 DCache 的 mem_en（只有本拍确实要发一次读才为 1，见端口处不变量）。
  assign perip_ren = dcache_mem_en;

  // v9 修复（B8）：irom_en 就是 ICache 的 mem_en（ICache 内部 cpu_en_r 上电后恒为 1，所以它
  //   实际一直为 1）—— 显式引出是为了不再依赖层次化引用，并给 SoC 侧留出按 ren 门控的余地。
  assign irom_en = icache_mem_en;

  // ==== WBU_inst0 —— 写回级（WB 级，流水线终点）：最终收束点 —— 无论结果来自 ALU、访存还是
  //   跳转/CSR 都在这里统一成最终写回值（jump/CSR → rd_value；load → 按 offset 选字节通道；
  //   否则 Ex_result）。ready 恒为 1（WBU.sv 末），它本来就不该被暂停。
  //   ★ 不变量（踩过大坑）：`.stall` **必须显式接 1'b0，绝不能悬空** —— WBU.sv 的时序块是
  //     `else if (!stall) begin ... end`，悬空成 x 后 `!stall` 也是 x，整段赋值全变 x，结果
  //     一条写回都出不来，且仿真/综合都不报错（iverilog 下尤其隐蔽）。见 §MYCPU-8
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
      .stall(1'b0),                  // 见上面 ★ 不变量：必须是常数 0，不许悬空

      .rd_next   (WBU_rd),
      .valid_next(WBU_valid)
  );

endmodule
