/* =============================================================================
 * Data_hazard.sv — v9 的**唯一**前递 / 冒险裁决源（组合逻辑，位于 IDU 读操作数之前）
 * -----------------------------------------------------------------------------
 * ★ 接口契约（改之前必读）：同一组命中条件同时驱动两件事 ——
 *   ① 谁来前递：IDU_rs1_choice / IDU_rs2_choice（数据多路选择的编码）
 *   ② 要不要停：load_use_stall（某一级是 load 且 rd 与 IDU 的源重叠）
 *   Control 只做两件事：把编码翻译成数据值、把 load_use_stall 接到 PC/EXU 的冻结上。
 *
 * ★ 不变量：load-use 的三个分级（exu / mem / pipe）必须与上面的命中口径**一起、
 *   只在 Data_hazard 里算** —— 不许再把任何一级的判断搬回 Control。
 *   原因：判定一旦散在两边（历史上 Control 的 mem_load_use 要求 MEM_valid，
 *   这里的 mem_hit 却不查 MEM_valid），两份口径不同步就会出现“Control 不判停顿、
 *   而这里又拿不到可用数据”，消费者读到寄存器堆旧值（3'b000 = 不前递）。
 *   踩坑史（B5 缺陷、C2 归并）：见 syn/修复史_全量.md §HAZARD-1
 *
 * ★ 不许改回去的地方（细节见 syn/修复史_全量.md）：
 *   - EXU 级不查 valid、也不认自己那级的 load 当前递源 → §HAZARD-1
 *   - WB 前递要带 WB_valid；三个 load_use 都**不乘 IDU_valid** → §HAZARD-1
 * ============================================================================= */
module Data_hazard(
    input [4:0] IDU_rs1,
    input [4:0] IDU_rs2,

    input [4:0] EXU_rd,
    input [4:0] MEM_rd,
    input [4:0] MEM_PIPE_rd,
    input [4:0] MEM2_rd,
    input [4:0] WB_rd,

    input        IDU_valid,
    input        EXU_valid,
    input        MEM_valid,
    input        MEM_PIPE_valid,
    input        MEM2_valid,
    input        WB_valid,

    input        MEM_mem_ren,
    input        MEM_PIPE_mem_ren,   // MEM_PIPE 级是不是 load（load 在 MEM2 才前递）
    /* ★ v15：M1（= MEM 级）的 load 数据**本拍可用**（DCache 第二读口命中）。
     *   为 1 时 MEM 级可以当前递源、且不必停拍 —— 这正是把 load-use 从 2 拍压到 1 拍的地方。 */
    input        MEM_m1_ok,
    input        EXU_R_Wen,
    input        EXU_mem_ren,        // EXU 级是不是 load（是的话 EX_result 是地址，不能当前递源）
    input        MEM_R_Wen,
    input        MEM_PIPE_R_Wen,
    input        MEM2_R_Wen,
    input        WB_R_Wen,

    output [2:0] IDU_rs1_choice,
    output [2:0] IDU_rs2_choice,

    // v9 修复（C2）：冒险判定从 Control 搬到这里，与下面的命中口径同源。
    output logic load_use_stall,     // 需要把 IDU/前端按停（供 Control 接 IFU_stall）
    output logic exu_load_use,       // 分级明细，便于波形观察与调试
    output logic mem_load_use,
    output logic pipe_load_use
);

logic exu_hit_rs1;
logic mem_hit_rs1;
logic pipe_hit_rs1;
logic mem2_hit_rs1;
logic wb_hit_rs1;
// ★ 不变量：EXU 级的 load 结果**当拍还不可用**，不能作为前递源 —— exu_hit 必须带
//   ~EXU_mem_ren。原因：只按 R_Wen/rd 匹配又给最高优先级，就会在“EXU 里是 load、
//   IDU 里是它的消费者”那拍选中 EXU 的旧值（EX_result 对 load 是地址，实测 lw 后
//   紧跟的 add 拿到的是基址 x1）；应让仲裁落到 MEM/MEM_PIPE 并由 load_use_stall
//   把消费者按住，到 MEM2 级再由 3'b011 前递。§HAZARD-1
assign exu_hit_rs1 = EXU_R_Wen && ~EXU_mem_ren && (EXU_rd == IDU_rs1) && (EXU_rd != 0);
// MEM / MEM_PIPE 只认“非 load 且 valid”的指令：load 数据一律由 MEM2 级提供，
//   这样即使 valid/控制位不同步也不会误命中。
assign mem_hit_rs1 = MEM_R_Wen && MEM_valid && (~MEM_mem_ren || MEM_m1_ok)
                   && (MEM_rd == IDU_rs1) && (MEM_rd != 0);
// ★ v11（S6）：M2（MEM_PIPE）**也能前递 load 数据**了 —— LSU 在 M2 用当拍的 rdata
//   （DCache 命中同拍组合）按 _pipe 的偏移/位宽重新扩展，见 LSU.sv 的 "M2 级扩展" 块。
//   所以"load 数据只由 MEM2 提供"这条收窄成"MEM2 兜底"：正常情况下 M2 就给出真值。
assign pipe_hit_rs1 = MEM_PIPE_R_Wen && MEM_PIPE_valid && (MEM_PIPE_rd == IDU_rs1) && (MEM_PIPE_rd != 0);
assign mem2_hit_rs1 = MEM2_R_Wen && MEM2_valid && (MEM2_rd == IDU_rs1) && (MEM2_rd != 0);
// v9 修复（C5）：WB 前递补上 WB_valid，与其他四个源口径一致。原因：WBU 送出的
//   WB_R_Wen 是**未被 valid 门控**的寄存值（WBU 里 R_wen_next = R_wen_reg & valid_reg，
//   而送 Control 的是 R_wen_reg 本身），WBU 里坐一条被作废的空操作时 WB_R_Wen 仍可能
//   是 1、WB_rd 是残值，消费者会取走陈旧数据而寄存器堆那拍并没有写。现有流水线里它
//   **应当是冗余的**（实测加它前后全量回归一致），但显式写出来才能保证口径唯一。
assign wb_hit_rs1  = WB_R_Wen  && WB_valid && (WB_rd  == IDU_rs1) && (WB_rd  != 0);
// rs1 优先级从近到远：EXU > MEM > MEM_PIPE > MEM2 > WB（load 固定在 MEM2 前递）。
// choice 编码 = 前递选择码：3'b000 不前递取寄存器堆；3'b001 EXU；3'b010 MEM；
//   3'b101 MEM_PIPE；3'b011 MEM2（**load 数据只走这条**）；3'b100 WB。
assign IDU_rs1_choice = exu_hit_rs1 ? 3'b001 :
                        mem_hit_rs1 ? 3'b010 :
                        pipe_hit_rs1 ? 3'b101 :
                        mem2_hit_rs1 ? 3'b011 :
                        wb_hit_rs1  ? 3'b100 : 3'b000;

logic exu_hit_rs2;
logic mem_hit_rs2;
logic pipe_hit_rs2;
logic mem2_hit_rs2;
logic wb_hit_rs2;
assign exu_hit_rs2 = EXU_R_Wen && ~EXU_mem_ren && (EXU_rd == IDU_rs2) && (EXU_rd != 0);
// 与 rs1 同口径（见上方说明），rs2 用同样的优先级编码，保证双源规则一致。
assign mem_hit_rs2 = MEM_R_Wen && MEM_valid && (~MEM_mem_ren || MEM_m1_ok)
                   && (MEM_rd == IDU_rs2) && (MEM_rd != 0);
assign pipe_hit_rs2 = MEM_PIPE_R_Wen && MEM_PIPE_valid && (MEM_PIPE_rd == IDU_rs2) && (MEM_PIPE_rd != 0);
assign mem2_hit_rs2 = MEM2_R_Wen && MEM2_valid && (MEM2_rd == IDU_rs2) && (MEM2_rd != 0);
assign wb_hit_rs2  = WB_R_Wen  && WB_valid && (WB_rd  == IDU_rs2) && (WB_rd  != 0);
assign IDU_rs2_choice = exu_hit_rs2 ? 3'b001 :
                        mem_hit_rs2 ? 3'b010 :
                        pipe_hit_rs2 ? 3'b101 :
                        mem2_hit_rs2 ? 3'b011 :
                        wb_hit_rs2  ? 3'b100 : 3'b000;

/* ---------------------------------------------------------------------------
 * v9 修复（C2）：load-use 冒险判定（原来在 Control 里）
 * 判据与上面的“可用性”严格互补：EXU / MEM / MEM_PIPE 里是 load 且 rd 与 IDU 的源
 *   重叠就停（三个分级各自输出，便于波形观察）；到 MEM2 数据已就绪，由 3'b011 前递，
 *   不再停 —— 停顿长度因此自然覆盖到数据可用的那一刻。
 *
 * ★ 不变量：这三级的判定**不能**乘 IDU_valid。原因：IDU 在被 stall 的那拍会把下游
 *   valid 拉低，若这里要求 IDU_valid=1，暂停条件会在同一拍自己消失，消费者被提前
 *   放出去。不乘也不会误判：IDU 空时 inst_d 是 NOP（rs1=rs2=0）而这里都要求 rd != 0。
 * ★ 不变量：EXU 一级**也不乘 EXU_valid**。原因：被 EXU_inst_clear 作废的那拍
 *   EXU_R_Wen 与 EXU_mem_ren 已归零，“命中”和“停顿”同时消失 —— 这正是解除条件。
 * ------------------------------------------------------------------------- */
assign exu_load_use  = EXU_mem_ren
                     && (((EXU_rd == IDU_rs1) || (EXU_rd == IDU_rs2)) && (EXU_rd != 0));
// ★ v15：MEM 级的 load 若被 M1 探测口命中（MEM_m1_ok=1），数据当拍就可用 ⇒ **不停**。
//   不命中 / MMIO / store 才停 —— 这正是把 load-use 从 2 拍压到 1 拍的那一项。
assign mem_load_use  = MEM_mem_ren && MEM_valid && ~MEM_m1_ok
                     && (((MEM_rd == IDU_rs1) || (MEM_rd == IDU_rs2)) && (MEM_rd != 0));
assign pipe_load_use = MEM_PIPE_mem_ren && MEM_PIPE_valid
                     && (((MEM_PIPE_rd == IDU_rs1) || (MEM_PIPE_rd == IDU_rs2)) && (MEM_PIPE_rd != 0));
// MEM2（LSU 第三级）的 load 数据已经在 forward_val_wb 里，由 3'b011 直接前递（现在是兜底）。
// ★ v11（S6）：`pipe_load_use` 不再参与停顿 —— M2 已经能给出 load 真值（见上面 pipe_hit 的
//   说明），消费者在"load 位于 M2"那一拍就能被放出去，比原来少停 1 拍。
//   它仍然算出来，只做波形观察用（正常情况下应为 0；不为 0 说明 M2 前递路径断了）。
assign load_use_stall = exu_load_use | mem_load_use;

endmodule                                                           //Arbiter
