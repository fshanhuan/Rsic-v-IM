`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * Reg_Stack.sv — 通用寄存器堆 + CSR 的封装（ID 级读入口 + WB 级写回落点），被 IDU 例化。
 * 本模块自身没有流水寄存器（纯组合 + 两个子块），横跨两处：
 *   · 读侧在 ID 级：rs1/rs2 组合读出 GPR → rs1_value/rs2_value；csr_addr 译码选出某个
 *     机器模式 CSR → csrs（CSRR* 的读值）。
 *   · 写侧在 WB 级：rd/rd_value/R_wen/csr_wen/csrd 由 WBU 驱动，中间隔 EXU → MEM(LSU) →
 *     WB **三级流水寄存器原样携带**（每级只是换名重打，WB 拍才定出最终 rd_value/csrd）。
 *     所以读写口**天然差三级**：同一拍读到的永远是还没写回的旧值，缺的那份由 Control 的
 *     前递 / Data_hazard 的暂停补 —— 这是最容易看错的一处。
 *   · 系统通路：ecall/mret/intr_take 与 trap_take/trap_take_q（一次异常的单拍脉冲）在 ID 级
 *     直接进 CSR，**不经过三级流水**；软件 CSR 写走 WB 级，两条路互不干扰。
 * ★ 观察口从哪来：mepc/mtvec/mtval/mcause 四个 *_out **不是本模块产生的**，而是 CSR 子块
 *   寄存器的直通：mepc/mtvec 给 Control 算 mret 与异常入口，mtval/mcause 引到顶层 debug。
 * ★ 不许改回去：mtval 的写通路/读通路/引出三者缺一不可（曾是死寄存器 + 漏驱动）→ §REGSTACK-1、§REGSTACK-2
 * 参考：docs/模块阅读文档.md、syn/修复史_全量.md
 * ============================================================================= */
module Reg_Stack (
    input  logic        reset,
    input  logic        clock,
    input  logic [31:0] pc,
    input  logic        ecall_flag,
    input  logic        mret_flag,
    input  logic        intr_take,

    // ---- 通用寄存器侧：rs1/rs2 是 ID 级的组合读地址，rd/rd_value 是 WB 级的写口 ----
    input  logic [ 4:0] rs1,
    input  logic [ 4:0] rs2,
    input  logic [ 4:0] rd,
    input  logic [31:0] rd_value,

    // ---- CSR 侧：csr_addr 来自 IDU 的 imm[11:0]（只有 SYSTEM 指令有意义）；csr_wen[15:0] 是写使能
    //   位图（bit0=mepc / bit1=mcause / bit2=mstatus / bit3=mtvec / bit4=mie / bit5=mip /
    //   bit6=mscratch / bit7=mtimecmp / bit9=mtval / bit10=mtime，见 para.sv；bit8 是
    //   `CSRW_OP 指令标记，不是寄存器）；csrd 是在 WB 级生效的写数据（= EX 级 ALU 结果）。
    input  logic [11:0] csr_addr,
    input  logic        R_wen,
    input  logic [15:0] csr_wen,
    input  logic [31:0] csrd,

    // ---- v9 新增（C4）：统一异常通道，透传给 CSR（v10：trap_take_q 已删除，
    //   新增 fault_pc = 出错指令自己的 PC，见 CSR.sv 的 mepc 一节）----
    input  logic        trap_take,
    input  logic [ 3:0] trap_cause,
    input  logic [31:0] fault_addr,
    input  logic [31:0] fault_inst,
    input  logic [31:0] fault_pc,

    // ★ v12（B）：退休脉冲（来自 LSU 的 WB 入口），只给 Zicntr 的 minstret 用
    input  logic        retire,

    // ---- 输出口：前三个是 GPR 读值（a0_value 固定读 x10）；csrs 是 CSR 读值；其余 *_out 都是 CSR
    //   寄存器的直通观察口（不是本模块产生的新状态），IDU 例化处只接了下面四根，其余接空预留。
    output logic [31:0] rs1_value,
    output logic [31:0] rs2_value,
    output logic [31:0] a0_value,
    output logic [31:0] csrs,
    output logic [31:0] mepc_out,
    output logic [31:0] mtvec_out,
    output logic [31:0] mcause_out,
    output logic [31:0] mstatus_out,
    output logic [31:0] mie_out,
    output logic [31:0] mip_out,
    output logic [31:0] mscratch_out,
    output logic [31:0] mtime_out,
    output logic [31:0] mtimecmp_out,
    // v9 新增（C4）：mtval 引出（原来它是死寄存器 + 漏驱动，现在真正落地）。
    //   ★ 不变量：mtval 的写通路、读通路（下面 csrs 的 `CSR_mtval 分支）与引出三者缺一不可
    //   —— 少任何一处，软件读 mtval 都只能读到 0，异常现场无法定位。→ §REGSTACK-1、§REGSTACK-2
    output logic [31:0] mtval_out,
    // ★ v12（B）：Zicntr 计数器直通（IDU 只取 mcycle 低 32 位给 ILA probe，
    //   minstret 仅供读多路使用 —— 板上量指令数就是量 mcycle）
    output logic [63:0] mcycle_out,
    output logic [63:0] minstret_out,
    output logic        intr_pending
);

    logic [31:0] wdata;

    logic [31:0] mvendorid_out;
    logic [31:0] marchid_out;

    // GPR 写数据：rd==0 钳成 0（写口在 WB 级），配合 RegisterFile 的复位保证 x0 恒 0。
    assign wdata = (rd == 5'd0) ? 32'd0 : rd_value;

    // 读 CSR：按 csr_addr 把各机器寄存器并到 csrs；不匹配任何已实现 CSR 时返回 32'd0。
    // ★ v10.3：补上 misa（0x301）。`CSR_misa 宏在 para.sv 里**早就定义了却从来没人用** ——
    //   读它恒为 0，而 0 的语义是"一个扩展都不支持"，与事实相反；更要命的是它是自描述的
    //   那一个寄存器，启动代码/CoreMark 之类一读就判定本核什么都没有。
    //   取值 0x4000_1100 = MXL[31:30]=01(RV32) | bit8='I' | bit12='M'。
    //   写侧：地址 0x301 的 csr[11:10]=2'b00（R/W 段），所以写它**不报非法**；但 IDU 的
    //   csr_onehot 里没有 misa 这一位 → 位图里没有它 → 任何写使能都到不了寄存器，
    //   写入被忽略（WARL：MXL 与扩展位都不可改，这正是规范给的自由度）。
    localparam logic [31:0] MISA_VALUE = 32'h4000_1100;
    assign csrs = (csr_addr == `CSR_mepc)      ? mepc_out       :
                  (csr_addr == `CSR_mcause)    ? mcause_out     :
                  (csr_addr == `CSR_mtval)     ? mtval_out      :
                  (csr_addr == `CSR_mstatus)   ? mstatus_out    :
                  (csr_addr == `CSR_misa)      ? MISA_VALUE     :
                  (csr_addr == `CSR_mtvec)     ? mtvec_out      :
                  (csr_addr == `CSR_mie)       ? mie_out        :
                  (csr_addr == `CSR_mip)       ? mip_out        :
                  (csr_addr == `CSR_mscratch)  ? mscratch_out   :
                  (csr_addr == `CSR_mtime)     ? mtime_out      :
                  (csr_addr == `CSR_mtimecmp)  ? mtimecmp_out   :
                  // ★ v12（B）Zicntr：0xB0x/0xB8x 是 MRW 本体，0xC0x/0xC8x 是它的只读影子。
                  //   ★ 不变量：`instret(0xC02)` 与 `minstret(0xB02)` 必须指向**同一个**
                  //   64 位计数器（规范如此），别写成两份状态；`time(0xC01)` 映射到 mtime，
                  //   `timeh(0xC81)` 读 0（mtime 只有 32 位，编造高位会让软件算出错误的墙钟）。
                  (csr_addr == `CSR_mcycle)    ? mcycle_out[31:0]   :
                  (csr_addr == `CSR_mcycleh)   ? mcycle_out[63:32]  :
                  (csr_addr == `CSR_minstret)  ? minstret_out[31:0] :
                  (csr_addr == `CSR_minstreth) ? minstret_out[63:32]:
                  (csr_addr == `CSR_cycle)     ? mcycle_out[31:0]   :
                  (csr_addr == `CSR_cycleh)    ? mcycle_out[63:32]  :
                  (csr_addr == `CSR_instret)   ? minstret_out[31:0] :
                  (csr_addr == `CSR_instreth)  ? minstret_out[63:32]:
                  (csr_addr == `CSR_time)      ? mtime_out          :
                  (csr_addr == `CSR_timeh)     ? 32'd0              :
                  (csr_addr == `CSR_mvendorid) ? mvendorid_out  :
                  (csr_addr == `CSR_marchid)   ? marchid_out    :
                  // v10.3b：mimpid/mconfigptr 读 0（"信息拿不到就给 0"，与 mvendorid/marchid 同口径）。
                  //   ★ 不变量：规范对 mimpid 的要求是 "must be readable in any implementation"
                  //   （§2.1.1.4）—— 这里返回 0 是对的，让它陷入（v10.3 的行为）是错的。
                  (csr_addr == `CSR_mimpid)    ? 32'd0          :
                  // v10.3：mhartid 是常量 0（单 hart），见 para.sv 的说明
                  (csr_addr == `CSR_mhartid)   ? 32'd0          :
                  (csr_addr == `CSR_mconfigptr) ? 32'd0         : 32'd0;

    // CSR 子块（实现见 CSR.sv）：参数 #(32,0) = (CSR_WIDTH, RESET_VAL)。三组输入：① 陷入/返回发起
    //   （ID 级电平）② 统一异常通道（trap_cause 是 `EXC_* 独热码，fault_inst 就是 IDU 的 inst_d_out）
    //   ③ 软件写口（WB 级生效）。
    CSR #(32, 0) CSR_inst (
        .clock        (clock),
        .reset        (reset),
        .pc           (pc),
        .ecall_flag   (ecall_flag),
        .mret_flag    (mret_flag),
        .intr_take    (intr_take),
        // v9 新增（C4）：统一异常通道（v10：trap_take_q → fault_pc）
        .trap_take    (trap_take),
        .trap_cause   (trap_cause),
        .fault_addr   (fault_addr),
        .fault_inst   (fault_inst),
        .fault_pc     (fault_pc),
        .retire       (retire),
        .csrd         (csrd),
        .csr_wen      (csr_wen),
        .mvendorid_out(mvendorid_out),
        .marchid_out  (marchid_out),
        .mepc_out     (mepc_out),
        .mcause_out   (mcause_out),
        .mstatus_out  (mstatus_out),
        .mtvec_out    (mtvec_out),
        .mie_out      (mie_out),
        .mip_out      (mip_out),
        .mscratch_out (mscratch_out),
        .mtime_out    (mtime_out),
        .mtimecmp_out (mtimecmp_out),
        .mtval_out    (mtval_out),
        .mcycle_out   (mcycle_out),
        .minstret_out (minstret_out),
        .intr_pending (intr_pending)
    );

    // RegisterFile 子块：#(5,32) 按位置对应 (ADDR_WIDTH, DATA_WIDTH) → 5 位地址选 32 个 32 位寄存器
    //   （注意那边两个默认值是反的，别照默认值理解位宽）；waddr=rd、wen=R_wen、wdata 已钳过零。
    RegisterFile #(5, 32) Reg_inst (
        .clock    (clock),
        .wdata    (wdata),
        .waddr    (rd),
        .wen      (R_wen),
        .reset    (reset),
        .rs1_addr (rs1),
        .rs2_addr (rs2),
        .rs1_value(rs1_value),
        .rs2_value(rs2_value),
        .a0_value (a0_value)
    );

endmodule
