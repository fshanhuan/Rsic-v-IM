`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * DCache.sv — 直接映射数据缓存（上板改造：同步 BRAM + 单拍写请求 + MMIO 保护）
 * -----------------------------------------------------------------------------
 * 写策略是「写直达 write-through + 命中更新行」，为适配**同步 BRAM** 做了三处修正：
 *   1. 同步化：DRAM 是同步读（固定 1 拍延迟），引入 cpu_addr_r / cpu_en_r /
 *      cpu_index_r / cpu_tag_r 一整套“请求-返回”对齐寄存器；
 *   2. 读一次：只在「该行不驻留」时发一次 DRAM 读（cache_rd_req），
 *      miss 那一拍把访存流水停住（hold），返回后回填；
 *   3. 写一次：store 请求被寄存成**真正的一次性脉冲**（store_fire -> store_req_r）。
 *
 * 端口：
 *   cpu_en / cpu_wen / cpu_addr / cpu_wdata / cpu_mask : 来自 LSU 的访存请求
 *   mem_rdata : 外部 DRAM 的**原始整字**读数据（同步读，1 拍延迟）
 *   cpu_rdata : 回给 LSU 的**原始整字**读数据（字节/半字抽取由 LSU 按 funct3 做）
 *   mem_*     : 转发到外部 DRAM 的访问信号
 *   hit/miss/hold : 本拍访问结果与「需要停一拍重试」请求
 *
 * 三个“有效性”限定（都是实测踩出来的，少一个就出错）：
 *   resp_valid_r : cpu_en_r 的延迟，表示比较侧寄存器已装过一条真实请求。
 *       缺它 -> 复位后第一拍用复位值去比，把垃圾当“未命中”填进缓存行，
 *               于是 load 恒读到 x。
 *   addr_same_r  : cpu_addr 与 cpu_addr_r 相同，表示请求地址已稳定一拍。
 *       缺它 -> 新地址第一拍就发 DRAM 读，那时 DRAM 还没采到新地址，
 *               返回的是上一个地址的数据（load 读到的值整体偏一个 index）。
 *   mem_req_r    : “本请求已经发过读”。cache_rd_req 用它做一次性限制，
 *       这样 mem_en 只高 1 拍；再配合 ~mem_en & mem_req_r 就能稳定标出
 *       DRAM 数据返回的那一拍。若不做一次性限制，mem_en 一直为 1，
 *       返回标志永不成立、hold 永不释放 -> 整机死锁。
 *
 * store 为什么用状态机而不是边沿检测：
 *   cpu_en / cpu_addr 都由上游 LSU 的 pipe 级寄存器保持，是**电平**。
 *   前一条 load 已经让 cpu_en=1 时，紧跟的 store 不会产生 0->1；
 *   而流水线冻结期间地址还可能被上游改写，所以“上升沿”和“地址变化”两种
 *   边沿检测都不可靠（实测：load 之后紧跟的 store 一笔都写不进去）。
 *   这里改成只看“请求是否存在”的小状态机，与地址、与上游是否推进都无关：
 *     WR_IDLE  --(有 store 请求)--> WR_ISSUE ：本拍发一次脉冲
 *     WR_ISSUE --(请求仍在)------> WR_WAIT  ：请求持续，绝不重复发
 *     WR_WAIT  --(请求消失)------> WR_IDLE
 *   另外也不能直接写 store_req_r <= cpu_en & cpu_wen（那是电平）：
 *   流水线冻结期间会连续多拍 mem_wen=1，一次 store 被写多次
 *   （实测被测试台的 write-once 断言抓到：同地址连写 4 拍）。
 *
 * 一致性（写直达 + 命中更新行）：
 *   修掉旧实现的错误序列：
 *     1) load  X -> miss，把 X 填进缓存行（此时存储器里可能还是旧值）
 *     2) store X -> miss，写直达存储器，但缓存行仍是旧值
 *     3) load  X -> **命中**，读到第 1 步缓存的旧值 -> 结果错误
 *   现在 store 命中就同步合并进缓存行；未命中则本就不驻留，不会残留旧值。
 *
 * MMIO（uncacheable）保护：
 *   写直达缓存如果只看 tag/index，会把外设寄存器也缓存起来。外设读常有副作用
 *  （读清中断标志、FIFO 出队），一旦命中缓存，软件读到的就是上一次的快照，
 *   行为不可预测。因此 addr & ~UNCACHE_MASK != 0 的地址一律：
 *     - 命中判定恒为“不驻留” -> 读直通外设、不写缓存行；
 *     - store 的命中合并条件也被排除 -> 不会用旧值去合并写 MMIO 行。
 * =========================================================================== */
module DCache #(
    parameter INDEX_BITS = `DCACHE_INDEX_BITS,
    parameter TAG_BITS   = `DCACHE_TAG_BITS,
    // 不可缓存区间：addr & ~UNCACHE_MASK != 0 视为 MMIO。
    //   默认 0x0FFF_FFFF => 只有低于 0x1000_0000 的地址可缓存。
    parameter UNCACHE_MASK = 32'h0FFF_FFFF
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cpu_en,
    input  logic        cpu_wen,
    input  logic [31:0] cpu_addr,
    input  logic [31:0] cpu_wdata,
    input  logic [ 1:0] cpu_mask,
    input  logic [31:0] mem_rdata,

    output logic [31:0] cpu_rdata,
    output logic [31:0] mem_addr,
    output logic        mem_en,
    output logic        mem_wen,
    output logic [31:0] mem_wdata,
    output logic [ 1:0] mem_mask,
    output logic        hit,
    output logic        miss,
    output logic        hold,
    output logic [31:0] hit_cnt,
    output logic [31:0] miss_cnt
);

    localparam LINES = 1 << INDEX_BITS;

    logic                valid [0:LINES-1];
    logic [TAG_BITS-1:0] tag   [0:LINES-1];
    logic [31:0]         data  [0:LINES-1];

    /* ---------------- 1) 请求侧寄存器（喂 DRAM） ---------------- */
    logic [31:0]           cpu_addr_r;
    logic                  cpu_en_r;
    logic                  resp_valid_r;   // cpu_en_r 的延迟
    logic [INDEX_BITS-1:0] cpu_index_r;
    logic [TAG_BITS-1:0]   cpu_tag_r;
    logic [ 1:0]           cpu_wen_r;

    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0]   tag_in;
    assign index  = cpu_addr[INDEX_BITS+1:2];
    assign tag_in = cpu_addr[31:INDEX_BITS+2];

    // 请求地址是否已经稳定一拍（cpu_addr_r 是上一沿采到的 cpu_addr）
    logic addr_same_r;
    assign addr_same_r = resp_valid_r & (cpu_addr == cpu_addr_r);

    // 不可缓存判断：请求侧用寄存地址（与比较侧同拍），store 用组合地址
    logic uncacheable;
    assign uncacheable = (cpu_addr_r & ~UNCACHE_MASK) != 32'b0;
    logic uncacheable_req;
    assign uncacheable_req = (cpu_addr & ~UNCACHE_MASK) != 32'b0;

    // 该行是否已驻留（MMIO 恒不驻留）
    logic line_resident;
    assign line_resident = resp_valid_r & ~uncacheable
                         & valid[cpu_index_r] & (tag[cpu_index_r] == cpu_tag_r);

    /* ---------------- 2) 向 DRAM 发读 / 等返回 ---------------- */
    // load 且行不驻留时才发读（命中直接从 data[] 取，不必等 DRAM）。
    // 必须是**一次性**的：mem_en 只高 1 拍，下一拍用 ~mem_en & mem_req_r
    // 就能标出 DRAM 数据返回的那一拍。
    logic cache_rd_req;
    assign cache_rd_req = cpu_en_r & ~cpu_wen_r & ~line_resident & ~mem_req_r;

    logic mem_req_r;      // 已经发过读（mem_en 为 1 过）
    logic mem_data_vld;   // 本拍 mem_rdata 已是本次读的返回数据
    assign mem_data_vld = ~cache_rd_req & mem_req_r;

    assign mem_en = cache_rd_req;

    /* ---------------- 3) 判定侧 ---------------- */
    // 一次“真正完成的访问”：请求已装载 + 地址稳定 + 返回数据已到
    logic access_en;
    assign access_en = addr_same_r & mem_data_vld;

    // -----------------------------------------------------------------------
    // v9 修复（B2）：读握手契约必须保证「hold 撤销的那一拍，cpu_rdata 就是
    //   **当前正在请求的那个地址**的数据」。
    //   原实现用 resp_valid_r（= cpu_en 延迟 2 拍）当门，而 cpu_index_r/cpu_tag_r
    //   只延迟 1 拍，两者错开一拍；更关键的是 hold 里的 `| cache_rd_req` 会在
    //   **发出读的那一拍**就把 hold 解掉 —— 数据还没回来，LSU 却已被放行，
    //   于是把上一拍的总线残留值（或 x）锁进 rdata_reg2，真正的数据落在一个
    //   valid=0 的气泡上。tb_iverilog.sv 的 DRAM 读口不门控（每拍都读），
    //   恰好掩盖了它；换成带读使能的真实 BRAM（board/sync_mem）就变成 x。
    //
    //   新口径（与「同步 BRAM：请求 1 拍、数据 1 拍后到」严格对应）：
    //     hit_now     : 用**当前**地址组合判断是否命中 -> 本拍 cpu_rdata 已可用；
    //     resp_for_now: 本拍 mem_rdata 是**当前地址**那次读的返回（地址在 hold
    //                   期间保持不动，所以比较寄存后的 index/tag 即可）；
    //     hold        : 请求存在且两者都不成立时才停拍。
    //   这样 hold 撤销的那一拍，cpu_rdata 一定是这条 load 的数据。
    // -----------------------------------------------------------------------
    logic hit_now;
    assign hit_now = cpu_en & ~cpu_wen & ~uncacheable_req
                   & valid[index] & (tag[index] == tag_in);

    logic resp_for_now;
    assign resp_for_now = mem_data_vld & (cpu_index_r == index) & (cpu_tag_r == tag_in);

    // 本拍请求是否命中（供 cpu_rdata 与计数器使用）
    assign hit  = hit_now;
    assign miss = resp_for_now & ~hit_now;

    // 命中取缓存行（当前地址的 index）；未命中直接给 DRAM 回来的原始整字
    assign cpu_rdata = hit_now ? data[index] : mem_rdata;

    // load 停拍条件：本拍 mem_rdata 不是这条 load 的结果，且它自己还没发出读。
    //   ~mem_req_r | cache_rd_req 的含义：
    //     - 刚发出读的那一拍（cache_rd_req=1）：数据还没回来，但读已经上路，
    //       下一拍 mem_data_vld 就会取回来，不必再停，省一拍气泡；
    //     - 已发过读、数据还没到（mem_req_r=1 且非返回拍）才需要停。
    //   写成 ~hit & ~mem_req_r 会在“本拍既没命中、又还没发读”的那一拍死等：
    //   那一拍 hold=1 把 LSU 的 pipe 级冻住，而发出读又需要缓一拍，
    //   于是 hold 自己把自己锁住（实测：load 之后整机停摆）。
    // store 是写直达，不依赖读数据，永不停拍。
    // load 的停拍：请求存在、且本拍 cpu_rdata 不是这条 load 的数据（既没命中、
    // 也不是它的读返回）—— 必须停到数据真的可用那一拍为止（见上面的新口径）。
    assign hold = (cpu_en & ~cpu_wen) & ~(hit_now | resp_for_now);

    /* ---------------- 4) store 请求单拍脉冲（状态机） ---------------- */
    localparam WR_IDLE  = 2'd0;
    localparam WR_ISSUE = 2'd1;
    localparam WR_WAIT  = 2'd2;

    logic [1:0] store_state;
    logic       store_fire;

    logic [31:0] store2_addr;
    logic [31:0] store2_wdata;
    logic [ 1:0] store2_mask;
    logic [INDEX_BITS-1:0] store2_index;
    logic [TAG_BITS-1:0]   store2_tag;
    logic [ 1:0]           store2_offset;
    logic                  store2_hit;
    logic                  store_req_r;

    assign store_fire = cpu_en & cpu_wen & (store_state == WR_IDLE);

    // mem_addr 始终跟随寄存后的地址（读、写都用同一份，避免与脉冲错拍）
    assign mem_addr  = cpu_addr_r;
    assign mem_wen   = store_req_r;
    assign mem_wdata = store2_wdata;
    assign mem_mask  = store2_mask;

    /* ---------------- 5) 顺序与写回 ---------------- */
    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < LINES; i = i + 1)
                valid[i] <= 1'b0;
            cpu_addr_r   <= 32'b0;
            cpu_en_r     <= 1'b0;
            resp_valid_r <= 1'b0;
            cpu_index_r  <= {INDEX_BITS{1'b0}};
            cpu_tag_r    <= {TAG_BITS{1'b0}};
            cpu_wen_r    <= 1'b0;
            mem_req_r    <= 1'b0;
            store_state  <= WR_IDLE;
            store_req_r  <= 1'b0;
            store2_addr  <= 32'b0;
            store2_wdata <= 32'b0;
            store2_mask  <= 2'b0;
            store2_index <= {INDEX_BITS{1'b0}};
            store2_tag   <= {TAG_BITS{1'b0}};
            store2_offset<= 2'b0;
            store2_hit   <= 1'b0;
            hit_cnt      <= 32'b0;
            miss_cnt     <= 32'b0;
        end else begin
            // ---- 请求侧：同一沿、同源采样，严格描述同一条请求 ----
            cpu_addr_r   <= cpu_addr;
            cpu_index_r  <= index;
            cpu_tag_r    <= tag_in;
            cpu_en_r     <= cpu_en;
            resp_valid_r <= cpu_en_r;
            cpu_wen_r    <= cpu_wen;

            // ---- 读请求追踪：发读后保持 mem_req_r，直到数据被回填用掉 ----
            if (cache_rd_req)      mem_req_r <= 1'b1;
            else if (mem_data_vld) mem_req_r <= 1'b0;

            // ---- store 状态机：只在第一次出现请求时发一拍脉冲 ----
            store_req_r <= store_fire;
            case (store_state)
                WR_IDLE:  if (cpu_en & cpu_wen) store_state <= WR_ISSUE;
                WR_ISSUE: if (cpu_en & cpu_wen) store_state <= WR_WAIT;
                          else                  store_state <= WR_IDLE;
                default:  if (!(cpu_en & cpu_wen)) store_state <= WR_IDLE;
            endcase

            // ---- store 载荷：在 store_fire 那一拍采齐，供下一拍脉冲使用 ----
            //   只在 store_fire 采，这样载荷与脉冲严格属于同一次 store；
            //   若每拍都采，脉冲那一拍会采到上游已推进上来的下一条指令的地址。
            if (store_fire) begin
                store2_addr   <= cpu_addr;
                store2_wdata  <= cpu_wdata;
                store2_mask   <= cpu_mask;
                store2_index  <= index;
                store2_tag    <= tag_in;
                store2_offset <= cpu_addr[1:0];
                store2_hit    <= ~uncacheable_req & valid[index] & (tag[index] == tag_in);
            end

            // ---- 计数器（口径随新的判定侧一起更新，仅用于观测）----
            //   命中：本拍请求就是由缓存行服务的；
            //   缺失：这条缺失的读返回（即回填）那一拍记一次。
            if (hit_now)                                    hit_cnt  <= hit_cnt + 32'd1;
            if (resp_for_now & ~hit_now & ~uncacheable)     miss_cnt <= miss_cnt + 32'd1;

            // ---- load 未命中回填整字（此时 mem_data_vld=1，mem_rdata 就是本行数据）----
            //   MMIO 地址不回填（不分配），保证外设寄存器永远不会被缓存。
            if (access_en && !hit && !uncacheable) begin
                valid[cpu_index_r] <= 1'b1;
                tag[cpu_index_r]   <= cpu_tag_r;
                data[cpu_index_r]  <= mem_rdata;
            end

            // ---- store 命中时把数据合并进缓存行（用与脉冲严格对齐的副本）----
            if (store_req_r && store2_hit) begin
                case (store2_mask)
                    2'b00: case (store2_offset)          // sb
                               2'b00: data[store2_index][7:0]   <= store2_wdata[7:0];
                               2'b01: data[store2_index][15:8]  <= store2_wdata[7:0];
                               2'b10: data[store2_index][23:16] <= store2_wdata[7:0];
                               default: data[store2_index][31:24] <= store2_wdata[7:0];
                           endcase
                    2'b01: if (store2_offset[1] == 1'b0) data[store2_index][15:0]  <= store2_wdata[15:0];
                           else                            data[store2_index][31:16] <= store2_wdata[15:0];
                    default: data[store2_index] <= store2_wdata;
                endcase
            end
        end
    end

endmodule
