`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * Branch_Predictor.sv — gshare 动态分支预测器（全局历史 XOR PC + BTB）
 * -----------------------------------------------------------------------------
 * 与双峰（bimodal）预测器的区别：
 *   双峰：直接拿 PC 低位索引一张 2 位计数器表，只看“这一条分支自己的历史”。
 *   gshare：把**全局历史寄存器 GHR**（最近 HIST_BITS 次分支结果）与 PC 低位
 *           做异或，再去索引计数器表。这样不同分支只要历史不同就会落到不同
 *           表项，能捕捉分支之间的相关性（例如循环退出分支与循环体分支）。
 *
 * 结构：
 *   - GHR ：HIST_BITS 位全局历史，每次 EX 级解析一条控制流指令就左移一位；
 *   - PHT ：1<<INDEX_BITS 项 2 位饱和计数器，索引 = pc[INDEX+1:2] ^ GHR；
 *   - BTB ：1<<INDEX_BITS 项 {valid, tag, target}，按 PC 索引，保存跳转目标。
 *
 * 端口：
 *   IF 级查询（组合）：
 *     fetch_pc -> pred_taken / pred_target / pred_index
 *     pred_index 是本次实际用到的 PHT 索引，必须随指令下传，
 *     否则流水线里 GHR 变化后会在错误的表项上更新。
 *   EX 级更新（同步）：
 *     update_en/update_pc/update_index/update_taken/update_target/update_correct
 *
 * 预测规则：BTB 命中 且 PHT 计数器最高位为 1 → 预测 taken。
 * 更新规则：
 *   - 方向：在 update_index 处饱和 +1 / -1；
 *   - 目标：taken 时刷新 BTB（valid/tag/target）；
 *   - 历史：GHR <= {GHR[HIST-2:0], update_taken}。
 * =========================================================================== */
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
    input  logic [INDEX_BITS-1:0] update_index,   // 预测时用过的 PHT 索引
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
    assign gidx    = fpc_idx ^ ghr[INDEX_BITS-1:0];

    assign btb_hit     = btb_valid[fpc_idx] && (btb_tag[fpc_idx] == ftag);
    assign pred_taken  = btb_hit && pht[gidx][1];   // BTB 命中且 gshare 预测 taken
    assign pred_target = btb_target[fpc_idx];
    assign pred_index  = gidx;                       // 随指令下传，供更新使用

    /* --------------------------- EX 级：更新 ------------------------------- */
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
            // ---- 方向计数器：在“预测时用过的索引”上更新 ----
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
            // ---- 统计 ----
            pred_cnt <= pred_cnt + 32'd1;
            if (update_correct) hit_cnt  <= hit_cnt  + 32'd1;
            else                miss_cnt <= miss_cnt + 32'd1;
        end
    end

endmodule
