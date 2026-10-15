`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * MDU_pipelined.sv — RV32M 乘除法的「时序化」实现（**v9 上板改造后已接入 `EXU`**）
 * -----------------------------------------------------------------------------
 * 为什么要改：
 *   原实现把「3 个 32×32 乘法器 + 32 级恢复余数法除法链」全塞进 EX 级一级
 *   组合逻辑。仿真能过，但综合后这是整机最长的一条组合路径，FPGA 上很难收敛。
 *
 * 现在的结构（乘法与除法分开对待，因为二者代价不同）：
 *   ┌ 乘法：**单拍**。直接用端口输入 d1/d2 做组合乘法，与 EXU 锁存操作数
 *   │       在同一拍结束，结果在下一拍出现在 EX_result 上，与 ALU 完全同拍。
 *   │       因此乘法**不需要任何暂停**，也不会打乱流水线的 PC/rd/valid 对齐。
 *   └ 除法：**多周期**。32 拍「左移-试减-回写」时序状态机，每拍 1 位商。
 *           期间用 busy 暂停整机（前端 + 访存流水 + 写回寄存器同步冻结）。
 *
 * 握手：
 *   start ：EX 级本拍接受一条 M 扩展指令（单周期脉冲）
 *   busy  ：除法运算中（乘法恒为 0）
 *   done  ：结果已就绪（与 res 同拍）
 *   op[4] ：IDU 译码约定，1 表示走 MDU 通路
 *
 * RISC-V 边界语义（逐条保留）：
 *   除零        -> 商 = 0xFFFF_FFFF，余数 = 被除数
 *   有符号溢出  -> INT_MIN / -1：商 = INT_MIN，余数 = 0
 * =========================================================================== */
module MDU_pipelined #(
    // 除法迭代次数，固定 32（RV32 位宽）
    parameter DIV_BITS = 32
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,   // EX 级发射一条 M 指令
    input  logic [31:0] d1,      // 被乘数 / 被除数
    input  logic [31:0] d2,      // 乘数   / 除数
    input  logic [ 4:0] op,      // ALU/MDU 编码，op[4]=1 表示 M 扩展
    output logic [31:0] res,     // 运算结果
    output logic        busy,    // 除法运算中（用于暂停流水线）
    output logic        done     // 本拍结果有效
);

    /* ---------------------------------------------------------------------
     * 0) 译码
     *    mul/mulh/mulhsu/mulhu -> op[2]=0：单拍乘法
     *    div/divu/rem/remu     -> op[2]=1：多周期除法
     * ------------------------------------------------------------------- */
    logic [1:0] op_sel;
    assign op_sel = op[1:0];

    logic is_mul_pre, is_div_pre;
    assign is_mul_pre = start & op[4] & ~op[2];
    assign is_div_pre = start & op[4] &  op[2];

    logic div_signed_pre;
    assign div_signed_pre = (op_sel == 2'b00) || (op_sel == 2'b10);

    function automatic [31:0] abs32(input [31:0] v);
        abs32 = v[31] ? (~v + 32'd1) : v;
    endfunction

    /* =====================================================================
     * 1) 乘法：单拍路径
     * ---------------------------------------------------------------------
     * 用**端口输入** d1/d2 做组合乘法，与 EXU 锁存操作数同一拍完成；
     * 结果在下一个时钟边界寄存，于是 T+1 拍就与 ALU 结果同时出现在
     * EX_result 上，流水线无需为乘法暂停。
     * =================================================================== */
    logic [63:0] prod_ss, prod_su, prod_uu;
    assign prod_ss = $signed(d1) * $signed(d2);            // 有符号 × 有符号
    assign prod_su = $signed(d1) * $signed({1'b0, d2});    // 有符号 × 无符号
    assign prod_uu = {32'b0, d1} * {32'b0, d2};            // 无符号 × 无符号

    logic [31:0] mul_res_comb;
    always_comb begin
        unique case (op_sel)
            2'b00:   mul_res_comb = prod_uu[31:0];   // mul
            2'b01:   mul_res_comb = prod_ss[63:32];  // mulh
            2'b10:   mul_res_comb = prod_su[63:32];  // mulhsu
            default: mul_res_comb = prod_uu[63:32];  // mulhu
        endcase
    end

    logic [31:0] mul_res_reg;
    logic        mul_stb;          // 上一拍发生了乘法，结果已寄存

    /* =====================================================================
     * 2) 除法：32 拍顺次迭代（恢复余数法）
     * =================================================================== */
    logic [31:0] r_rem, r_q, r_div, r_a;
    logic [ 4:0] div_cnt;
    logic        div_run;          // 迭代中
    logic        div_hold;         // 结果已稳定，保持一拍后释放 busy

    // 锁存的原始操作数与译码（除法的边界判断与结果回正都要用，
    // 不能读端口 d1/d2/op —— 它们会随流水线前进而变成下一条指令）
    logic [31:0] op_a_r, op_b_r;
    logic [ 1:0] div_sel_r;
    logic        d1_neg_r, sign_diff_r, div_signed_r;

    logic        not_neg;
    logic [31:0] shifted, rem_nxt, q_nxt;
    assign shifted = {r_rem[30:0], r_a[31]};       // 左移一位并引入被除数当前位
    assign not_neg = ~(shifted < r_div);           // shifted >= r_div
    assign rem_nxt = not_neg ? (shifted - r_div) : shifted;
    assign q_nxt   = {r_q[30:0], not_neg};

    always_ff @(posedge clk) begin
        if (reset) begin
            mul_res_reg <= 32'b0;
            mul_stb     <= 1'b0;
            div_run     <= 1'b0;
            div_hold    <= 1'b0;
            div_cnt     <= 5'b0;
            r_rem       <= 32'b0;
            r_q         <= 32'b0;
            r_div       <= 32'b0;
            r_a         <= 32'b0;
            op_a_r      <= 32'b0;
            op_b_r      <= 32'b0;
            div_sel_r   <= 2'b0;
            d1_neg_r    <= 1'b0;
            sign_diff_r <= 1'b0;
            div_signed_r<= 1'b0;
        end else begin
            /* ---- 乘法：单拍寄存 ---- */
            if (is_mul_pre) begin
                mul_res_reg <= mul_res_comb;
                mul_stb     <= 1'b1;
            end else begin
                mul_stb     <= 1'b0;
            end

            /* ---- 除法：装载 / 迭代 / 结果保持 ---- */
            if (div_hold) begin
                div_hold <= 1'b0;                       // 结果窗口结束
            end else if (!div_run && is_div_pre) begin
                div_run     <= 1'b1;
                div_cnt     <= 5'b0;
                r_a         <= div_signed_pre ? abs32(d1) : d1;
                r_rem       <= 32'b0;
                r_div       <= div_signed_pre ? abs32(d2) : d2;
                r_q         <= 32'b0;
                op_a_r      <= d1;
                op_b_r      <= d2;
                div_sel_r   <= op_sel;
                d1_neg_r    <= d1[31];
                sign_diff_r <= d1[31] ^ d2[31];
                div_signed_r<= div_signed_pre;
            end else if (div_run) begin
                r_rem <= rem_nxt;
                r_q   <= q_nxt;
                r_a   <= {r_a[30:0], 1'b0};
                if (div_cnt == DIV_BITS-1) begin
                    div_run  <= 1'b0;
                    div_hold <= 1'b1;                   // 结果窗口
                    div_cnt  <= 5'b0;
                end else begin
                    div_cnt <= div_cnt + 5'd1;
                end
            end
        end
    end

    /* =====================================================================
     * 3) 除法结果回正与边界收束
     *    一律使用锁存的原始操作数 op_a_r/op_b_r 与 div_sel_r。
     * =================================================================== */
    logic [31:0] q_signed, r_signed;
    assign q_signed = sign_diff_r ? (~r_q + 32'd1) : r_q;
    assign r_signed = d1_neg_r    ? (~r_rem + 32'd1) : r_rem;

    logic [31:0] div_res;
    always_comb begin
        unique case (div_sel_r)
            2'b00: begin // div：有符号，除零->全1，溢出->INT_MIN
                if (op_b_r == 32'b0)                                     div_res = 32'hFFFF_FFFF;
                else if (op_a_r == 32'h8000_0000 && op_b_r == 32'hFFFF_FFFF) div_res = 32'h8000_0000;
                else                                                    div_res = q_signed;
            end
            2'b01: begin // divu：无符号，除零->全1
                if (op_b_r == 32'b0)                                     div_res = 32'hFFFF_FFFF;
                else                                                    div_res = r_q;
            end
            2'b10: begin // rem：有符号，除零->被除数，溢出->0
                if (op_b_r == 32'b0)                                     div_res = op_a_r;
                else if (op_a_r == 32'h8000_0000 && op_b_r == 32'hFFFF_FFFF) div_res = 32'b0;
                else                                                    div_res = r_signed;
            end
            default: begin // remu：无符号，除零->被除数
                if (op_b_r == 32'b0)                                     div_res = op_a_r;
                else                                                    div_res = r_rem;
            end
        endcase
    end

    /* =====================================================================
     * 4) 对外握手与结果
     * =================================================================== */
    logic div_active;
    assign div_active = div_run | div_hold;

    assign busy = div_active;          // 乘法恒不暂停
    assign done = mul_stb | div_hold;  // 本拍结果有效
    assign res  = div_active ? div_res : mul_res_reg;

endmodule
