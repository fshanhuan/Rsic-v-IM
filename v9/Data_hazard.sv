/* Deal with the Data hazard */

// 前递仲裁器只负责回答一个问题：
// IDU 当前看到的 rs1/rs2，应该优先从哪个流水级取最新值。
// 编码本身不搬运数据，真正的数据多路选择在 Control 中完成。
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
    input        MEM_PIPE_mem_ren,   // v9 修复（B5）：MEM_PIPE 级是不是 load（load 在 MEM2 才前递）
    input        EXU_R_Wen,
  input        EXU_mem_ren,     // EXU 级是不是 load（是的话当拍 EX_result 是地址，不能当前递源）
    input        MEM_R_Wen,
    input        MEM_PIPE_R_Wen,
    input        MEM2_R_Wen,
    input        WB_R_Wen,

    output [2:0] IDU_rs1_choice,
    output [2:0] IDU_rs2_choice
);

logic exu_hit_rs1;
logic mem_hit_rs1;
logic pipe_hit_rs1;
logic mem2_hit_rs1;
logic wb_hit_rs1;
// v9 上板改造修正：EXU 级的 load 结果**当拍还不可用**，不能作为前递源。
//   原来的 exu_hit 只看 R_Wen/rd 匹配，优先级又最高，于是在“EXU 里是 load、
//   IDU 里是它的消费者”的那一拍，会选中 EXU 级的旧值（EX_result 对 load 而言
//   是地址），消费者拿到错数据（实测：lw 之后紧跟的 add 得到的是基址 x1，
//   而不是 load 回来的值）。
//   正确做法：EXU 级若是 load，就不认 exu_hit，让仲裁落到 MEM_PIPE
//   （load 数据真正可用的那一级），期间由 Control 的 load-use 暂停把消费者
//   按在 IDU 里等。这与注释里“MEM 若是 load 则返回 000 交给上层做停顿”是
//   同一条思路，只是原来漏了 EXU 这一级。
assign exu_hit_rs1 = EXU_R_Wen && ~EXU_mem_ren && (EXU_rd == IDU_rs1) && (EXU_rd != 0);
// v9 修复（B5）：仲裁口径必须与 Control 的 load-use 暂停口径**完全一致**。
//   原实现里：
//     - Control 的 mem_load_use/pipe_load_use 要求 MEM_valid / MEM_PIPE_valid；
//     - 这里的 mem_hit 却**不检查 MEM_valid**，而且 MEM 若是 load 就直接返回 3'b000
//       （"不复用，交给上层停顿"）。
//   两处口径不一致时会出现这样的状态：load 的 payload 已经流到 MEM 级、带着
//   mem_ren=1/rd=x3，但 valid=0（load-use 暂停期间 EXU 的 valid 与控制寄存器不同步）。
//   此时 Control 不判停顿（要求 valid），而 mem_hit 却命中并把优先级更高的
//   3'b000 返回，**把 MEM2 级上真正可用的 load 数据挡掉了** —— 消费者（例如紧接着的
//   sw 用 load 的结果做数据）拿到寄存器堆里的旧值（实测写进 0）。
//   修法：MEM/pipe 级的前递只认"非 load 且 valid"的指令，load 的数据一律由
//   MEM2 级（forward_val_wb）提供；这样即使 valid/控制位不同步也不会误命中。
//   注意：load-use 的停顿判定仍在 Control（这里只改"谁来前递"，不影响何时停顿）。
assign mem_hit_rs1 = MEM_R_Wen && MEM_valid && ~MEM_mem_ren && (MEM_rd == IDU_rs1) && (MEM_rd != 0);
assign pipe_hit_rs1 = MEM_PIPE_R_Wen && MEM_PIPE_valid && ~MEM_PIPE_mem_ren && (MEM_PIPE_rd == IDU_rs1) && (MEM_PIPE_rd != 0);
assign mem2_hit_rs1 = MEM2_R_Wen && MEM2_valid && (MEM2_rd == IDU_rs1) && (MEM2_rd != 0);
assign wb_hit_rs1  = WB_R_Wen  && (WB_rd  == IDU_rs1) && (WB_rd  != 0);
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
// 与 rs1 同口径（见上方 B5 修复说明）
assign mem_hit_rs2 = MEM_R_Wen && MEM_valid && ~MEM_mem_ren && (MEM_rd == IDU_rs2) && (MEM_rd != 0);
assign pipe_hit_rs2 = MEM_PIPE_R_Wen && MEM_PIPE_valid && ~MEM_PIPE_mem_ren && (MEM_PIPE_rd == IDU_rs2) && (MEM_PIPE_rd != 0);
assign mem2_hit_rs2 = MEM2_R_Wen && MEM2_valid && (MEM2_rd == IDU_rs2) && (MEM2_rd != 0);
assign wb_hit_rs2  = WB_R_Wen  && (WB_rd  == IDU_rs2) && (WB_rd  != 0);
// rs2 采用同样的优先级编码，保证双源操作数的前递规则一致。
assign IDU_rs2_choice = exu_hit_rs2 ? 3'b001 :
                        mem_hit_rs2 ? 3'b010 :
                        pipe_hit_rs2 ? 3'b101 :
                        mem2_hit_rs2 ? 3'b011 :
                        wb_hit_rs2  ? 3'b100 : 3'b000;

endmodule                                                           //Aribter
