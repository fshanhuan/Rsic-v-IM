// ★★★ 本文件在工程里存在【两个逐字相同的副本】，改一个必须同时改另一个 ★★★
//   ① ./rtl/MDU_pipelined.sv          （**在编译的那一份**：Vivado 与官方 cdp-tests 都取它）
//   ② ./experimental/MDU_pipelined.sv （历史位置，只留档，**不再参与编译**）
// 为什么必须待在 CPU RTL 目录里（H3）：官方评测 cdp-tests 的 Makefile 源码列表是
//   CPU_VSRC = $(wildcard $(CPU_DIR)/*.sv $(CPU_DIR)/*.v) —— 只通配 CPU 目录的**顶层**
//   （即 rtl/）。该目录里缺它时 Verilator 直接报
//   "%Error: Cannot find file containing module: 'MDU_pipelined'"（功能全对也编译不过）。
//   注意 -I$(CPU_DIR) 只对 `include 生效，**不能**当模块搜索路径用（报错里的搜索位置已证明）。
// 一致性自检：fc /b rtl\MDU_pipelined.sv experimental\MDU_pipelined.sv   （或 cmp）
// 完整记录：syn/修复史_全量.md §MDU-4

`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * MDU_pipelined.sv — RV32M 乘除法的「时序化」实现（v9 上板改造后已接入 EXU）
 * -----------------------------------------------------------------------------
 * 定位：EXU 的私有乘除单元（EX 级）。"pipelined" 指**把原来塞在 EX 一级组合逻辑里的乘除
 *   拆成多拍时序**，不是同时跑多条指令 —— 同一时刻只服务 EX 里那一条（原实现是整机最长
 *   组合路径，仿真能过、FPGA 难收敛，详见 syn/修复史_全量.md §MDU-2）。
 * 流水级：乘法 = 1 级（端口 d1/d2 组合乘 + 一级结果寄存器，下一拍与 ALU 同拍出 EX_result，
 *   不暂停流水）；除法 = 装载 + 32 拍「左移-试减-回写」迭代（每拍 1 位商）+ 1 拍结果窗口
 *   div_hold，期间 busy=1 暂停整机（前端 + 访存流水 + 写回寄存器同步冻结）。
 * ★ 接口契约：start=EX 级本拍发射一条 M 指令（单周期脉冲，每条只发一次）；busy=div_run|
 *   div_hold（乘法恒 0）；done=mul_stb|div_hold，**与 res 同拍**且只高 1 拍；res 只在 done
 *   那拍有效、之后可能被下一次 start 覆盖 → EXU 必须锁存。op[4]=1 才是 M 通路，op[2] 选乘(0)/除(1)，op[1:0] 选具体操作。
 * RISC-V 边界语义：除零 -> 商 = 0xFFFF_FFFF、余数 = 被除数；有符号溢出 INT_MIN / -1 -> 商 = INT_MIN、余数 = 0。
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

    // 译码：op[4]=1 才是 M 指令，op[2] 再分乘/除 —— mul/mulh/mulhsu/mulhu -> op[2]=0（单拍乘），
    //   div/divu/rem/remu -> op[2]=1（多周期除），op[1:0] 继续选具体操作；start=0 时二者恒 0
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

    // 乘法：单拍路径（组合乘 + 一级结果寄存器 = 1 级流水）。用**端口** d1/d2 组合乘，与 EXU 锁存
    //   操作数同拍完成，结果下一拍与 ALU 同拍上 EX_result，无需暂停；三种积都算再按 op_sel 选。
    logic [63:0] prod_ss, prod_su, prod_uu;
    assign prod_ss = $signed(d1) * $signed(d2);            // 有符号 × 有符号
    assign prod_su = $signed(d1) * $signed({1'b0, d2});    // 有符号 × 无符号
    assign prod_uu = {32'b0, d1} * {32'b0, d2};            // 无符号 × 无符号

    logic [31:0] mul_res_comb;
    always_comb begin
        // —— 组合乘法选择（无状态，op_sel 来自端口 op）：`unique case` 是断言式写法，要求分支互斥
        //   且完全覆盖，将来编码改坏（重叠/漏项）仿真期就报错；default 落在 mulhu（2'b11）。
        unique case (op_sel)
            2'b00:   mul_res_comb = prod_uu[31:0];   // mul
            2'b01:   mul_res_comb = prod_ss[63:32];  // mulh
            2'b10:   mul_res_comb = prod_su[63:32];  // mulhsu
            default: mul_res_comb = prod_uu[63:32];  // mulhu
        endcase
    end

    logic [31:0] mul_res_reg;
    logic        mul_stb;          // 上一拍发生了乘法，结果已寄存

    // 除法：32 拍顺次迭代（恢复余数法）。r_rem/r_q 每拍左移一位、试减一次，div_cnt 数到
    //   DIV_BITS-1 收工；状态全在下面那个 always_ff 里推进（DIV_BITS 拍迭代 + 1 拍结果窗口）。
    logic [31:0] r_rem, r_q, r_div, r_a;
    logic [ 4:0] div_cnt;
    logic        div_run;          // 迭代中
    logic        div_hold;         // 结果已稳定，保持一拍后释放 busy

    // ★ 不变量：边界判断与结果回正必须用**锁存**的原始操作数与译码（op_a_r/op_b_r/div_sel_r/
    //   d1_neg_r/sign_diff_r），不能读端口 d1/d2/op —— 端口会随流水线前进变成下一条指令。
    logic [31:0] op_a_r, op_b_r;
    logic [ 1:0] div_sel_r;
    logic        d1_neg_r, sign_diff_r;
    // ★ 不变量（v9 修复 C6）：div_signed_r 已删除，**别再加回来** —— 结果回正只用 sign_diff_r
    //   与 d1_neg_r，边界判断只用 op_a_r/op_b_r/div_sel_r，锁存它没有任何读者（Quartus 报
    //   Warning (10036) assigned a value but never read）。原文见 syn/修复史_全量.md §MDU-1

    logic        not_neg;
    logic [31:0] shifted, rem_nxt, q_nxt;
    assign shifted = {r_rem[30:0], r_a[31]};       // 左移一位并引入被除数当前位
    assign not_neg = ~(shifted < r_div);           // shifted >= r_div
    assign rem_nxt = not_neg ? (shifted - r_div) : shifted;
    assign q_nxt   = {r_q[30:0], not_neg};

    // —— 本模块唯一的 always_ff：维护乘法结果寄存器 + 除法迭代状态 ——
    //   乘法单拍寄存（mul_stb 与 mul_res_reg 同拍置起 = done 拍）；除法三段靠 if/else 链的**顺序**
    //   表达优先级：div_hold（窗口结束，只停一拍）> 装载（要求 !div_run）> 迭代，换序会让正在迭代的除法被重新装载。
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
        end else begin
            /* ---- 乘法：单拍寄存 ---- */
            if (is_mul_pre) begin
                mul_res_reg <= mul_res_comb;
                mul_stb     <= 1'b1;
            end else begin
                mul_stb     <= 1'b0;
            end

            /* ---- 除法：装载 / 迭代 / 结果保持（三段互斥，优先级见块首说明）---- */
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

    // 除法结果回正与边界收束：一律用锁存的原始操作数与 div_sel_r（见上方 ★ 不变量）。回正规则：商看 sign_diff_r（异号取负），余数看 d1_neg_r（跟随被除数符号）。
    logic [31:0] q_signed, r_signed;
    assign q_signed = sign_diff_r ? (~r_q + 32'd1) : r_q;
    assign r_signed = d1_neg_r    ? (~r_rem + 32'd1) : r_rem;

    logic [31:0] div_res;
    // —— 组合的除法结果选择 + 边界收束（按锁存的 div_sel_r 选商/余数与符号）：`unique case`
    //   同为断言式写法。各分支内先判除零、再判有符号溢出、最后才用回正后的商/余数 —— 顺序不能换。
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

    /* 对外握手与结果（EXU 侧用法见 EXU.sv）：发射拍给 start → 除法期间 busy=1 冻结整机 → done
     * 那拍 res 有效、必须被锁存 → 下一条指令的 start 会覆盖 res。res 与 rd 的对齐关系：MDU 只算
     * 数据，**rd 不在本模块里** —— 写回目标由 EXU 的 rd_reg 一路带着走，而 busy 期间整机冻结、
     * rd_reg 不动，所以 done 那拍的 res 与 EXU 里同一条指令的 rd 天然对齐。 */
    logic div_active;
    assign div_active = div_run | div_hold;

    assign busy = div_active;          // 乘法恒不暂停
    assign done = mul_stb | div_hold;  // 本拍结果有效
    assign res  = div_active ? div_res : mul_res_reg;

endmodule
