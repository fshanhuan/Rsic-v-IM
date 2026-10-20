`timescale 1ns / 1ps
`include "para.sv"

/* =============================================================================
 * IFU.sv — 取指级：PC 生成 + **取指队列**（前端与后端的解耦点）
 * -----------------------------------------------------------------------------
 * 上游：Control（dnpc / dnpc_flag）、ICache（resp_valid / cpu_rdata）、
 *       Branch_Predictor（pred_taken / pred_target / pred_index，组合查询）。
 * 下游：IDU（inst / pc / snpc / valid / pred_*），ICache（ic_addr / ic_req）。
 *
 * ★ v10 改造（前端解耦）——结构说明：
 *   旧实现里 IFU 的 PC 与 ICache 是**紧耦合闭环**：PC 只有在"这一拍的返回数据属于
 *   当前 PC"（inst_valid）且下游 ready 时才能推进，而 ICache 又要求 PC 连续稳定 2 拍
 *   才敢交付一条 → 稳态 **3 拍/条**（实测 0.33 IPC 上限）。PC 生成器与取指之间
 *   一个缓冲都没有，后端的每一次停拍都直接损失一次本就稀缺的取指机会。
 *
 *   新结构分成两半，中间用 QDEPTH 深的队列隔开：
 *
 *      pc ──组合──> ICache（1 拍延迟）──> [取指队列] ──> IDU
 *       ▲                                   │
 *       └── pred / dnpc 决定下一拍 ──────────┘（只在队列有空间时才发请求）
 *
 *   - **生产者（PC 生成侧）**：队列有空间就每拍发一次请求，PC 每拍 +4（或跳预测目标）。
 *     ICache 1 拍后交付，指令连同自己的 pc / pred_* 一起入队。稳态 **1 条/拍**。
 *     ★ 关键：PC 生成**不再看下游 ready/stall** —— 这是解耦的全部意义。
 *   - **消费者（IDU 侧）**：valid = 队头有效，ready = IDU_ready，两者同时为 1 才出队
 *     （advance_en）。后端 load-use / MDU 忙 / D-Cache 未命中期间队列照常填空，
 *     等后端恢复后**每拍一条**地把积压吐出来，而不是回到 3 拍一条。
 *
 * ★ 接口契约（改之前必读）：
 *   - 一条指令被"发出"（ic_req）就等于被**接收**：队列保证最终交付，或者随重定向
 *     一起丢弃。所以预测跳转可以在发请求那一拍就改 PC（旧的 §IFU-1 不变量在此结构下
 *     由构造保证：再没有"发了却没人接"的窗口）。
 *   - dnpc_flag（真实重定向）**不看 ready、不看 valid、不看队列深度**：当拍清空队列、
 *     清空在途请求、PC 直接拨到 dnpc。它同时也**就是** IDU 的 flush。
 *     ★ 不许加回任何门控 —— dnpc_flag 只有一拍宽（ecall/mret/fence.i/异常不重发）。
 *   - inst 在 valid=0 时输出 `NOP。
 *   - pred_* 必须**跟着指令走**（随队列条目一起入队出队）。绝不能在出队那拍再去查
 *     预测器 —— 那时 fetch_pc 早已是别的地址，IDU/EXU 会把别人的预测结果当成这条
 *     指令的预测（静默错，无报错）。
 *
 * 参考：docs/模块阅读文档.md、syn/修复史_全量.md
 * ============================================================================= */
module IFU #(
    // 取指队列深度。4 = 足以吸收 load-use(1 拍)/D-Cache 未命中(2 拍)的抖动，
    //   并对 MDU 多拍忙(17~34 拍)给出 4 条的前置缓冲；再深收益递减而面积线性涨。
    parameter QDEPTH = 4
) (
    input               clock,
    input               reset,
    input       [31:0]  dnpc,
    input               dnpc_flag,
    input       [31:0]  irom_data,      // ICache.cpu_rdata
    input               inst_valid,     // ICache.resp_valid（与本拍 irom_data 同拍）
    input               pred_taken,
    input       [31:0]  pred_target,
    input  [`BP_INDEX_BITS-1:0] pred_index,

    // ---- 取指请求侧（→ ICache）----
    output      [31:0]  ic_addr,        // 当拍要取的地址（组合直通 BRAM）
    output logic        ic_req,         // 本拍发一次取指
    output      [31:0]  fetch_pc,       // 取指侧 PC（→ Branch_Predictor 的 fetch_pc）

    // ---- 交付侧（→ IDU）----
    output      [31:0]  snpc,
    output logic [31:0] pc,
    output      [31:0]  inst,
    output logic        pred_taken_out,
    output      [31:0]  pred_target_out,
    output logic [`BP_INDEX_BITS-1:0] pred_index_out,

    input               ready,
    output logic        valid
);

    localparam QPTR = (QDEPTH > 1) ? $clog2(QDEPTH + 1) : 1;
    localparam [QPTR-1:0] QMAX  = QDEPTH;      // 满
    localparam [QPTR-1:0] QLAST = QDEPTH - 1;  // 最大下标

    /* ======================= ① PC 生成（生产者侧） ======================= */
    // pc_f 是**取指侧** PC 寄存器；输出端口 pc 是**交付侧**队头 PC，两者绝不能混用
    //   （混用会把 PC 生成器接到队列上，闭环又回来了）。
    logic [31:0] pc_f;
    logic [31:0] seq_next, fetch_next;
    assign seq_next   = pc_f + 32'd4;
    // 预测跳转目标。pred_* 是**对 ic_addr 这条指令**的预测（预测器按 pc_f 组合查询）。
    assign fetch_next = pred_taken ? pred_target : seq_next;

    assign ic_addr  = pc_f;
    assign fetch_pc = pc_f;

    /* ======================= ② 在途请求的元数据（1 拍对齐） ======================= */
    // 发请求那一拍把 {pc, pred_*} 存下来，下一拍与 ICache 的响应拼成队列条目。
    //   ★ 不变量：这里必须与 ICache 的 idx_r/tag_r 同沿更新（两者都是 cpu_req 的延迟），
    //     否则指令会配上别人的 pc/pred_* —— 这类错配不会有任何报错。
    logic        meta_v;
    logic [31:0] meta_pc;
    logic        meta_pt;
    logic [31:0] meta_ptg;
    logic [`BP_INDEX_BITS-1:0] meta_pi;

    /* ======================= ③ 取指队列（QDEPTH 项，队头恒在 slot 0） ======================= */
    logic                      q_v   [0:QDEPTH-1];
    logic [31:0]               q_pc  [0:QDEPTH-1];
    logic                      q_pt  [0:QDEPTH-1];
    logic [31:0]               q_ptg [0:QDEPTH-1];
    logic [`BP_INDEX_BITS-1:0] q_pi  [0:QDEPTH-1];
    logic [31:0]               q_ins [0:QDEPTH-1];

    logic [QPTR-1:0] q_cnt;

    logic flush;
    assign flush = dnpc_flag;

    // 出队：队头有效且下游这一拍能收（ready 已含 ~stall，见 IDU.ready_last）
    logic pop;
    assign pop = q_v[0] & ready;

    // 入队：在途请求这一拍拿到响应（inst_valid 与 meta_v 恒等，两者都是 ic_req 的延迟）
    // ★ v10 时序修正：这里**不要**再与 ~flush 相与。flush 在同一组 always_ff 里是**更高
    //   优先级的分支**（`if (reset) ... else if (flush) ... else if (push ...)`），所以
    //   flush 那拍 push 是 1 也不会写进队列；而把它写进 CE 会把 dnpc_flag（一条
    //   EXU add1_reg → ALU → Control 的长组合链）拖进 4 个队列槽的时钟使能，
    //   实测就是关键路径的端点（timing_noila.default.rpt：q_ptg_reg[*]/CE）。
    logic push;
    assign push = meta_v & inst_valid;

    // 入队落点：出队时腾出来的是**最高的已占用槽**（cnt-1），否则就是第一个空槽（cnt）
    logic [QPTR-1:0] push_slot;
    assign push_slot = pop ? (q_cnt - {{(QPTR-1){1'b0}}, 1'b1}) : q_cnt;

    // 发请求条件：本拍账务完成后仍要给"即将产生的那条在途请求"留一个空位
    //   occ_after_this_cycle = q_cnt + push - pop，要求 <= QDEPTH-1
    logic [QPTR-1:0] occ_after;
    assign occ_after = q_cnt
                     + (push ? {{(QPTR-1){1'b0}}, 1'b1} : {QPTR{1'b0}})
                     - (pop  ? {{(QPTR-1){1'b0}}, 1'b1} : {QPTR{1'b0}});
    logic room;
    assign room = (occ_after <= QLAST);

    // ★ 不变量：dnpc_flag 当拍**不许**真的发请求进队列（PC 正要被拨走，发出来的也是错路径）。
    //   但这里**不再**用 `~flush` 门控 —— 那会把 dnpc_flag（EXU add1_reg → ALU → Control
    //   的长组合链）拖到 **IROM 的读使能** mem_en 上，实测这就是关键路径的第一条
    //   （timing_noila.default.rpt：…… → irom_inst/g_rom.rdata_reg_*/ENARDEN，2.383ns）。
    //   正确性由"flush 优先级最高"保证，不靠门控：
    //     · pc_f   ：`else if (dnpc_flag) pc_f <= dnpc;` 在 ic_req 之前 → PC 还是按 dnpc 走
    //     · meta_v ：flush 分支把它清 0 → 下一拍 push = meta_v & inst_valid = 0，
    //                这一拍读回来的那条**绝不会**进队列
    //     · 队列/q_cnt：flush 分支整体清空
    //   即"发一个注定被丢弃的读请求"，代价是那拍多一次 BRAM 读，收益是关键路径缩短。
    assign ic_req = ~reset & room;

    // ---- 队列本体：每槽一个 always_ff，条件与"pop 的移位语义"严格一致 ----
    //   ★ 优先级：flush > 本槽被选为入队落点 > pop 时整体下移 > 保持。
    //     入队压过下移是必须的：pop 腾出的正是最高占用槽，它这一拍没有来自下游的内容。
    genvar k;
    generate
    for (k = 0; k < QDEPTH; k = k + 1) begin : g_queue
        always_ff @(posedge clock) begin
            if (reset) begin
                q_v[k]   <= 1'b0;
                q_pc[k]  <= 32'b0;
                q_pt[k]  <= 1'b0;
                q_ptg[k] <= 32'b0;
                q_pi[k]  <= {`BP_INDEX_BITS{1'b0}};
                q_ins[k] <= `NOP;
            end else if (flush) begin
                q_v[k]   <= 1'b0;
                // 队头的 pc 直接摆成重定向目标：波形上"PC 当拍被拨走"仍可见，
                //   下游也不会看到一条带着旧 PC 的空条目（valid=0，语义无用但便于观察）。
                q_pc[k]  <= (k == 0) ? dnpc : 32'b0;
                q_pt[k]  <= 1'b0;
                q_ptg[k] <= 32'b0;
                q_pi[k]  <= {`BP_INDEX_BITS{1'b0}};
                q_ins[k] <= `NOP;
            end else if (push && (push_slot == k)) begin
                q_v[k]   <= 1'b1;
                q_pc[k]  <= meta_pc;
                q_pt[k]  <= meta_pt;
                q_ptg[k] <= meta_ptg;
                q_pi[k]  <= meta_pi;
                q_ins[k] <= irom_data;
            end else if (pop) begin
                if (k == QDEPTH-1) q_v[k] <= 1'b0;
                else begin
                    q_v[k]   <= q_v[k+1];
                    q_pc[k]  <= q_pc[k+1];
                    q_pt[k]  <= q_pt[k+1];
                    q_ptg[k] <= q_ptg[k+1];
                    q_pi[k]  <= q_pi[k+1];
                    q_ins[k] <= q_ins[k+1];
                end
            end
        end
    end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset) begin
            q_cnt <= {QPTR{1'b0}};
        end else if (flush) begin
            q_cnt <= {QPTR{1'b0}};
        end else begin
            q_cnt <= q_cnt
                   + (push ? {{(QPTR-1){1'b0}}, 1'b1} : {QPTR{1'b0}})
                   - (pop  ? {{(QPTR-1){1'b0}}, 1'b1} : {QPTR{1'b0}});
        end
    end

    /* ======================= ④ PC 更新与在途元数据 ======================= */
    // PC 优先级：reset > dnpc 真实重定向 > 本拍发了请求则前进 > 保持。
    //   ★ 不变量：真实重定向**不看 ready / 不看 inst_valid / 不看队列**（见文件头）。
    always_ff @(posedge clock) begin
        if (reset)
            pc_f <= 32'h0;
        else if (dnpc_flag)
            pc_f <= dnpc;
        else if (ic_req)
            pc_f <= fetch_next;
    end

    always_ff @(posedge clock) begin
        if (reset | flush) begin
            meta_v   <= 1'b0;
            meta_pc  <= 32'b0;
            meta_pt  <= 1'b0;
            meta_ptg <= 32'b0;
            meta_pi  <= {`BP_INDEX_BITS{1'b0}};
        end else begin
            // 在途只有 1 条（ICache 1 级延迟），且它在下一拍必然入队（room 保证有空位），
            //   所以这里无条件按本拍是否发请求刷新即可。
            meta_v   <= ic_req;
            if (ic_req) begin
                meta_pc  <= pc_f;          // ★ 采的是**发请求那条**的 pc，不是下一拍的 pc
                meta_pt  <= pred_taken;
                meta_ptg <= pred_target;
                meta_pi  <= pred_index;
            end
        end
    end

    /* ======================= ⑤ 交付侧 ======================= */
    assign valid = q_v[0];
    assign pc    = q_pc[0];
    assign snpc  = q_pc[0] + 32'd4;
    // valid=0 时灌 `NOP：下游按"合法空操作"执行，不会产生任何副作用。
    assign inst  = q_v[0] ? q_ins[0] : `NOP;
    // ★ 不变量：pred_* 必须来自**队头条目**，不能在这里再去查预测器（见文件头）。
    assign pred_taken_out  = q_pt[0];
    assign pred_target_out = q_ptg[0];
    assign pred_index_out  = q_pi[0];

    // 交付脉冲（每交付一条指令 1 拍）：= 队头有效且下游收下。
    //   保留这个名字是有意的 —— 仿真/波形脚本按 advance_en 统计"前端交付了几条"。
    logic advance_en;
    assign advance_en = valid & ready;

endmodule
