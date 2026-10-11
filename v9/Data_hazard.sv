/* Deal with the Data hazard —— v9 的**唯一**前递/冒险裁决源
 *
 * 修复（C2）：这个模块原来是"前递仲裁器"，而 load-use 冒险判定散在 Control 里，
 * 两边各写一份"某一级的数据到底可不可用"的条件。历史上 B5 缺陷就是这么出的：
 *   - Control 的 mem_load_use 要求 MEM_valid；
 *   - 这里的 mem_hit 却不检查 MEM_valid；
 * 两份口径一旦不同步，就会出现"Control 不判停顿、而这里把优先级更高的
 * 3'b000 返回，把 MEM2 级上真正可用的 load 数据挡掉"，消费者读到寄存器堆旧值。
 *
 * 现在把口径**收敛到这一个文件**，并且用同一组命中条件同时驱动两件事：
 *   1) 谁来前递   —— IDU_rs1_choice / IDU_rs2_choice（数据多路选择的编码）
 *   2) 要不要停   —— load_use_stall（某一级是 load 且 rd 与 IDU 的源重叠）
 * Control 只做两件事：把编码翻译成数据值、把 load_use_stall 接到 PC/EXU 的冻结上。
 * **Control 里不再有任何"某级是不是 load / 数据可不可用"的判断。**
 *
 * 命中口径（五个前递源，逐条写清，不再有隐含假设）：
 *   EXU      : R_Wen 且**不是 load**（load 在 EXU 里 EX_result 还是地址，不能用）
 *              —— 不查 EXU_valid：它是仲裁链里最快的一环，valid 由 load_use 承担
 *   MEM      : R_Wen 且 valid 且不是 load
 *   MEM_PIPE : R_Wen 且 valid 且不是 load
 *   MEM2     : R_Wen 且 valid（load 的数据**只在**这一级前递）
 *   WB       : R_Wen 且 valid
 *   rd == 0 的任何一级都不算命中（x0 永远读寄存器堆的 0）。
 *
 * load-use 停顿口径（必须与上面的"可用性"严格互补）：
 *   某一级是 load、rd != 0、rd 与 IDU 的 rs1/rs2 重叠 → 数据当拍不可用 → 必须停。
 *   三级分别是 EXU / MEM / MEM_PIPE；到 MEM2 数据已经可前递，不再停。
 *   注意 EXU 一级**不看 EXU_valid**：被 EXU_inst_clear 作废的那一拍，
 *   EXU_R_Wen/mem_ren 已经归零，"命中"与"停顿"会同时消失，语义自洽。
 */
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
    input        EXU_R_Wen,
    input        EXU_mem_ren,        // EXU 级是不是 load（是的话 EX_result 是地址，不能当前递源）
    input        MEM_R_Wen,
    input        MEM_PIPE_R_Wen,
    input        MEM2_R_Wen,
    input        WB_R_Wen,

    output [2:0] IDU_rs1_choice,
    output [2:0] IDU_rs2_choice,

    // v9 修复（C2）：冒险判定从 Control 搬到这里，与上面的命中口径同源。
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
// EXU 级的 load 结果**当拍还不可用**，不能作为前递源。
//   原来的 exu_hit 只看 R_Wen/rd 匹配，优先级又最高，于是在“EXU 里是 load、
//   IDU 里是它的消费者”的那一拍，会选中 EXU 级的旧值（EX_result 对 load 而言
//   是地址），消费者拿到错数据（实测：lw 之后紧跟的 add 得到的是基址 x1，
//   而不是 load 回来的值）。
//   正确做法：EXU 级若是 load，就不认 exu_hit，让仲裁落到 MEM/MEM_PIPE，
//   期间由 load_use_stall 把消费者按在 IDU 里等；到 MEM2 级再由 3'b011 前递。
assign exu_hit_rs1 = EXU_R_Wen && ~EXU_mem_ren && (EXU_rd == IDU_rs1) && (EXU_rd != 0);
// MEM / MEM_PIPE 级的前递只认"非 load 且 valid"的指令，load 的数据一律由
//   MEM2 级（forward_val_wb）提供；这样即使 valid/控制位不同步也不会误命中。
assign mem_hit_rs1 = MEM_R_Wen && MEM_valid && ~MEM_mem_ren && (MEM_rd == IDU_rs1) && (MEM_rd != 0);
assign pipe_hit_rs1 = MEM_PIPE_R_Wen && MEM_PIPE_valid && ~MEM_PIPE_mem_ren && (MEM_PIPE_rd == IDU_rs1) && (MEM_PIPE_rd != 0);
assign mem2_hit_rs1 = MEM2_R_Wen && MEM2_valid && (MEM2_rd == IDU_rs1) && (MEM2_rd != 0);
// v9 修复（C5）：WB 级前递补上 WB_valid，与其他四个源口径一致。
//   WBU 送出来的 WB_R_Wen 是**未被 valid 门控**的寄存值（WBU.sv 里
//   R_wen_next = R_wen_reg & valid_reg，而送 Control 的是 R_wen_reg 本身），
//   所以 WBU 里坐一条被作废的空操作时，WB_R_Wen 仍可能是 1、WB_rd/WB_rd_value
//   仍是上一条的残值；若消费者 rs 正好撞上那个残值 rd，就会取走陈旧数据，
//   而寄存器堆那一拍并没有写（写被 valid 掐掉了）。
//   在现有流水线里这一条**应当是冗余的**（实测加它前后全量回归逐项一致），
//   但显式写出来才能保证"谁来前递"只有一个口径。
assign wb_hit_rs1  = WB_R_Wen  && WB_valid && (WB_rd  == IDU_rs1) && (WB_rd  != 0);
// rs1 优先级从近到远：EXU > MEM > MEM_PIPE > MEM2 > WB。
// load 的结果固定在 MEM2 级前递（MEM/MEM_PIPE 级的 load 已在上面的命中条件里排除）。
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
// 与 rs1 同口径（见上方说明）
assign mem_hit_rs2 = MEM_R_Wen && MEM_valid && ~MEM_mem_ren && (MEM_rd == IDU_rs2) && (MEM_rd != 0);
assign pipe_hit_rs2 = MEM_PIPE_R_Wen && MEM_PIPE_valid && ~MEM_PIPE_mem_ren && (MEM_PIPE_rd == IDU_rs2) && (MEM_PIPE_rd != 0);
assign mem2_hit_rs2 = MEM2_R_Wen && MEM2_valid && (MEM2_rd == IDU_rs2) && (MEM2_rd != 0);
assign wb_hit_rs2  = WB_R_Wen  && WB_valid && (WB_rd  == IDU_rs2) && (WB_rd  != 0);
// rs2 采用同样的优先级编码，保证双源操作数的前递规则一致。
assign IDU_rs2_choice = exu_hit_rs2 ? 3'b001 :
                        mem_hit_rs2 ? 3'b010 :
                        pipe_hit_rs2 ? 3'b101 :
                        mem2_hit_rs2 ? 3'b011 :
                        wb_hit_rs2  ? 3'b100 : 3'b000;

/* ---------------------------------------------------------------------------
 * v9 修复（C2）：load-use 冒险判定（原来在 Control 里）
 * ---------------------------------------------------------------------------
 * 判据与上面的"可用性"严格互补：
 *   - EXU 里是 load      -> 数据不可用，必须停（exu_load_use）
 *   - MEM 里是 load      -> 数据不可用，必须停（mem_load_use）
 *   - MEM_PIPE 里是 load -> 数据不可用，必须停（pipe_load_use）
 *   其余情况数据已就绪，由前递直接给值，不再停。
 * 停顿长度因此自然覆盖到 load 数据可用的那一刻：数据可用的下一拍
 * 三个条件全为 0，消费者被放行并拿到正确的前递值。
 *
 * 三级的"是不是 load 且 rd 与 IDU 的源寄存器相同"判定**不能**乘 IDU_valid：
 *   IDU 在被 stall 的那一拍会把下游 valid 拉低，如果这里要求 IDU_valid=1，
 *   暂停条件会在同一拍自己消失，消费者被提前放出去。
 *   不乘也不会误判：IDU 空时 inst_d 是 NOP（rs1=rs2=0），而这里都要求 rd != 0，
 *   NOP 永远匹配不上；被冻结的 inst_d 保留的正是那条等待中的指令的源寄存器。
 *
 * EXU 一级**也不乘 EXU_valid**（与上面 exu_hit 同一取向）：
 *   被 EXU_inst_clear 作废的那一拍，EXU_R_Wen 与 EXU_mem_ren 已经归零，
 *   "命中"和"停顿"会同时消失 —— 这正是 load-use 停顿的解除条件。
 * ------------------------------------------------------------------------- */
assign exu_load_use  = EXU_mem_ren
                     && (((EXU_rd == IDU_rs1) || (EXU_rd == IDU_rs2)) && (EXU_rd != 0));
assign mem_load_use  = MEM_mem_ren && MEM_valid
                     && (((MEM_rd == IDU_rs1) || (MEM_rd == IDU_rs2)) && (MEM_rd != 0));
assign pipe_load_use = MEM_PIPE_mem_ren && MEM_PIPE_valid
                     && (((MEM_PIPE_rd == IDU_rs1) || (MEM_PIPE_rd == IDU_rs2)) && (MEM_PIPE_rd != 0));
// 三级之后（MEM2 = LSU 第三级）load 数据已经在 forward_val_wb 里了，
//   由 3'b011 编码直接前递，不再需要暂停。
assign load_use_stall = exu_load_use | mem_load_use | pipe_load_use;

endmodule                                                           //Arbiter
