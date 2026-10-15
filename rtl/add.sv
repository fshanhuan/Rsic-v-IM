// 共享加法器。
// 通过 choose_add_sub 选择 add_2 或其按位取反加 1，实现加/减统一。
// 纯组合、位宽由参数 BW 决定（默认 4 只是占位；全工程唯一例化点是 ALU.sv 的 add_inst0，传 .BW(BW)=32）：result = add_1 + (choose_add_sub ? add_2_inv : add_2) + {{(BW-1){1'b0}}, choose_add_sub}。末项那个 1 位常量就是**进位输入**（补码减法=取反加一），add_2_inv 由**调用方**提供（ALU 传 ~d2），接错极性会静默算错减法。
// 它实际承担：addi/lui/auipc/load-store 的 rs1+imm、分支/jal 的 PC+imm、jalr 的 rs1+imm —— EXU 把这些统一映射成 `alu_add/`alu_sub 后再进 ALU，本模块没有别的直接例化点。
module add
#(
    parameter BW=4
)
(
   input choose_add_sub,
   input [BW-1:0]add_1,
   input [BW-1:0]add_2,
   input [BW-1:0]add_2_inv,
   output [BW-1:0]result
);
// if {choose_add_sub == 1} addd_1 - add_2 else  add_1 + add_2   ← 原作者留下的等价说明（addd_1 是笔误，值就是 add_1），保留不改。
// ★ 不变量：加减法统一靠"取反 + 进位"成对出现（补码减法=取反加一），改一个就错 —— 唯一一行组合赋值：加数选择 + 进位输入；没有流水寄存器、没有复位。末项 {{(BW-1){1'b0}}, ...} 要求 BW >= 1（BW=1 时复制 0 次，退化成 1 位全加器，仍合法）。
assign result = add_1 + (choose_add_sub ? add_2_inv : add_2) + {{(BW-1){1'b0}}, choose_add_sub};

endmodule
