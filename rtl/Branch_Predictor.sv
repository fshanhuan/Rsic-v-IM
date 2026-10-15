/* =============================================================================
 * Branch_Predictor.sv — gshare 动态分支预测器（全局历史 XOR PC + BTB）
 * -----------------------------------------------------------------------------
 * 与双峰（bimodal）预测器的区别：
 *   双峰：直接拿 PC 低位索引一张 2 位计数器表，只看“这一条分支自己的历史”。
 *   gshare：把**全局历史寄存器 GHR**（最近 HIST_BITS 次分支结果）与 PC 低位
 *           做异或，再去索引计数器表。这样不同分支只要历史不同就会落到不同
 *           表项，能捕捉分支之间的相关性（例如循环退出分支与循环体分支）。
 *
 * 结构：GHR = HIST_BITS 位全局历史，每次 EX 级解析一条控制流指令就左移一位；
 *   PHT = 1<<INDEX_BITS 项 2 位饱和计数器，索引 = pc[INDEX+1:2] ^ GHR；
 *   BTB = 1<<INDEX_BITS 项 {valid, tag, target}，按 PC 索引，保存跳转目标。
 *   端口：IF 级组合查询 fetch_pc -> pred_taken/pred_target/pred_index（pred_index 是本次
 *   实际用到的 PHT 索引，**必须随指令下传**，否则流水线里 GHR 变化后会在错误的表项上更新）；
 *   EX 级同步更新 update_en/update_pc/update_index/update_taken/update_target/update_correct。
 * 预测规则：BTB 命中 且 PHT 计数器最高位为 1 → 预测 taken。更新规则：方向 = 在
 *   update_index 处饱和 +1/-1；目标 = taken 时刷新 BTB；历史 = GHR <= {GHR[HIST-2:0], taken}。
 * 位宽参数：INDEX_BITS = 表项数 2^INDEX_BITS（索引取 pc[INDEX_BITS+1:2]，即**字地址**、
 *   跳过恒 0 的 [1:0]）；TAG_BITS = BTB 标签宽（取 pc[31:INDEX_BITS+2]，与索引切片不重叠、
 *   合起来覆盖整个 PC，默认 24 = 32-6-2）；HIST_BITS = GHR 位数，也是异或时参与的低位位数
 *   （要求 HIST_BITS <= INDEX_BITS）。
 *
 * ★ 不变量：预测跳转必须与顺序推进用**同一个接受条件** —— 本模块给出的 pred_taken/
 *   pred_target 只是"建议"，真正拨 PC 的是 IFU，IFU 必须用 valid & ready & inst_valid &
 *   ~stall 这同一个条件去投机拨 PC；否则会出现"预测说跳了、PC 没跳"，而 EXU 侧比较
 *   actual==pred 认为没错，这条分支被丢掉却无人纠正（B4 的根因）。
 *   原文与实测见 syn/修复史_全量.md §BP-2（原文在 IFU.sv）
 * ============================================================================= */
`include "para.sv"
`timescale 1ns / 1ps

module Branch_Predictor #(
    parameter INDEX_BITS = `BP_INDEX_BITS,
    parameter TAG_BITS   = `BP_TAG_BITS,
    parameter HIST_BITS  = `BP_HIST_BITS
) (
    input  logic        clk,
    input  logic        reset,

    /* ---- IF 级查询（组合） ---- */
    input  logic [31:0] fetch_pc,
    output logic        pred_taken,
    output logic [31:0] pred_target,
    output logic [INDEX_BITS-1:0] pred_index,

    /* ---- EX 级更新（同步） ---- */
    input  logic        update_en,
    input  logic [31:0] update_pc,
    input  logic [INDEX_BITS-1:0] update_index,
    input  logic        update_taken,
    input  logic [31:0] update_target,
    input  logic        update_correct,

    /* ---- 统计 ---- */
    output logic [31:0] pred_cnt,
    output logic [31:0] hit_cnt,
    output logic [31:0] miss_cnt
);

    localparam LINES = 1 << INDEX_BITS;

    /* ------------------------------- 表项 ---------------------------------- */
    logic                btb_valid  [0:LINES-1];
    logic [TAG_BITS-1:0] btb_tag    [0:LINES-1];
    logic [31:0]         btb_target [0:LINES-1];
    logic [1:0]          pht        [0:LINES-1];
    logic [HIST_BITS-1:0] ghr;                    // 全局历史寄存器

    /* --------------------------- IF 级：预测 ------------------------------- */
    logic [INDEX_BITS-1:0] fpc_idx;   // PC 低位
    logic [TAG_BITS-1:0]   ftag;
    logic [INDEX_BITS-1:0] gidx;      // gshare 索引 = PC ^ GHR
    logic                  btb_hit;

    assign fpc_idx = fetch_pc[INDEX_BITS+1:2];
    assign ftag    = fetch_pc[31:INDEX_BITS+2];
    // ★ 不变量：gshare 索引必须是 fpc_idx ^ GHR[INDEX_BITS-1:0] —— 这正是与双峰的全部区别（用
    //   全局历史把同一条 PC 在不同历史下映射到不同 PHT 表项）；改成直连 fpc_idx 就退化成双峰。
    assign gidx    = fpc_idx ^ ghr[INDEX_BITS-1:0];

    // ★ 不变量：BTB 用 fpc_idx（PC 一一映射，项里存 tag/target），PHT 用 gidx（gshare 映射）；
    //   若 BTB 也异或 GHR，同一条 PC 会随历史命中不同表项，tag/target 就与 PC 不再对应。
    assign btb_hit     = btb_valid[fpc_idx] && (btb_tag[fpc_idx] == ftag);
    assign pred_taken  = btb_hit && pht[gidx][1];   // BTB 命中且 gshare 预测 taken
    assign pred_target = btb_target[fpc_idx];
    assign pred_index  = gidx;                       // 随指令下传，供更新使用

    /* --------------------------- EX 级：更新 ------------------------------- */
    // uidx/utag 用 update_pc 现算，只给 BTB 用（PHT 见下面那条不变量）
    logic [INDEX_BITS-1:0] uidx;
    logic [TAG_BITS-1:0]   utag;
    assign uidx = update_pc[INDEX_BITS+1:2];
    assign utag = update_pc[31:INDEX_BITS+2];

    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < LINES; i = i + 1) begin
                btb_valid[i]  <= 1'b0;
                btb_tag[i]    <= {TAG_BITS{1'b0}};
                btb_target[i] <= 32'b0;
                pht[i]        <= 2'b01;   // 初始弱不跳转
            end
            ghr      <= {HIST_BITS{1'b0}};
            pred_cnt <= 32'b0;
            hit_cnt  <= 32'b0;
            miss_cnt <= 32'b0;
        end else if (update_en) begin
            // ★ 不变量：PHT 必须索引 update_index（预测拍随指令下传的 gshare 索引），**不能**用
            //   update_pc 现算的 uidx —— GHR 在 IF→EX 之间已左移过，现算索引会打到另一个表项，
            //   预测永远学不会。饱和计数：taken 向 2'b11、不 taken 向 2'b00 各走一步，到顶保持。
            if (update_taken) begin
                if (pht[update_index] != 2'b11) pht[update_index] <= pht[update_index] + 2'b01;
            end else begin
                if (pht[update_index] != 2'b00) pht[update_index] <= pht[update_index] - 2'b01;
            end
            // ---- BTB：只在 taken 时分配/刷新 ----
            if (update_taken) begin
                btb_valid[uidx]  <= 1'b1;
                btb_tag[uidx]    <= utag;
                btb_target[uidx] <= update_target;
            end
            // ---- 全局历史左移 ----
            ghr <= {ghr[HIST_BITS-2:0], update_taken};
            // ---- 统计 ----：每次有控制流指令在 EX 解析记一次预测，按 update_correct 二选一
            pred_cnt <= pred_cnt + 32'd1;
            if (update_correct) hit_cnt  <= hit_cnt  + 32'd1;
            else                miss_cnt <= miss_cnt + 32'd1;
        end
    end

endmodule
