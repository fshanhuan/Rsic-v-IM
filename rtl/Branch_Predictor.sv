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
    /* ---- v11（S4）：返回地址栈（RAS）的 call/ret 分类（EX 级，与 update_en 同拍） ---- */
    input  logic        update_is_call,   // jal/jalr 且 rd∈{x1,x5}
    input  logic        update_is_ret,    // jalr x0, 0(x1|x5)  → 规范意义上的 return

    /* ---- 统计 ---- */
    output logic [31:0] pred_cnt,
    output logic [31:0] hit_cnt,
    output logic [31:0] miss_cnt
);

    localparam LINES = 1 << INDEX_BITS;
    localparam RAS_DEPTH = 8;

    /* ------------------------------- 表项 ---------------------------------- */
    // ★ v14：256 行之后表项写在**打包向量**里（原来是一行一位/一行的 unpacked 数组）。
    //   两个理由，都不是风格问题：
    //   1) Verilator 对"for 循环里给数组做非阻塞赋值"的展开有上限（%Error-BLKLOOPINIT），
    //      LINES=64 能展开、>=256 直接报错 —— 与 v11 给 DCache 的 valid 换打包向量是同一个坑；
    //   2) 复位变成一条整向量赋值（`btb_valid <= '0`），三个仿真器与综合器口径一致。
    //   位选/动态索引语义与数组完全等价（`btb_valid[idx]`、`btb_tag[idx]` 都照旧）。
    // ★ ram_style=distributed：这些表是"同步写、**组合读**"（IF 级当拍要看），BRAM 做不到
    //   组合读，所以必须落在 LUTRAM（RAM64X1）上。256 行 × 57 位 ≈ 230 个 LUT6，几乎白送；
    //   不加这个属性 Vivado 会退化成 14.6k 个触发器（也能跑，但白烧 FF）。
    (* ram_style = "distributed" *) logic [LINES-1:0]               btb_valid;
    (* ram_style = "distributed" *) logic [LINES-1:0][TAG_BITS-1:0] btb_tag;
    (* ram_style = "distributed" *) logic [LINES-1:0][31:0]         btb_target;
    // v11（S4）：BTB 项附带 2 位"控制流种类"，让取指侧知道这条 PC 是不是 return ——
    //   是的话目标要取 RAS 顶，而不是 btb_target（后者只有"上一次"的返回地址）。
    //   KIND_NORMAL / KIND_CALL / KIND_RET，CALL 只用于统计与可读性，预测行为与 NORMAL 相同。
    localparam [1:0] KIND_NORMAL = 2'b00, KIND_CALL = 2'b01, KIND_RET = 2'b10;
    (* ram_style = "distributed" *) logic [LINES-1:0][1:0]          btb_kind;
    logic [1:0]                     upd_kind;
    // v11（S4）：返回地址栈 —— 8 项、循环栈、带"满/空"饱和。
    logic [31:0]         ras [0:RAS_DEPTH-1];
    logic [3:0]          ras_sp;                  // 0..RAS_DEPTH
    logic                ras_empty, ras_full;
    assign ras_empty = (ras_sp == 4'd0);
    assign ras_full  = (ras_sp == RAS_DEPTH);
    // ★ 索引必须掩码：ras_sp=0 时 (0-1) 下溢成 15，直接拿去索引 [0:7] 是越界读（Verilator 报
    //   SELRANGE、iverilog 给 x）。掩码后恒落在 0..7，且该值只在 ~ras_empty 时才被选中。
    logic [31:0]         ras_top;
    assign ras_top = ras[(ras_sp - 4'd1) & 4'd7];
    // ★ v14：PHT 的 2 位饱和计数器拆成**两根 1 位向量**（hi/lo），不用 [LINES-1:0][1:0]。
    //   原因：iverilog 不支持"对二维打包数组连续做两次索引"（`pht[idx][1]` 直接报
    //   "Array index expressions must be constant"），而全量回归跑在 iverilog 上。
    //   拆成两根之后 `pht_hi[idx]` / `pht_lo[idx]` 都是普通的一维位选，三家仿真器一致。
    //   计数器编码仍是 2 位二进制 {hi,lo}：00 强不跳 / 01 弱不跳 / 10 弱跳 / 11 强跳。
    (* ram_style = "distributed" *) logic [LINES-1:0] pht_hi;
    (* ram_style = "distributed" *) logic [LINES-1:0] pht_lo;
    logic [HIST_BITS-1:0] ghr;                    // 全局历史寄存器

    /* --------------------------- IF 级：预测 ------------------------------- */
    logic [INDEX_BITS-1:0] fpc_idx;   // PC 低位
    logic [TAG_BITS-1:0]   ftag;
    logic [INDEX_BITS-1:0] gidx;      // gshare 索引 = PC ^ GHR
    logic                  btb_hit;
    logic                  pred_is_ret;

    assign fpc_idx = fetch_pc[INDEX_BITS+1:2];
    assign ftag    = fetch_pc[31:INDEX_BITS+2];
    // ★ 不变量：gshare 索引必须是 fpc_idx ^ GHR[INDEX_BITS-1:0] —— 这正是与双峰的全部区别（用
    //   全局历史把同一条 PC 在不同历史下映射到不同 PHT 表项）；改成直连 fpc_idx 就退化成双峰。
    assign gidx    = fpc_idx ^ ghr[INDEX_BITS-1:0];

    // ★ 不变量：BTB 用 fpc_idx（PC 一一映射，项里存 tag/target），PHT 用 gidx（gshare 映射）；
    //   若 BTB 也异或 GHR，同一条 PC 会随历史命中不同表项，tag/target 就与 PC 不再对应。
    assign btb_hit     = btb_valid[fpc_idx] && (btb_tag[fpc_idx] == ftag);
    // ★ v11（S4）：判"这条 PC 是 return"**只认 BTB 命中 + kind**，不看 PHT 计数器 ——
    //   return 的"方向"（一定跳）是确定性的，2 位计数器只会让它冷启动时白错一次。
    assign pred_is_ret = btb_hit && (btb_kind[fpc_idx] == KIND_RET) && ~ras_empty;
    assign pred_taken  = pred_is_ret ? 1'b1 : (btb_hit && pht_hi[gidx]);
    assign pred_target = pred_is_ret ? ras_top : btb_target[fpc_idx];
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
            // ★ v14：表项是打包向量，复位是一条整向量赋值（不再有 for 循环 —— 见声明处的说明）
            btb_valid  <= {LINES{1'b0}};
            btb_tag    <= {LINES{{TAG_BITS{1'b0}}}};
            btb_target <= {LINES{32'b0}};
            btb_kind   <= {LINES{KIND_NORMAL}};
            pht_hi     <= {LINES{1'b0}};   // {hi,lo} = 01 = 初始弱不跳转
            pht_lo     <= {LINES{1'b1}};
            for (i = 0; i < RAS_DEPTH; i = i + 1)
                ras[i]   <= 32'b0;
            ras_sp   <= 4'd0;
            ghr      <= {HIST_BITS{1'b0}};
            pred_cnt <= 32'b0;
            hit_cnt  <= 32'b0;
            miss_cnt <= 32'b0;
        end else if (update_en) begin
            // ★ 不变量：PHT 必须索引 update_index（预测拍随指令下传的 gshare 索引），**不能**用
            //   update_pc 现算的 uidx —— GHR 在 IF→EX 之间已左移过，现算索引会打到另一个表项，
            //   预测永远学不会。饱和计数：taken 向 11、不 taken 向 00 各走一步，到顶保持。
            // ★ v14：计数器拆成两根 1 位向量后，加减法要按位写（等价于对 {hi,lo} 的 2 位饱和计数）：
            //     +1：lo' = ~lo | hi      hi' = hi | lo      （11 时保持 11）
            //     -1：lo' = hi & ~lo      hi' = hi & lo      （00 时保持 00）
            //   这两组式子与原来的 `pht[idx] ± 1` 逐状态等价（见 _diag/bp_sweep.sh 回归：
            //   改法前后 64/6 配置必须给出同一组误预测数 10 680）。
            if (update_taken) begin
                pht_lo[update_index] <= ~pht_lo[update_index] | pht_hi[update_index];
                pht_hi[update_index] <=  pht_hi[update_index] | pht_lo[update_index];
            end else begin
                pht_lo[update_index] <= pht_hi[update_index] & ~pht_lo[update_index];
                pht_hi[update_index] <= pht_hi[update_index] &  pht_lo[update_index];
            end
            // ---- BTB：只在 taken 时分配/刷新；v11（S4）同时刷"种类" ----
            if (update_taken) begin
                btb_valid[uidx]  <= 1'b1;
                btb_tag[uidx]    <= utag;
                btb_target[uidx] <= update_target;
                btb_kind[uidx]   <= upd_kind;
            end
            // ---- v11（S4）：RAS 压栈/弹栈，**跟着架构语义走、不跟预测走** ----
            //   一条 call 无论预测对错都要压栈（它确实执行了），一条 ret 无论预测对错都要弹栈；
            //   预测错的 ret 会在 EX 用 update_target 把 PC 改回来，但栈已经弹对。
            if (update_is_call) begin
                if (!ras_full) begin
                    ras[ras_sp[2:0]] <= update_pc + 32'd4;   // 返回地址 = 调用点 + 4
                    ras_sp           <= ras_sp + 4'd1;
                end
            end else if (update_is_ret) begin
                if (!ras_empty) ras_sp <= ras_sp - 4'd1;
            end
            // ---- 全局历史左移 ----
            ghr <= {ghr[HIST_BITS-2:0], update_taken};
            // ---- 统计 ----：每次有控制流指令在 EX 解析记一次预测，按 update_correct 二选一
            pred_cnt <= pred_cnt + 32'd1;
            if (update_correct) hit_cnt  <= hit_cnt  + 32'd1;
            else                miss_cnt <= miss_cnt + 32'd1;
        end
    end

    assign upd_kind = update_is_ret ? KIND_RET : (update_is_call ? KIND_CALL : KIND_NORMAL);

endmodule
