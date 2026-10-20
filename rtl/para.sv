/* =============================================================================
 * para.sv — BigBird v9 全局参数与编码约定
 * -----------------------------------------------------------------------------
 * 这里集中定义整颗 CPU 用到的“公共契约”，其它模块只通过宏名互相协作，
 * 避免在 IDU / EXU / ALU 各处散落魔法数字。
 *
 *   1. opcode   ：7 位主操作码，决定指令属于哪一大类。
 *   2. alu_op   ：5 位 ALU/MDU 运算编码，IDU 译码后交给 EXU 解释执行。
 *   3. 汇编器约定：cache / 分支预测 / CSR 的相关参数。
 *
 * 注意：v9 在 v8（RV32I）基础上扩展为 RV32IM：
 *   - 整数基址指令仍走原有 ALU 通路；
 *   - 乘除法新增 MDU，运算编码在 alu_op 高位置 1 区分（见下）。
 *
 * ★ 改这里等于改跨模块契约：带位宽的宏（ICACHE/DCACHE/BP 的 INDEX/TAG/HIST、
 *   MTIME_DIV_DEFAULT、NOP）会同时挪动几个模块的位切片与计时行为，改完要全局搜。
 * =========================================================================== */
`ifndef PARA_SV
`define PARA_SV

/* ------------------------------- 主操作码 ---------------------------------- */
`define R_opcode   7'b0110011   // R-type：整数寄存器-寄存器运算（含 M 扩展）
`define I0_opcode  7'b0000011   // I-type load：lb/lh/lw/lbu/lhu
`define I1_opcode  7'b0010011   // I-type 立即数运算：addi...
`define I2_opcode  7'b1100111   // jalr
`define S_opcode   7'b0100011   // store：sb/sh/sw
`define B_opcode   7'b1100011   // 分支：beq/bne/blt/bge/bltu/bgeu
`define U0_opcode  7'b0110111   // lui
`define U1_opcode  7'b0010111   // auipc
`define J_opcode   7'b1101111   // jal
`define SYS_opcode 7'b1110011   // 系统：ecall/mret/CSR
`define MISC_opcode 7'b0001111  // MISC-MEM：fence / fence.i（v9 修复 C4 新增：
                                //   原来没地方检查这个 opcode，会被当未知指令丢掉）

/* ------------------------- R 型 funct7 区分位 ------------------------------ */
`define funct7_base 7'b0000000     // 普通 RV32I 整数运算
`define funct7_sub  7'b0100000     // sub/sra
`define funct7_m    7'b0000001     // RV32M 乘除法

/* ------------------------------- ALU 编码 ----------------------------------
 * 5 位编码：[4] 为 1 表示“走 MDU（乘除法）”，否则走普通 ALU 数据通路。
 * 这样 IDU 只需输出一个统一的操作码，EXU 依据最高位选择执行单元即可。
 * ------------------------------------------------------------------------- */
// ---- 基础整数运算（走 ALU）----
`define alu_add                 5'b00000
`define alu_sub                 5'b00001
`define alu_or                  5'b00010
`define alu_and                 5'b00011
`define alu_xor                 5'b00100
`define alu_signed_comparator   5'b00101
`define alu_unsigned_comparator 5'b00110
`define alu_equal               5'b00111
`define alu_sll                 5'b01000
`define alu_srl                 5'b01001
`define alu_sra                 5'b01010
// v10.2 新增：alu_bitclr = d2 & ~d1（把 d1 里为 1 的位从 d2 里清掉）—— 只服务 csrrc/csrrci。
//   语义与操作数顺序**绑死**在 CSRR* 的统一映射上：d1 = 源操作数（rs1 或 uimm），
//   d2 = CSR 旧值，于是"清位"恰好就是 csr & ~src，三种 CSRRC/CSRRCI 形式共用同一份映射。
//   ★ 别改成 d1 & ~d2：那样 csrrci 会算成 uimm & ~csr（实测把 mscratch 从 0x1234F678
//     写成 0x00000000，csrrci 的"清一位"变成"只留那一位的反"）。
//   复用 ALU 里已有的 d1_inv（~d1 本来就给 xor 用），代价是一条 32 位与非门。
`define alu_bitclr                5'b01011

// ---- RV32M 乘除法（走 MDU）----
`define alu_mul                 5'b10000   // 有符号/无符号低 32 位相同
`define alu_mulh                5'b10001   // 有符号 × 有符号，取高 32 位
`define alu_mulhsu              5'b10010   // 有符号 × 无符号，取高 32 位
`define alu_mulhu               5'b10011   // 无符号 × 无符号，取高 32 位
`define alu_div                 5'b10100   // 有符号除法
`define alu_divu                5'b10101   // 无符号除法
`define alu_rem                 5'b10110   // 有符号取余
`define alu_remu                5'b10111   // 无符号取余

/* -------------------------- 访存宽度（funct3） ------------------------------ */
`define mem_f3_sb  3'b000
`define mem_f3_sh  3'b001
`define mem_f3_sw  3'b010
`define mem_f3_lb  3'b000
`define mem_f3_lh  3'b001
`define mem_f3_lw  3'b010
`define mem_f3_lbu 3'b100
`define mem_f3_lhu 3'b101

/* ------------------------------- CSR 地址 ---------------------------------- */
// RISC-V 特权规范的标准 12 位 CSR 编号（300/301/304/305/340~344/f11/f12）。
`define CSR_mstatus 12'h300
`define CSR_misa    12'h301
`define CSR_mie     12'h304
`define CSR_mtvec   12'h305
`define CSR_mscratch 12'h340
`define CSR_mepc    12'h341
`define CSR_mcause  12'h342
`define CSR_mtval   12'h343
`define CSR_mip     12'h344
`define CSR_mvendorid 12'hf11
`define CSR_marchid   12'hf12
// v10.3b：mimpid / mconfigptr 也必须"能读"。特权规范 §2.1.1.4 原文：
//   "The `mimpid` CSR ... **This register must be readable in any implementation**,
//    but a value of 0 can be returned to indicate that the field is not implemented."
// 也就是说"不实现"的正确写法是**读回 0**，而不是报非法指令。原来这两个地址不在
// csr_known 白名单里 → `csrr x, mimpid` 直接 mcause=2，属于把"不实现"做成了"不存在"。
// mconfigptr(0xF15) 同属"Machine Information Registers"一栏的 MRO，本核没有配置数据结构，
// 按惯例读 0（口径与 mvendorid/marchid 一致：信息拿不到就给 0）。
`define CSR_mimpid    12'hf13
`define CSR_mhartid   12'hf14
`define CSR_mconfigptr 12'hf15
// 教学用自定义定时器 CSR（标准 mtime/mtimecmp 属 CLINT 内存映射，这里并入 CSR 便于观察）
`define CSR_mtime    12'h7c0
`define CSR_mtimecmp 12'h7c1

/* --------------------------- v12（B）Zicntr 计数器 ------------------------- */
// 特权规范（Zicntr，原属 Base counters 章节）规定的一组**标准**计数器。v9~v11 一直
// 没有实现，理由是"RTOS 用不到"；但上板之后发现的真实需求是相反的：
//   · mtime(csr 0x7C0) 是 `MTIME_DIV_DEFAULT 分频后的**墙钟**（50MHz/100 = 500kHz），
//     它量不出"这条指令花了多少拍"；
//   · 于是板上一切性能问题只能靠仿真推断，与真实硬件对不上（历史上 sim 与上板
//     的拍数口径就从来没对齐过）。
// mcycle/minstret 补上之后，程序末尾一条 `csrr a0, mcycle` 就能把周期数送进 ILA，
// 这是"板上可量化"的唯一入口，所以它是 v12（B）的第一项。
//
// 地址（规范 §Zicntr，机器模式可读写 / 用户模式只读影子）：
//   0xB00 mcycle   0xB02 minstret   0xB80 mcycleh   0xB82 minstreth   ← MRW（csr[11:10]=2'b10）
//   0xC00 cycle    0xC01 time       0xC02 instret   ← MRO 影子（csr[11:10]=2'b11）
//   0xC80 cycleh   0xC81 timeh      0xC82 instreth
// ★ 不变量：0xC02(instret) 与 0xB02(minstret) 是**同一个 64 位计数器的两个地址**
//   （前者只读影子），不是两个寄存器 —— 别把它们写成两份状态。
// ★ 本核把 time/timeh 映射到已有的 mtime：time = mtime（32 位墙钟），timeh 读 0。
//   这是有意的简化：mtime 只做了 32 位，timeh 编造高位反而会让软件算出错误的墙钟。
`define CSR_mcycle    12'hb00
`define CSR_minstret  12'hb02
`define CSR_mcycleh   12'hb80
`define CSR_minstreth 12'hb82
`define CSR_cycle     12'hc00
`define CSR_time      12'hc01
`define CSR_instret   12'hc02
`define CSR_cycleh    12'hc80
`define CSR_timeh     12'hc81
`define CSR_instreth  12'hc82

/* -------------------- CSR 写使能位（csr_wen 的位映射） ---------------------- */
// CSRW_* 是 myCPU 内部 `csr_wen` 总线的**位序号**（不是地址）：写侧用
// (1 << `CSRW_XXX) 选寄存器，如 ecall 置 bit0|bit1 = 写 mepc + mcause。
// v10.3：mtime / mtval 现在都有写位（见下面 bit9/bit10 的说明）。
`define CSRW_MEPC     0
`define CSRW_MCAUSE   1
`define CSRW_MSTATUS  2
`define CSRW_MTVEC    3
`define CSRW_MIE      4
`define CSRW_MIP      5
`define CSRW_MSCRATCH 6
`define CSRW_MTIMECMP 7
// ★ v10.2 新增：bit8 不是"写某个 CSR"，而是"**本拍这条指令是 CSR 指令**"的标记位。
//   原来下游（WBU 的 wb_sel_jmp_csr、LSU 的两级 forward_val、Control/IDU 的 CSR 前递）
//   一律用 `|csr_wen` 判"这是不是 CSR 指令、rd 该取 csrs 还是 Ex_result"。这在
//   "读一个只读 CSR"（mtime / mvendorid / marchid / mtval / misa）时会把 rd 选成
//   Ex_result —— 而 Ex_result 对 CSRR* 只是"将要写进 CSR 的新值"，对只读 CSR 根本不是读值。
//   置上这一位后 `|csr_wen` 严格等于"是 CSR 指令"，与"要不要写"彻底解耦。
//   CSR.sv 只认下面这些位，这一位对它完全透明。
`define CSRW_OP      8
// ★ v10.3 新增：bit9 = mtval、bit10 = mtime 的软件写位。
//   为什么要加：特权规范 §1.1 的 CSR 地址映射表把 0x343(mtval) 列为 **MRW**（可读可写），
//   把 0x7C0/0x7C1(mtime/mtimecmp) 列在"Custom read/write"段（0x7C0-0x7FF）里 ——
//   也就是说这两类**软件必须能写**。原来 mtval 的写通路只接了 intr_take|trap_take、
//   mtime 根本没有写位，于是 `csrw mtval, x1` / `csrw mtime, x1` 被**静默丢弃**，
//   读回来还是旧值：既不是 read-only（地址编码是 01/00 而不是 11），也不报错，
//   属于"看起来支持、实际不支持"的假实现。
//   加位之后要同步的地方（三处，漏一处就是半截功能）：
//     ① IDU 的 csr_onehot 位映射（写使能 + 读前递命中判据都用它）
//     ② CSR.sv 里对应寄存器的 always_ff 写条件
//     ③ 本文档的 csr_wen 位图注释
`define CSRW_MTVAL   9
`define CSRW_MTIME   10
// ★ v12（B）新增：Zicntr 的四个写位（bit11~bit14）。位图原本只用 0~10，11~15 全空，
//   正好够。四条各对应**一半**：mcycle 的低/高 32 位是两个独立可写寄存器，所以需要
//   四个写位而不是两个（CSR 是 32 位一口，64 位计数器只能拆成两个地址，规范就是这么定义的）。
//   加位之后同样要同步三处（与上面 bit9/bit10 的清单一致）：
//     ① IDU 的 csr_onehot 位映射   ② CSR.sv 的 always_ff 写条件   ③ 本段注释
//   ★ 顺带一提：`cycle/instret`(0xC0x) **不占写位** —— csr[11:10]=2'b11 是只读段，
//     IDU 的 csr_illegal 会直接把 `csrw cycle, x1` 判成非法指令，正确地走不通。
`define CSRW_MCYCLE    11
`define CSRW_MINSTRET  12
`define CSRW_MCYCLEH   13
`define CSRW_MINSTRETH 14

/* ------------------------------ 中断相关位 -------------------------------- */
// mstatus
`define MSTATUS_MIE   3           // 全局中断使能
`define MSTATUS_MPIE  7           // 中断前的 MIE 备份
// mie / mip
`define IRQ_MSI  0                // 机器软件中断
`define IRQ_MTI  7                // 机器定时器中断
`define IRQ_MEI  11               // 机器外部中断
// mcause：最高位 1 表示中断，0 表示异常
`define MCAUSE_INTR_BIT 31
// ---- 异常（mcause 最高位为 0）----
// v9 修复（C4）：补齐"非法/异常"这一类，并给异常入口一个统一的编码约定。
`define MCAUSE_IADDR_MISALIGN 0     // instruction address misaligned
`define MCAUSE_ILLEGAL_INST    2     // illegal instruction
`define MCAUSE_BREAKPOINT      3     // breakpoint（v10.2 起真的实现了：ebreak 陷入，
                                     //   mcause=3、mtval=ebreak 自己的 PC）
`define MCAUSE_LOAD_MISALIGN   4     // load address misaligned
`define MCAUSE_STORE_MISALIGN  6     // store/AMO address misaligned
`define MCAUSE_ECALL_M         11    // ecall from M-mode
// ---- 中断 ----
`define MCAUSE_MTI      (`MCAUSE_INTR_BIT | `IRQ_MTI)
`define MCAUSE_MSI      (`MCAUSE_INTR_BIT | `IRQ_MSI)
`define MCAUSE_MEI      (`MCAUSE_INTR_BIT | `IRQ_MEI)

/* ------------------------------ 定时器参数 -------------------------------- */
// v9 修复（C7）：mtime 原来每拍 +1（比真实时间快约 1000 万倍），只能当"拍数计数器"。
//   现在按 (100MHz / MTIME_DIV) 分频递增；默认 100 → 1MHz（每 1us 加 1），
//   置 1 则退回"每拍 +1"的旧行为（回归脚本用得到）。
`define MTIME_DIV_DEFAULT 100

/* ---------------------- CSR 的 WARL 写掩码 / 强制位（v10.3） ---------------- */
// 这两个常数必须**同时**用在两处，绝不能只改一处：
//   ① CSR.sv 里各寄存器的写端口（决定寄存器里真正存什么）
//   ② Control.sv 的 CSR 前递影子链入口 csrval_sh[0]（决定"紧跟写入的读"看到什么）
// 为什么：CSR 读口的前递值本来就是各级的 Ex_result（= ALU 算出的**原始**新值），
//   而寄存器落盘时还会再掩一次。两处不一致时，"csrw 紧跟 csrr"读到的就是 ALU 原值、
//   "隔几条再 csrr"读到的是掩码后的寄存器值 —— 同一段程序读同一个 CSR 得到两个答案。
//   v10.3 第一次加掩码时就踩到了（实测：csrw mip,0xFFFFFFFF 紧跟 csrr 读回 0xFFFFFFFF，
//   而寄存器里只有 1），是 sys_zicsr 用例把它们抓出来的。
// 口径：wmask = 软件可写的位；force = 写入后**恒为 1** 的位（本核只有 mstatus.MPP=11）。
`define CSR_WMASK_ALL      32'hFFFF_FFFF
`define CSR_WMASK_MIP      32'h0000_0001   // 只 MSIP 可写（MEIP/MTIP 由硬件驱动，只读）
`define CSR_WMASK_MIE      32'h0000_0881   // MSI(0) | MTI(7) | MEI(11)
`define CSR_WMASK_MSTATUS  32'h0000_1888   // MIE(3) | MPIE(7) | MPP(12:11，随后强制成 11)
`define CSR_FORCE_MSTATUS  32'h0000_1800   // MPP 恒为 M
`define CSR_WMASK_MTVEC    32'hFFFF_FFFC   // [1:0] 是 MODE，本核只有 direct=0
`define CSR_WMASK_MEPC     32'hFFFF_FFFC   // IALIGN=32 → mepc[1:0] 恒 0

/* --------------------------- 异常类型编码（ID/EX 内部用） ------------------ */
// Control 用这 4 位告诉 CSR"本拍发生的是哪种异常"，CSR 据此写 mcause/mtval。
//   bit0 : 非法指令        (mcause=2,  mtval=faulting instruction)
//   bit1 : load 非对齐     (mcause=4,  mtval=faulting address)
//   bit2 : store 非对齐    (mcause=6,  mtval=faulting address)
//   bit3 : 指令地址非对齐  (mcause=0,  mtval=faulting target)
// ecall 不在这里（它有自己的通道，语义是"正常流到 WB 再写 CSR"）。
// v10.2：ebreak 也**复用 bit0**（它和非法指令走同一条"ID 级判定 → EX 级锁存 → 陷入"通路），
//   由 CSR.sv 用 fault_inst == 32'h0010_0073 把它翻成 mcause=3、mtval=出错 PC。
//   这样不必新增第 5 个异常位、也不必在 EXU/Control 里多一根线。
// 这 4 个宏是**独热位**（不是序号）：可同时置多位表示多类异常并存。
`define EXC_NONE        4'b0000
`define EXC_ILLEGAL     4'b0001
`define EXC_LOAD_MIS    4'b0010
`define EXC_STORE_MIS   4'b0100
`define EXC_IADDR_MIS   4'b1000

/* --------------------------- Cache / 预测器参数 ---------------------------- */
// I-Cache：直接映射，行大小 = 1 个字（教学用，便于观察命中/缺失），因此没有 offset；
// 切片：index = cpu_addr[INDEX_BITS+1:2]（跳过低 2 位字节偏移），tag 是剩下的高位。
`define ICACHE_INDEX_BITS 6       // 64 行（v11：ICache 已旁路，此参数仅给"接回真 cache"时用）
`define ICACHE_TAG_BITS   (32 - `ICACHE_INDEX_BITS - 2)
// ★ v11（S2）：D-Cache 64 行 → **256 行**。
//   为什么：64 行 × 1 字/行 = **256 B** 工作集，任何真实程序（栈 + 全局 + 循环体）都装不下，
//   而 miss 一次要停 1 拍（dcache_hold）。256 行 = 1 KB，代价是 LUTRAM 从
//   64×(32+24) 涨到 256×(32+22) ≈ +216 LUT（实测见 util 报告），0 BRAM、0 FF。
//   面积不敏感（7020 用了 20%），所以按"够用"取 1 KB，没有再往上加。
`define DCACHE_INDEX_BITS 8       // 256 行 = 1 KB（1 字/行，直接映射）
`define DCACHE_TAG_BITS   (32 - `DCACHE_INDEX_BITS - 2)

// 分支预测：gshare（PC 低位 XOR 全局历史 GHR）+ BTB，直接映射
//   BP_INDEX_BITS：PHT（2 位饱和计数器表）与 BTB 的行数 = 1 << BP_INDEX_BITS，
//     同时是 PC 切片宽度 fpc_idx = fetch_pc[BP_INDEX_BITS+1:2]；
//     BP_TAG_BITS 是 BTB 标签宽度（公式同上，一对一缓存“这条 PC 的跳转目标”）。
//   BP_HIST_BITS：GHR 位宽，与索引位宽一致，所以 XOR 后仍是 BP_INDEX_BITS 位。
// ★ v14：由 _diag/bp_sweep.sh 在 CoreMark 上实测扫描得出（1 次迭代的总拍数，
//   基准 64/6 = 482 990 拍 / 10 680 次误预测 / 73 707 条分支 = 14.5% 误预测率）：
//     64 行/6 位  482 990 拍   10 680 次   （原配置）
//    256 行/6 位  471 384 拍    8 376 次
//    256 行/8 位  468 266 拍    7 753 次   ← **采用**：+3.1%，代价约 230 个 LUTRAM
//   1024 行/8 位  462 715 拍    6 618 次      （+1.4% 更多，但要 ~900 LUT 和 1024 选 1 的读 mux）
//   1024 行/10 位 461 825 拍    6 466 次      （再加 0.2%，历史位已饱和）
//   结论：**加宽 BTB/PHT 值得做，但停在 256 行**；剩下的 10.5% 误预测主要是
//   冷启动（compulsory）与 gshare 的容量冲突，再堆尺寸的边际收益已经很小。
`define BP_INDEX_BITS 8           // 256 项计数表 / BTB（v14：64 → 256）
`define BP_TAG_BITS   (32 - `BP_INDEX_BITS - 2)
`define BP_HIST_BITS  8           // 全局历史长度（v14：6 → 8，要求 <= BP_INDEX_BITS）

/* ------------------------------ 性能计数（v11：常开，按键取消） --------------- */
// v11（S3）：原来的 `Performance_Count 宏**从未被任何文件引用**（定义了却没有任何 ifdef），
//   是"看起来可裁剪、实际不可裁剪"的假开关 —— 已删除。为什么不改成真开关：
//   这 4 个计数器（icache/dcache 各一对）正是板级 ILA 的观测载荷，实现构建里必须有；
//   做成宏只会制造"仿真开、上板关"的口径分叉（本项目最忌讳的就是同一份 RTL 两种行为）。
//   实测代价：4×32 位计数器 ≈ 140 LUT + 128 FF（1.3%），买的是可观测性。
//   （其中 ICache 那两对在 v11 已恒 0，见 myCPU.sv 的 debug_icache_* 注释。）

// ★ 不变量：`NOP 必须就是 addi x0,x0,0（32'h00000013），后级要能把它当**合法空操作**
//   执行掉：它既是 IFU 在 valid=0 时灌给 IDU 的“泡”，也是冲刷时填进流水寄存器的
//   占位指令；换成别的指令就会让冲刷/停拍路径产生副作用（写寄存器 / 触发异常）。
`define NOP 32'h00000013

`endif // PARA_SV
