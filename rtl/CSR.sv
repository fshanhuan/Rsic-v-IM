`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * CSR.sv — 机器模式控制状态寄存器 + 中断判决（v9）· Reg_Stack 的子块
 * -----------------------------------------------------------------------------
 * 上游 ID 级给 ecall/mret/intr_take/trap_take，下游 Reg_Stack 的 csrs 读多路选择。
 * 寄存器：mstatus · mie · mip · mtvec · mepc · mcause · mscratch · mtval ·
 *   mvendorid/marchid(常量) · mtime/mtimecmp(教学定时器 0x7C0/0x7C1) ·
 *   **mcycle/minstret(64 位，v12（B）新增的 Zicntr)**。
 * 陷入入口都是 mtvec（PC 重定向在 Control 中）；中断优先级 MEI(11)>MSI(0)>MTI(7)。
 *
 * ★ 接口契约（改之前必读）：
 *   - 陷入/返回的 CSR 更新都在**译码级**那一拍完成（ecall/mret/intr_take/trap_take
 *     都由 ID 级发起），软件 CSR 写（csr_wen/csrd）在 WB 级生效；两者分离，
 *     同拍相撞时陷入优先 —— 见各 always_ff 里 if 链的顺序。
 *   - RESET_VAL 只给 mepc/mcause/mtvec/mscratch/mtval 用；mstatus/mie/mip 各有自己
 *     的复位常量，mtime/mtimecmp 不受它影响。
 *   - 是否真的在这拍接收中断由 Control 决定，本模块只报 intr_pending。
 *   - 各现场寄存器的写使能口径见下方 ★ 不变量（原编号 C4/C7 保留）。
 * =========================================================================== */
module CSR #(
    parameter CSR_WIDTH = 32,
    // 软件可见现场寄存器（mepc/mcause/mtvec/mscratch/mtval）的复位值
    parameter RESET_VAL = 0
) (
    input  logic        clock,
    input  logic        reset,

    input  logic [31:0] pc,          // 被陷入指令的 PC（译码级，写进 mepc）
    input  logic        ecall_flag,
    input  logic        mret_flag,
    input  logic        intr_take,   // Control 判定“本拍接收中断”

    // ---- v9 新增（C4）：统一异常通道 ----
    // ★ 不变量（v10 修正）：这里**只有 trap_take 一根确认线**。原来还有一根
    //   trap_take_q（下一拍补发），并且要求所有"登记一次陷入"的条件都含它 —— 那是
    //   错的：补发那一拍 EX 级已经没有异常了，trap_cause 退化成 0000、ID 级 pc 也
    //   已经换成了重定向后的值，于是把刚写对的 mepc/mcause 覆盖成 0
    //   （实测 exc_illegal：cyc14 mcause=2/mepc=0x20 → cyc15 mcause=0/mepc=0，
    //    mret 回到 0 → 无限重启）。v10 的前端不再会丢重定向脉冲，补发机制整体删除。
    //   trap_cause 见 para.sv 的 `EXC_*，**必须独热**，由 exc_mcause/exc_mtval 翻译。
    //   细节：syn/修复史_全量.md §CSR-2
    input  logic        trap_take,
    input  logic [ 3:0] trap_cause,
    input  logic [31:0] fault_addr,  // 非对齐/非法目标地址（EX_result）
    input  logic [31:0] fault_inst,  // 非法指令的编码（IDU_inst）
    // ★ v10 新增（C9）：出错指令的 PC（= EX 级 PC）。同步异常在 EX 级判定，而本模块的
    //   pc 端口接的是**译码级** PC（差两条指令），所以 mepc 必须用这一根。
    input  logic [31:0] fault_pc,

    input  logic [31:0] csrd,        // 软件写入数据（WB 级生效）
    // csr_wen 位号 = `CSRW_*，对应 12 位地址 [0]MEPC341 [1]MCAUSE342 [2]MSTATUS300
    //   [3]MTVEC305 [4]MIE304 [5]MIP344 [6]MSCRATCH340 [7]MTIMECMP7c1
    //   [9]MTVAL343（v10.3 新增：特权规范把 mtval 列为 MRW）
    //   [10]MTIME7c0（v10.3 新增：0x7C0 落在 "Custom read/write" 段）
    //   [8] 是 `CSRW_OP 标记位（不是寄存器），[11:15] 未使用
    input  logic [15:0] csr_wen,

    // ★ v12（B）新增：一条指令**真正退休**的单拍脉冲（来自 LSU 的 WB 入口：
    //   `valid_reg_pipe & ready_next & ~lsu_freeze`）。minstret 只认这一个信号。
    //   ★ 不能用 WBU_valid 代替：WBU 从不背压，但 LSU 的 mem_hold（DCache 缺失）/mdu_busy
    //     会把 WB 入口冻住，valid_wb 于是**连续多拍为 1**；拿它当计数使能会把一次访存
    //     缺失数成 3~4 条指令（这正好是历史上"仿真与上板拍数口径对不上"的同类坑）。
    //   ★ 口径说明：本核的 minstret 计的是"进入 WB 的指令"。陷入的那一条本身也在 WB
    //     记账（规范说陷入指令不算退休），差 1/次陷入 —— 对性能测量无影响，故不为它
    //     加门控（门控还得把 EX 级 trap_take 的时间差算进来，得不偿失）。
    input  logic        retire,

    // 读出并到 Reg_Stack 的 csrs 多路选择（软件 csrr* 的返回口），mvendorid/marchid
    //   是常量。只有 mepc/mtvec/mcause/mtval 被 IDU 继续引到 myCPU 的 debug 端口
    //   （顶层/ILA 可观察）；mstatus/mie/mip/mscratch/mtime/mtimecmp 在 IDU 里悬空。
    output logic [31:0] mvendorid_out,
    output logic [31:0] marchid_out,
    output logic [31:0] mepc_out,
    output logic [31:0] mcause_out,
    output logic [31:0] mstatus_out,
    output logic [31:0] mtvec_out,
    output logic [31:0] mie_out,
    output logic [31:0] mip_out,
    output logic [31:0] mscratch_out,
    output logic [31:0] mtime_out,
    output logic [31:0] mtimecmp_out,
    // v9 新增（C4）：mtval 引出（非法指令编码 / 非对齐地址）
    output logic [31:0] mtval_out,
    // ★ v12（B）新增：Zicntr 的 64 位计数器（读通路在 Reg_Stack 的多路选择里）。
    //   mcycle_out 的低 32 位同时引到顶层当 ILA probe（板上"每条指令花了几拍"的唯一来源）。
    output logic [63:0] mcycle_out,
    output logic [63:0] minstret_out,

    output logic        intr_pending // = mstatus.MIE & |(mie & mip)
);

    /* ----------------------------- 常量 ID ------------------------------- */
    assign mvendorid_out = 32'h79737978;   // "ysyx"，教学标识；下面 marchid 为示例值，两者只读
    assign marchid_out   = 32'h16FBCBD;

    /* --------------------------- mtime / mtimecmp ------------------------ */
    // ★ 不变量：mtime 是**按 `MTIME_DIV_DEFAULT 分频的递增计数器**，不是“每拍 +1”的
    //   拍计数器（原 C7）。100MHz 下每拍 +1 会让它比真实时间快约 1000 万倍，拿它算
    //   时间/延时没有意义；分频后（默认 100）相当于 1MHz，即每 1us 加 1，置 1 则退回
    //   旧的“每拍 +1”（回归脚本依赖该口径）。代价只有 log2(DIV) 个触发器。
    //   ★ v12 补充（口径订正）：上面"1MHz"是按 100MHz 时钟算的，**上板实际是 50MHz**
    //     （board_top_ila 的 MMCM 分频），所以 mtime 的真实速率是 **500kHz / 2µs 每 tick**。
    //     也正因为它是墙钟而不是拍数，v12（B）才补了 mcycle/minstret —— 要量拍数只能靠它们。
    //   细节：syn/修复史_全量.md §CSR-1
    logic [31:0] mtime_reg;
    logic [31:0] mtime_divcnt;
    logic        mtime_tick;
    always_comb begin
        if (`MTIME_DIV_DEFAULT <= 1) mtime_tick = 1'b1;
        else                         mtime_tick = (mtime_divcnt >= (`MTIME_DIV_DEFAULT - 1));
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            mtime_divcnt <= 32'b0;
            mtime_reg    <= 32'b0;
        end else if (csr_wen[`CSRW_MTIME]) begin
            // ★ v10.3：软件写优先于自增，且顺带把分频计数器清零（下一 tick 从整分频开始算，
            //   否则刚写完 0 又立刻 +1，读回来比写入值大 1，软件没法用它做精确基准）。
            //   原来这里没有写分支，`csrw mtime, x1` 被静默丢弃 —— 而 0x7C0 在规范里属于
            //   "Custom read/write"，不写就是假实现。
            mtime_divcnt <= 32'b0;
            mtime_reg    <= csrd;
        end else if (mtime_tick) begin
            mtime_divcnt <= 32'b0;
            mtime_reg    <= mtime_reg + 32'd1;
        end else begin
            mtime_divcnt <= mtime_divcnt + 32'd1;
        end
    end

    logic [31:0] mtimecmp_reg;
    always_ff @(posedge clock) begin
        // mtimecmp 复位成全 1：上电后 mtime 追不上它，不会立刻冒出 MTIP 中断
        if (reset)                              mtimecmp_reg <= 32'hFFFF_FFFF;
        else if (csr_wen[`CSRW_MTIMECMP])        mtimecmp_reg <= csrd;
    end

    assign mtime_out    = mtime_reg;
    assign mtimecmp_out = mtimecmp_reg;

    /* --------------------------- v12（B）Zicntr -------------------------- */
    // 标准计数器对（Zicntr，原 Base counters）：mcycle = 时钟拍数，minstret = 退休指令数。
    // 都是 **64 位**：RV32 上必须拆成 两个 32 位 CSR（低半 / 高半，见 para.sv 的地址表）。
    // ★ 为什么要在这里做：mtime 是分频后的墙钟（50MHz/`MTIME_DIV_DEFAULT = 500kHz），
    //   它量不出拍数。没有 mcycle 就只能靠仿真猜性能，与真实硬件对不上。
    // ★ 不变量：软件写**优先于自增**（与 mtime 的口径一致）。写成"自增后覆盖"会让
    //   `csrw mcycle, 0` 读回来是 1，程序无法用它做精确基准。
    // ★ 不变量：`cycle/instret`(0xC0x) 是这里两个寄存器的**只读影子**，不另建状态。
    //   读写权限由 IDU 的 csr_rdonly（csr[11:10]==2'b11）判，本模块不管 —— 所以
    //   这里根本不需要 cycle 的写分支，写了也不会来（会先被判成非法指令）。
    logic [63:0] mcycle_reg;
    logic [63:0] minstret_reg;

    always_ff @(posedge clock) begin
        if (reset)                            mcycle_reg <= 64'b0;
        else if (csr_wen[`CSRW_MCYCLE])       mcycle_reg[31:0]  <= csrd;
        else if (csr_wen[`CSRW_MCYCLEH])      mcycle_reg[63:32] <= csrd;
        else                                  mcycle_reg <= mcycle_reg + 64'd1;
    end

    always_ff @(posedge clock) begin
        if (reset)                            minstret_reg <= 64'b0;
        else if (csr_wen[`CSRW_MINSTRET])     minstret_reg[31:0]  <= csrd;
        else if (csr_wen[`CSRW_MINSTRETH])    minstret_reg[63:32] <= csrd;
        else if (retire)                      minstret_reg <= minstret_reg + 64'd1;
    end

    assign mcycle_out   = mcycle_reg;
    assign minstret_out = minstret_reg;

    /* ------------------------------ mie / mip ---------------------------- */
    // ★ v10.3：mie 写入必须按"已实现的中断源"掩码。WARL 寄存器里没有实现的位是
    //   只读 0；原来整字覆盖，写 0xFFFFFFFF 再读回来就是 0xFFFFFFFF，等于凭空
    //   声明了 29 个本核根本没有的中断源（pending = mie & mip 又恰好把它们全屏蔽了，
    //   所以功能上一直没暴露 —— 典型"读得出、没作用"的假寄存器）。
    //   掩码宏与 Control.sv 的 CSR 前递链共用（见 para.sv `CSR_WMASK_* 的说明）。
    logic [31:0] mie_reg;
    always_ff @(posedge clock) begin
        if (reset)                        mie_reg <= 32'b0;
        else if (csr_wen[`CSRW_MIE])      mie_reg <= csrd & `CSR_WMASK_MIE;
    end
    assign mie_out = mie_reg;

    logic [31:0] mip_sw_reg;              // 软件可写部分（MSIP）
    logic        mtip;                    // 定时器中断挂起（硬件）
    logic        meip;
    assign mtip = (mtime_reg >= mtimecmp_reg);  // 无符号比较：mtime 追平即挂起
    assign meip = 1'b0;                   // 预留外部中断输入

    always_ff @(posedge clock) begin
        if (reset)                        mip_sw_reg <= 32'b0;
        else if (csr_wen[`CSRW_MIP])      mip_sw_reg <= csrd & `CSR_WMASK_MIP; // 仅 MSIP 可写
    end

    assign mip_out = mip_sw_reg | (mtip ? (32'h1 << `IRQ_MTI) : 32'b0)
                                 | (meip ? (32'h1 << `IRQ_MEI) : 32'b0);

    /* ------------------------------ 中断判决 ----------------------------- */
    logic [31:0] pending;
    logic [ 3:0] intr_cause;
    assign pending    = mie_reg & mip_out;
    // 优先级：外部(11) > 软件(0) > 定时器(7) —— 这是 if/else 链的先后，换序即改语义。
    assign intr_cause = pending[`IRQ_MEI] ? 4'd11 :
                        pending[`IRQ_MSI] ? 4'd0  : 4'd7;
    /* ------------------------------ mstatus ------------------------------ */
    logic [31:0] mstatus_reg;
    logic [31:0] mstatus_nxt;
    logic        mstatus_wen;
    // ★ 不变量：mstatus_wen 必须含 trap_take —— 同步异常（非法指令/非对齐访存）与
    //   中断/ecall/mret **一样**要改 mstatus（MPIE<=MIE、MIE<=0）。原来只有
    //   intr_take|ecall_flag|mret_flag，同步异常不关中断，语义是错的。§CSR-2
    assign mstatus_wen = csr_wen[`CSRW_MSTATUS] | trap_commit_eff | mret_flag;

    // 统一的"本拍在登记一次陷入"条件（中断/ecall/同步异常都算）
    logic trap_commit;
    assign trap_commit = intr_take | ecall_flag | trap_take;

    /* ★★ v13 修复（第二个真实缺陷）：一次陷入只能提交一次。
     *
     * 现象（FreeRTOS 空闲任务的 `ecall` @0x2d8，`[E]`/`[R]` 是 ecall/mret 边界）：
     *     [E] cyc=33240 mstatus=00001888   ← 第一次陷入，MPIE<=MIE=1, MIE<=0
     *     [E] cyc=33272 mstatus=00001880   ← 同一条指令还在 ID，正常
     *     [E] cyc=33299 mstatus=0001800    ← **27 拍后 CSR 又提交了一次陷入**
     * 第二次提交时 MIE 已经是 0，于是 MPIE<=0；之后每次 mret 都把 MIE 恢复成 0，
     * 中断永久关闭 —— 表现就是"FreeRTOS 的 tick 只来一次"。
     *
     * 原因：陷入后 PC 改指向 mtvec，但那条 ecall/mret 在流水里还要待几拍才被冲掉，
     * 这几拍里 `ecall_flag`（ID 级电平）仍然为 1，trap_commit 于是重复成立。
     *
     * 修法：提交一次后消隐 8 拍（足够覆盖冲流水 + 重定向），期间不再更新 mstatus。
     * 只挡 mstatus —— mcause/mepc 重复写成同值是幂等的，不必动。
     * ------------------------------------------------------------------- */
    logic [3:0] trap_blank;
    always_ff @(posedge clock) begin
        if (reset)                   trap_blank <= 4'd0;
        else if (trap_commit)        trap_blank <= 4'd8;
        else if (trap_blank != 4'd0) trap_blank <= trap_blank - 4'd1;
    end
    logic trap_commit_eff;
    assign trap_commit_eff = trap_commit & (trap_blank == 4'd0);

    /* ★★ v13 修复（真实功能缺陷，v12 及以前一直存在）：
     *   "csrw mstatus, x" 紧跟 "mret" 时，软件写会在 WB 落盘，而 mret 对 mstatus 的
     *   更新是在 **ID** 做的（mret_flag 直接驱动本模块）。两者相差 4~5 拍，
     *   于是**更老的软件写覆盖了更年轻的 mret**：MIE <= MPIE 这条更新被冲掉，
     *   中断使能位丢失。最小复现（sw/gen_mrettest.py → sim/mrettest.hex）：
     *       csrw mstatus, 0x1880   (MIE=0, MPIE=1)
     *       mret                   期望 0x1888
     *       csrr x10, mstatus      实测 0x1880   ← MIE 丢了
     *   FreeRTOS 的 portRESTORE_CONTEXT 正是这个形状，所以它的第一个 yield 之后
     *   中断就永久关闭（tick 只来一次）。
     *
     *   修法：记一个"mret 在途"窗口；当**软件写 mstatus** 落盘时，若窗口内有一个
     *   更年轻的 mret，就把 mret 的效果叠加到这次写上（MIE<=MPIE, MPIE<=1）。
     *   这样与具体流水级数无关，窗口 8 拍足够覆盖 ID→WB 的距离。 */
    logic [3:0] mret_inflight;
    always_ff @(posedge clock) begin
        if (reset)                   mret_inflight <= 4'd0;
        else if (mret_flag)          mret_inflight <= 4'd8;
        else if (mret_inflight != 0) mret_inflight <= mret_inflight - 4'd1;
    end
    logic mret_pending;
    assign mret_pending = (mret_inflight != 4'd0);

    always_comb begin
        if (trap_commit_eff) begin
            // 陷入：MPIE(bit7) <= MIE(bit3)，MIE(bit3) <= 0，其余位原样保留
            mstatus_nxt = {mstatus_reg[31:8], mstatus_reg[`MSTATUS_MIE],
                           mstatus_reg[6:4], 1'b0, mstatus_reg[2:0]};
        end else if (mret_flag) begin
            // 返回：MIE <= MPIE，MPIE <= 1（同样是逐位拼接，不动别的位）
            mstatus_nxt = {mstatus_reg[31:8], 1'b1,
                           mstatus_reg[6:4], mstatus_reg[`MSTATUS_MPIE], mstatus_reg[2:0]};
        end else begin
            // 纯软件写：WARL 掩码（v10.3）。本核只有 M 模式，所以
            //   · MIE(3)/MPIE(7) 可写（W）；
            //   · MPP(12:11) **恒为 2'b11**：特权规范要求"只支持 M 模式的实现
            //     MPP 是只读 3"，写 0 也不许把它改成 U 模式；
            //   · 其余位（SD/FS/XS/…）本核没有，必须读回 0。
            //   原来是整字覆盖 `mstatus_nxt = csrd`，软件写 0xFFFFFFFF 就能读回
            //   0xFFFFFFFF，凭空造出 29 个不存在的字段 —— WARL 违规。
            //   掩码宏与 Control.sv 的前递链共用（见 para.sv `CSR_WMASK_*）。
            mstatus_nxt = (csrd & `CSR_WMASK_MSTATUS) | `CSR_FORCE_MSTATUS;
            // ★ v13：若有一个更年轻的 mret 在途，把它的效果叠加到这次软件写上
            //   （否则 4~5 拍后这次写会把 mret 做的 MIE<=MPIE 冲掉）
            if (mret_pending)
                mstatus_nxt = {mstatus_nxt[31:8], 1'b1,
                               mstatus_nxt[6:4], mstatus_nxt[`MSTATUS_MPIE],
                               mstatus_nxt[2:0]};
        end
    end

    always_ff @(posedge clock) begin
        if (reset)              mstatus_reg <= 32'h0000_1800;  // MPP=M
        else if (mstatus_wen)   mstatus_reg <= mstatus_nxt;
    end
    assign mstatus_out = mstatus_reg;
    assign intr_pending = mstatus_reg[`MSTATUS_MIE] & (|pending);  // 依赖 mstatus_reg，故在此处赋值

    /* -------------------------------- mepc ------------------------------- */
    // ★ 不变量：mepc_wen 必须与 trap_commit 同口径。取值分三种来源，顺序不能换：
    //     trap_take        -> fault_pc（**EX 级** PC，出错指令本身；v10 修复 C9）
    //     intr_take/ecall  -> pc       （译码级 PC，这两个本来就在 ID 级判定，是对的）
    //     其余             -> csrd     （软件 csrw mepc）
    //   原来一律写 pc，于是同步异常的 mepc 比出错指令晚两条（实测 0x1c 的非法指令
    //   写进了 0x20），mret 直接跳过错指令位置或跑飞。
    logic [31:0] mepc_reg;
    logic        mepc_wen;
    assign mepc_wen = csr_wen[`CSRW_MEPC] | intr_take | ecall_flag | trap_take;
    always_ff @(posedge clock) begin
        if (reset)            mepc_reg <= RESET_VAL;
        else if (mepc_wen) begin
            if (trap_take)                  mepc_reg <= fault_pc;
            else if (intr_take | ecall_flag) mepc_reg <= pc;
            // ★ v10.3：软件写要掩低 2 位 —— 特权规范规定 mepc[1:0] 恒 0（IALIGN=32）。
            //   原来整字存，软件写个奇数进去再 mret 就会跳到非对齐地址，
            //   触发 mcause=0 的"指令地址非对齐"，把一次正常的返回变成异常。
            else                            mepc_reg <= csrd & `CSR_WMASK_MEPC;
        end
    end
    assign mepc_out = mepc_reg;

    /* ------------------------------- mcause ------------------------------ */
    // v9 修复（C4）：原来 mcause 只认“中断/ecall”，非法指令与非对齐访存无处登记。
    // ★ 不变量：exc_mcause 的位序（bit3 指令地址非对齐优先）必须与 Control 的 trap_cause
    //   编码优先级一致；四路来源的顺序为 中断 > 同步异常 > ecall > 软件写（见下面 if 链）。
    //   细节：syn/修复史_全量.md §CSR-3
    logic [31:0] mcause_reg;
    logic        mcause_wen;
    logic [31:0] exc_mcause;
    // ★ v10.2：ebreak 复用"非法指令"那条陷入通路（trap_cause[0]），靠出错指令编码区分。
    //   这样 mcause=2（非法）与 mcause=3（断点）共用同一套 mepc/mtval/重定向逻辑，
    //   不必在 IDU/EXU/Control 之间再穿一根线。
    logic        exc_is_ebreak;
    assign exc_is_ebreak = (fault_inst == 32'h0010_0073);
    always_comb begin
        // 优先级与 Control 的 trap_cause 编码保持一致
        exc_mcause = trap_cause[3] ? `MCAUSE_IADDR_MISALIGN   // bit3 指令地址非对齐 = 0
                   : trap_cause[0] ? (exc_is_ebreak ? `MCAUSE_BREAKPOINT
                                                    : `MCAUSE_ILLEGAL_INST) // bit0 = 3 / 2
                   : trap_cause[1] ? `MCAUSE_LOAD_MISALIGN     // bit1 load 非对齐     = 4
                   : trap_cause[2] ? `MCAUSE_STORE_MISALIGN    // bit2 store 非对齐    = 6
                   : 32'd0;
    end
    assign mcause_wen = csr_wen[`CSRW_MCAUSE] | trap_commit;
    always_ff @(posedge clock) begin
        if (reset)            mcause_reg <= RESET_VAL;
        else if (mcause_wen) begin
            if (intr_take)              mcause_reg <= {1'b1, 27'b0, intr_cause};  // 中断
            else if (trap_take)         mcause_reg <= exc_mcause;                 // 同步异常
            else if (ecall_flag)        mcause_reg <= `MCAUSE_ECALL_M;            // 环境调用
            else                        mcause_reg <= csrd;
        end
    end
    assign mcause_out = mcause_reg;

    /* -------------------------------- mtval ------------------------------ */
    // v9 修复（C4）：mtval_reg 原来是个**死寄存器**（只复位、从不写）。RISC-V 语义：
    //   非法指令 -> 出错指令编码；取指/访存非对齐 -> 出错的有效地址；中断/ecall -> 0。
    logic [31:0] mtval_reg;
    logic        mtval_wen;
    logic [31:0] exc_mtval;
    always_comb begin
        // ebreak：mtval = ebreak 自己的 PC（特权规范允许"出错地址或 0"，这里给地址，
        //   处理程序可以据此判断断点位置，比给指令编码有用）
        exc_mtval = exc_is_ebreak ? fault_pc        // 断点：出错指令的 PC
                  : trap_cause[0] ? fault_inst      // 非法指令：出错指令编码
                  : (trap_cause[3] | trap_cause[1] | trap_cause[2]) ? fault_addr  // 非对齐：出错地址
                  : 32'd0;
    end
    // ★ 不变量：mtval_wen = intr_take | trap_take | 软件写（v10.3）。这里 v10 曾经**故意**
    //   没有 csr_wen 项，理由是"位图里没有 mtval 写位，软件写不进去，只能由硬件在陷入时填"
    //   —— 但特权规范 §1.1.2.4 把 mtval(0x343) 列为 **MRW**，软件必须能写（比如陷阱处理
    //   程序把 mtval 清掉再 mret）。位图补上 bit9 之后，这里必须一起补，否则就是
    //   "有个写位但没人接"——比没有写位更难查。优先级：陷入 > 软件写（陷入在后，
    //   与 mepc/mcause 的口径一致）。
    assign mtval_wen = intr_take | trap_take | csr_wen[`CSRW_MTVAL];
    always_ff @(posedge clock) begin
        if (reset)                 mtval_reg <= RESET_VAL;
        else if (mtval_wen) begin
            if (intr_take)         mtval_reg <= 32'd0;      // 中断：mtval 清零
            else if (trap_take)    mtval_reg <= exc_mtval;  // 同步异常：写指令或地址
            else                   mtval_reg <= csrd;       // 软件写 mtval
        end
    end
    // ★ 不变量：这一行 assign mtval_out **不能删**（原 C4 遗留）—— 以前这里漏了 assign，
    //   mtval_out 成了无驱动的输出网，综合把 mtval_reg 当死寄存器优化掉，顶层
    //   debug_mtval 与 ILA probe11 恒 0，看着像“ILA 没接对”，其实是 RTL 漏驱动。
    //   综合告警原文：syn/修复史_全量.md §CSR-4
    assign mtval_out = mtval_reg;

    /* ------------------------------- mtvec ------------------------------- */
    // 陷入入口基址，纯软件寄存器（硬件只读不改）。
    // ★ v10.3：WARL 掩码低 2 位。mtvec[1:0] 是 MODE 字段，本核只实现 0（direct）；
    //   MODE=1（vectored）没有被支持，写进去必须被**忽略**而不是存下来 —— 原来整字存，
    //   软件一写 0x301 就把 "MODE=1 + base=0x300" 塞进 mtvec，而 dnpc 直接拿整字当 PC 用，
    //   于是陷入目标变成 0x301（指令地址非对齐，mcause=0），整个异常体系跟着塌。
    //   直接写成 0 是规范允许的 WARL 处理（"写不支持的值 → 退到某个合法值"）。
    logic [31:0] mtvec_reg;
    always_ff @(posedge clock) begin
        if (reset)                       mtvec_reg <= RESET_VAL;
        else if (csr_wen[`CSRW_MTVEC])   mtvec_reg <= csrd & `CSR_WMASK_MTVEC;
    end
    assign mtvec_out = mtvec_reg;

    /* ------------------------------ mscratch ----------------------------- */
    // 供陷入处理程序自用的暂存，硬件完全不解释其值。
    logic [31:0] mscratch_reg;
    always_ff @(posedge clock) begin
        if (reset)                        mscratch_reg <= RESET_VAL;
        else if (csr_wen[`CSRW_MSCRATCH]) mscratch_reg <= csrd;
    end
    assign mscratch_out = mscratch_reg;

endmodule
