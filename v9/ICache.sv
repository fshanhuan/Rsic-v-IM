`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * ICache.sv — 直接映射指令缓存（上板改造：同步 BRAM）
 * -----------------------------------------------------------------------------
 * 输入：
 *   clk / reset        : 时钟与同步复位
 *   cpu_addr           : IFU 当前取指地址（来自 PC，请求指针）
 *   mem_rdata          : 来自外部 IROM 的指令数据（**同步读**，地址打一拍后返回）
 * 输出：
 *   cpu_rdata          : 送给 IFU 的指令（命中取缓存，未对齐/未命中给 `NOP）
 *   mem_addr           : 送往 IROM 的地址（寄存输出，接 BRAM 地址口）
 *   mem_en             : 本拍向存储器发起读（供 SoC 侧同步 ROM 做读使能）
 *   fetch_align        : 本拍的返回结果是否**属于当前 cpu_addr 这条请求**
 *   hit / miss         : 本拍访问结果（只有 fetch_align=1 时才有意义）
 *   hold               : 本拍无法完成访问，需要把前端停一拍后重试
 *   hit_cnt / miss_cnt : 累计命中 / 缺失次数
 *
 * 组织方式：
 *   行大小 1 个 32 位字（para.sv:ICACHE_INDEX_BITS/TAG_BITS，只有 index/tag、
 *   没有 offset），因此**不需要突发**，miss 的语义就是“废掉一拍再重试”。
 *
 * 为什么原来必须改（上板必炸）：
 *   旧写法是“同拍组合旁路”：
 *       assign cpu_rdata = hit ? data[index] : mem_rdata;
 *   它假设 mem_rdata 与本拍 cpu_addr 同拍有效（零延迟组合 ROM）。
 *   FPGA 的 Block RAM 是**同步读**：地址打一拍、数据下一拍才出，
 *   所以真实存储器不可能同拍返回数据。
 *
 * 时间对齐（本文件最关键的部分，所有寄存器都为这一条服务）：
 *   一次取指横跨两拍，且“喂 BRAM 的地址”与“做判定的 index/tag”必须描述
 *   **同一条请求**，判定还必须与 mem_rdata 落在同一拍：
 *
 *     拍 T   ：IFU 呈现 cpu_addr(T) = A
 *     ── posedge T→T+1 ──
 *              ① cpu_addr_r  <= A           // 喂 BRAM，下一拍才出数据
 *              ② cpu_index_r <= A 的 index   // 必须同沿、同源，与①配对
 *                 cpu_tag_r   <= A 的 tag
 *     拍 T+1 ：align_index_r/align_tag_r（T→T+1 沿由②再寄存一拍）
 *              与 mem_rdata(=A 的数据) 同拍 → hit/cpu_rdata/miss 全部对齐到 A
 *
 *   两个实测踩过的坑：
 *   - ② 必须与 cpu_addr_r **同沿同源**，否则两者的请求会差一拍，
 *     每条新指令都被误判成 miss（前端变成 3 拍走一条）。
 *   - 判定不能挂在“本拍 cpu_addr”上：本拍 cpu_addr 已是**下一条**请求，
 *     它的数据还在 BRAM 里。
 *
 * fetch_align 与 IFU 的契约：
 *   BRAM 的返回结果比 IFU 当前呈现的地址**晚一拍**，所以新地址出现的第一拍，
 *   拿回来的还是**上一个**地址的结果。这一拍必须：
 *     - 报 fetch_align=0（结果无效），
 *     - 顺带把 hold 拉高，让 IFU 保持 PC（myCPU 已把 hold 并进 IFU_stall），
 *   从而维持不变式「cpu_addr 稳定 ⇒ 返回结果属于当前 pc」。
 *   如果这一拍就放行 PC，IFU 会把下一条地址的指令和上一条的返回错配，
 *   而且会把别的地址的数据当成当前行填进缓存（污染后造成假命中）。
 *
 * 访问时序（miss 路径，PC 停在 A）：
 *   T   : 呈现 A，采样 cpu_addr_r=A（这一拍返回的是旧结果，fetch_align=0 → 停拍）
 *   T+1 : 本拍 fetch_align=1 且 miss → hold=1，前端继续停住；
 *         同拍用 A 的 tag/valid + mem_rdata(=A 的数据) 回填整行
 *   T+2 : PC 仍是 A，本拍 fetch_align=1 且 hit → 解除 hold，PC 前进
 *   miss 的额外代价固定 +1 拍。因为 PC 被停住，重试拍必然命中，miss 永不重复。
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

    localparam LINES = 1 << INDEX_BITS;

    logic                 valid [0:LINES-1];
    logic [TAG_BITS-1:0]  tag   [0:LINES-1];
    logic [31:0]          data  [0:LINES-1];

    // 组合地址侧：只用于生成“本拍要寄存的 index/tag”，与 cpu_addr_r 同沿寄存
    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0]   tag_in;
    assign index  = cpu_addr[INDEX_BITS+1:2];
    assign tag_in = cpu_addr[31:INDEX_BITS+2];

    /* ---------------- 请求侧寄存器（喂 BRAM） ---------------- */
    logic [31:0]           cpu_addr_r;
    logic                  cpu_en_r;
    logic [INDEX_BITS-1:0] cpu_index_r;
    logic [TAG_BITS-1:0]   cpu_tag_r;

    assign mem_addr = cpu_addr_r;
    assign mem_en   = cpu_en_r;

    /* ---------------- 判定侧寄存器（与 mem_rdata 同拍对齐） ---------------- */
    logic [INDEX_BITS-1:0] align_index_r;
    logic [TAG_BITS-1:0]   align_tag_r;
    // 返回侧寄存器是否已经装过一条**真实请求**。
    //   reset / 第一个请求拍：align_*_r 还是复位值，而 mem_rdata 是复位前的
    //   垃圾。如果不加这个限定，那一条垃圾数据会被写进缓存行，之后带着
    //   valid=1 命中，整机就从这个错误指令开始跑（实测踩到过）。
    logic                  resp_valid_r;

    // 地址是否已经稳定到“当前这条请求”：新地址出现的第一拍，BRAM 返回的还是
    // 旧地址的结果，这一拍必须报未对齐。
    logic addr_same_r;
    assign addr_same_r = (cpu_addr == cpu_addr_r) & cpu_en_r;

    // 只有“返回侧已装载”且“地址稳定”时，align_*_r 与 mem_rdata 才是同一条请求。
    assign fetch_align = resp_valid_r & addr_same_r;

    assign hit  = fetch_align && valid[align_index_r] && (tag[align_index_r] == align_tag_r);
    assign miss = fetch_align && ~hit;

    // 未对齐或未命中时给前端灌 `NOP`，绝不把未就绪/别的地址的数据当指令。
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

            // ---- ③ 判定与回填：只在结果确实属于当前请求时才动缓存 ----
            //     这样新地址带来的废拍不会把别的地址的数据写进缓存行。
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
