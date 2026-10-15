`include "para.sv"
`timescale 1ns / 1ps

// ALU — EXU 内部的整数运算单元：统一承接算术、逻辑、移位和比较。RV32M 乘除法不在本模块里（由 EXU 并行的 MDU 执行），本模块遇到 M 编码只返回 0（永远不会被真正选中）。
// 例化点：EXU.sv 的 ALU 实例（.BW(32)，d1/d2 用已锁存的 add1_reg/add2_reg）。choice 是 5 位 alu_op 编码（para.sv §ALU 编码），bit[4]=1 表示 RV32M 走 MDU。
// 接口约定：比较结果**只放在 res[0]**、高位全 0（res 是 0/1 布尔，不是真值位图）。
// choice 编码 → 运算（完整编码表见 para.sv §ALU 编码这个宏定义处；本模块只实现 ≤5'b01010 的整数部分）：00000 add=d1+d2 ｜ 00001 sub=d1-d2 ｜ 00010 or ｜ 00011 and ｜ 00100 xor ｜ 00101 signed_comparator（res[0]=$signed(d1)<$signed(d2)）｜ 00110 unsigned_comparator（res[0]=d1<d2）｜ 00111 equal（宏名叫 equal，实际给的是"**不**相等"）｜ 01000/01001/01010 sll/srl/sra（移位量只取 d2[4:0]）｜ 1xxxx alu_mul…alu_remu（RV32M，由 MDU 执行，本模块一律落到 default 的 res='0）。
// 分支方向的"另一半"在 IDU/EXU：IDU 把 beq/bge/bgeu 标成 inv_flag，EXU 用 {exec_res[31:1], exec_res[0]^inv_flag_reg} 把"不等/不小于"翻成"相等/大于等于"，所以这里只需实现不等与小于这两个方向。
// ★ 不变量：`unique case` 蕴含的两个综合限定符（parallel_case / full_case）必须成立 —— parallel_case（各 case 项互斥 → 可并行译码、不生成优先级链）与 full_case（全覆盖 → 不生成锁存器）。工具打印那条 INFO 是 unique 的正常产物，**不是**待修告警（别为了消掉它去掉 unique）；反过来若工具报 "unique case violation"，说明真有多路 choice 同时命中或漏了覆盖，那才必须查编码表。这里 choice 是常量互不相同的 5 位编码、default 兜住 RV32M 与非法编码，两个限定符都成立。
// ★ 不变量：choose_add_sub 必须在**每一条分支**上都赋确定值：它一边决定 add 实例做加还是做减、一边被本块读 add_result，任何路径漏赋值都会推出锁存器（并让 res 吃到上一拍的残留选择）。比较类分支先 res='0 再写 res[0]，保证高位为 0，EXU 可直接把 res[0] 当布尔用。
// 有符号比较（blt/bge 的一半）为什么要两个符号位：异号时负数一定更小 → 直接取 d1 的符号位就是结论（同时规避了 d1-d2 只在异号时发生的溢出）；同号时减法不溢出 → add_result[BW-1] 就是结论。若简化成只看 add_result[BW-1]，异号溢出时会给出相反的比较结果。
module ALU #(
    parameter BW = 32
) (
    input      [BW-1:0] d1,
    input      [BW-1:0] d2,
    input      [4:0]    choice,
    output logic [BW-1:0] res
);

    logic choose_add_sub;
    logic [BW-1:0]       add_result;
    logic [BW-1:0]       d2_inv;
    logic [BW-1:0]       d1_inv;
    assign d2_inv = ~d2;   // d2_inv 有两种用途：xor 的 (d1 & ~d2) | (~d1 & d2)，以及 add 实例的减法（~d2 + 1），所以要提成具名 wire
    assign d1_inv = ~d1;

    // 组合逻辑里只做功能选择；真正的加/减法被折叠到下面的 add 模块复用。
    always_comb begin
        res = '0;
        unique case (choice)
            `alu_signed_comparator: begin
                choose_add_sub = 1'b1;
                res = '0;
                res[0] = (d1[BW-1] != d2[BW-1]) ? d1[BW-1] : add_result[BW-1];
            end
            `alu_unsigned_comparator: begin   // 不借减法，直接让综合做 d1<d2 的比较器
                choose_add_sub = 1'b0;
                res[0] = (d1 < d2);
            end
            `alu_add: begin
                choose_add_sub = 1'b0;
                res = add_result;
            end
            `alu_sub: begin
                choose_add_sub = 1'b1;
                res = add_result;
            end
            `alu_and: begin
                res = d1 & d2;
                choose_add_sub = 1'b0;
            end
            `alu_or: begin
                res = d1 | d2;
                choose_add_sub = 1'b0;
            end
            `alu_xor: begin
                res = (d1 & d2_inv) | (d1_inv & d2);
                choose_add_sub = 1'b0;
            end
            `alu_equal: begin               // 名字叫 equal，给的是"不相等"；EXU 再与 inv_flag 异或才得到 beq/bne 的方向
                choose_add_sub = 1'b0;
                res = '0;
                res[0] = (d1 != d2);
            end
            `alu_sll: begin
                choose_add_sub = 1'b0;
                res = d1 << d2[4:0];
            end
            `alu_srl: begin
                choose_add_sub = 1'b0;
                res = d1 >> d2[4:0];
            end
            `alu_sra: begin                 // 只有算术右移需要 $signed；三个移位都只取 d2[4:0]（RV32 移位量 5 位），不截位在仿真里未定义、综合里会被优化掉
                choose_add_sub = 1'b0;
                res = $signed(d1) >>> d2[4:0];
            end
            default: begin                  // RV32M（choice[4]=1，由 MDU 执行）与一切非法编码都落这里，返回 0 —— 这是有意的兜底，不是漏写分支
                choose_add_sub = 1'b0;
                res = '0;
            end
        endcase
    end

    // 通过 choose_add_sub 复用一套加法器，实现 add/sub/部分比较所需的差值计算。有符号比较还要读 add_result[BW-1]（差值的符号位），所以这个实例不只服务 add/sub —— 删掉它 alu_signed_comparator 立刻失效。组合路径 choose_add_sub → add → add_result → res 无环（add 不读 res），但 add 的延时直接压在 ALU 关键路径上。
    add #(
        .BW (BW)
    ) add_inst0 (
        .choose_add_sub (choose_add_sub),
        .add_1          (d1),
        .add_2          (d2),
        .add_2_inv      (d2_inv),
        .result         (add_result)
    );

endmodule
