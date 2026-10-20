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
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_ifu_pc,    // ← IFU_pc：重定向的"结果"（取指级 PC 本体，比 debug_wb_pc 早 3~4 拍）

    // ★ v12（B）新增：把"停在哪"做成一根 32 位状态字 + 一根拍计数器。
    //   为什么挤成一根而不是各加一个探针：ILA 的 16 个探针宽度是**冻结的**
    //   （build_project_boot.tcl 的 ILA_PROBES），改宽度要重建 IP、还得同步所有分析脚本。
    //   把 8 个 1 位量打进一根 32 位字，探针表一个字节都不用动。
    //   位分配（bit0 起）：
    //     0 IFU_stall        前端冻结（load-use 冒险 / dcache_hold）—— 停顿时长的总分母
    //     1 dcache_hold      LSU 冻结：DCache load 缺失（同步 BRAM 的 1 拍回不来）
    //     2 mdu_busy         MDU 多拍迭代未完成（乘/除的 17 拍忙碌）
    //     3 system_redirect  mret / ecall / fence.i / trap 引起的重定向（不含分支预测失败）
    //     4 trap_seen        **粘滞**：复位后发生过至少一次同步异常/断点。抓"第一次出事"
    //                        靠它 —— trap_take 只有一拍，抓包很难恰好停在那一拍。
    //     5 dnpc_flag        任意重定向请求（与 probe13 同源，方便单看一根字）
    //     6 load_use_stall   Control 判定的 load-use 冒险（IFU_stall 的子集）
    //     7 IDU_ready        下游背压（与 probe14 同源）
    //   8~10 由 board_top 填：boot_busy / boot_ok / boot_err（见 board/board_top.sv）
    //   ★ 不变量：这根字的低 8 位**只由本模块驱动**，board_top 只能置 8~10 位，
    //     别在板级层再改写低位（两处都驱动同一个 bit 会综合出多驱动）。
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_status,
    // ★ v12（B）：mcycle 的低 32 位。板上量"一条指令几拍"**唯一**的可信来源：
    //   ILA 每一拍都带这个数，任意两个采样点之间做差就是精确拍数，不用改被测程序。
    //   （mtime(0x7C0) 是 500kHz 墙钟，量不出拍数 —— 这正是补 Zicntr 的原因。）
    (* mark_debug = "true", keep = "true" *) output  logic [31:0] debug_mcycle

);

  // ===== 流水级内部连线：命名 <级名>_<信号>；IFU*（取指 → IDU）= 指令字 / PC / PC+4 / 有效位 =====
  logic [31:0] IFU_inst;
  logic        IFU_valid;
  logic [31:0] IFU_pc;             // ★ v10 起 = **队头**指令的 PC（不再等于取指侧 PC）
  logic [31:0] IFU_snpc;
  // v10：取指队列把 pc / pred_* 与指令绑成一条，交付侧一律从队头取；
  //   fetch_pc 是取指侧 PC（预测器查询用），两者语义不同，别混用。
  logic [31:0] IFU_fetch_pc;
  logic        IFU_pred_taken;
  logic [31:0] IFU_pred_target;
  logic [`BP_INDEX_BITS-1:0] IFU_pred_index;

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
  // ★ v13.2（P0）：Control → IDU 的"系统指令提交许可"（见 Control.sv 里 sys_commit_ok 的注释）
  logic        sys_commit_ok_ctrl;
  logic        IDU_fence_i_flag;
  /************************* EXU ********************/   // 执行 → LSU：ALU 结果 + 分支/跳转结论 + 访存控制位
  logic [31:0] EXU_branch_pc;
  logic        EXU_jump_flag;
  logic [ 2:0] EXU_funct3;
  logic [31:0] EXU_rs2_value;
  logic [ 4:0] EXU_rd;
  logic [31:0] EXU_inst_reg;          // v11（S4）：EX 级寄存的指令原码（EXU.fault_inst_reg 引出）
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
  // v10.2：CSR 读口 RAW 前递（IDU 发"读哪个"，Control 从 4 深影子链 + EX 级挑最新在途写值）
  logic [15:0] IDU_csr_sel;           // IDU → Control：本拍所读 CSR 的独热码
  logic [31:0] csr_rd_fwd_val;        // Control → IDU：前递后的 CSR 读值
  logic        csr_rd_fwd_en;         // Control → IDU：前递命中（否则用寄存器本体）
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
  // v11（S1）：icache_clr 已删除 —— ICache 被旁路后指令存储器不可变，fence.i 是合法空操作。
  //   Control 仍产出 icache_clr（端口保留），但 myCPU 不再连它；接回真 cache 时把它接回去即可。
  // ★ 不变量：存储侧的 hold 必须**先于使用处**声明（否则 Verilog 先按隐式 1 位 wire 建网，
  //   再报重复声明；ModelSim 直接 vlog-2730 硬报错）。踩坑史见 §MYCPU-5
  //   v10：icache_hold 随"I-Cache 全流水化"整体删除（取指不再有 hold 停拍）。
  logic dcache_hold;
  // v12（B）：系统重定向观察（Control 的 system_redirect 直通，进 debug_status bit3）
  logic system_redirect;
  // v12（B）：Zicntr 观察口与退休脉冲
  logic [31:0] IDU_mcycle_dbg;   // ← IDU（CSR mcycle 低 32 位），进 debug_mcycle
  logic        LSU_retire_wb;    // ← LSU：本拍有一条指令推进到 WB（minstret 的计数使能）

  // ★ 不变量：IFU_stall / IFU_mem_stall 的来源必须同源，且**只**并入存储侧 hold，
  //   绝不并入 EXU_inst_clear —— 只有存储侧 hold 参与灌泡/重放语义（load-use 只冻结接收）。
  //   v10：I-Cache 改成**全流水、未命中零停顿**之后，**icache_hold 这根线已经不存在** ——
  //   取指不再有 hold，IFU_stall 里也就没有它。留下的 dcache_hold 仍然必须并入：
  //   load 未命中期间 EX 级那条指令的操作数要**重放**（由 Control 的 mem_stall 项负责），
  //   同时 IDU 要冻结（由这里的 IFU_stall 负责）。
  //   ★ 不变量：IFU_stall 仍然只当"冻结接收"用，不要拿去门控 IFU 内部的 PC 生成 ——
  //   前端解耦的全部意义就是"后端停了，取指照跑"（见 IFU.sv 文件头）。
  assign IFU_stall     = IFU_stall_ctrl | dcache_hold;
  assign IFU_mem_stall = dcache_hold;

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
  logic [3:0]  trap_cause;            // `EXC_* 独热码
  logic [31:0] fault_addr, fault_inst;   // mtval 取值来源：地址用 EXU 的有效地址/跳转目标，编码用 EXU_fault_inst
  logic [31:0] fault_pc;              // mepc 取值来源：**EX 级**出错指令的 PC（v10 新增 C9）
  logic        exc_pending;           // Control：EX 级确有一条指令在等异常处理（= exc_any & EXU_valid）
  logic [31:0] IDU_mtval_out;         // 供顶层 debug 端口观察
  logic [31:0] IDU_mcause_out;        // 异常/中断原因码观察

  /* ---------- v11（S1）：取指侧观测信号（ICache 已旁路，见下方例化处） ---------- */
  logic [31:0] icache_rdata;          // 返回给 IFU 的指令数据（= IFU.irom_data）
  // v10：原 icache_fetch_align / icache_hold 被删（I-Cache 全流水、未命中旁路）。
  // v11：icache_hit / icache_miss / hit_cnt / miss_cnt 一并删除 —— 旁路后它们恒为 0，
  //   留着只会让"命中率"这个数字继续误导人（见 debug_icache_* 的注释）。
  logic        icache_resp_valid;     // 本拍 icache_rdata 有效（= cpu_req 的 1 拍延迟）
  logic [31:0] icache_addr;           // IFU → 取指地址（组合直通 BRAM）
  logic        icache_req;            // IFU → 取指请求（= IROM 的读使能门控）
  logic        icache_mem_en;         // → IROM 的读使能，顶层直连 irom_en

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

  // ==== v11（S1）：取指级 = 组合直通 BRAM + 1 拍响应，**没有指令缓存** ====
  //   为什么删 ICache（证据链，见 docs/优化_v11_进度.md）：
  //     ① 响应侧 `cpu_rdata = hit ? data[idx_r] : mem_rdata`：hit 成立意味着 data[idx_r]
  //        就是同一地址上一次从 IROM 读回的那个字，而 IROM 是只读的（board_top.sv 里
  //        READ_ONLY(1)）→ 两者**逐位恒等**，这个 mux 是恒等 mux。
  //     ② 请求侧 `mem_en = cpu_req` 与 hit 无关 → 命中并不省一次 IROM 读（连功耗都不省）。
  //     ③ hit/miss 的唯一读者是下面 4 个 debug 计数器；IFU 只吃 resp_valid。
  //   ⇒ 在"BRAM 直连、固定 1 拍延迟"的结构下，ICache 对周期数/功耗的贡献精确为 0，
  //     只留下一个 fence.i 一致性责任。v10 把 IFU 改成全流水 + 指令队列后，
  //     "取指与访存解耦"这件事已经由队列完成，cache 的历史使命已经结束。
  //   ★ rtl/ICache.sv **原样保留**，作为"以后把取指搬到 DDR/AXI 时的参考实现"
  //     （那时延迟可变，1 字/行、64 行、直接映射都得重做，所以留着并不省事，只是留个起点）。
  //   ★ 若改回真 cache：恢复 ICache 例化、把 irom_en 接到它的 mem_en、把 icache_clr 接回去；
  //     resp_valid 仍是 cpu_req 的 1 拍延迟（接口口径不变，其余代码无需改）。
  logic        icache_req_r;          // cpu_req 的 1 拍延迟 = resp_valid（与同步 BRAM 同拍对齐）
  always_ff @(posedge cpu_clk) begin
      if (cpu_rst) icache_req_r <= 1'b0;
      else         icache_req_r <= icache_req;
  end

  assign icache_resp_valid = icache_req_r;               // 本拍 icache_rdata 有效
  assign irom_addr         = icache_addr;                // 地址组合直通 BRAM
  assign icache_mem_en     = icache_req;                 // IROM 读使能门控（空转拍不读）
  // ★ 不变量：resp_valid=0 时必须给 `NOP，绝不把 sync_mem 在 ren=0 时保持的旧 rdata 当指令。
  assign icache_rdata      = icache_req_r ? irom_data : `NOP;

  // ==== debug 观察口赋值：只做"内部网 → 顶层端口"直连，不插逻辑（加寄存器/与门会失真）====
  // (1) 写回级提交值：直连 WBU 输出，所以看到的就是真实写回口径。
assign debug_wb_have_inst = WBU_valid;
assign debug_wb_pc = WBU_pc;
assign debug_wb_ena = WBU_R_wen;
assign debug_wb_reg = WBU_rd;
assign debug_wb_value = WBU_rd_value;

// (2) 缓存计数器（B8：原来是 board_top 的层次化引用，综合不认，见 §MYCPU-1）
//   ★ v11（S1）：ICache 旁路后，"指令命中/缺失"已不存在 → 这两个端口恒 0。
//     保留端口是为了不动 board_top / xdc / ILA 的引脚与探针表（改端口会牵动 4 处）。
//     数据侧（DCache）仍是真 cache，它的两个计数器照常工作。
assign debug_icache_hit_cnt  = 32'b0;
assign debug_icache_miss_cnt = 32'b0;
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

// (5) v12（B）：停顿时长 / 重定向来源的状态字 + 拍计数器。
//   ★ 不变量：低 8 位只在这里拼，board_top 只往 bit8~10 填引导状态。
//   ★ trap_seen 是**粘滞**位（复位前一直为 1），不随 trap_take 回落：
//     trap_take 只有一拍宽，让它挂在探针上等于"赌抓包恰好停在那拍"。
logic trap_seen;
always_ff @(posedge cpu_clk) begin
    if (cpu_rst)      trap_seen <= 1'b0;
    else if (trap_take) trap_seen <= 1'b1;
end

assign debug_status = {24'b0,
                       IDU_ready,          // bit7
                       load_use_stall,     // bit6
                       dnpc_flag,          // bit5
                       trap_seen,          // bit4
                       system_redirect,    // bit3
                       EXU_mdu_busy,       // bit2
                       dcache_hold,        // bit1
                       IFU_stall};         // bit0
//   mcycle 低 32 位：从 CSR 经 Reg_Stack/IDU 直通上来，纯观察
assign debug_mcycle = IDU_mcycle_dbg;


  // ==== IFU_Inst0 —— 取指级（IF 级）：**PC 生成器 + 4 项取指队列**（v10 解耦点）。
  //   生产者侧 ic_addr/ic_req 每拍向 ICache 发一次请求，不看下游 ready/stall；
  //   消费者侧 valid/ready 标准握手，队头出队才更新 id 侧看到的 pc/inst/pred_*。
  //   ★ 不变量（B4/B7/B9 + v10）：真实重定向 dnpc_flag **既不看 inst_valid、也不看 ready、
  //     也不看队列深度**，别把任何门控加回来；它同时清空队列与在途请求。
  //   ★ 不变量：predictor 的 fetch_pc 必须接 IFU 的 **fetch_pc**（取指侧 PC），不能接
  //     IFU_pc（队头 PC）—— 后者是两条指令之前发出的地址，查出来的预测是别人的。
  IFU IFU_Inst0 (
      .clock    (cpu_clk),
      .reset    (cpu_rst),
      .dnpc     (dnpc),
      .dnpc_flag(dnpc_flag),
      .inst_valid(icache_resp_valid),
      .pred_taken (bp_pred_taken),
      .pred_target(bp_pred_target),
      .pred_index (bp_pred_index),
      .ic_addr  (icache_addr),
      .ic_req   (icache_req),
      .fetch_pc (IFU_fetch_pc),
      .pc       (IFU_pc),
      .snpc     (IFU_snpc),
      .inst     (IFU_inst),
      .irom_data(icache_rdata),
      .pred_taken_out (IFU_pred_taken),
      .pred_target_out(IFU_pred_target),
      .pred_index_out (IFU_pred_index),

      .ready(IDU_ready),
      .valid(IFU_valid)
  );


  // ---- 前递值两级口径（都送给 Control 选前递源）----
  // MEM 级：普通算术/地址类前递 EX 结果，跳转/CSR 前递已经准备好的 rd_value（EXU 级同款）。
  logic [31:0] MEM_forward_val;
  // ★ v15：MEM 级的 load 若被 DCache 的 M1 探测口命中，前递值取**读回数据**（不是地址）。
  assign MEM_forward_val = (MEM_m1_ok)                       ? LSU_Rdata_m1 :
                           (LSU_jump_flag | (|LSU_csr_wen))   ? LSU_rd_value :
                                                                LSU_Ex_result;

  // v9 修复（B6）：★ 不变量：jump / CSR 前递的必须是 rd_value（link 地址 / CSR 读值），不能是
  //   Ex_result（对 jump 那是**跳转目标地址**）；判据是独热码非零 `|csr_wen`，不是 ==1。
  //   踩坑史 + 实测现象：见 §MYCPU-6
  logic [31:0] EXU_forward_val;
  assign EXU_forward_val = (EXU_jump_flag | (|EXU_csr_wen)) ? EXU_rd_value : EXU_Ex_result;
  
  // ---- MEM 级现场（LSU 本级，第 1 级前递点）----
  // v11（S3）：LSU_Rdata_raw 删除（全工程零读者）。
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
      .MEM_m1_ok  (MEM_m1_ok),
      .MEM_PIPE_mem_ren(LSU_mem_ren_pipe),

      .IDU_rs1(IDU_rs1),
      .IDU_rs2(IDU_rs2),

      .IDU_valid(IDU_valid),
      // ★ v13.2（P0）：系统指令提交许可（Control 内部的 ecall/mret 门控要用它）
      .IDU_ready(IDU_ready),
      .sys_commit_ok(sys_commit_ok_ctrl),
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
      // v10 新增（C10）：CSR RAW 前递的输入（EX 级写使能位图）
      .EXU_csr_wen(EXU_csr_wen),
      // v10.2 新增：CSR 读口 RAW 前递（同一份影子链，服务所有 CSRR* 读）
      .IDU_csr_sel(IDU_csr_sel),
      .csr_rd_fwd(csr_rd_fwd_val),
      .csr_rd_fwd_en(csr_rd_fwd_en),
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
      // v11（S1）：.icache_clr 不再接 —— ICache 旁路后无人消费它。Control 端口保留。
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
      .trap_cause               (trap_cause),
      .fault_addr               (fault_addr),
      .fault_inst               (fault_inst),
      .fault_pc                 (fault_pc),
      .exc_pending              (exc_pending),
      // v12（B）：系统重定向观察口（直通，见 Control.sv 的端口说明）
      .system_redirect_dbg      (system_redirect)
  );

  // ==== v11（S4）：RAS 的 call/ret 分类 =========================================
  //   为什么需要单独打一拍：bp_update_en 是 **EX 级**控制流指令被解析的那一拍
  //   （Control: EXU_valid & (branch_flag|jump_flag)），而 IDU_inst_d 是"本拍正进入 EX"的
  //   指令 —— 晚一拍。这里把 IDU_inst_d 打一拍，与 EX 级现场严格对齐
  //   （与 EXU 内部 fault_inst_reg 的口径完全一样，见 EXU.sv 的 fault_inst_reg）。
  //   分类口径按 RISC-V psABI 的惯例：
  //     call = (jal|jalr) 且 rd ∈ {x1, x5}      ← 压栈，记返回地址 pc+4
  //     ret  = jalr x0, 0(x1|x5)                ← 弹栈
  //   注意：预测错了只是**慢**（RAS 只影响预测，不影响任何交付值），所以这个分类允许有
  //   边角不精确（例如把 tail-call 当 call），不会带来功能错误。
  logic [31:0] EX_inst_for_ras;
  logic        bp_is_call, bp_is_ret;
  logic        inst_is_jal, inst_is_jalr;
  // ★ 源必须是 **EXU 里已寄存的那条指令**（inst_reg_exc = fault_inst_reg），
  //   与 bp_update_en 用的 branch_flag_reg/jump_flag_reg 同源同拍。
  assign EX_inst_for_ras = EXU_inst_reg;
  assign inst_is_jal  = (EX_inst_for_ras[6:0] == 7'h6F);
  assign inst_is_jalr = (EX_inst_for_ras[6:0] == 7'h67);
  assign bp_is_call = (inst_is_jal | inst_is_jalr)
                   && ((EX_inst_for_ras[11:7] == 5'd1) || (EX_inst_for_ras[11:7] == 5'd5));
  assign bp_is_ret  = inst_is_jalr && (EX_inst_for_ras[11:7] == 5'd0)
                   && ((EX_inst_for_ras[19:15] == 5'd1) || (EX_inst_for_ras[19:15] == 5'd5))
                   && (EX_inst_for_ras[31:20] == 12'd0);

  // ==== BPU_inst —— 跨 IF/EX 两级的分支预测器（2 位 BHT + BTB）：查询**组合**（fetch_pc →
  //   pred_taken/target/index，当拍随指令进 IDU/EXU），更新**同步**（update_en 那拍写表）。
  //   ★ 不变量：update_index 必须用 EXU_pred_index（EX 级打拍副本），用取指侧索引会把更新写到
  //     别的表项上（命中率上不去且无报错）；update_correct 必须接 `~bp_mispredict`，接反 BHT 学反。
  Branch_Predictor BPU_inst (
      .clk           (cpu_clk),
      .reset         (cpu_rst),
      // ★ 不变量（v10）：必须接 IFU 的**取指侧** PC。接 IFU_pc（队头 PC）会让预测器
      //   去查"两条指令之前那个地址"的预测，而 pred_* 又要随指令入队 —— 静默错位。
      .fetch_pc      (IFU_fetch_pc),
      .pred_taken    (bp_pred_taken),
      .pred_target   (bp_pred_target),
      .pred_index    (bp_pred_index),
      .update_en     (bp_update_en),
      .update_pc     (EXU_pc),
      .update_index  (EXU_pred_index),
      .update_taken  (bp_update_taken),
      .update_target (bp_update_target),
      .update_correct(~bp_mispredict),
      .update_is_call(bp_is_call),
      .update_is_ret (bp_is_ret),
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
      // ★ 不变量（v10）：预测信息**随指令走**，必须接 IFU 队头那一份（IFU_pred_*），
      //   不能再接 bp_pred_*（那是"当前取指侧 PC"的预测，属于两条指令之后的地址）。
      .pred_taken_in (IFU_pred_taken),
      .pred_target_in(IFU_pred_target),
      .pred_index_in (IFU_pred_index),
      .intr_take   (intr_take),
      // ★ v13.2（P0）：只有"确实会提交"的那一拍，ecall/mret 才会改 CSR
      .sys_commit_ok(sys_commit_ok_ctrl),
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
      .trap_cause  (trap_cause),
      .fault_addr  (fault_addr),
      .fault_inst  (fault_inst),
      .fault_pc    (fault_pc),
      // v10.2 新增：CSR 读口 RAW 前递（csr_sel 发出，前递值收回）
      .csr_sel      (IDU_csr_sel),
      .csr_rd_fwd_en(csr_rd_fwd_en),
      .csr_rd_fwd   (csr_rd_fwd_val),

      // ★ v12（B）Zicntr：retire 来自 LSU 的 WB 入口（见 LSU.sv 的 retire_wb），
      //   mcycle_dbg 是 CSR 计数器的低 32 位直通（纯观察）。
      .retire       (LSU_retire_wb),
      .mcycle_dbg   (IDU_mcycle_dbg)

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
      .inst_reg_exc             (EXU_inst_reg),
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
      .m1_hit        (dcache_m1_hit),
      .m1_rdata      (dcache_m1_rdata),
      .LSU_Rdata_m1  (LSU_Rdata_m1),
      .m1_load_ok    (MEM_m1_ok),
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
      .valid_next(LSU_valid),

      // ★ v12（B）：退休脉冲（= 本拍有一条有效指令推进到 WB 级）→ IDU 的 minstret。
      //   注意它与下面的 lsu_adv 是**同一式**（ready_next & ~lsu_freeze），只是额外与了
      //   valid_reg_pipe —— 前者回答"推没推进"，后者回答"推进的是不是一条真指令"。
      .retire_wb(LSU_retire_wb),
      .req_seq  (lsu_req_seq)

  );

  // ==== DCache_inst —— 访存级（LSU ↔ 外设总线之间）：没有 valid/ready 对 —— 请求方向 cpu_en/
  //   cpu_wen/addr/wdata/mask 出去、cpu_rdata 回来，背压反过来（用 hold 冻结 LSU）。cpu_en =
  //   LSU_mem_ren_pipe | lsu_bus_wen；store 请求由 DCache 寄存成**单拍脉冲**（一次 store 只写一次）。
  //   ★ 容易漏接：`hold` 漏接则 load 缺失时用旧数据继续算，同样不报错。
  //   ★ 容易漏接（v10.1 新增）：`cpu_adv` 必须与 LSU 内部推进条件**同式**
  //     （LSU.sv: `ready_next & ~lsu_freeze`，其中 lsu_freeze = mem_hold | mdu_busy）。
  //     漏接/接错 → 一条 store 在 MDU 忙期间被写成多拍（测试台 write-once 断言抓到
  //     同地址连写 4 拍）；反过来若用状态机串行化，则背靠背的两条 store 里第二条被
  //     静默丢弃（v10.1 修掉的真 bug）。两个方向都错，只能靠这个推进信号。
  logic lsu_adv;
  logic lsu_req_seq;   // ★ v14（P4）：LSU 的请求身份证 → DCache
  // ★ v15（load-use）：DCache 的 M1 命中探测口 ↔ LSU
  logic        dcache_m1_hit;   // M1 地址命中（数据本拍可用）
  logic [31:0] dcache_m1_rdata; // M1 地址的整字
  logic [31:0] LSU_Rdata_m1;    // 按 M1 的 funct3/偏移选道后的值
  logic        MEM_m1_ok;       // 本拍 MEM 级 load 数据可用（供前递 + 免停）
  assign lsu_adv = WBU_ready & ~dcache_hold & ~EXU_mdu_busy;
  DCache DCache_inst (
      .clk       (cpu_clk),
      .reset     (cpu_rst),
      .cpu_en    (LSU_mem_ren_pipe | lsu_bus_wen),
      .cpu_wen   (lsu_bus_wen),
      .cpu_addr  (lsu_bus_addr),
      .cpu_wdata (lsu_bus_wdata),
      .cpu_mask  (lsu_bus_mask),
      .cpu_adv   (lsu_adv),
      .req_seq   (lsu_req_seq),
      .m1_addr   (LSU_Ex_result),
      .m1_en     (LSU_mem_ren),
      .m1_hit    (dcache_m1_hit),
      .m1_rdata  (dcache_m1_rdata),
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

  // v9 修复（B8）：irom_en 就是 ICache 的 mem_en，必须走顶层端口引出（不再依赖层次化引用）。
  //   v10：它现在**真的会门控**了 —— mem_en = cpu_req，只在 IFU 真发一次取指那拍为 1；
  //   队列满 / 重定向 / 复位期间都为 0，IROM 不读（板级 sync_mem 的 ren=0 时 rdata 保持，
  //   因此消费侧必须只看 resp_valid=1 的拍，见 ICache.sv 的不变量）。
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
