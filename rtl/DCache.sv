`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * DCache.sv — 直接映射数据缓存（上板改造：同步 BRAM + 单拍写请求 + MMIO 保护）
 * 写策略：写直达 write-through + 命中更新行；为适配**同步 BRAM**（固定 1 拍读延迟 + 读使能）做了三处修正：
 *   1. 同步化：引入 cpu_addr_r / cpu_en_r / cpu_index_r / cpu_tag_r 一整套“请求-返回”对齐寄存器；
 *   2. 读一次：只在「该行不驻留」时发一次 DRAM 读（cache_rd_req），miss 那一拍把访存流水 hold 住，返回后回填；
 *   3. 写一次：store 请求被寄存成**真正的一次性脉冲**（store_fire -> store_req_r）。
 *
 * 端口：cpu_en/cpu_wen/cpu_addr/cpu_wdata/cpu_mask ← LSU 的访存请求（cpu_en = mem_ren_pipe | wen）；
 *   mem_* 转发到外部 DRAM；cpu_rdata 回给 LSU 的是**原始整字**；hit/miss 是本拍访问结果，hold 是「需要停一拍重试」。
 *
 * ★ 与 sync_mem 的读写时序契约（改之前先读 board/sync_mem.sv 头部）：
 *   - 读：mem_en=1 的**那一拍**给出 mem_addr，sync_mem 在下一个时钟沿输出 rdata，正好被本模块 mem_data_vld 那一拍采走 —— 所以 mem_en 只高 1 拍（cache_rd_req 一次性），再用 ~mem_en & mem_req_r 标出「数据返回那一拍」。
 *   - 写：mem_wen 是**单拍脉冲**，sync_mem 在同一沿按 mem_mask 合并写入；mem_addr 始终跟随寄存后的地址（读、写共用 cpu_addr_r，避免与脉冲错拍）。
 *   - 字节/半字抽取不在本模块做（cpu_rdata 是原始整字），由 LSU/WBU 按 funct3 + addr[1:0] 选道。
 *
 * ★ 不变量（少一个就出错；细节与实测见 syn/修复史_全量.md）：
 *   - resp_valid_r（cpu_en_r 的延迟）表示比较侧寄存器已装过一条真实请求：缺它 -> 复位后第一拍用复位值去比，把垃圾当「未命中」填进缓存行，于是 load 恒读到 x。
 *   - addr_same_r（cpu_addr == cpu_addr_r）表示请求地址已稳定一拍：缺它 -> 新地址第一拍就发 DRAM 读，那时 DRAM 还没采到新地址，返回的是上一个地址的数据（load 值整体偏一个 index）。
 *   - 若不做 mem_req_r 的一次性限制，mem_en 一直为 1，返回标志永不成立、hold 永不释放 -> 整机死锁。
 *
 * ★ store 为什么用状态机而不是边沿检测（不要改回边沿检测）：cpu_en / cpu_addr 都由上游 LSU 的 pipe 级寄存器保持，是**电平** —— 前一条 load 已让 cpu_en=1 时，紧跟的 store 不会产生 0->1；而流水线冻结期间地址还可能被上游改写，所以「上升沿」与「地址变化」两种边沿检测都不可靠（实测：load 之后紧跟的 store 一笔都写不进去）。改成只看「请求是否存在」的小状态机，与地址、与上游是否推进都无关：WR_IDLE --(有 store 请求)--> WR_ISSUE（本拍发一次脉冲）--(请求仍在)--> WR_WAIT（请求持续，绝不重复发）--(请求消失)--> WR_IDLE。
 * ★ 不变量：store_req_r 必须是**单拍脉冲**，绝不能直接写成 store_req_r <= cpu_en & cpu_wen（那是电平：流水冻结期间会连续多拍 mem_wen=1，一次 store 被写多次 —— 实测被测试台的 write-once 断言抓到同地址连写 4 拍）→ §DCACHE-2。
 *
 * ★ 一致性（写直达 + 命中更新行）：旧实现的错误序列是「load X -> miss，把 X 填进缓存行（存储器里可能还是旧值）-> store X -> miss，写直达存储器但缓存行仍是旧值 -> load X -> **命中**，读到第 1 步缓存的旧值」。现在 store 命中就同步合并进缓存行，未命中则本就不驻留，不会残留旧值 → §DCACHE-4。
 *
 * ★ MMIO（uncacheable）保护：写直达缓存如果只看 tag/index，会把外设寄存器也缓存起来。外设读常有副作用（读清中断标志、FIFO 出队），一旦命中缓存，软件读到的就是上一次的快照，行为不可预测。因此 addr & ~UNCACHE_MASK != 0 的地址一律：命中判定恒为「不驻留」（读直通外设、不写缓存行），store 的命中合并条件也被排除（不会用旧值去合并写 MMIO 行）→ §DCACHE-3。
 * 参考：docs/模块阅读文档.md、syn/修复史_全量.md、board/sync_mem.sv
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
    logic mem_req_r;      // 已经发过读（mem_en 为 1 过）—— 必须先声明，见下面的 cache_rd_req
    logic cache_rd_req;
    assign cache_rd_req = cpu_en_r & ~cpu_wen_r & ~line_resident & ~mem_req_r;

    logic mem_data_vld;   // 本拍 mem_rdata 已是本次读的返回数据
    assign mem_data_vld = ~cache_rd_req & mem_req_r;

    assign mem_en = cache_rd_req;

    /* ---------------- 3) 判定侧 ---------------- */
    // 一次“真正完成的访问”：请求已装载 + 地址稳定 + 返回数据已到
    logic access_en;
    assign access_en = addr_same_r & mem_data_vld;

    // ★ 不变量（v9 修复 B2）：hold 撤销的那一拍，cpu_rdata 必须就是**当前正在请求的那个地址**的数据。
    //   原因：同步 BRAM 是「请求 1 拍、数据 1 拍后到」，判定只能用**当前**地址的组合结果 —— hit_now（当前
    //   地址组合判命中）与 resp_for_now（本拍 mem_rdata 是当前地址那次读的返回；hold 期间地址不动，比较
    //   寄存后的 index/tag 即可），两者都不成立才 hold。原实现用 resp_valid_r 当门（cpu_en 延迟 2 拍，与
    //   只延迟 1 拍的 cpu_index_r/cpu_tag_r 错开），且 hold 里含 | cache_rd_req → 会在**发出读的那一拍**就
    //   解掉 hold（数据还没回来，LSU 已被放行），把总线残留值/x 锁进 rdata_reg2。
    //   踩坑史 + 实测现象：见 syn/修复史_全量.md §DCACHE-1
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

    // hold 口径（见上面的契约）：请求存在、且本拍 cpu_rdata 不是这条 load 的数据（既没命中、也不是它的
    //   读返回）时才停拍 —— 必须停到数据真的可用那一拍。若写成 ~hit & ~mem_req_r，会在「既没命中、又还
    //   没发读」那一拍死等：那拍 hold=1 把 LSU 的 pipe 级冻住，而发读又要缓一拍，hold 自己把自己锁住
    //   （实测：load 之后整机停摆）。省掉的那一拍来自 cache_rd_req=1 时读已上路、下一拍 mem_data_vld 必到。
    //   store 是写直达、不依赖读数据，永不停拍。
    assign hold = (cpu_en & ~cpu_wen) & ~(hit_now | resp_for_now);

    /* ---------------- 4) store 请求单拍脉冲（状态机） ---------------- */
    localparam WR_IDLE  = 2'd0;
    localparam WR_ISSUE = 2'd1;
    localparam WR_WAIT  = 2'd2;

    logic [1:0] store_state;
    logic       store_fire;

    logic [31:0] store2_wdata;
    logic [ 1:0] store2_mask;
    // v9 修复（C6）：删掉了 store2_addr / store2_tag —— 它们在 store_fire 那一拍被锁存，但**从来没有被读过**
    //   （Quartus Warning 10036: object "store2_addr"/"store2_tag" assigned a value but never read）。一次 store
    //   需要跨拍保留的只有 payload（wdata/mask）与「它属于哪一行」（index，用于命中合并）；地址本身既不再上
    //   总线（总线地址走 mem_addr = cpu_addr_r）、也不再做比较。踩坑史见 syn/修复史_全量.md §DCACHE-5
    logic [INDEX_BITS-1:0] store2_index;
    logic [ 1:0]           store2_offset;
    logic                  store2_hit;
    logic                  store_req_r;

    assign store_fire = cpu_en & cpu_wen & (store_state == WR_IDLE);

    // mem_addr 始终跟随寄存后的地址（读、写都用同一份，避免与脉冲错拍）
    assign mem_addr  = cpu_addr_r;
    assign mem_wen   = store_req_r;
    assign mem_wdata = store2_wdata;
    // H2（v9 修复）：读请求窗口向存储器声明**整字访问**（2'b10），让课程 SoC 的 dram_driver 返回
    //   原始整字，再由 CPU 按 addr[1:0] 自己抽取；写口仍用真实字节 mask。
    //   原因：上板改造后的契约是"存储器给整字、CPU 抽取"（§DCACHE-1 / v9 修复 B1），而课程原始 SoC
    //   的 dram_driver（在上游 cdp-tests 套件里，不在本仓库）会按 mask 先在存储器侧抽一次 →
    //   二次抽取，lb/lbu/lh/lhu/lw 读成 0、
    //   sb/sh 也错（官方差分恰好这 7 条）。
    // ★ 不变量：整字 mask 必须保持到数据被采走那一拍（mem_req_r=1）—— 课程 DRAM 是**组合读**
    //   （dram_driver 每拍按当前 mask 重新抽取），只给 mem_en 那一拍会在数据回来前就掉回 store2_mask。
    //   板级 board/sync_mem.sv 读口不看 mask，所以对已上板的 bitstream 无影响。
    //   实测证据见 syn/修复史_全量.md §DCACHE-6
    assign mem_mask  = mem_wen ? store2_mask
                              : ((mem_en | mem_req_r) ? 2'b10 : store2_mask);

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
            store2_wdata <= 32'b0;
            store2_mask  <= 2'b0;
            store2_index <= {INDEX_BITS{1'b0}};
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
                store2_wdata  <= cpu_wdata;
                store2_mask   <= cpu_mask;
                store2_index  <= index;
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
