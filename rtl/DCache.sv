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
 * ★ store 单次触发怎么判（这一条踩过两个方向的坑，别再改回任一种）：
 *   - cpu_en / cpu_wen 是**电平**，由上游 LSU 的 pipe 级寄存器保持：流水线被 MDU busy 或下游不就绪
 *     冻住时，同一条 store 会连续多拍保持。所以「每拍都写」是错的（实测同地址连写 4 拍）；
 *   - 但「只在有一拍空闲后才再发」也是错的：三态状态机 WR_IDLE/ISSUE/WAIT 会让**背靠背的两条
 *     store 里第二条永远拿不到脉冲**，被静默丢弃（v10.1 用 Verilator + 随机差分 + 黄金模型
 *     测出来的真功能缺陷，最小复现见 _diag/vsim/probe_store.py 的 A 变体：
 *       sh x23,174(x31) ; sb x6,168(x31) ; lb x16,168(x31) -> 读回 0）。
 *   正确判据只有一个：**本拍这次访存是否真的被受理（推进）**，即端口 cpu_adv
 *   （顶层 myCPU 里 = LSU 的 ready_next & ~lsu_freeze，与 LSU.sv 的推进条件同式）。
 *   store_fire = cpu_en & cpu_wen & cpu_adv —— 每条 store 恰好一拍；冻结期间不重复写。
 * ★ 不变量：store_req_r 必须是**单拍脉冲**（一次 store 只写一次），串行化/边沿检测/纯电平原样照搬
 *   三者都错，只有 cpu_adv 这条判据对 → §DCACHE-2。
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
    // 本拍 LSU 访存流水**确实推进**（= LSU 内部 ready_next & ~lsu_freeze）。
    //   cpu_en/cpu_wen 是电平，会因 MDU 忙 / 下游不就绪而保持多拍；store 的「发过一次」
    //   必须用推进信号判定，否则一条 store 会被写成多拍（实测被测试台 write-once 抓到
    //   同地址连写 4 拍）。详见下面 store_fire 处的说明。
    input  logic        cpu_adv,
    // ★ v14（P4）：LSU 的"本次请求身份证"（每推进一条 M2 指令翻转一次）。
    //   用来区分"同一条请求还在"和"同地址的下一条请求到了"—— 只比地址区分不了。
    input  logic        req_seq,

    /* ★ v15：M1 命中探测口（第二个读口，只读）—— 用来把 load-use 从 2 拍压到 1 拍。
     *   为什么需要第二个口：DCache 的数组读是**组合**的（`data[index]`），但地址用的是
     *   M2 那一段；而 M1 那一段（`Ex_result_addr_reg`，load 的有效地址）现在就能查。
     *   命中时 M1 当拍就能给出数据 ⇒ 消费者不必等到 M2。
     *   ★ 只在**命中**且**同拍没有 store 合并打同一行**时有效；不命中/MMIO 一律退回老路径。 */
    input  logic [31:0] m1_addr,
    input  logic        m1_en,
    output logic        m1_hit,
    output logic [31:0] m1_rdata,

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

    logic [LINES-1:0]    valid;              // v11（S2）：打包向量（原为 [0:LINES-1] 数组）
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

    /* ---------------- 2a) P4 修复（v14）：uncacheable 读只发一次 ----------------
     * 机制（实测，见 docs/CHECKPOINT_v14.md §4）：
     *   `mem_req_r` 在数据返回那一拍被清，而 `cpu_en_r` 要到 LSU 推进后才掉 ——
     *   中间那个窗口里 `cache_rd_req` 又为 1，于是**同一条已服务完的请求**
     *   又对总线打了一次读（板上 `perip_ren` 出现第二条脉冲）。
     *
     * 修法：给"这条 uncacheable 请求已经发过读"一个粘滞位 `unc_busy`，并且
     *   **只允许用请求身份证（req_seq）来清**：
     *     · 同一条请求还在（LSU 冻结/数据刚回）→ seq 不变 → 粘滞位保持 → 不重发；
     *     · 换了一条请求（哪怕地址完全相同、背靠背轮询同一寄存器）→ seq 变了 → 清。
     *   只比地址是**错的**：`while (!(RXSTAT & 1));` 这种同地址轮询会读到上一次的旧值。
     *   ★ 粘滞期间必须让响应保持有效（resp_for_now 里那一项），否则 mem_req_r 已清、
     *     hold 又变 1，而重发被禁止 ⇒ LSU 等一个永远不来的响应（自锁）。
     *   验收：sim/tb_monitor.sv 的 [COUNT] 里 RXDATA reads == rx_pop pulses（原来是 2:1）。
     * --------------------------------------------------------------------------- */
    logic unc_busy;       // 本请求已发过 uncacheable 读
    logic req_seq_r;      // 与 cpu_addr_r 同沿寄存的身份证
    logic unc_seq_r;      // 发读那一刻的身份证
    logic req_same;       // 寄存侧看到的还是"发读时那一条"请求
    assign req_same = (req_seq_r == unc_seq_r);

    assign cache_rd_req = cpu_en_r & ~cpu_wen_r & ~line_resident & ~mem_req_r
                        & ~(uncacheable & unc_busy & req_same);

    logic mem_data_vld;   // 本拍 mem_rdata 已是本次读的返回数据
    assign mem_data_vld = ~cache_rd_req & mem_req_r;

    assign mem_en = cache_rd_req;

    /* ★★ v13 修复（第四处）：记住"这次读是替哪个地址发的"。
     * `mem_data_vld` 只表示"有一份读数据当拍到达"，它**不保证**这份数据属于
     * 当前这条请求。实测（+wtrace=000101d4）：
     *     [S] c=3082 addr=000101d4 wd=000102c8 store_hit=0     ← store 写直达进 DRAM
     *     [F] c=4554 addr=000101d4 mem_rdata=0001033c          ← 回填用了**别的地址**的读数据
     *     [L] c=5875 addr=000101d4 rdata=0001033c dram=000102c8 ← 之后一直命中脏行
     * 也就是说：某次读返回的那一拍，地址恰好与当前请求相同（addr_same_r 成立），
     * 但那份 mem_rdata 是**更早的另一次读**留下的 —— 于是把别人的数据当成自己的填进缓存。
     * 后果就是 CoreMark 里 .rodata 的字被填成指针值、CRC 全错。
     * 修法：在发读那一拍把地址记下来，回填（以及 hit/resp 判定）必须要求
     *   `rd_addr_r == cpu_addr_r`，即"这份数据确实是为这个地址取的"。
     *   代价只有 32 个 FF。 */
    logic [31:0] rd_addr_r;

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
    // ★ v13：和回填一样，读返回也必须"确实是发给当前地址的那次读"。
    //   只比 index/tag 还不够 —— 实测（[MBAD] c=4564 addr=000103c8 got=00010530）
    //   出现过"读返回被张冠李戴给另一个地址"的情况，data 是别人的。
    assign resp_for_now = (mem_data_vld & (cpu_index_r == index) & (cpu_tag_r == tag_in)
                           & (rd_addr_r == cpu_addr_r))
                        | (uncacheable & unc_busy & req_same & (rd_addr_r == cpu_addr_r));

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

    /* ---------------- 4) store 请求单拍脉冲 ---------------- */
    // ★ v10.1 修复（真实功能缺陷，用 Verilator + 随机差分测出来的）：
    //   原来是三态状态机 WR_IDLE/ISSUE/WAIT，脉冲条件写的是
    //       store_fire = cpu_en & cpu_wen & (store_state == WR_IDLE)
    //   而 state 只有在「有一拍没有 store」时才会回到 WR_IDLE。于是**两条背靠背的
    //   store 里第二条永远拿不到脉冲**，被静默丢弃（不报错、不重放）：
    //       实测 minimal repro（_diag/vsim/probe_store.py 的 A 变体）：
    //         sh x23,174(x31) ; sb x6,168(x31) ; lb x16,168(x31)
    //       → 总线只在第一条 store 上出现一次写，第二条一次都没有，读回 0。
    //   为什么可以去掉状态机：LSU.sv 的接口契约就是「一次访问只在 M2 那一拍发一次」
    //   （见 LSU.sv:13），store 的 mem_hold 恒为 0（写直达、不等读数据），所以
    //   cpu_en & cpu_wen 天然就是「一条 store 一拍」。状态机非但没提供保护，
    //   反而把相邻 store 吃掉了。
    //   代价/边界：如果将来把 store 改成可能冻结多拍（写缓冲/背压），这里会在同一
    //   地址上重复写同样的数据 —— 对 RAM/BRAM 幂等无害，对 MMIO 会重复副作用，
    //   届时请改用「能否推进」做单次判定，而不是恢复这个状态机。
    logic       store_fire;

    logic [31:0] store2_wdata;
    // ★ v13：store2_mask 仍要保留 —— 它是**发往存储器的写脉冲**用的字节掩码。
    //   写脉冲在 store_fire 的下一拍才发（mem_wen = store_req_r），那一拍的
    //   cpu_mask 已经推进到下一条指令了，所以必须用寄存副本。
    //   而 store2_index / store2_offset / store2_hit 随"合并前移"一起删掉了
    //   （合并改在请求拍做，不再需要它们跨拍保存）。
    logic [ 1:0] store2_mask;
    logic                  store_req_r;

    assign store_fire = cpu_en & cpu_wen & cpu_adv;

    /* ---------------- 4b) store 命中合并：必须在**请求拍**做 ----------------
     * ★ v13 修复（v12 之前一直存在的真实功能缺陷）：
     *
     * 症状（三条独立线索指向同一处）：
     *   · 背靠背 `sw x,t0 ; lw x,t0` 读回**旧值**。用 sw/gen_storelw.py 量的窗口：
     *     store 与 load 之间 0 个 nop → 错；1~4 个 nop → 全对。即**窗口正好 1 拍**。
     *   · CoreMark 在 matrix_test 里循环上界变成天文数字（指针读回旧值）。
     *   · FreeRTOS 的 `++uxSchedulerSuspended` 后紧跟 configASSERT 读它 →
     *     断言 tasks.c:2446 挂掉。
     *
     * 原因：原来只在 `store_req_r`（= store_fire 打一拍）那一拍把载荷合并进
     *   data[index]，而 load 的命中判定 hit_now 用的是**当前拍**的 data[]。
     *   紧接着的那条 load 恰好在这一拍做判定 —— 合并的赋值要下一拍才生效，于是
     *   它读到的是合并前的旧行。整条链就差这 1 拍。
     *
     * 修法：合并直接用 store 请求拍（store_fire）的 cpu_wdata/cpu_mask/cpu_addr，
     *   在本拍写入 data[index]（赋值在本拍末生效 → 下一拍的任何 load 都能看到）。
     *   ★ 为什么可以放心用 cpu_* 而不是寄存副本：LSU 的契约就是"一次访问只在 M2
     *     那一拍发一次"（LSU.sv:13），store_fire 那一拍的 cpu_wdata/cpu_mask 与
     *     cpu_addr 严格属于这一次 store；而 store2_* 本来就是在**同一拍**由它们
     *     采出来的副本，值完全一样。
     *   ★ 不变量：**不能**同时保留"store_req_r 拍合并"和"store_fire 拍合并"。
     *     两条背靠背 store 打同一字时，晚一拍的那次合并会拿**更老**的载荷覆盖
     *     新数据（非阻塞赋值的覆盖顺序由语句先后决定）。所以下面那份旧的
     *     F+1 合并已删除，store2_* 只留给"发往 DRAM 的写脉冲"用。
     *
     * 未命中（行不驻留）时照旧不分配、不合并 —— 写直达把数据送进 DRAM，
     *   后继 load 会 miss 后从 DRAM 取回新值（读请求比写脉冲晚 ≥1 拍）。 */
    logic store_hit_now;
    assign store_hit_now = ~uncacheable_req & valid[index] & (tag[index] == tag_in);

    /* ---------------- 4c) 同一拍"回填"与"store 合并"撞同一行 → 放弃合并 ----------------
     * ★ v13 修复（第二个真实缺陷，与 4b 同源但机制不同）：
     *
     * 场景：load 在 T 拍 miss 并发出读；数据在 T+2 拍回来 → 那一拍执行回填
     *   `data[cpu_index_r] <= mem_rdata; tag[cpu_index_r] <= cpu_tag_r; valid[...] <= 1`。
     *   而 T+2 拍**同时**可能有一条 store 命中（`store_hit_now` 用**旧**的 tag[] 判的）。
     *   如果两者的 index 相同、tag 不同（不同地址映射到同一行），两条非阻塞赋值
     *   写的是同一个 data[index]：语句在后的 store 合并会覆盖掉刚填进去的 load 数据，
     *   而 valid/tag 却被回填写成了 load 的 —— 结果是一行**"标签是 A、数据是 B"**
     *   的脏行。之后任何读 A 的 load 都会命中并拿到 B 的数据，**不报错、不留痕**。
     *
     * 症状（实测）：`sw/memtest.c` 先把 4KB 阵列写一遍（1KB 的 DCache 被彻底冲刷），
     *   之后读 .rodata 打印字符串，个别字节变成 0xd7/0xab 这种内存里根本不存在的值。
     *
     * 修法（★ 第一版写反了，被"命中值必须等于 DRAM"的自检抓出来）：
     *   同一拍冲突时，让 **store 合并赢、回填让掉**。
     *   理由：store 是**更年轻**的指令，语义上它该占住这一行；而那条 load 的数据
     *   直接从 `mem_rdata` 返回（`cpu_rdata = hit_now ? data[index] : mem_rdata`），
     *   并不需要 data[] 里也有一份 —— 少这一次回填不影响它的结果。
     *   ⚠️ 反过来"放弃合并"是**错的**：行仍然 valid、tag 仍然匹配，于是它变成一条
     *     **脏行**（tag 对应某地址、data 却是旧值），之后所有读该地址的 load 全部
     *     命中并拿到旧值 —— 实测就是栈上 0x1ff9c 读到 0、而 DRAM 里是 7。
     * ------------------------------------------------------------------- */
    logic fill_now;
    // ★★ v13 修复（第三处、也是最隐蔽的一处）：回填必须要求**本拍真的是一条 load**。
    //   原来只有 `access_en & ~hit & ~uncacheable`。`access_en` 只表示"地址稳定一拍 +
    //   有一份读数据在路上"，**并不看本拍是什么访问**；而 `hit` 对 store 恒为 0
    //   （hit_now 里有 ~cpu_wen）。于是出现这条链：
    //       sw 0x1ff9c,7   （命中，合并进行 = 7）
    //       下一拍         （同一地址，cpu_addr==cpu_addr_r，resp_valid_r 仍为 1，
    //                       且有历史遗留的 mem_req_r/mem_data_vld）
    //       → fill_now 成立 → 用**陈旧**的 mem_rdata(=0) 回填同一行 → 把 7 覆盖成 0
    //   实测（tb_cm +wtrace=0001ff9c）：
    //       [S] c=14112 addr=0001ff9c wd=00000007 store_hit=1
    //       [F] c=14113 addr=0001ff9c mem_rdata=00000000   ← 假回填
    //       [L] c=14223 addr=0001ff9c rdata=00000000 dram=00000007
    //   这就是 CoreMark/FreeRTOS 里"栈上的值莫名其妙变成 0"的来源。
    //   ★ v13：还要"这份数据是为当前地址取的"（见上面 rd_addr_r 的说明）
    assign fill_now = access_en & cpu_en & ~cpu_wen & ~hit & ~uncacheable
                    & (rd_addr_r == cpu_addr_r);

    logic store_merge_now;
    assign store_merge_now = store_fire & store_hit_now;

    /* ---------------- 4d) v15：M1 命中探测（第二个读口） ----------------
     *   m1_addr = LSU 的 M1 级有效地址（load 的 Ex_result），m1_en = 该级是 load。
     *   命中条件与主读口**同一口径**（同 index/tag/valid、非 MMIO），只多一条护栏：
     *   若本拍有一次 store 合并打到**同一个 index**，数组里还是合并前的旧值（合并在本拍
     *   末才生效），这时不能用 M1 端口的数据 —— 退回 M2 路径（多停 1 拍，功能正确）。
     *   ★ 不需要为"回填（fill）撞同一行"设护栏：回填只在行不驻留时发生，而那时
     *     m1_hit 本来就为 0（valid/tag 不匹配）；本拍读到的旧行对"命中"而言仍是正确值。 */
    logic [INDEX_BITS-1:0] m1_idx;
    logic [TAG_BITS-1:0]   m1_tag;
    logic                  m1_unc;
    logic                  m1_conflict;
    assign m1_idx      = m1_addr[INDEX_BITS+1:2];
    assign m1_tag      = m1_addr[31:INDEX_BITS+2];
    assign m1_unc      = (m1_addr & ~UNCACHE_MASK) != 32'b0;
    assign m1_conflict = store_merge_now & (index == m1_idx);
    assign m1_hit      = m1_en & ~m1_unc & ~m1_conflict
                       & valid[m1_idx] & (tag[m1_idx] == m1_tag);
    assign m1_rdata    = data[m1_idx];

    // 回填与 store 合并撞同一 index → 放弃回填（store 赢）
    logic fill_blocked;
    assign fill_blocked = store_merge_now & (cpu_index_r == index);

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
    // ★ v11（S2）：valid 从「一行一位的数组」改成**打包向量** `[LINES-1:0]`。
    //   原因：S2 把 LINES 从 64 提到 256 之后，Verilator 5.020 直接报
    //     %Error-BLKLOOPINIT: Delayed assignment to array inside for loops
    //   —— 它对"for 循环里给数组做非阻塞赋值"的展开有上限，64 行能展开、256 行不行。
    //   改成向量后复位就是一条 `valid <= '0`，不再有循环：三个仿真器与综合器口径一致。
    //   （读侧 `valid[idx]`、填充侧 `valid[idx] <= 1'b1` 在位选上完全等价。）
    always_ff @(posedge clk) begin
        if (reset) begin
            valid        <= {LINES{1'b0}};
            cpu_addr_r   <= 32'b0;
            cpu_en_r     <= 1'b0;
            resp_valid_r <= 1'b0;
            cpu_index_r  <= {INDEX_BITS{1'b0}};
            cpu_tag_r    <= {TAG_BITS{1'b0}};
            cpu_wen_r    <= 1'b0;
            mem_req_r    <= 1'b0;
            unc_busy     <= 1'b0;
            req_seq_r    <= 1'b0;
            unc_seq_r    <= 1'b0;
            rd_addr_r    <= 32'b0;
            store_req_r  <= 1'b0;
            store2_wdata <= 32'b0;
            store2_mask  <= 2'b0;
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

            // ★ v14（P4）：身份证与请求侧寄存器**同沿**采样（与 cpu_addr_r 一起），
            //   这样"寄存侧看到的请求"和"发读时的请求"能逐拍对齐。
            req_seq_r <= req_seq;
            if (cache_rd_req && uncacheable) begin
                unc_busy  <= 1'b1;
                unc_seq_r <= req_seq_r;          // 记下"这条请求"的身份证
            end else if (!req_same) begin
                unc_busy  <= 1'b0;               // 换请求了（同地址也算换）
            end

            // ★ v13：记录"这次读是替哪个地址发的"，供回填/命中判定校验归属
            if (cache_rd_req) rd_addr_r <= cpu_addr_r;

            // ---- store 脉冲：store_fire 那一拍采载荷，下一拍发一拍写脉冲 ----
            store_req_r <= store_fire;

            // ---- store 载荷：只给"发往存储器的写脉冲"用 ----
            //   ★ v13：缓存行的合并已经挪到 store_fire 那一拍（见 4b 段），这里只
            //     保留写脉冲需要的 wdata 副本；mask/index/offset 不再需要跨拍保留。
            if (store_fire) store2_wdata <= cpu_wdata;
            if (store_fire) store2_mask  <= cpu_mask;

            // ---- 计数器（口径随新的判定侧一起更新，仅用于观测）----
            //   命中：本拍**load**由缓存行服务（hit_now），或上一拍发出的**store**命中了
            //         （store_req_r & store2_hit）。
            //   ★ v12（B）修口径：原来只统计 load —— `hit_now` 里带 `~cpu_wen`，而 store
            //     命中的判定在 `store2_hit` 里、**没有任何计数器在记**。后果是程序里
            //     一轮 `sw + lw` 两次访存只涨 1，用计数器反推访存次数会算错一半。
            //     现在两类都记，且用"加法"而不是 if/else —— 因为 sw 之后的下一拍正好是
            //     lw 的请求拍，两个条件可以同拍成立，用 if/else 会吞掉一个。
            //   ★ 仍然是 32 位：50MHz 下 demo 程序约 2.4M 次/s，约 **30 分钟**回绕；
            //     要看长时间行为请以 mtime/周期为参考，别只看这个计数。
            hit_cnt  <= hit_cnt + (hit_now ? 32'd1 : 32'd0)
                                + ((store_fire & store_hit_now) ? 32'd1 : 32'd0);
            if (resp_for_now & ~hit_now & ~uncacheable)     miss_cnt <= miss_cnt + 32'd1;

            // ---- load 未命中回填整字（此时 mem_data_vld=1，mem_rdata 就是本行数据）----
            //   MMIO 地址不回填（不分配），保证外设寄存器永远不会被缓存。
            //   ★ v13：若同一拍有 store 合并打同一 index，则让合并赢、回填让掉
            //     （详见上面 4c 段；反过来会造出"tag 匹配但 data 是旧值"的脏行）。
            if (fill_now && !fill_blocked) begin
                valid[cpu_index_r] <= 1'b1;
                tag[cpu_index_r]   <= cpu_tag_r;
                data[cpu_index_r]  <= mem_rdata;
            end

            // ---- store 命中时把数据合并进缓存行 ----
            //   ★ v13：合并挪到 store 的**请求拍**（原来在 store_req_r 那一拍，
            //   导致"store 后紧跟同地址 load"读旧值，见上面 4b) 段的长注释）。
            if (store_fire && store_hit_now) begin
                case (cpu_mask)
                    2'b00: case (cpu_addr[1:0])          // sb
                               2'b00: data[index][7:0]   <= cpu_wdata[7:0];
                               2'b01: data[index][15:8]  <= cpu_wdata[7:0];
                               2'b10: data[index][23:16] <= cpu_wdata[7:0];
                               default: data[index][31:24] <= cpu_wdata[7:0];
                           endcase
                    2'b01: if (cpu_addr[1] == 1'b0) data[index][15:0]  <= cpu_wdata[15:0];
                           else                     data[index][31:16] <= cpu_wdata[15:0];
                    default: data[index] <= cpu_wdata;
                endcase
            end
        end
    end

endmodule
