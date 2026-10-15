`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * ICache.sv — 直接映射指令缓存（同步 BRAM：请求拍 + 响应拍）
 * -----------------------------------------------------------------------------
 * 上游 IFU 的取指地址 pc；下游 IFU 的 irom_data（= EXU 的 inst）。存储器侧接
 * SoC 同步 IROM：用 mem_addr/mem_en 发起读，**下一拍**才从 mem_rdata 拿回数据。
 *
 * ★ 接口契约（改之前必读）：
 *   - fetch_align：本拍 mem_rdata 是否**属于当前 cpu_addr 这条请求**。
 *   - hold：本拍无法完成访问（未对齐或未命中），前端要停一拍后重试。
 *     IFU 的 inst_valid = fetch_align、mem_stall = hold —— 全设计的核心握手之一。
 *   - cpu_rdata：命中取缓存，未对齐 / 未命中一律给 `NOP`，绝不把未就绪或
 *     别的地址的数据当指令；hit / miss 只有 fetch_align=1 时才有意义。
 *   - 一次取指横跨两拍、请求与响应交替：请求拍把 cpu_addr 寄存给 BRAM
 *     （mem_addr = cpu_addr_r），响应拍才拿到 mem_rdata；正因如此每拍都在
 *     “发新请求”与“判上一个响应”之间交替，判定必须跟 mem_rdata 落在同一拍。
 *   - 组织：行大小 1 个 32 位字（只有 index/tag、没有 offset），**不需要突发**，
 *     miss 的语义就是“废掉一拍再重试”；miss 代价固定 +1 拍（PC 被停住，重试拍
 *     必然命中，永不重复）。
 *
 * ★ 不变量：喂 BRAM 的地址与做判定的 index/tag 必须**同沿、同源**（都取自同一个
 *   cpu_addr），判定也不许改挂到当拍 cpu_addr 上 —— 当拍 cpu_addr 已是下一条请求，
 *   它的数据还在 BRAM 里；错开后两者差一拍，每条新指令都被误判成 miss（前端变成
 *   3 拍走一条）。踩坑史（旧“同拍组合旁路”为什么上板必炸）：见 §ICACHE-1
 * ★ 不变量：新地址出现的第一拍必须报 fetch_align=0 并拉高 hold，从而维持
 *   「cpu_addr 稳定 ⇒ 返回结果属于当前 pc」；否则 PC 会跑在取指数据前面，
 *   IDU 收到「下一条地址 + 上一条指令」，还会拿别的地址的数据填行（污染→假命中）。
 * ★ 不变量：缓存行只在 fetch_align=1 时写（命中只计数）；未对齐那拍的 mem_rdata
 *   不属于当前请求，写进去就是别的地址的数据。
 *
 * 计数器语义：
 *   hit_cnt  : fetch_align=1 且命中 = 一次
 *   miss_cnt : fetch_align=1 且未命中 = 一次（hold 持续多拍不会重复计数）
 * =========================================================================== */
module ICache #(
    parameter INDEX_BITS = `ICACHE_INDEX_BITS,
    parameter TAG_BITS   = `ICACHE_TAG_BITS
) (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] cpu_addr,
    input  logic [31:0] mem_rdata,

    output logic [31:0] cpu_rdata,
    output logic [31:0] mem_addr,
    output logic        mem_en,
    output logic        fetch_align,
    output logic        hit,
    output logic        miss,
    output logic        hold,
    output logic [31:0] hit_cnt,
    output logic [31:0] miss_cnt
);

    localparam LINES = 1 << INDEX_BITS;   // 行数 = 1 << INDEX_BITS（默认 6 → 64 行）

    // tag/data 综合成隐含 RAM（读组合：valid/tag/data 三路同拍做比较；写同步）。
    logic                 valid [0:LINES-1];
    logic [TAG_BITS-1:0]  tag   [0:LINES-1];
    logic [31:0]          data  [0:LINES-1];

    // 组合地址侧：只用于生成“本拍要寄存的 index/tag”，与 cpu_addr_r 同沿寄存。
    //   位选：低 2 位是字内字节偏移（行大小 1 个字，用不到），所以 index 从 bit2 起，
    //   tag 是剩下的高位 —— 必须与 para.sv 的 TAG_BITS = 32-INDEX_BITS-2 对齐。
    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0]   tag_in;
    assign index  = cpu_addr[INDEX_BITS+1:2];
    assign tag_in = cpu_addr[31:INDEX_BITS+2];

    /* ---------------- 请求侧寄存器（喂 BRAM） ---------------- */
    // cpu_addr_r 给 BRAM；cpu_index_r/cpu_tag_r 是**同一条请求**的快照，留给判定侧。
    logic [31:0]           cpu_addr_r;
    logic                  cpu_en_r;
    logic [INDEX_BITS-1:0] cpu_index_r;
    logic [TAG_BITS-1:0]   cpu_tag_r;

    assign mem_addr = cpu_addr_r;
    assign mem_en   = cpu_en_r;

    /* ---------------- 判定侧寄存器（与 mem_rdata 同拍对齐） ---------------- */
    logic [INDEX_BITS-1:0] align_index_r;
    logic [TAG_BITS-1:0]   align_tag_r;
    // ★ 不变量：命中/回填还要看 resp_valid_r（= 返回侧已装载过一条真实请求），
    //   不能只看 addr_same_r。原因：reset / 第一个请求拍，align_*_r 还是复位值而
    //   mem_rdata 是复位前的垃圾，不加限定就会把垃圾写进缓存行、之后 valid=1 假命中，
    //   整机从这个错误指令开始跑（实测踩到过）。
    logic                  resp_valid_r;

    // 地址是否已稳定到“当前这条请求”：新地址出现的第一拍，BRAM 返回的还是旧地址的
    // 结果，这一拍必须报未对齐。cpu_en_r=0（复位后首拍）也算不稳定。
    logic addr_same_r;
    assign addr_same_r = (cpu_addr == cpu_addr_r) & cpu_en_r;

    // 只有“返回侧已装载”且“地址稳定”时，align_*_r 与 mem_rdata 才是同一条请求。
    assign fetch_align = resp_valid_r & addr_same_r;

    // 命中比较三路与：①属于当前请求 ②该行有效 ③tag 相等。
    assign hit  = fetch_align && valid[align_index_r] && (tag[align_index_r] == align_tag_r);
    assign miss = fetch_align && ~hit;

    // 未对齐或未命中时给前端灌 `NOP，绝不把未就绪/别的地址的数据当指令。
    assign cpu_rdata = hit ? data[align_index_r] : `NOP;

    // 未对齐（结果还没回来）或未命中，都需要停一拍。
    assign hold = ~fetch_align | miss;

    /* ---------------- 顺序与写回 ---------------- */
    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < LINES; i = i + 1)
                valid[i] <= 1'b0;
            cpu_addr_r    <= 32'b0;
            cpu_en_r      <= 1'b0;
            cpu_index_r   <= {INDEX_BITS{1'b0}};
            cpu_tag_r     <= {TAG_BITS{1'b0}};
            align_index_r <= {INDEX_BITS{1'b0}};
            align_tag_r   <= {TAG_BITS{1'b0}};
            resp_valid_r  <= 1'b0;
            hit_cnt       <= 32'b0;
            miss_cnt      <= 32'b0;
        end else begin
            // ---- ① 请求侧：cpu_addr_r 与 cpu_index_r/cpu_tag_r 在同一沿、
            //         从同一个 cpu_addr 采样，三者严格描述同一条请求 ----
            cpu_addr_r  <= cpu_addr;
            cpu_index_r <= index;
            cpu_tag_r   <= tag_in;
            cpu_en_r    <= 1'b1;

            // ---- ② 判定侧：把上一条请求的 index/tag 再寄存一拍，
            //         与同一条请求的 mem_rdata 对齐 ----
            align_index_r <= cpu_index_r;
            align_tag_r   <= cpu_tag_r;
            resp_valid_r  <= cpu_en_r;

            // ---- ③ 判定与回填：只在结果确实属于当前请求时才动缓存（miss 时回填
            //         整行；命中只计数），这样新地址带来的废拍不会污染缓存行 ----
            if (fetch_align) begin
                if (hit) begin
                    hit_cnt <= hit_cnt + 32'd1;
                end else begin
                    miss_cnt             <= miss_cnt + 32'd1;
                    valid[align_index_r] <= 1'b1;
                    tag[align_index_r]   <= align_tag_r;
                    data[align_index_r]  <= mem_rdata;
                end
            end
        end
    end

endmodule
