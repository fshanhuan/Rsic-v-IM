/* verilator lint_off UNUSEDSIGNAL */

`timescale 1ns / 1ps

// 访存级除了产生总线访问信号，还显式保留了多拍流水寄存器，
// 这样前递网络可以分别观察到“刚进入访存”“访存中间拍”“即将写回”三个阶段的结果。
// ============================================================================
// 位置：EXU 之后、DCache/WBU 之前 —— 上游 EXU 用 valid_last/ready_last 握手，下游 DCache 收 addr/wen/wdata/mask 并回 rdata + mem_hold，WBU 收 *_wb 一组。
// 三级内部流水（后缀即级号，全部由同一个 always_ff 推进）：
//   reg   M1：EXU 刚送进来的那一拍；Ex_result_addr_reg 供本级字节选道，Ex_result_fwd_reg 供前递。
//   pipe  M2：**对外发总线访问的那一拍** —— addr/wen/wdata/mask 全从这里组合出去（DCache 的 cpu_en = mem_ren_pipe|wen、cpu_wen = wen），DCache 在下一个时钟沿才采到它。
//   reg2  M3：写回前最后一拍；rdata_reg2 在同一沿采 DCache 返回的**原始整字**（load 数据要等 DCache 撤销 hold 的那一拍才出现在 rdata 上），Ex_result_fwd_reg2[1:0] 就是写回拍的 load 偏移。
// ★ 接口契约：一次访问只发一次（mem_ren/mem_wen/mem_addr 都只在 M2 那一拍有效）；推进条件只有一个 = ready_next & ~lsu_freeze，ready_last 与它必须同式；上游送来的一切都按“电平”看待，一次访问持续多久由 mem_hold 决定，不靠计数。
// ★ 不许改回去：mem_hold/mdu_busy 期间必须冻结整条流水（含 M2）→ §LSU-2；字节/半字必须按地址低 2 位选道再符号扩展（B1）→ §LSU-1；jump/CSR 的前递值必须取 rd_value 而不是 Ex_result → §LSU-3。
// 参考：docs/模块阅读文档.md、syn/修复史_全量.md、DCache.sv（读写时序契约）
// ============================================================================
module LSU (
    input clock,
    input reset,

    input mem_ren,
    input mem_wen,
    input R_wen,
    input [15:0] csr_wen,
    input [31:0] Ex_result,
    input [4:0] rd,
    input [2:0] funct3,
    input [31:0] rs2_value,
    input jump_flag,
    input [31:0] rd_value,
    input [31:0] pc,


    output [31:0] rd_value_next,
    output R_wen_next,
    output [31:0] LSU_Rdata,
    // v11（S3）：LSU_Rdata_raw 已删除 —— 全工程零读者（WBU 要的是 M3 的 rdata_wb_raw，
    //   走的是另一根线），综合本来就会把它整条锥体 DCE 掉。删它只是为了让"谁在用哪个数据"唯一。
    output [2:0] funct3_next,
    output [15:0] csr_wen_next,
    output [31:0] Ex_result_next,
    output [4:0] rd_next,
    output mem_ren_next,
    output jump_flag_next,

    output logic [31:0] pc_out,
    output logic [31:0] pc_wb,
    output [31:0] addr,
    output wen,
    output [31:0] wdata,
    output [1:0] mask,
    // 同步读返回的**原始整字**（来自 DCache 的 cpu_rdata）：字节/半字选道与符号扩展都在本模块做
    input [31:0] rdata,
    /* ★ v15：DCache 的 M1 命中探测口。命中时 M1 当拍就拿到数据，
     *   消费者因此可以少停 1 拍（见下 m1_load_ok 处的不变量）。 */
    input  logic        m1_hit,
    input  logic [31:0] m1_rdata,
    output logic [31:0] LSU_Rdata_m1,
    output logic        m1_load_ok,
    // 来自 DCache：同步 DRAM 的 load 未命中，需要把访存流水整体冻一拍后重试
    input mem_hold,
    // 来自 EXU：MDU 正在等结果，访存流水必须**同步冻结**，
    // 否则会把 EXU 保持的陈旧值一级级推下去
    input mdu_busy,

    output [31:0] rdata_wb_raw,
    output [2:0] funct3_wb,
    // v9 修复（B1）：写回拍 load 地址的低 2 位。
    //   WBU 也会按 funct3 再抽取一次（它是最终写回值来源），那里同样需要偏移，
    //   否则 LSU 修好了、写回值仍然是"第 0 字节"。
    output [1:0] rdata_offset_wb,
    output [15:0] csr_wen_wb,
    output [31:0] Ex_result_wb,
    output [31:0] rd_value_wb,
    output [4:0] rd_wb,
    output mem_ren_wb,
    output R_wen_wb,
    output jump_flag_wb,
    output [31:0] forward_val_wb,
    output logic valid_wb,

    output [31:0] Ex_result_pipe,
    output [4:0] rd_pipe,
    output mem_ren_pipe,
    output R_wen_pipe,
    output valid_pipe,
    output [31:0] forward_val_pipe,

    input valid_last,
    output logic ready_last,

    input ready_next,
    output logic valid_next,

    output logic retire_wb,

    // ★ v14（P4 修法）：给 DCache 一个「本次总线请求的身份证」——
    //   每进入 M2 一条新指令就翻转一位。DCache 用"寄存后的 req_seq 变没变"判断
    //   "这是不是同一条请求"，这是**唯一**能区分下面两件事的信号：
    //     · 同一条请求还在（数据已回、LSU 还没推进）→ 不该再发读；
    //     · 同地址的下一条请求到了（`lw a0,0(x); lw a1,0(x)`）→ 必须再发读。
    //   只比地址的话这两种情况长得一模一样，压掉后一种会让"同地址轮询"读到旧值。
    //   翻转条件 = lsu_adv（M2 真的推进），冻结期间 lsu_adv=0 ⇒ 身份证不变。
    output logic req_seq
);

  logic        mem_ren_reg;
  logic        mem_wen_reg;
  logic        R_wen_reg;
  logic [15:0]  csr_wen_reg;
  // 命名约定：无后缀 = M1（EXU 送入的那一拍）、*_reg_pipe = M2（发总线那一拍）、*_reg2 = M3（写回前那拍）。
  // (* max_fanout *) 只影响综合：这些寄存器扇出到 DCache、比较器与 3 个前递点，按它自动复制寄存器的“值”，功能不变。
  (* max_fanout = 32 *) logic [31:0] Ex_result_addr_reg;
  (* max_fanout = 16 *) logic [31:0] Ex_result_fwd_reg;
  logic [4:0]  rd_reg;
  logic [2:0]  funct3_reg;
  logic [31:0] rs2_value_reg;
  logic        jump_flag_reg;
  logic [31:0] rd_value_reg;
  logic [31:0] pc_reg;
  logic        valid_reg;

  logic [31:0] rdata_8i;
  logic [31:0] rdata_16i;
  logic [31:0] rdata_8u;
  logic [31:0] rdata_16u;

  logic [31:0] rdata_ex;

  logic        mem_ren_reg_pipe;
  logic        mem_wen_reg_pipe;
  logic        R_wen_reg_pipe;
  logic [15:0]  csr_wen_reg_pipe;
  (* max_fanout = 8 *) logic [31:0] Ex_result_addr_reg_pipe;
  logic [31:0] Ex_result_fwd_reg_pipe;
  logic [4:0]  rd_reg_pipe;
  logic [2:0]  funct3_reg_pipe;
  logic [31:0] rs2_value_reg_pipe;
  logic        jump_flag_reg_pipe;
  logic [31:0] rd_value_reg_pipe;
  logic [31:0] pc_reg_pipe;
  logic        valid_reg_pipe;

  logic        mem_ren_reg2;
  logic        R_wen_reg2;
  logic [15:0]  csr_wen_reg2;
  logic [31:0] Ex_result_fwd_reg2;
  logic [4:0]  rd_reg2;
  logic [2:0]  funct3_reg2;
  logic        jump_flag_reg2;
  logic [31:0] rd_value_reg2;
  logic [31:0] pc_reg2;
  logic        valid_reg2;
  logic [31:0] rdata_reg2;

  logic [31:0] rdata_8i2;
  logic [31:0] rdata_16i2;
  logic [31:0] rdata_8u2;
  logic [31:0] rdata_16u2;
  logic [31:0] rdata_wb2;

  /* ---- v11（S6）：M2 级（_pipe）的读数据扩展与前瞻前递 ----------------------
   * 为什么要单独一套：DCache 的命中路径是**同拍组合**的
   *   （`cpu_rdata = hit_now ? data[index] : mem_rdata`，hit_now 直接由当拍的
   *    cpu_en/cpu_addr 组合比较得出），所以当一条 load 停在 M2 时，`rdata` **本拍就是它的数据**；
   *   未命中时 DCache 拉 hold，LSU 被冻结在 M2，数据同样在解冻那一拍的 `rdata` 上。
   *   ⇒ 在 M2 就地按 M2 的偏移/位宽扩展一次，就能把 load 结果前递给"紧跟其后的消费者"，
   *     不必等它走到 M3（那正是 load-use 多停 1 拍的原因）。
   * ★ 反面踩坑（v11 第一版）：曾经把 M1 的 `rdata_ex` **寄存一拍**当 M2 前递源 —— 那是
   *   "上一拍 rdata（属于前一条请求）+ 本条 M1 的偏移"的混搭，只在部分地址上碰巧相等；
   *   表现为 prog 1 项、prog_load_use 2 项定向自检失败（周期数却变快了）。
   *   结论：**必须在 M2 用当拍 rdata 重算**，不能搬 M1 的结果。
   */
  logic [31:0] rdata_byte_sel_pipe;
  logic [31:0] rdata_half_sel_pipe;
  logic [31:0] rdata_8i_pipe;
  logic [31:0] rdata_16i_pipe;
  logic [31:0] rdata_8u_pipe;
  logic [31:0] rdata_16u_pipe;
  logic [31:0] rdata_ex_pipe;

  // mem_hold / mdu_busy 期间必须把自己的一级也停住（ready_last 拉低），
  // 否则上级会把新指令推进来覆盖正在等待的那一条。
  // ★ 不变量：lsu_freeze 必须同时进 ready_last 与下面 always_ff 的推进条件（两处是同一个表达式）。
  //   只挡一处，要么上级照样推进、要么本级在等待期间把 mem_ren_reg_pipe 推走 —— DCache 的 cpu_en
  //   组合来源随之变化，hold 自己就把自己解掉了。
  logic lsu_freeze;
  assign lsu_freeze = mem_hold | mdu_busy;

  // ★★ v15：M1 命中前递（把 load-use 从 2 拍压到 1 拍）
  //   为什么原来做不到：DCache 的数组读虽然是组合的，但地址取自 **M2** 那一段；
  //   而 M1 那段（= load 的有效地址 Ex_result_addr_reg）在本拍就能查 —— 给 DCache
  //   加一个**只读探测口**（m1_addr/m1_en → m1_hit/m1_rdata）之后，命中时数据当拍就有。
  //   ★ 口径必须与主读口一致：字节/半字仍按 M1 的 funct3 + addr[1:0] 选道再符号扩展
  //     （与上面 rdata_ex 同一套规则，只是数据源换成 m1_rdata）。
  //   ★ 只在 `mem_ren_reg & valid_reg & m1_hit` 时成立：store / 空拍 / 未命中 / MMIO
  //     一律退回原路径（多停 1 拍），所以这条通路**只可能变快，不可能改错语义**。
  function automatic [31:0] lane_extract(input [31:0] w, input [2:0] f3, input [1:0] off);
    reg [7:0]  b;
    reg [15:0] h;
    begin
      case (off)
        2'b00:   b = w[7:0];
        2'b01:   b = w[15:8];
        2'b10:   b = w[23:16];
        default: b = w[31:24];
      endcase
      h = off[1] ? w[31:16] : w[15:0];
      case (f3)
        3'b000:  lane_extract = {{24{b[7]}}, b};      // lb
        3'b001:  lane_extract = {{16{h[15]}}, h};     // lh
        3'b010:  lane_extract = w;                     // lw
        3'b100:  lane_extract = {24'b0, b};            // lbu
        3'b101:  lane_extract = {16'b0, h};            // lhu
        default: lane_extract = 32'b0;
      endcase
    end
  endfunction

  assign LSU_Rdata_m1 = lane_extract(m1_rdata, funct3_reg, Ex_result_addr_reg[1:0]);
  assign m1_load_ok   = mem_ren_reg & valid_reg & m1_hit;

  assign ready_last = ready_next & ~lsu_freeze;   // 与下一行推进条件同式，别只改一处
  assign valid_next = valid_reg;                  // LSU 的 valid 就是 M1 寄存后的 EXU valid
  // v12（B）：退休脉冲 = 本拍真的把一条有效指令推进到 WB 级（同上式 + valid_reg_pipe）。
  //   气泡拍 valid_reg_pipe=0 → 不计数；冻结拍被 ~lsu_freeze 挡掉 → 不重复计数。
  //   一条指令在 WB 入口只可能"落"一次，所以这正是 minstret 要的口径。
  assign retire_wb = ready_next & ~lsu_freeze & valid_reg_pipe;

  /* ★ v14（P4）：请求身份证。每推进一条 M2 指令翻转一次（冻结期间不翻转），
   *   DCache 把它与 cpu_addr_r 一起寄存，用"寄存后的 seq 变没变"判断换没换请求。
   *   ★ 这里的推进条件必须与下面 always_ff 的推进条件**逐字一致**
   *     （`ready_next & ~lsu_freeze`）：只挡一处会让身份证与实际推进脱钩。 */
  always_ff @(posedge clock) begin
    if (reset)                        req_seq <= 1'b0;
    else if (ready_next & ~lsu_freeze) req_seq <= ~req_seq;
  end

  // ★★ v13 修复（真实功能缺陷，扩到 128KB DRAM 后才暴露）：
  //   原来是 `{Ex_result_addr_reg_pipe[31:18], 2'b00, [15:0]}` —— 把 **bit[17:16] 强制清零**。
  //   v12 时代 DRAM 只有 64KB（board_top 用 perip_addr[15:2] 索引），bit[17:16] 恒为 0，
  //   所以这个"清零"从未生效过；一旦把 DRAM 扩到 128KB、软件把 .rodata/.data 放在
  //   0x1_0000 以上，**地址的 bit16 会被硬件吃掉**，0x10038 变 0x00038 —— 数据访问
  //   全部回卷到低 64KB，与栈/全局变量糊在一起。
  //   现在原样透传：宽度由 mask(funct3[1:0]) 决定，字节通道靠 addr[1:0]，
  //   DRAM 的容量译码交给顶层（board_top 的 sync_mem 用 addr[$clog2(WORDS)+1:2]）。
  assign addr  = Ex_result_addr_reg_pipe;
  assign wdata = rs2_value_reg_pipe;
  assign mask  = funct3_reg_pipe[1:0];
  assign wen   = mem_wen_reg_pipe;

  // *_next = M1 的直通输出（EXU 刚送进来的那条指令）、*_pipe = M2、*_wb = M3 —— 三级各留一份观察点，
  //   就是为了「结果一可用就前递」：Data_hazard 不必等指令走到写回才拿到值（见 myCPU.sv 的 MEM_* 一组）。
  //   LSU_Rdata 是**已扩展**的本级（M1）读数据 —— v11（S6）起它真的被用上了：
  //   作为 DCache 命中时的 M1 前递源（load-use 停顿 2 拍 → 1 拍）。
  assign LSU_Rdata      = rdata_ex;
  assign funct3_next    = funct3_reg;
  assign Ex_result_next = Ex_result_fwd_reg;
  assign rd_value_next  = rd_value_reg;
  assign rd_next        = rd_reg;
  assign mem_ren_next   = mem_ren_reg;
  assign R_wen_next     = R_wen_reg;
  assign jump_flag_next = jump_flag_reg;
  assign csr_wen_next   = csr_wen_reg;
  assign pc_out         = pc_reg;

  assign Ex_result_pipe = Ex_result_fwd_reg_pipe;
  assign rd_pipe        = rd_reg_pipe;
  assign mem_ren_pipe   = mem_ren_reg_pipe;
  assign R_wen_pipe     = R_wen_reg_pipe;
  assign valid_pipe     = valid_reg_pipe;

  // 对前递来说，跳转/CSR 与普通 ALU 指令不同：
  // 它们真正想被下游看到的是 rd_value，而不是地址/ALU 原始结果。
  // 这个判据在 M1/M2/M3 三处必须完全一致（myCPU 的 MEM_forward_val 用同一式子），否则前递会给出"地址"而不是"要写的值"；
  // M3 的优先级 jump/CSR > load > Ex_result 与 WBU 内部一致 —— 这里先算好给前递用，最终值由 WBU 再选一次。
  logic wb_sel_jmp_csr_pipe;
  assign wb_sel_jmp_csr_pipe = jump_flag_reg_pipe | (|csr_wen_reg_pipe);
  // ★ v11（S6）：M2 级如果是 **load**，前递值必须是**读回并已扩展的数据**，不能是 Ex_result
  //   （那对 load 是有效地址）。数据在 M2 当拍就有效（DCache 命中路径同拍组合；未命中时
  //   hold 冻结 LSU、解冻那拍同样在 rdata 上），见下方 M2 扩展块的说明。
  //   优先级仍是 jump/CSR > load > Ex_result；但 load 一定不是 jump/CSR，所以先判 load 等价。
  assign forward_val_pipe = mem_ren_reg_pipe      ? rdata_ex_pipe          :
                            wb_sel_jmp_csr_pipe   ? rd_value_reg_pipe     :
                                                    Ex_result_fwd_reg_pipe;

  assign pc_wb          = pc_reg2;
  assign rdata_wb_raw   = rdata_reg2;
  assign funct3_wb      = funct3_reg2;
  // load 的 exec_res 就是有效地址，reg2 级把它随流水带过来了
  assign rdata_offset_wb = Ex_result_fwd_reg2[1:0];
  assign csr_wen_wb     = csr_wen_reg2;
  assign Ex_result_wb   = Ex_result_fwd_reg2;
  assign rd_value_wb    = rd_value_reg2;
  assign rd_wb          = rd_reg2;
  assign mem_ren_wb     = mem_ren_reg2;
  assign R_wen_wb       = R_wen_reg2;
  assign jump_flag_wb   = jump_flag_reg2;
  assign valid_wb       = valid_reg2;

  logic wb_sel_jmp_csr2;
  assign wb_sel_jmp_csr2 = jump_flag_reg2 | (|csr_wen_reg2);
  assign forward_val_wb = wb_sel_jmp_csr2 ? rd_value_reg2 : (mem_ren_reg2 ? rdata_wb2 : Ex_result_fwd_reg2);

  // 上板改造：只要 mem_hold=1（DCache 因同步 DRAM load miss 需要重试）或 mdu_busy=1（EXU 在等 MDU 结果），
  // 整条访存流水**同步冻结**（推进条件与 ready_last 同用 lsu_freeze）：否则 mem_ren_reg_pipe 会被推进到下一级、
  // DCache 的 cpu_en 组合来源随之变化，hold 自己就把自己解掉了；MDU 的情况则会推着陈旧值往下走。
  // ★ rdata_reg2 <= rdata 是与 DCache 的时序契约：它采的是**组合的** rdata，而 DCache 保证「撤销 hold 的那一拍
  //   rdata 就是本 load 的数据」，于是数据正好落进写回拍（见 DCache.sv 的 B2 契约）。
  always_ff @(posedge clock) begin
    if (reset) begin
      mem_ren_reg   <= 1'b0;
      mem_wen_reg   <= 1'b0;
      R_wen_reg     <= 1'b0;
      csr_wen_reg   <= 16'b0;
      Ex_result_addr_reg <= 32'b0;
      Ex_result_fwd_reg  <= 32'b0;
      rd_reg        <= 5'b0;
      funct3_reg    <= 3'b0;
      rs2_value_reg <= 32'b0;
      jump_flag_reg <= 1'b0;
      rd_value_reg  <= 32'b0;
      pc_reg        <= 32'b0;
      valid_reg     <= 1'b0;

      mem_ren_reg_pipe   <= 1'b0;
      mem_wen_reg_pipe   <= 1'b0;
      R_wen_reg_pipe     <= 1'b0;
      csr_wen_reg_pipe   <= 16'b0;
      Ex_result_addr_reg_pipe <= 32'b0;
      Ex_result_fwd_reg_pipe  <= 32'b0;
      rd_reg_pipe        <= 5'b0;
      funct3_reg_pipe    <= 3'b0;
      rs2_value_reg_pipe <= 32'b0;
      jump_flag_reg_pipe <= 1'b0;
      rd_value_reg_pipe  <= 32'b0;
      pc_reg_pipe        <= 32'b0;
      valid_reg_pipe     <= 1'b0;

      mem_ren_reg2  <= 1'b0;
      R_wen_reg2    <= 1'b0;
      csr_wen_reg2  <= 16'b0;
      Ex_result_fwd_reg2 <= 32'b0;
      rd_reg2       <= 5'b0;
      funct3_reg2   <= 3'b0;
      jump_flag_reg2 <= 1'b0;
      rd_value_reg2 <= 32'b0;
      pc_reg2       <= 32'b0;
      valid_reg2    <= 1'b0;
      rdata_reg2    <= 32'b0;
    end else if (ready_next & ~lsu_freeze) begin   // ★ 推进条件：与 ready_last 同式，lsu_freeze 挡住一切
      // ---- 三段搬运全部读**本拍旧值**（非阻塞赋值），段与段之间没有先后语义；分三段只为对齐「一级一级往下搬」----
      mem_ren_reg2  <= mem_ren_reg_pipe;
      R_wen_reg2    <= R_wen_reg_pipe;
      csr_wen_reg2  <= csr_wen_reg_pipe;
      Ex_result_fwd_reg2 <= Ex_result_fwd_reg_pipe;
      rd_reg2       <= rd_reg_pipe;
      funct3_reg2   <= funct3_reg_pipe;
      jump_flag_reg2 <= jump_flag_reg_pipe;
      rd_value_reg2 <= rd_value_reg_pipe;
      pc_reg2       <= pc_reg_pipe;
      valid_reg2    <= valid_reg_pipe;
      rdata_reg2    <= rdata;

      mem_ren_reg_pipe   <= mem_ren_reg;
      mem_wen_reg_pipe   <= mem_wen_reg;
      R_wen_reg_pipe     <= R_wen_reg;
      csr_wen_reg_pipe   <= csr_wen_reg;
      Ex_result_addr_reg_pipe <= Ex_result_addr_reg;
      Ex_result_fwd_reg_pipe  <= Ex_result_fwd_reg;
      rd_reg_pipe        <= rd_reg;
      funct3_reg_pipe    <= funct3_reg;
      rs2_value_reg_pipe <= rs2_value_reg;
      jump_flag_reg_pipe <= jump_flag_reg;
      rd_value_reg_pipe  <= rd_value_reg;
      pc_reg_pipe        <= pc_reg;
      valid_reg_pipe     <= valid_reg;

      // ---- M1：采 EXU 本拍送来的信号（valid_last 就是 EXU 的 valid）----
      mem_ren_reg   <= mem_ren;
      mem_wen_reg   <= mem_wen;
      R_wen_reg     <= R_wen;
      csr_wen_reg   <= csr_wen;
      Ex_result_addr_reg <= Ex_result;
      Ex_result_fwd_reg  <= Ex_result;
      rd_reg        <= rd;
      funct3_reg    <= funct3;
      rs2_value_reg <= rs2_value;
      jump_flag_reg <= jump_flag;
      rd_value_reg  <= rd_value;
      pc_reg        <= pc;
      valid_reg     <= valid_last;
    end
  end

  // 当前拍（M1）读数据按 funct3 扩展，供 LSU 本级使用与早期观察：
  // 000 lb / 001 lh / 010 lw / 100 lbu / 101 lhu；default 给 0，避免非法 funct3 把 x 传下去。
  always @(*) begin
    case (funct3_reg)
      3'b000:  rdata_ex = rdata_8i;
      3'b001:  rdata_ex = rdata_16i;
      3'b010:  rdata_ex = rdata;
      3'b100:  rdata_ex = rdata_8u;
      3'b101:  rdata_ex = rdata_16u;
      default: rdata_ex = 0;
    endcase
  end

  // ★ 不变量（v9 修复 B1）：字节/半字读必须先按**地址低 2 位**选道，再符号扩展。
  //   原因：读口（DRAM / DCache / 板级同步 BRAM）返回的是「该地址所在字」的原始整字，偏移信息只存在于地址里；直接取
  //   rdata[7:0] / rdata[15:0] 等于把 lb/lh/lbu/lhu 的第 1/2/3 字节全读成第 0 字节。选道口径必须与写侧一致（DCache
  //   的 store 合并、board/sync_mem 的 mask 写）：字节按 addr[1:0] 取 4 个字节之一、半字按 addr[1] 取低/高半字。
  //   reg 级用 Ex_result_addr_reg[1:0]、reg2 级用 Ex_result_fwd_reg2[1:0]（EXU 对 load 的 exec_res 就是有效地址，两级都随流水带过来了）。
  //   踩坑史 + 实测现象：见 syn/修复史_全量.md §LSU-1
  //
  // 选道中间量：把目标字节/半字搬到低位，好让**同一份数据**同时喂给零扩展与 sext 实例。它们只在 [7:0]/[15:0] 上被读
  //   （见下面 rdata_8u/rdata_16u 与 sext 的 .data 连接），所以综合会把这些 mux 的高 24/16 位裁掉（case 2'b00 那支只留
  //   rdata[7:0]）—— 这不是 bug，也别「优化」成直接位选：位选表达不了 addr[1:0] 的 4 选 1。
  logic [31:0] rdata_byte_sel;
  logic [31:0] rdata_half_sel;
  logic [31:0] rdata_byte_sel2;
  logic [31:0] rdata_half_sel2;

  always @(*) begin
    case (Ex_result_addr_reg[1:0])
      2'b00:   rdata_byte_sel = rdata;
      2'b01:   rdata_byte_sel = {8'd0,  rdata[31:8]};
      2'b10:   rdata_byte_sel = {16'd0, rdata[31:16]};
      default: rdata_byte_sel = {24'd0, rdata[31:24]};
    endcase
  end
  assign rdata_half_sel = Ex_result_addr_reg[1] ? {16'd0, rdata[31:16]} : rdata;   // M1：2 选 1 半字（字节那支是同构的上面的 case）

  // M3 级与 M1 同构的一份，只是数据源换成 rdata_reg2、偏移换成 Ex_result_fwd_reg2[1:0]
  always @(*) begin
    case (Ex_result_fwd_reg2[1:0])
      2'b00:   rdata_byte_sel2 = rdata_reg2;
      2'b01:   rdata_byte_sel2 = {8'd0,  rdata_reg2[31:8]};
      2'b10:   rdata_byte_sel2 = {16'd0, rdata_reg2[31:16]};
      default: rdata_byte_sel2 = {24'd0, rdata_reg2[31:24]};
    endcase
  end
  assign rdata_half_sel2 = Ex_result_fwd_reg2[1] ? {16'd0, rdata_reg2[31:16]} : rdata_reg2;

  assign rdata_8u  = {24'd0, rdata_byte_sel[7:0]};    // lbu：零扩展，不走 sext 实例
  assign rdata_16u = {16'd0, rdata_half_sel[15:0]};   // lhu：零扩展

  // 4 个 sext 实例 = lb/lh × (M1 级 sext_i8/sext_i16、M3 级 sext_i8_2/sext_i16_2)：
  //   同一个符号扩展模块被参数化成 8/16 位两份，这里两级各来一套，好让写回拍直接用（写回值才是最终值）。
  /* verilator lint_off PINMISSING */
  sext #(
      .DATA_WIDTH(8),
      .OUT_WIDTH (32)
  ) sext_i8 (
      .data     (rdata_byte_sel[7:0]),
      .sext_data(rdata_8i)
  );

  sext #(
      .DATA_WIDTH(16),
      .OUT_WIDTH (32)
  ) sext_i16 (
      .data     (rdata_half_sel[15:0]),
      .sext_data(rdata_16i)
  );

  assign rdata_8u2  = {24'd0, rdata_byte_sel2[7:0]};
  assign rdata_16u2 = {16'd0, rdata_half_sel2[15:0]};

  /* verilator lint_off PINMISSING */
  sext #(
      .DATA_WIDTH(8),
      .OUT_WIDTH (32)
  ) sext_i8_2 (
      .data     (rdata_byte_sel2[7:0]),
      .sext_data(rdata_8i2)
  );

  sext #(
      .DATA_WIDTH(16),
      .OUT_WIDTH (32)
  ) sext_i16_2 (
      .data     (rdata_half_sel2[15:0]),
      .sext_data(rdata_16i2)
  );

  // 写回前再次按 funct3 整理数据宽度，形成最终提交给 WBU 的 load 结果（WBU 还会按同一口径再选一次）；
  // default 给 0：非法 funct3 不把 x 传播进写回值。
  always @(*) begin
    case (funct3_reg2)
      3'b000:  rdata_wb2 = rdata_8i2;
      3'b001:  rdata_wb2 = rdata_16i2;
      3'b010:  rdata_wb2 = rdata_reg2;
      3'b100:  rdata_wb2 = rdata_8u2;
      3'b101:  rdata_wb2 = rdata_16u2;
      default: rdata_wb2 = 0;
    endcase
  end

  /* ============================ v11（S6）M2 级扩展 ============================
   * 与 M1/M3 同构，只是数据源是**当拍**的 rdata、偏移/位宽取 _pipe 那一组。
   * 选道口径必须与 M1/M3、LSU 的 store 合并、board/sync_mem 的 mask 写完全一致
   * （字节按 addr[1:0] 取 4 个字节之一、半字按 addr[1] 取低/高半字），否则同一字节
   * 在三处会错位 —— 见本文件 §LSU-1 与 WBU.sv 的同类说明。
   * ========================================================================= */
  always @(*) begin
    case (Ex_result_addr_reg_pipe[1:0])
      2'b00:   rdata_byte_sel_pipe = rdata;
      2'b01:   rdata_byte_sel_pipe = {8'd0,  rdata[31:8]};
      2'b10:   rdata_byte_sel_pipe = {16'd0, rdata[31:16]};
      default: rdata_byte_sel_pipe = {24'd0, rdata[31:24]};
    endcase
  end
  assign rdata_half_sel_pipe = Ex_result_addr_reg_pipe[1] ? {16'd0, rdata[31:16]} : rdata;

  assign rdata_8u_pipe  = {24'd0, rdata_byte_sel_pipe[7:0]};
  assign rdata_16u_pipe = {16'd0, rdata_half_sel_pipe[15:0]};

  /* verilator lint_off PINMISSING */
  sext #(
      .DATA_WIDTH(8),
      .OUT_WIDTH (32)
  ) sext_i8_pipe (
      .data     (rdata_byte_sel_pipe[7:0]),
      .sext_data(rdata_8i_pipe)
  );

  sext #(
      .DATA_WIDTH(16),
      .OUT_WIDTH (32)
  ) sext_i16_pipe (
      .data     (rdata_half_sel_pipe[15:0]),
      .sext_data(rdata_16i_pipe)
  );

  always @(*) begin
    case (funct3_reg_pipe)
      3'b000:  rdata_ex_pipe = rdata_8i_pipe;
      3'b001:  rdata_ex_pipe = rdata_16i_pipe;
      3'b010:  rdata_ex_pipe = rdata;
      3'b100:  rdata_ex_pipe = rdata_8u_pipe;
      3'b101:  rdata_ex_pipe = rdata_16u_pipe;
      default: rdata_ex_pipe = 0;
    endcase
  end



endmodule  //MEM
