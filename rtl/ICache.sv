`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * ICache.sv — 直接映射指令缓存（**全流水、每拍一次取指、未命中零停顿**）
 * -----------------------------------------------------------------------------
 * 上游 IFU 的取指地址 pc；下游 IFU 的 irom_data。存储器侧接 SoC 同步 IROM：
 * 本拍给 mem_addr/mem_en，**下一拍**mem_rdata 就有效（1 级延迟，不是 2 级）。
 *
 * ★ v10 改造（前端解耦）——原来这里有个致命的取指节拍限制，务必读完再改：
 *   旧实现的地址是**再寄存一拍**的（mem_addr = cpu_addr_r），然后用
 *   `addr_same_r = (cpu_addr == cpu_addr_r)` 去判"返回结果属不属于当前请求"。
 *   这就把"每拍都能取指"退化成"PC 必须连续稳定 2 拍才敢交付一条"：
 *       PC 变 → 第 1 拍不等（hold）→ 第 2 拍才交付 → 于是**每 3 拍才能出一条指令**。
 *   实测（`_fw/` 前端专项）：delivered=132 / cyc_window=396 = 0.33 IPC 上限，
 *   prog_loop 里 110/288 拍耗在 icache_hold 上 —— 前端就是整机的瓶颈。
 *   根因不是命中率，而是"地址寄存一拍 + 拿当拍 PC 去对账"这个结构。
 *
 * ★ 新契约（改前必读）：
 *   - **mem_addr = cpu_addr（组合直通 BRAM）**，mem_en = cpu_req。同步 BRAM 在
 *     cpu_req 那一拍采地址，下一拍 mem_rdata 就是 mem[cpu_addr(T)]。地址来自 IFU
 *     的 PC 寄存器，本来就有一整拍余量，不需要再打一拍。
 *   - cpu_req 可以**每拍为 1**：一次取指只占 1 拍，稳态吞吐 1 条/拍。
 *   - resp_valid(T+1) = cpu_req(T)：本拍 cpu_rdata 有效。IFU 只在这拍采数据。
 *   - **未命中不停顿**：miss 那拍直接把 mem_rdata **旁路**出去（数据此刻就在手上），
 *     同一沿把行填好。所以 miss 对时序的代价是 **0 拍**，缓存只影响功耗与计数器。
 *     （旧的 hold/miss 重试机制整体删除 —— 它正是 3 拍节拍的来源。）
 *   - clr（fence.i）= 全部行 valid 清零；在途请求由 IFU 侧 flush 一起丢弃。
 *   - mem_en 只在 cpu_req 那拍为 1：IROM 的 ren 因此**不再恒为 1**，空转拍不读
 *     BRAM（省动态功耗），也顺手修好 hit_cnt/miss_cnt 的重复计数。
 *
 * ★ 不变量：喂 BRAM 的地址与"跟着响应走的 index/tag 快照"必须**同一沿、同源**。
 *   新实现把它做在硬件结构里：cpu_req 那拍，BRAM 采 cpu_addr、idx_r/tag_r 采
 *   同一条 cpu_addr 的切片，下一拍两者描述的必然是同一条请求 —— 不再有
 *   "拿当拍 PC 去对账"这回事，也就不可能错相。
 *
 * 计数器语义（v10 修正）：每**一次请求**恰好记一次，hit/miss 之和 = 取指数。
 *   旧实现在 PC 被冻结的多拍里 `fetch_align` 可能反复为 1，把同一次取指重复计数。
 * =========================================================================== */
module ICache #(
    parameter INDEX_BITS = `ICACHE_INDEX_BITS,
    parameter TAG_BITS   = `ICACHE_TAG_BITS
) (
    input  logic        clk,
    input  logic        reset,
    // 取指请求侧（来自 IFU）：cpu_addr 是**当拍**要取的地址，组合直通 BRAM
    input  logic [31:0] cpu_addr,
    input  logic        cpu_req,
    input  logic        clr,          // fence.i：清全部 valid 位
    // 存储器侧
    input  logic [31:0] mem_rdata,

    output logic [31:0] cpu_rdata,
    output logic [31:0] mem_addr,
    output logic        mem_en,
    // 响应侧（与 mem_rdata 同拍）
    output logic        resp_valid,
    output logic        hit,
    output logic        miss,
    output logic [31:0] hit_cnt,
    output logic [31:0] miss_cnt
);

    localparam LINES = 1 << INDEX_BITS;   // 行数 = 1 << INDEX_BITS（默认 6 → 64 行）

    // tag/data 综合成隐含 RAM（读组合：valid/tag/data 三路同拍比较；写同步）。
    logic                 valid [0:LINES-1];
    logic [TAG_BITS-1:0]  tag   [0:LINES-1];
    logic [31:0]          data  [0:LINES-1];

    // 组合切片：只用于在 cpu_req 那拍随地址一起寄存快照。位选与 para.sv 的
    //   TAG_BITS = 32-INDEX_BITS-2 严格对齐（低 2 位是字内字节偏移，行大小 1 字用不到）。
    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0]   tag_in;
    assign index  = cpu_addr[INDEX_BITS+1:2];
    assign tag_in = cpu_addr[31:INDEX_BITS+2];

    /* ---------------- 请求侧：地址**不进寄存器**，直接给 BRAM ---------------- */
    assign mem_addr = cpu_addr;
    assign mem_en   = cpu_req;          // ← IROM 读使能门控：只在真发请求那拍为 1

    /* ---------------- 响应侧：与 mem_rdata 同一沿对齐的 index/tag 快照 ---------------- */
    logic [INDEX_BITS-1:0] idx_r;
    logic [TAG_BITS-1:0]   tag_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            idx_r      <= {INDEX_BITS{1'b0}};
            tag_r      <= {TAG_BITS{1'b0}};
            resp_valid <= 1'b0;
        end else begin
            // ★ 不变量：这一拍 BRAM 采的地址就是 cpu_addr，所以快照必须同沿采同一条
            //   cpu_addr 的切片 —— 两者要么一起更新、要么一起不更新。
            idx_r      <= index;
            tag_r      <= tag_in;
            resp_valid <= cpu_req;      // 1 级延迟，与 mem_rdata 严格同拍
        end
    end

    // 命中比较三路与：①属于本拍响应 ②该行有效 ③tag 相等。
    assign hit  = resp_valid && valid[idx_r] && (tag[idx_r] == tag_r);
    assign miss = resp_valid && ~hit;

    // ★ 不变量：未命中必须是**旁路**（把本拍 mem_rdata 直接给出去），而不是停拍重试 ——
    //   数据这一拍已经在手上，停一拍纯属浪费。resp_valid=0 时给 `NOP，绝不把上次残留的
    //   mem_rdata（sync_mem 在 ren=0 时保持旧值）当指令。
    assign cpu_rdata = resp_valid ? (hit ? data[idx_r] : mem_rdata) : `NOP;

    /* ---------------- 行填充（只在 miss 那拍写一次）与计数器 ---------------- */
    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < LINES; i = i + 1)
                valid[i] <= 1'b0;
            hit_cnt  <= 32'b0;
            miss_cnt <= 32'b0;
        end else begin
            if (clr) begin
                for (i = 0; i < LINES; i = i + 1)
                    valid[i] <= 1'b0;
            end else if (miss) begin
                valid[idx_r] <= 1'b1;
                tag[idx_r]   <= tag_r;
                data[idx_r]  <= mem_rdata;
            end

            // 每次取指恰好记一次：hit + miss = 请求数
            if (hit)  hit_cnt  <= hit_cnt  + 32'd1;
            if (miss) miss_cnt <= miss_cnt + 32'd1;
        end
    end

endmodule
