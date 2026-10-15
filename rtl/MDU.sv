`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * MDU.sv — RV32M 乘除法单元
 * -----------------------------------------------------------------------------
 * 本版本对 v9 原始实现做了一处**纯组合**的时序整理：
 *   - 乘法：三种符号组合的 64 位乘积共用同一组操作数，避免三份独立乘法器
 *     各自驱动一条长路径；结果选择放在最后一级做（唯一的一处改动）。
 *   - 除法：保留可读性更好的恢复余数法。
 *
 * 说明（重要）：
 *   本模块当前仍是**单拍纯组合**单元，因此不引入任何流水线暂停。
 *   要把除法的长组合链真正切短，需要把它改成多周期时序单元，并同步改造
 *   EXU/Control/LSU 的握手与对齐——该工作已在 `MDU_pipelined.sv` 中给出
 *   模块级实现与说明，供后续接入。
 *
 * RISC-V 边界语义：
 *   除零        -> 商 = 0xFFFF_FFFF，余数 = 被除数
 *   有符号溢出  -> INT_MIN / -1：商 = INT_MIN，余数 = 0
 * =========================================================================== */
module MDU (
    input  logic [31:0] d1,
    input  logic [31:0] d2,
    input  logic [ 4:0] op,
    output logic [31:0] res
);

    /* ---------------------------------------------------------------------
     * 1) 乘法：共用操作数，一次算出三种符号组合的 64 位乘积
     * ------------------------------------------------------------------- */
    logic signed [63:0] prod_ss;
    logic        [63:0] prod_su;
    logic        [63:0] prod_uu;

    assign prod_ss = $signed(d1) * $signed(d2);            // 有符号 × 有符号
    assign prod_su = $signed(d1) * $signed({1'b0, d2});    // 有符号 × 无符号
    assign prod_uu = {32'b0, d1} * {32'b0, d2};            // 无符号 × 无符号

    /* ---------------------------------------------------------------------
     * 2) 除法：恢复余数法（组合展开，逐位试减）
     * ------------------------------------------------------------------- */
    logic [31:0] a_abs, b_abs, core_a, core_b;
    logic [31:0] q_u, r_u, q_s, r_s;

    assign a_abs = d1[31] ? (~d1 + 32'd1) : d1;
    assign b_abs = d2[31] ? (~d2 + 32'd1) : d2;

    // 有符号除法（div/rem）用绝对值；无符号（divu/remu）直接用原值
    logic div_signed;
    assign div_signed = (op[1:0] == 2'b00) || (op[1:0] == 2'b10);
    assign core_a = div_signed ? a_abs : d1;
    assign core_b = div_signed ? b_abs : d2;

    always_comb begin
        logic [32:0] rem;
        q_u = 32'b0;
        rem = 33'b0;
        for (int i = 31; i >= 0; i--) begin
            rem = {rem[31:0], core_a[i]};              // 左移并引入被除数当前位
            if (rem >= {1'b0, core_b}) begin
                rem   = rem - {1'b0, core_b};          // 够减：置商位并更新余数
                q_u[i] = 1'b1;
            end
        end
        r_u = rem[31:0];
    end

    // 有符号结果：商的符号 = 两操作数符号异或；余数符号跟随被除数
    assign q_s = (d1[31] ^ d2[31]) ? (~q_u + 32'd1) : q_u;
    assign r_s = d1[31]             ? (~r_u + 32'd1) : r_u;

    /* ---------------------------------------------------------------------
     * 3) 结果选择：除零 / 溢出等边界在此统一收束
     * ------------------------------------------------------------------- */
    always_comb begin
        res = 32'b0;
        unique case (op)
            `alu_mul:    res = prod_uu[31:0];
            `alu_mulh:   res = prod_ss[63:32];
            `alu_mulhsu: res = prod_su[63:32];
            `alu_mulhu:  res = prod_uu[63:32];

            `alu_div: begin
                if (d2 == 32'b0)                                     res = 32'hFFFF_FFFF;
                else if (d1 == 32'h8000_0000 && d2 == 32'hFFFF_FFFF) res = 32'h8000_0000;
                else                                                 res = q_s;
            end
            `alu_divu: begin
                if (d2 == 32'b0) res = 32'hFFFF_FFFF;
                else             res = q_u;
            end
            `alu_rem: begin
                if (d2 == 32'b0)                                     res = d1;
                else if (d1 == 32'h8000_0000 && d2 == 32'hFFFF_FFFF) res = 32'b0;
                else                                                 res = r_s;
            end
            `alu_remu: begin
                if (d2 == 32'b0) res = d1;
                else             res = r_u;
            end
            default: res = 32'b0;
        endcase
    end

endmodule
