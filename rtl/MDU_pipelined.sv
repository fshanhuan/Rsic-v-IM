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
 *   不暂停流水）；除法 = 装载 + 16 拍 radix-4 迭代（每拍 2 位商）+ 1 拍结果窗口 div_hold，
 *   常规路径 busy 共 17 拍；**v11（S5）起有三类快路径只要 1 拍**（div/rem 配对缓存命中、
 *   除数为 0、|a|<|b|），见下方 §v11-S5 说明。
 * ★ v9 面积/时序改造（本次）：
 *   ① 乘法从「3 个并列 32x32 乘法器（≈12 个 DSP48E1）」压到「**1 个** 32x32 无符号乘法器
 *      + 符号修正（abs32 + 64 位条件取反）」——DSP 用量约 4 倍下降，代价是两个 32 位取负器、
 *      一个 64 位条件取负器与几组选择器（纯 LUT/CARRY）。
 *   ② 除法从 32 拍 radix-2 改成 16 拍 radix-4（每拍两级「左移-试减-回写」组合展开），
 *      整机停顿拍数直接减半（32+1 -> 16+1），结果窗口 div_hold 与全部边界语义逐字保留。
 * ★ 接口契约：start=EX 级本拍发射一条 M 指令（单周期脉冲，每条只发一次）；busy=div_run|
 *   div_hold（乘法恒 0）；done=mul_stb|div_hold，**与 res 同拍**且只高 1 拍；res 只在 done
 *   那拍有效、之后可能被下一次 start 覆盖 → EXU 必须锁存。op[4]=1 才是 M 通路，op[2] 选乘(0)/除(1)，op[1:0] 选具体操作。
 * RISC-V 边界语义：除零 -> 商 = 0xFFFF_FFFF、余数 = 被除数；有符号溢出 INT_MIN / -1 -> 商 = INT_MIN、余数 = 0。
 * =========================================================================== */
module MDU_pipelined #(
    // 除法操作数位宽（RV32 固定 32）；迭代拍数由它派生：DIV_BITS/2（每拍 2 位商）
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
    //   操作数同拍完成，结果下一拍与 ALU 同拍上 EX_result，无需暂停。
    // ★ 单乘法器改造：原来并列例化 3 个 32x32 乘法器（prod_ss/prod_su/prod_uu，约 12 个 DSP48E1），
    //   改成**只实例化 1 个无符号 32x32 乘法器**，符号靠「先取幅值、再按需对 64 位积取反」修正。
    //   正确性证明（64 位二补数）：
    //     ① 有符号/无符号乘法的**低 32 位完全相同**，mul 直接取 prod_mag[31:0]，不需要符号信息；
    //     ② 有符号乘法可写成 a*b = sign * |a|*|b|（sign = a[31]^b[31]），故 mulh/mulhsu 取
    //        prod_signed[63:32]，其中 prod_signed = sign ? -prod_mag : prod_mag；
    //     ③ **64 位永不溢出**：|a| ≤ 2^31，|b| ≤ 2^32-1（mulhsu 的无符号乘数取原值），
    //        故 |a|*|b| ≤ 2^31*(2^32-1) < 2^63 —— 「无符号积截 64 位后取反」恰好等于真二补数积，
    //        不会出现 |积| = 2^63 那种取反后又溢出的死角；
    //     ④ abs32(INT_MIN) = 0x8000_0000 正是 |INT_MIN| = 2^31（按无符号读），
    //        INT_MIN*INT_MIN = 2^62 仍 < 2^63，64 位取反依然正确（穷举 + 随机已验证）。
    //   注：mulhsu 是「有符号 × 无符号」——被乘数取幅值、乘数 d2 保持无符号原值，符号只看 d1[31]。
    logic [31:0] mul_a, mul_b;     // 送进唯一乘法器的幅值 / 无符号输入
    logic        mul_neg;          // 64 位积是否需要取反（符号修正）
    always_comb begin
        // —— 组合幅值/符号选择（无状态，op_sel 来自端口 op）：`unique case` 是断言式写法，要求分支
        //   互斥且完全覆盖，将来编码改坏（重叠/漏项）仿真期就报错；default 落在 mulhu（2'b11）。
        unique case (op_sel)
            2'b00: begin mul_a = d1;        mul_b = d2;        mul_neg = 1'b0;          end // mul    -> prod_mag 低 32 位
            2'b01: begin mul_a = abs32(d1); mul_b = abs32(d2); mul_neg = d1[31]^d2[31]; end // mulh   -> prod_signed 高 32 位
            2'b10: begin mul_a = abs32(d1); mul_b = d2;        mul_neg = d1[31];        end // mulhsu -> prod_signed 高 32 位
            default: begin mul_a = d1;      mul_b = d2;        mul_neg = 1'b0;          end // mulhu  -> prod_mag 高 32 位
        endcase
    end

    logic [63:0] prod_mag, prod_signed;
    assign prod_mag    = {32'b0, mul_a} * {32'b0, mul_b};              // ★ 全模块唯一的一个乘法器
    assign prod_signed = mul_neg ? (~prod_mag + 64'd1) : prod_mag;     // 64 位二补数取反（符号修正）

    logic [31:0] mul_res_comb;
    always_comb begin
        // —— 组合乘法选择（无状态）：`unique case` 同为断言式写法，分支互斥且完全覆盖。
        unique case (op_sel)
            2'b00:   mul_res_comb = prod_mag[31:0];      // mul
            2'b01:   mul_res_comb = prod_signed[63:32];  // mulh
            2'b10:   mul_res_comb = prod_signed[63:32];  // mulhsu
            default: mul_res_comb = prod_mag[63:32];     // mulhu
        endcase
    end

    logic [31:0] mul_res_reg;
    logic        mul_stb;          // 上一拍发生了乘法，结果已寄存

    // 除法：16 拍 radix-4 迭代（每拍算 2 位商）。r_rem/r_q 是迭代状态，每拍把**两级 radix-2 的
    //   「左移-试减-回写」组合展开**：第 1 级吃被除数当前位 r_a[31]，第 2 级吃下一位 r_a[30]，
    //   商一次进 2 位 {r_q[29:0], ge1, ge2}，r_a 一次左移 2 位 → 32 位商只要 16 拍。
    //   div_cnt 数到 DIV_ITER-1 收工；状态全在下面那个 always_ff 里推进（16 拍迭代 + 1 拍结果窗口）。
    localparam int DIV_ITER = DIV_BITS / 2;   // 迭代拍数 = 16（每拍 2 位商）
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

    logic        ge1, ge2;                 // 第 1/2 级「shifted >= r_div」（原 not_neg，即不需要借位）
    logic [31:0] shifted1, rem1, shifted2, rem2, q_nxt;

    /* =========================================================================
     * v11（S5）：除法快路径 + div/rem 配对缓存
     * -------------------------------------------------------------------------
     * ★ 先纠正一个**错误的预期**（别照它去优化）：迭代拍数并不能靠"除数前导零"大幅缩短。
     *   商位宽的界是 `bitlen(a) - bitlen(b) + 1`，而本算法的 r_a 从 bit31 往下**逐个**消耗被
     *   除数，所以拍数 = ceil(商位宽/2)。对 b=10：0xFFFFFFFF/10 的商是 0x19999999（29 位）
     *   → 仍需 15 拍，只省 1 拍。只有"被除数本身很小"时才能省，而那要改成本余数寄存器预装
     *   被除数高位的形式（等于重写除法器），不值。
     *
     * 真正有收益的是这三类，且都是**精确**的（不是启发式）：
     *   ① **div/rem 同源配对缓存**：`q = x/10; r = x%10;` 是 C 里除法赋值的标准形态，也是
     *      printf/itoa 的每一次十进制转换 —— 两次除法算的是完全相同的商和余数。缓存上次的
     *      (原始操作数, 有符号标志) → (商幅值, 余数幅值)，第二次直接命中，**17 拍 → 1 拍**。
     *      缓存的是幅值 r_q/r_rem，结果仍走原有 div_res 的边界收束（除零 / INT_MIN÷-1），
     *      所以那套语义一行都不用改。
     *   ② **除数为 0**：div_res 的边界分支直接出结果（商全 1 / 余数=被除数），不必迭代。
     *   ③ **|a| < |b|**：商 0、余数 |a|（有符号回正由 r_signed 用 d1_neg_r 完成）。
     *   ②③ 都是 17 拍 → 1 拍，条件各是一次 32 位比较（≈ 35 LUT）。
     *
     * ★ 时序契约：快路径在**装载那拍**就把 div_hold 置起 → 下一拍 busy=1 且 done=1，
     *   res 由刚装入的 r_q/r_rem 经 div_res 组合给出。整机因此只冻 1 拍。
     * ========================================================================= */
    logic        cq_vld, cq_sig;
    logic [31:0] cq_a, cq_b, cq_q, cq_rem;
    logic [31:0] a_mag, b_mag;
    logic        cq_hit;
    assign a_mag  = div_signed_pre ? abs32(d1) : d1;
    assign b_mag  = div_signed_pre ? abs32(d2) : d2;
    // ★ 命中比较用**原始操作数** d1/d2（不是幅值）：abs 是确定性的，用原值比较等价，
    //   但省掉一组 32 位比较器 —— 而且能区分 +0/-0 之外的一切（-0 就是 0，无所谓）。
    assign cq_hit = cq_vld && (cq_sig == div_signed_pre) && (cq_a == d1) && (cq_b == d2);
    assign shifted1 = {r_rem[30:0], r_a[31]};                 // 第 1 级：左移一位并引入被除数 bit31
    assign ge1      = ~(shifted1 < r_div);
    assign rem1     = ge1 ? (shifted1 - r_div) : shifted1;    // 试减成立则减，否则保持（恢复余数法）
    assign shifted2 = {rem1[30:0], r_a[30]};                  // 第 2 级：接着引入被除数 bit30
    assign ge2      = ~(shifted2 < r_div);
    assign rem2     = ge2 ? (shifted2 - r_div) : shifted2;
    assign q_nxt    = {r_q[29:0], ge1, ge2};                  // 一拍进 2 位商（radix-4）
    // ★ 位宽不变量（为什么两级都敢用 32 位减法）：第 j 步（j=1..32）之前恒有 r_rem ≤ 2^(j-1)-1
    //   且 r_rem < r_div，故 shifted = 2*r_rem + bit ≤ 2^j - 1 ≤ 2^32-1，永不溢出，第 2 级也不会因
    //   截位而与「先做第 1 步、下一拍再做第 2 步」的 radix-2 结果分叉。除零时 r_div=0 会让幅值乱走，
    //   但那种情况 div_res 走「除零」分支，r_rem/r_q 根本不参与结果，无副作用。
    // ★ 语义不变量：radix-4 只是把 radix-2 的相邻两步并到同一拍，试减/回写的次序与逐位商完全一致，
    //   所以 div_res 的边界收束（除零 / INT_MIN÷-1）与商余数回正逻辑一行都不必改。

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
            // v11（S5）：配对缓存复位后无效
            cq_vld      <= 1'b0;
            cq_sig      <= 1'b0;
            cq_a        <= 32'b0;
            cq_b        <= 32'b0;
            cq_q        <= 32'b0;
            cq_rem      <= 32'b0;
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
                // ---- 所有分支共用的现场锁存（边界判断/结果回正/缓存键都读它们）----
                op_a_r      <= d1;
                op_b_r      <= d2;
                div_sel_r   <= op_sel;
                d1_neg_r    <= d1[31];
                sign_diff_r <= d1[31] ^ d2[31];
                div_cnt     <= 5'b0;
                r_div       <= b_mag;
                cq_a        <= d1;                      // 缓存键：原始操作数 + 有符号标志
                cq_b        <= d2;
                cq_sig      <= div_signed_pre;
                if (cq_hit) begin
                    // ① 配对缓存命中：商/余数取上一条 div/rem 算好的幅值，1 拍出结果
                    div_run <= 1'b0;
                    div_hold <= 1'b1;
                    r_q     <= cq_q;
                    r_rem   <= cq_rem;
                    r_a     <= 32'b0;
                    cq_vld  <= 1'b1;                    // 键不变，保持有效
                end else if (b_mag == 32'b0) begin
                    // ② 除数为 0：div_res 的边界分支直接给结果（商全 1 / 余数=被除数）
                    div_run  <= 1'b0;
                    div_hold <= 1'b1;
                    r_q      <= 32'b0;
                    r_rem    <= a_mag;
                    r_a      <= 32'b0;
                    cq_q     <= 32'b0;
                    cq_rem   <= a_mag;
                    cq_vld   <= 1'b1;
                end else if (a_mag < b_mag) begin
                    // ③ |a| < |b|：商 0、余数 |a|（有符号回正由 r_signed 用 d1_neg_r 完成）
                    div_run  <= 1'b0;
                    div_hold <= 1'b1;
                    r_q      <= 32'b0;
                    r_rem    <= a_mag;
                    r_a      <= 32'b0;
                    cq_q     <= 32'b0;
                    cq_rem   <= a_mag;
                    cq_vld   <= 1'b1;
                end else begin
                    // 常规路径：16 拍 radix-4 迭代
                    div_run  <= 1'b1;
                    r_a      <= a_mag;
                    r_rem    <= 32'b0;
                    r_q      <= 32'b0;
                    cq_vld   <= 1'b0;                   // 迭代期间缓存不完整 → 先失效
                end
            end else if (div_run) begin
                r_rem <= rem2;                          // 一拍走完两级 radix-2 = 2 位商
                r_q   <= q_nxt;
                r_a   <= {r_a[29:0], 2'b00};            // 一次消耗被除数 2 位
                if (div_cnt == DIV_ITER-1) begin
                    div_run  <= 1'b0;
                    div_hold <= 1'b1;                   // 结果窗口
                    div_cnt  <= 5'b0;
                    // 迭代收工：填缓存（缓存键在装载那拍已锁存）
                    cq_q     <= q_nxt;
                    cq_rem   <= rem2;
                    cq_vld   <= 1'b1;
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
