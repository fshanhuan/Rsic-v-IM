// =============================================================================
// tb_iverilog.sv — v9 的 iverilog/vvp 自包含回归测试台（新增文件，不改动 RTL）
// -----------------------------------------------------------------------------
// 为什么单独写一个：
//   cdp-tests 的差分框架依赖 verilator + make + WSL，本机都不可用。
//   这个测试台把「IROM + DRAM + myCPU」全部做在一个文件里，只用
//   iverilog -g2012 + vvp 就能跑，作为上板改造前的功能回归基线。
//
// 与 cdp-tests / sim/tb_wave.sv 的关系：
//   - 存储器语义完全照抄 cdp-tests/mySoC/miniRV_SoC.v + dram_driver.sv
//     （IROM 组合读字地址 a=pc[13:2]；DRAM 按 mask/offset 抽取与合并写）；
//   - 采样时刻取**时钟下降沿**，与 cdp-tests 测试台读 debug_wb_* 的时刻一致
//     （见 sim/README.md）；
//   - 这里额外做了：写回事件逐拍打印 + 同事件去重、store/重定向追踪、
//     程序结束（ecall）检测、32 个通用寄存器快照与期望值比对、逐元素 VCD 导出。
//
// 本机环境注意事项（踩过的坑，别改回去）：
//   1. iverilog 的 $readmemh / $dumpfile 吃不了非 ASCII 绝对路径，
//      -o 给中文绝对路径会 Code generator failure。→ 一律 cd 到工作目录用相对路径。
//   2. iverilog 不支持 $fread（cdp-tests/vsrc/ram.v 读 .bin 用的就是 $fread），
//      所以这里改用**文本 hex**（sim/prog*.hex）+ $readmemh。
//   3. iverilog 不会自动导出存储器数组，$dumpvars(0, tb) 里拿不到 rf[0:31]，
//      必须逐个元素显式 $dumpvars（见文末）。
//
// 用法（在工作目录 v9/ 下执行）：
//   iverilog -g2012 -o sim/build/tb_iverilog.vvp \
//       myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv \
//       RegisterFile.sv CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv LSU.sv DCache.sv WBU.sv \
//       Data_hazard.sv Control.sv add.sv sext.sv Reg.sv sim/tb_iverilog.sv
//   mkdir -p wave
//   vvp sim/build/tb_iverilog.vvp +prog=sim/prog.hex +prog_id=0
//   （或直接跑 sim/run_iverilog.bat <prog>）
//
// 运行时 plusarg：
//   +prog=<path>     选择程序 hex（默认 sim/prog.hex）
//   +prog_id=<n>     选择期望值表：0=prog 1=prog_mul 2=prog_div
//                    3=prog_load_lane 4=prog_load_use 5=prog_loop 6=prog_div_pair
//                    （3~6 是 v9 修复缺陷后补的回归，覆盖 字节/半字偏移、load 取数、
//                      后向分支循环、背靠背除法）其它=只报实测
//   +max=<n>         最大拍数（默认 400，防跑飞）
//   +drain=<n>       ecall 之后再多跑几拍等流水线排空（默认 8）
//   +no_wbu_force    关掉 WBU.stall 的 force（RTL 修好后可用）
//   +raw_rf          关掉寄存器堆上电清零（看原始 x 传播行为）
//
// 注：运行时 $display 全部用 ASCII 英文，避免 Windows cmd(cp936) 下中文乱码；
//     源码注释保持中文。
// =============================================================================
`timescale 1ns / 1ps

module tb_iverilog #(
    parameter PROG_FILE    = "sim/prog.hex",
    parameter PROG_ID      = 3,      // 3 = 只报实测值，不做期望比对
    parameter MAX_CYCLES   = 400,
    parameter DRAIN_CYCLES = 8,
    // ecall 之后额外观察多少拍，用来验证"ecall 真的把 PC 拨到 mtvec 了吗"。
    //   见下方 ECALL REDIRECT 断言。
    parameter ECALL_REDIR_CYCLES = 16
);

    // ---------------------------------------------------------------------
    // 时钟与复位：10ns 周期 = 100MHz
    // ---------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    integer cycle = 0;

    // ---------------------------------------------------------------------
    // CPU 接口
    // ---------------------------------------------------------------------
    logic [31:0] irom_addr, irom_data;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic        perip_wen, perip_ren;
    logic [ 1:0] perip_mask;

    logic        dbg_have_inst;
    logic [31:0] dbg_pc;
    logic        dbg_ena;
    logic [ 4:0] dbg_reg;
    logic [31:0] dbg_value;

    // ---------------------------------------------------------------------
    // IROM：**同步读**（上板改造后与 FPGA BRAM 语义一致）
    //   - 本拍给定的地址 a=pc[13:2] 打一拍，下一拍 data 才有效；
    //   - 这正是 ICache 现在的时间假设（cpu_addr_r 寄存输出 → BRAM 1 拍延迟）；
    //   - 旧版本这里是组合读（assign irom_data = irom[...]），与上板时序不一致，
    //     已随 ICache.sv 的同步 BRAM 化一起改掉。
    //   - 初值仍是零填充 + $readmemh 载入（等价于板上的 BRAM 初始化）。
    // ---------------------------------------------------------------------
    localparam IROM_WORDS = 4096;              // 16KB
    logic [31:0] irom [0:IROM_WORDS-1];

    always_ff @(posedge clk) begin
        irom_data <= irom[irom_addr[13:2]];
    end

    // ---------------------------------------------------------------------
    // DRAM / 外设：**同步读 + 同步写**（上板改造后与 board/sync_mem.sv 同语义）
    //   - 读：本拍给定 perip_addr，下一拍 perip_rdata 才有效
    //         （DCache 的 cpu_valid_r 就是为这个 1 拍延迟准备的）；
    //   - 读口返回**原始整字**：字节/半字的抽取由 LSU 在写回前按 funct3 完成。
    //     旧版本在这里按 perip_mask 预先抽取，那是为“DCache 同拍组合旁路”
    //     配的；现在 DCache 走同步读并把整字回填给 LSU，抽取必须只做一次。
    //   - 写：按 perip_mask/offset 合并（read-modify-write），上升沿写入；
    //     DCache 把 store 请求寄存成单拍脉冲，因此 perip_wen 只高 1 拍。
    // ---------------------------------------------------------------------
    localparam DRAM_WORDS = 16384;             // 64KB
    logic [31:0] dram [0:DRAM_WORDS-1];
    logic [15:0] dram_word_addr;
    logic [ 1:0] dram_offset;
    logic [31:0] dram_raw, dram_din;

    assign dram_word_addr = perip_addr[15:2];
    assign dram_offset    = perip_addr[1:0];
    // DRAM 内容本身（写是同步的，所以在时钟沿读它就是读“旧值”）
    assign dram_raw       = dram[dram_word_addr];

    // 写数据合并：只把掩码选中的字节替换成 perip_wdata 的低位字节
    always_comb begin
        case (perip_mask)
            2'b00:   case (dram_offset)          // sb
                         2'b00:   dram_din = {dram_raw[31:8],  perip_wdata[7:0]};
                         2'b01:   dram_din = {dram_raw[31:16], perip_wdata[7:0], dram_raw[7:0]};
                         2'b10:   dram_din = {dram_raw[31:24], perip_wdata[7:0], dram_raw[15:0]};
                         default: dram_din = {perip_wdata[7:0], dram_raw[23:0]};
                     endcase
            2'b01:   case (dram_offset[1])       // sh
                         1'b0:    dram_din = {dram_raw[31:16], perip_wdata[15:0]};
                         default: dram_din = {perip_wdata[15:0], dram_raw[15:0]};
                     endcase
            default: dram_din = perip_wdata;     // sw
        endcase
    end

    // 同步读：地址打一拍，数据下一拍出（固定 1 拍延迟）。
    // v9 修复：这里必须像 board/sync_mem.sv 一样**按读使能门控**。
    //   原来是无条件 `perip_rdata <= dram[dram_word_addr];`（自由运行读口），
    //   每拍都更新 —— 恰好把 DCache 读握手的 off-by-one 掩盖掉了：
    //   真实 BRAM 只在 ren=1 时采样地址、下一拍给数据，而 LSU 在数据到齐前
    //   就已经把总线上的残留值采走了（上板表现为 x）。现在口子对齐真实语义，
    //   测试台不再掩盖这一类问题。
    always_ff @(posedge clk) begin
        if (rst)        perip_rdata <= 32'b0;
        else if (perip_ren) perip_rdata <= dram[dram_word_addr];
    end

    // 同步写：上升沿按掩码合并写入
    // 用 always 而非 always_ff：dram 还要在下面的 initial 里被清零，而 SV LRM
    //   禁止 always_ff 写过的变量再被别的进程写（ModelSim vlog-7061 报 Error，
    //   并且**拒绝把该模块写入库**，随后 vsim 会报 vopt-13130 找不到设计单元）。
    always @(posedge clk) begin
        if (perip_wen) dram[dram_word_addr] <= dram_din;
    end

    // ---------------------------------------------------------------------
    // 被测 CPU
    // ---------------------------------------------------------------------
    myCPU u_cpu (
        .cpu_clk            (clk),
        .cpu_rst            (rst),
        .irom_addr          (irom_addr),
        .irom_data          (irom_data),
        .perip_addr         (perip_addr),
        .perip_wen          (perip_wen),
        .perip_ren          (perip_ren),
        .perip_mask         (perip_mask),
        .perip_wdata        (perip_wdata),
        .perip_rdata        (perip_rdata),
        .debug_wb_have_inst (dbg_have_inst),
        .debug_wb_pc        (dbg_pc),
        .debug_wb_ena       (dbg_ena),
        .debug_wb_reg       (dbg_reg),
        .debug_wb_value     (dbg_value)
    );

    // ---------------------------------------------------------------------
    // 观测探针（给波形用；这些是普通 wire，会被 $dumpvars(0, tb) 自动导出）
    // ---------------------------------------------------------------------
    wire [31:0] p_if_pc      = u_cpu.IFU_pc;
    wire [31:0] p_if_inst    = u_cpu.IFU_inst;
    wire        p_if_deliver = u_cpu.IFU_Inst0.advance_en;   // IF 交付有效：= 队头 valid & ready（v10 起前端 1 条/拍，不再是 3 拍）
    wire [31:0] p_id_pc      = u_cpu.IDU_pc;
    wire        p_id_valid   = u_cpu.IDU_valid;             // ID2 的 valid（= valid_d 直通）
    wire        p_id1_valid  = u_cpu.IDU_Inst0.valid;       // ID1 的 valid（第一级流水寄存）
    wire [31:0] p_ex_pc      = u_cpu.EXU_pc;
    wire [31:0] p_ex_res     = u_cpu.EXU_Ex_result;
    wire [ 4:0] p_ex_rd      = u_cpu.EXU_rd;
    wire        p_ex_valid   = u_cpu.EXU_valid;
    wire        p_ex_clr     = u_cpu.EXU_inst_clear;   // EX 级指令清空（跳转/异常/mem_stall/load-use）
    wire        p_mem_valid  = u_cpu.LSU_valid;        // LSU 第一级(M1) valid
    wire        p_mem2_valid = u_cpu.LSU_valid_pipe;   // LSU 第二级(M2) valid
    wire        p_mem3_valid = u_cpu.LSU_valid_wb;   // LSU 第三级(M3) valid，即送 WBU 的 valid_wb
    wire [31:0] p_mem_addr   = u_cpu.lsu_bus_addr;
    wire        p_mem_wen    = u_cpu.lsu_bus_wen;
    wire [31:0] p_wb_pc      = u_cpu.WBU_pc;
    wire [ 4:0] p_wb_rd      = u_cpu.WBU_rd;
    wire [31:0] p_wb_val     = u_cpu.WBU_rd_value;
    wire        p_wb_valid   = u_cpu.WBU_valid;
    wire        p_stall      = u_cpu.IFU_stall;
    wire        p_dnpc_flag  = u_cpu.dnpc_flag;
    wire [31:0] p_dnpc       = u_cpu.dnpc;
    wire        p_pred_taken = u_cpu.bp_pred_taken;
    wire        p_mispredict = u_cpu.bp_mispredict;
    wire        p_ecall      = u_cpu.IDU_ecall_flag;

    /* 寄存器堆层次路径（grep 确认）：
       u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[0:31]
       —— Reg_Stack_inst0 在 IDU.sv:322 例化，Reg_inst 在 Reg_Stack.sv:89 例化。 */
    wire [31:0] p_r0  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[0];
    wire [31:0] p_r1  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[1];
    wire [31:0] p_r2  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[2];
    wire [31:0] p_r3  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[3];
    wire [31:0] p_r4  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[4];
    wire [31:0] p_r5  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5];
    wire [31:0] p_r6  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[6];
    wire [31:0] p_r7  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[7];
    wire [31:0] p_r8  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[8];
    wire [31:0] p_r9  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[9];
    wire [31:0] p_r10 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[10];

    // CSR 关键状态（普通 reg，$dumpvars(0, tb) 会自动导出）
    wire [31:0] p_mepc     = u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mepc_reg;
    wire [31:0] p_mcause   = u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mcause_reg;
    wire [31:0] p_mstatus  = u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mstatus_reg;
    wire [31:0] p_mtvec    = u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mtvec_reg;

    // ---------------------------------------------------------------------
    // 运行期状态
    // ---------------------------------------------------------------------
    integer  prog_id      = PROG_ID;
    integer  max_cycles   = MAX_CYCLES;
    integer  drain_cycles = DRAIN_CYCLES;

    reg [8*260-1:0] prog_path;
    reg [8*260-1:0] vcd_path;

    integer wb_events     = 0;
    integer wb_suppressed = 0;   // 同一事件连续保持多拍被去重掉的拍数
    logic   dedup_en      = 1'b1;  // +no_dedup 可关闭（对比“不去重会刷屏多少”）
    integer store_events  = 0;
    integer load_events   = 0;
    integer stall_cycles  = 0;
    // v10 前端 / IROM 门控的实测统计（每拍采样）
    integer irom_en_cycles = 0;      // IROM 读使能为 1 的拍数（= 真取指次数）
    integer ifu_deliver_cycles = 0;  // 前端真正交付一条指令的拍数
    integer ifu_qmax = 0;            // 取指队列达到过的最大深度
    integer redirect_cnt  = 0;
    integer ecall_cycle   = -1;
    integer drain_cnt     = 0;
    integer store_repeat  = 0;   // 同一 store 被重复发出的次数（必须为 0）
    integer fetch_bad     = 0;   // 取指对齐违例次数（必须为 0）
    logic   frozen        = 1'b0;

    // ---------------------------------------------------------------------
    // v9 新增断言③：ECALL REDIRECT（ecall 之后 PC 必须真的跳到 mtvec）
    //
    // 为什么加这一条 —— 这是**上板 ILA 抓出来的、仿真完全没覆盖的**一个真实 bug：
    //   板上抓 2048 拍 ×2，`debug_wb_pc` 从未出现过 0x00000000，也从未等于 mtvec；
    //   `mepc` 每绕 IROM 一圈（16KB）变一次（0x…8034 → 0x…c034，正好 +0x4000），
    //   说明 ecall 确实执行了、mepc 也写了，**但 PC 没有被重定向到 mtvec**，
    //   而是一路顺序爬行，每绕一圈再执行一次 ecall，如此无限循环。
    //
    // 为什么以前没抓到 —— 原来的停止条件是"ecall 在译码级出现后再 drain 8 拍"，
    //   然后立刻 $finish 打报告。报告里只比 GPR / dram / mepc / mcause，
    //   从来没有人看过 ecall **之后**的 PC。于是 35/35 全 PASS，bug 照样在。
    //
    // 本断言做什么：
    //   ecall 译码那一拍起，再连续观察 ECALL_REDIR_CYCLES 拍，逐拍打印 IFU_pc；
    //   只要其中任何一拍 IFU_pc === mtvec，就算重定向成功。
    //   （mtvec 复位值是 0，而 PC 只在复位期间才是 0，本检查远在复位之后，
    //     不存在误判为 PASS 的可能。）
    // ---------------------------------------------------------------------
    integer      ecall_redir_ok    = 0;   // 观察窗内是否见到 IFU_pc == mtvec
    integer      ecall_redir_polls = 0;   // 已经观察了几拍
    integer      ecall_redir_first = -1;  // 第几拍见到 mtvec（-1 = 从没见到）
    logic [31:0] ecall_pc_at_id    = 32'h0;  // ecall 在译码级那一拍的 IFU_pc

    // 取指级PC 历史（用于同一条断言打印：ecall 之后 PC 到底往哪跑了）
    logic [31:0] ecall_pc_trace [0:31];

    // ---------------------------------------------------------------------
    // v9 新增：报告快照（snapshot）
    //
    // 为什么需要 —— 断言③修好之后，ecall 会**正确**地跳到 mtvec=0，程序于是
    //   **从头再跑一遍**（这正是硬件上的预期行为：prog.hex 的 mtvec 复位值是 0，
    //   ecall 之后就从 0 重新执行，无限循环）。
    //   但报告原来是在 ecall 之后再等 DRAIN 拍**现场读** rf / CSR / 计数器，
    //   如果观察窗延长（为了看 PC 有没有跳），读到的就是**第二轮**的中间值 ——
    //   实测 prog_loop 因此报 x1=1/x2=0（应为 10/55），看起来像 RTL 坏了，
    //   其实是快照点被推到了第二轮循环里。
    //
    // 做法 —— 把"何时取快照"和"观察窗多长"彻底解耦：
    //   drain_cnt == drain_cycles 那一拍（= 原来 report 的时刻，7 个程序全部验证过）
    //   把需要的一切复制进 snap_*；之后继续跑到
    //   drain_cycles + ECALL_REDIR_CYCLES 只为看 PC 重定向，报告一律读 snap_*。
    // ---------------------------------------------------------------------
    logic [31:0] snap_gpr  [0:31];
    logic [31:0] snap_mepc, snap_mcause, snap_mstatus, snap_mtvec;
    logic [31:0] snap_dram1000;
    integer      snap_icache_hit, snap_icache_miss, snap_dcache_hit, snap_dcache_miss;
    integer      snap_bp_pred, snap_bp_hit, snap_bp_miss;
    integer      snap_wb_events, snap_wb_suppressed, snap_store_events, snap_load_events;
    integer      snap_stall_cycles, snap_redirect_cnt, snap_cycle;
    integer      snap_irom_en, snap_ifu_deliver, snap_qmax;
    integer      snap_done = 0;

    // 上一拍事件（用于“同一事件连续保持多拍”去重）
    logic        prev_have = 1'b0;
    logic [31:0] prev_pc   = 32'b0;
    logic [ 4:0] prev_reg  = 5'b0;
    logic [31:0] prev_val  = 32'b0;
    logic        prev_ena  = 1'b0;

    // 期望值
    logic        have_exp = 1'b0;
    logic [31:0] exp_reg  [0:31];
    logic [31:0] exp_dram = 32'h0;
    logic        have_exp_dram = 1'b0;

    // ---------------------------------------------------------------------
    // v9 上板改造新增断言（只加检查，不动原有断言）：
    //
    // ① write-once：同步 DRAM 下，一次 store 的 perip_wen 必须是**单拍脉冲**。
    //    DCache 里 store 请求被寄存成 store_req_r 单拍脉冲；若哪天有人把它改回
    //    “组合透传 mem_wen”，流水线冻结（load miss / IFU hold）期间就会重复
    //    发写，一次 store 写两次。这里连续两拍「同地址 + 同数据 + 同掩码」即判失败，
    //    并且把重复写次数累加进 store_repeat，最终报告里必须为 0。
    //    （v10.1：只比地址会把 `sh` 紧跟 `sb` 写同一个字误判成重复写，必须带上数据与掩码。）
    //
    // ② fetch 契约：IFU 交付指令时（valid=1），ICache 必须取到**当前 pc** 的
    //    指令。实现方式是在 negedge 采样 IFU_pc/IFU_inst，若 pc 连续两拍相同
    //    而指令不同，说明缓存交付了属于别的地址的数据（同步 BRAM 对齐写错时
    //    的典型症状）。
    // ---------------------------------------------------------------------
    logic [31:0] prev_store_addr = 32'b0;
    logic        prev_store_wen  = 1'b0;
    logic [31:0] prev_store_wdata = 32'b0;
    logic [ 1:0] prev_store_mask  = 2'b0;

    logic [31:0] prev_fetch_pc   = 32'hFFFF_FFFF;
    logic [31:0] prev_fetch_inst = 32'b0;
    logic        prev_fetch_vld  = 1'b0;

    // ---------------------------------------------------------------------
    // 小工具：把指令翻译成助记符（只为了日志可读，不影响功能）
    // ---------------------------------------------------------------------
    function [8*12-1:0] disasm(input [31:0] inst);
        reg [6:0] op;
        reg [2:0] f3;
        reg [6:0] f7;
        begin
            op = inst[6:0];
            f3 = inst[14:12];
            f7 = inst[31:25];
            disasm = "?";
            case (op)
                7'b0110011: begin                                   // R 型
                    if (f7 == 7'b0000001) begin
                        case (f3)
                            3'b000: disasm = "mul";
                            3'b001: disasm = "mulh";
                            3'b010: disasm = "mulhsu";
                            3'b011: disasm = "mulhu";
                            3'b100: disasm = "div";
                            3'b101: disasm = "divu";
                            3'b110: disasm = "rem";
                            default: disasm = "remu";
                        endcase
                    end else begin
                        case (f3)
                            3'b000: disasm = inst[30] ? "sub" : "add";
                            3'b001: disasm = "sll";
                            3'b010: disasm = "slt";
                            3'b011: disasm = "sltu";
                            3'b100: disasm = "xor";
                            3'b101: disasm = inst[30] ? "sra" : "srl";
                            3'b110: disasm = "or";
                            default: disasm = "and";
                        endcase
                    end
                end
                7'b0000011: begin
                    case (f3)
                        3'b000: disasm = "lb";
                        3'b001: disasm = "lh";
                        3'b010: disasm = "lw";
                        3'b100: disasm = "lbu";
                        3'b101: disasm = "lhu";
                        default: disasm = "ld?";
                    endcase
                end
                7'b0010011: begin
                    case (f3)
                        3'b000: disasm = "addi";
                        3'b001: disasm = "slli";
                        3'b010: disasm = "slti";
                        3'b011: disasm = "sltiu";
                        3'b100: disasm = "xori";
                        3'b101: disasm = inst[30] ? "srai" : "srli";
                        3'b110: disasm = "ori";
                        default: disasm = "andi";
                    endcase
                end
                7'b1100111: disasm = "jalr";
                7'b0100011: begin
                    case (f3)
                        3'b000: disasm = "sb";
                        3'b001: disasm = "sh";
                        3'b010: disasm = "sw";
                        default: disasm = "st?";
                    endcase
                end
                7'b1100011: begin
                    case (f3)
                        3'b000: disasm = "beq";
                        3'b001: disasm = "bne";
                        3'b100: disasm = "blt";
                        3'b101: disasm = "bge";
                        3'b110: disasm = "bltu";
                        3'b111: disasm = "bgeu";
                        default: disasm = "br?";
                    endcase
                end
                7'b0110111: disasm = "lui";
                7'b0010111: disasm = "auipc";
                7'b1101111: disasm = "jal";
                7'b1110011: begin
                    if (inst == 32'h00000073)      disasm = "ecall";
                    else if (inst == 32'h30200073) disasm = "mret";
                    else                           disasm = "csr";
                end
                7'b0001111: disasm = "fence.i";
                default:    disasm = "?";
            endcase
        end
    endfunction

    // ---------------------------------------------------------------------
    // 期望值表（prog.hex 的期望值由指令手工译码 + v9/figures 图上的寄存器终值交叉核对）
    // ---------------------------------------------------------------------
    task load_expectation(input integer pid);
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1) exp_reg[i] = 32'h0;
            have_exp      = 1'b1;
            have_exp_dram = 1'b0;
            case (pid)
                0: begin   // sim/prog.hex：lui/addi/add/mul/sw/lw/beq(不跳)/jal/ori/ecall
                    exp_reg[1]  = 32'h0000_1000;   // lui  x1, 0x1
                    exp_reg[2]  = 32'd5;           // addi x2, x0, 5
                    exp_reg[3]  = 32'd7;           // addi x3, x0, 7
                    exp_reg[4]  = 32'd12;          // add  x4, x2, x3
                    exp_reg[5]  = 32'd35;          // mul  x5, x2, x3
                    exp_reg[6]  = 32'd12;          // lw   x6, 0(x1)
                    exp_reg[7]  = 32'd17;          // add  x7, x6, x2
                    exp_reg[8]  = 32'd12;          // add  x8, x2, x3
                    exp_reg[9]  = 32'h0;           // addi x9 被 jal 跳过
                    exp_reg[10] = 32'd63;          // ori  x10(a0), x0, 63
                    exp_dram    = 32'd12;          // sw   x4, 0(x1) -> mem[0x1000]
                    have_exp_dram = 1'b1;
                end
                1: begin   // sim/prog_mul.hex：连续 8 条 mul（rd = x5,x8,x9,x10,x11,x12,x13,x14）
                    exp_reg[2]  = 32'd5;
                    exp_reg[3]  = 32'd7;
                    exp_reg[5]  = 32'd35;   // mul x5,  x2, x3   (023102b3, rd[6:0]=00101)
                    exp_reg[8]  = 32'd35;   // mul x8,  x2, x3
                    exp_reg[9]  = 32'd35;
                    exp_reg[10] = 32'd35;
                    exp_reg[11] = 32'd35;
                    exp_reg[12] = 32'd35;
                    exp_reg[13] = 32'd35;
                    exp_reg[14] = 32'd35;
                end
                2: begin   // sim/prog_div.hex：连续 4 条 div
                    exp_reg[2]  = 32'd100;
                    exp_reg[3]  = 32'd7;
                    exp_reg[4]  = 32'd14;   // 100/7
                    exp_reg[5]  = 32'd14;
                    exp_reg[6]  = 32'd14;
                    exp_reg[7]  = 32'd14;
                end
                // ---- v9 修复回归：下面 4 个程序专测本次修掉的缺陷（原来完全没覆盖）----
                // 期望值由独立参考模型（.verify/difftest）算出，不是手算。
                3: begin   // prog_load_lane：lb/lh/lbu/lhu 的**地址偏移**选道（B1）
                    exp_reg[1]  = 32'h0000_2000;
                    exp_reg[2]  = 32'hddcc_bbaa;
                    exp_reg[3]  = 32'hffff_ffaa;   // lb  offset 0
                    exp_reg[4]  = 32'hffff_ffbb;   // lb  offset 1
                    exp_reg[5]  = 32'hffff_ffcc;   // lb  offset 2
                    exp_reg[6]  = 32'hffff_ffdd;   // lb  offset 3
                    exp_reg[7]  = 32'h0000_00dd;   // lbu offset 3
                    exp_reg[8]  = 32'h0000_00bb;   // lbu offset 1
                    exp_reg[9]  = 32'hffff_bbaa;   // lh  offset 0
                    exp_reg[10] = 32'hffff_ddcc;   // lh  offset 2
                    exp_reg[11] = 32'h0000_ddcc;   // lhu offset 2
                    exp_reg[12] = 32'h0000_bbaa;   // lhu offset 0
                    exp_reg[13] = 32'hddcc_bbaa;   // lw
                end
                4: begin   // prog_load_use：load-use 冒险 + 首条/非访存后 load 的取数（B2）
                    exp_reg[1]  = 32'h0000_2400;
                    exp_reg[2]  = 32'h1122_3344;
                    exp_reg[3]  = 32'h1122_3344;   // lw 紧邻非访存指令后
                    exp_reg[4]  = 32'h2244_6688;
                    exp_reg[5]  = 32'h1122_3344;
                    exp_reg[6]  = 32'h0000_0044;   // lbu
                    exp_reg[7]  = 32'h0000_0044;
                    exp_reg[8]  = 32'h0000_1122;   // lh
                    exp_reg[9]  = 32'h0000_1166;
                    exp_reg[10] = 32'h1122_3344;   // lw（分支条件用它）
                    exp_reg[11] = 32'h0000_600d;
                    exp_reg[13] = 32'h1122_3344;   // lw → sw 数据相关（B5）
                    exp_reg[14] = 32'h1122_3344;
                    exp_reg[15] = 32'h2244_6688;
                end
                5: begin   // prog_loop：后向分支循环（B4：误预测不能被取指 hold 吞掉）
                    exp_reg[1]  = 32'd10;          // i
                    exp_reg[2]  = 32'h37;          // 1..10 累加 = 55
                    exp_reg[3]  = 32'd10;          // n
                    exp_reg[4]  = 32'h41;          // i + acc = 65
                end
                6: begin   // prog_div_pair：背靠背 div/rem（B3：结果与 rd 不能错位）
                    exp_reg[1]  = 32'd100;
                    exp_reg[2]  = 32'd7;
                    exp_reg[3]  = 32'd14;          // 100/7
                    exp_reg[4]  = 32'd1;           // 7/7
                    exp_reg[5]  = 32'd15;          // 1+14
                    exp_reg[6]  = 32'd2;           // 100%7
                    exp_reg[7]  = 32'd17;          // 2+15
                end
                default: have_exp = 1'b0;   // 无现成期望值：只报实测值
            endcase
        end
    endtask

    // ---------------------------------------------------------------------
    // v9 新增：在"原来 report 的那一拍"把需要的东西全部拷进 snap_*
    // ---------------------------------------------------------------------
    task take_snapshot;
        integer j;
        begin
            for (j = 0; j < 32; j = j + 1)
                snap_gpr[j] = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[j];
            snap_mepc     = p_mepc;
            snap_mcause   = p_mcause;
            snap_mstatus  = p_mstatus;
            snap_mtvec    = p_mtvec;
            snap_dram1000 = dram[16'h1000 >> 2];

            // v11（S1）：ICache 已旁路，这两个计数器由 myCPU 内部恒驱 0（端口仍在，见 myCPU.sv）。
            snap_icache_hit    = u_cpu.debug_icache_hit_cnt;
            snap_icache_miss   = u_cpu.debug_icache_miss_cnt;
            snap_dcache_hit    = u_cpu.dcache_hit_cnt;
            snap_dcache_miss   = u_cpu.dcache_miss_cnt;
            snap_bp_pred       = u_cpu.bp_pred_cnt;
            snap_bp_hit        = u_cpu.bp_hit_cnt;
            snap_bp_miss       = u_cpu.bp_miss_cnt;

            snap_wb_events     = wb_events;
            snap_wb_suppressed = wb_suppressed;
            snap_store_events  = store_events;
            snap_load_events   = load_events;
            snap_stall_cycles  = stall_cycles;
            snap_irom_en       = irom_en_cycles;
            snap_ifu_deliver   = ifu_deliver_cycles;
            snap_qmax          = ifu_qmax;
            snap_redirect_cnt  = redirect_cnt;
            snap_cycle         = cycle;
            snap_done          = 1;
        end
    endtask

    // ---------------------------------------------------------------------
    // 结束报告：寄存器快照 + 期望比对 + 计数器
    // ---------------------------------------------------------------------
    task final_report;
        integer i;
        integer nfail;
        integer npass;
        logic [31:0] v;
        begin
            // 兜底：如果没能在 drain_cycles 那一拍取到快照（例如极小的 drain），
            //   就在此刻现场取一次，行为与旧版一致。
            if (!snap_done) take_snapshot;

            $display("");
            $display("==================== WRITEBACK EVENT SUMMARY ====================");
            $display("  wb events (dedup)   = %0d", snap_wb_events);
            $display("  wb repeats removed  = %0d  (same event held over stall cycles)", snap_wb_suppressed);
            $display("  store accesses      = %0d", snap_store_events);
            $display("  load  accesses      = %0d", snap_load_events);
            $display("  IFU_stall cycles    = %0d", snap_stall_cycles);
            $display("  IROM irom_en cycles = %0d / %0d  (%0d%%)   <- v10 读使能门控",
                     snap_irom_en, snap_cycle,
                     (snap_cycle == 0) ? 0 : (snap_irom_en * 100 / snap_cycle));
            $display("  IFU delivered       = %0d / %0d  (%0d%%)   <- 1 条/拍上限",
                     snap_ifu_deliver, snap_cycle,
                     (snap_cycle == 0) ? 0 : (snap_ifu_deliver * 100 / snap_cycle));
            $display("  IFU queue max depth = %0d (QDEPTH=4)", snap_qmax);
            $display("  redirects (dnpc)    = %0d", snap_redirect_cnt);
            if (ecall_cycle >= 0)
                $display("  ecall decoded at cyc= %0d  (snapshot at +%0d, PC window +%0d)",
                         ecall_cycle, drain_cycles, ECALL_REDIR_CYCLES);
            else
                $display("  ecall               = NOT SEEN (stopped by timeout)");

            $display("");
            $display("==================== GPR SNAPSHOT x0..x31 ====================");
            $display("  (hier path: u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[])");
            nfail = 0;
            npass = 0;
            for (i = 0; i < 32; i = i + 1) begin
                v = snap_gpr[i];
                if (have_exp) begin
                    if (v === exp_reg[i]) begin
                        npass = npass + 1;
                        $display("  x%0d  = 0x%h  (%0d)   [PASS]  exp=0x%h", i, v, v, exp_reg[i]);
                    end else begin
                        nfail = nfail + 1;
                        $display("  x%0d  = 0x%h  (%0d)   [FAIL]  exp=0x%h", i, v, v, exp_reg[i]);
                    end
                end else begin
                    $display("  x%0d  = 0x%h  (%0d)   [MEASURED]  (no reference values)", i, v, v);
                end
            end

            $display("");
            $display("==================== CSR / MEMORY ====================");
            $display("  [snapshot taken at cycle %0d, before the post-ecall restart]", snap_cycle);
            $display("  mepc     = 0x%h", snap_mepc);
            $display("  mcause   = 0x%h   (11 = ecall exception)", snap_mcause);
            $display("  mstatus  = 0x%h", snap_mstatus);
            $display("  mtvec    = 0x%h", snap_mtvec);
            $display("  dram[0x1000] = 0x%h", snap_dram1000);
            if (have_exp_dram) begin
                if (snap_dram1000 === exp_dram) begin
                    npass = npass + 1;
                    $display("  dram[0x1000] check  [PASS]  exp=0x%h", exp_dram);
                end else begin
                    nfail = nfail + 1;
                    $display("  dram[0x1000] check  [FAIL]  exp=0x%h", exp_dram);
                end
            end
            $display("  ICache(bypassed): hit=%0d miss=%0d", snap_icache_hit, snap_icache_miss);
            $display("  DCache: hit=%0d miss=%0d", snap_dcache_hit, snap_dcache_miss);
            $display("  BPU   : pred=%0d hit=%0d miss=%0d", snap_bp_pred, snap_bp_hit, snap_bp_miss);

            $display("");
            $display("============ v9 BOARD-READINESS CHECKS (new) ============");
            if (store_repeat == 0) begin
                npass = npass + 1;
                $display("  write-once (store not repeated)   [PASS]");
            end else begin
                nfail = nfail + 1;
                $display("  write-once (store not repeated)   [FAIL] repeats=%0d", store_repeat);
            end
            if (fetch_bad == 0) begin
                npass = npass + 1;
                $display("  fetch-align (pc<->inst coherent)  [PASS]");
            end else begin
                nfail = nfail + 1;
                $display("  fetch-align (pc<->inst coherent)  [FAIL] violations=%0d", fetch_bad);
            end
            // 断言③：ecall → mtvec 重定向（上板 ILA 抓出来的真实 bug 的回归保护）
            if (ecall_cycle < 0) begin
                $display("  ecall-redirect (pc -> mtvec)      [SKIP] no ecall seen");
            end else if (ecall_redir_ok) begin
                npass = npass + 1;
                $display("  ecall-redirect (pc -> mtvec)      [PASS] pc hit mtvec=0x%h at +%0d cycles",
                         p_mtvec, ecall_redir_first);
            end else begin
                nfail = nfail + 1;
                $display("  ecall-redirect (pc -> mtvec)      [FAIL] pc never reached mtvec=0x%h in %0d cycles",
                         p_mtvec, ECALL_REDIR_CYCLES);
                $display("        ecall was at IFU_pc=0x%h; post-ecall IFU_pc trace:", ecall_pc_at_id);
                for (i = 0; i < ECALL_REDIR_CYCLES; i = i + 1)
                    $display("          +%0d  ifu_pc=0x%h", i + 1, ecall_pc_trace[i]);
            end

            $display("");
            $display("==================== RESULT ====================");
            $display("  total cycles = %0d", snap_cycle);
            if (!have_exp) begin
                $display("[SELFCHECK] status=NO_EXPECTATION  (measured values only)");
            end else if (nfail == 0) begin
                $display("[SELFCHECK] status=PASS  (%0d/%0d checks passed)", npass, npass + nfail);
            end else begin
                $display("[SELFCHECK] status=FAIL  (%0d mismatched, %0d passed)", nfail, npass);
            end
            $display("===============================================");
            if (ecall_cycle < 0) begin
                $fatal(1, "[SELFCHECK] TIMEOUT: no ecall within %0d cycles", cycle);
            end else if (have_exp && nfail != 0) begin
                $fatal(1, "[SELFCHECK] FAIL: %0d mismatch(es)", nfail);
            end else begin
                $finish;
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // 初始化：清存储器 / 载入程序 / 开波形
    // ---------------------------------------------------------------------
    integer k;
    initial begin
        // ram.v 里 IROM/DRAM 都是零填充（mem[j] = 0），这里保持一致
        for (k = 0; k < IROM_WORDS; k = k + 1) irom[k] = 32'h0000_0000;
        for (k = 0; k < DRAM_WORDS; k = k + 1) dram[k] = 32'h0000_0000;

        prog_path = PROG_FILE;
        vcd_path  = "wave/tb_iverilog.vcd";           // 默认波形名（+vcd= 可覆盖）
        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("vcd=%s",  vcd_path))  ;
        if ($value$plusargs("prog_id=%d", prog_id)) ;
        if ($value$plusargs("max=%d", max_cycles)) ;
        if ($value$plusargs("drain=%d", drain_cycles)) ;
        if ($test$plusargs("no_dedup")) dedup_en = 1'b0;

        load_expectation(prog_id);

        $display("==============================================================");
        $display(" v9 iverilog regression testbench  tb_iverilog");
        $display("   program file : %0s", prog_path);
        $display("   expectation  : prog_id=%0d (%0s)", prog_id,
                 have_exp ? "checking enabled" : "no reference, measured only");
        $display("   max cycles   : %0d   clock 10ns (100MHz)", max_cycles);
        $display("==============================================================");

        $readmemh(prog_path, irom);

        // -----------------------------------------------------------------
        // 【重要】myCPU.sv:537 例化 WBU_inst0 时漏接了 `.stall`：
        // - Verilator 会把未连接的 input 默认接 0（所以 cdp-tests 能过），
        //   iverilog 则让它保持 z → WBU 里 `if (!stall)` 变成 x → 寄存器
        //   永远不更新 → 一条写回都出不来（现象：rf 全是 x、debug_wb 恒 0）。
        //   iverilog -Wall 会直接报：
        //     myCPU.sv:537: warning: Instantiating module WBU with dangling
        //                   input port 14 (stall) floating.
        //   不改 RTL，用层次化 force 把这根线钉到 0（+no_wbu_force 可关闭）。
        // -----------------------------------------------------------------
        //   v10.1 补：RTL 已把 `.stall(1'b0)` 硬接（myCPU.sv:807），force 成了冗余；
        //   而 Verilator 静态检查直接拒绝「对 input 端口 force」(ASSIGNIN)，
        //   所以这一段在 Verilator 下整体跳过 —— 语义等价（都是常数 0）。
`ifdef VERILATOR
        $display("[TB] note: Verilator build, skip force (RTL hardwires .stall(1'b0))");
`else
        if (!$test$plusargs("no_wbu_force")) begin
            force u_cpu.WBU_inst0.stall = 1'b0;
            $display("[TB] workaround: force u_cpu.WBU_inst0.stall = 1'b0  (myCPU.sv:537 leaves .stall open)");
        end
`endif

        // -----------------------------------------------------------------
        // 【重要】RegisterFile.sv:20-22 的寄存器堆没有复位：
        //       always_ff @(posedge clock) if (wen) rf[waddr] <= wdata;
        //   4 态仿真下 rf[0]（即 x0）一直是 x，于是任何以 x0 为源操作数的
        //   指令（addi x2,x0,5 …）都会算出 x，整条数据通路全被 x 污染。
        // - Verilator 是 2 态（未初始化 = 0）、FPGA 上 BRAM 上电也是 0，
        //   所以 cdp-tests / 上板都看不到这个问题。
        //   不改 RTL：在 0 时刻把寄存器堆按“上电初值 0”清一遍（+raw_rf 关闭）。
        // -----------------------------------------------------------------
        if (!$test$plusargs("raw_rf")) begin
            for (k = 0; k < 32; k = k + 1)
                u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[k] = 32'h0000_0000;
            $display("[TB] workaround: register file has no reset; preloaded rf[0:31]=0 (power-up value)");
        end

        $dumpfile(vcd_path);
        $dumpvars(0, tb_iverilog);
        // iverilog 不自动导出存储器数组：32 个通用寄存器逐个显式导出
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[0]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[1]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[2]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[3]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[4]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[6]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[7]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[8]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[9]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[10]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[11]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[12]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[13]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[14]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[15]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[16]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[17]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[18]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[19]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[20]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[21]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[22]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[23]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[25]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[26]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[27]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[28]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[29]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[30]);
        $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[31]);
        // prog.hex 的 sw 目标字（0x1000 -> word 1024）也显式导出，方便看写内存
        $dumpvars(0, dram[1024]);

        // 复位：高电平有效，保持 8 拍后释放。
        //   ★ 必须在 **negedge** 释放，不能紧跟在 @(posedge clk) 后面用阻塞赋值：
        //     那等于“在时钟沿那一瞬把 rst 拉低”，与各模块 always_ff 的采样处于
        //     同一仿真时刻 → 复位是否被 FF 看见取决于进程调度顺序（LRM 不保证）。
        //     实测：iverilog 12.0 的 FF 在那一拍仍看到 rst=1，Verilator 5.020 看到
        //     rst=0，于是整条流水线整体差 1 拍（WB 首事件 cyc=10 vs cyc=9），
        //     而所有功能结果一致 —— 典型复位竞争。放到 negedge 后两套仿真器逐拍一致。
        rst = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        $display("[TB] reset released at cycle boundary, start running...");
    end

    // ---------------------------------------------------------------------
    // 逐拍监控：时钟下降沿采样（与 cdp-tests 读 debug_wb_* 的时刻一致）
    // ---------------------------------------------------------------------
    logic [31:0] inst_at_wb;
    always @(negedge clk) begin
        if (!rst && !frozen) begin
            cycle = cycle + 1;

            if (u_cpu.IFU_stall) stall_cycles = stall_cycles + 1;
            // v10：IROM 读使能门控的实测口径 —— cpu_req 为 1 的拍才真的读 BRAM。
            //   改造前 mem_en 上电后恒为 1，这个比值应该接近 100%。
            if (u_cpu.icache_mem_en) irom_en_cycles = irom_en_cycles + 1;
            if (u_cpu.IFU_Inst0.advance_en) ifu_deliver_cycles = ifu_deliver_cycles + 1;
            if (u_cpu.IFU_Inst0.q_cnt > ifu_qmax) ifu_qmax = u_cpu.IFU_Inst0.q_cnt;

            // ---- 写回事件：同一事件连续保持多拍时只打印一次 ----
            if (dbg_have_inst) begin
                if (!dedup_en ||
                    !(prev_have && (dbg_pc === prev_pc) && (dbg_reg === prev_reg)
                                  && (dbg_value === prev_val) && (dbg_ena === prev_ena))) begin
                    wb_events = wb_events + 1;
                    inst_at_wb = irom[dbg_pc[13:2]];
                    $display("[WB ] cyc=%0d pc=%h inst=%h %0s ena=%0d reg=x%0d val=%h",
                             cycle, dbg_pc, inst_at_wb, disasm(inst_at_wb),
                             dbg_ena, dbg_reg, dbg_value);
                end else begin
                    // 流水线冻结（load-use 暂停等）时写回口保持多拍 → 去重，不刷屏
                    wb_suppressed = wb_suppressed + 1;
                end
            end
            prev_have = dbg_have_inst;
            prev_pc   = dbg_pc;
            prev_reg  = dbg_reg;
            prev_val  = dbg_value;
            prev_ena  = dbg_ena;

            // ---- 访存事件 ----
            if (perip_wen) begin
                store_events = store_events + 1;
                $display("[ST ] cyc=%0d addr=%h mask=%b wdata=%h", cycle, perip_addr, perip_mask, perip_wdata);
                // 断言①：perip_wen 必须是单拍脉冲，不得连续两拍把**同一笔写**发两次。
                //   ★ 不能只看地址：`sh x6,0(x2)` 紧跟 `sb x7,2(x2)` 是两条不同的 store，
                //     地址（同一个字）相同但数据/掩码不同，属于正常行为（v10.1 用随机
                //     差分测出来的误判 —— 当时地址相同即报错，把合法程序判成失败）。
                //     真正的重复写是「地址 + 数据 + 掩码」全都一样。
                if (prev_store_wen && (perip_addr === prev_store_addr)
                    && (perip_wdata === prev_store_wdata) && (perip_mask === prev_store_mask)) begin
                    store_repeat = store_repeat + 1;
                    $display("[CHK] cyc=%0d FAIL write-once: perip_wen held 2+ cycles at addr=%h data=%h mask=%b",
                             cycle, perip_addr, perip_wdata, perip_mask);
                end
            end
            prev_store_wen   = perip_wen;
            prev_store_addr  = perip_addr;
            prev_store_wdata = perip_wdata;
            prev_store_mask  = perip_mask;

            // 断言②：同一 PC 上重复交付的指令必须一致（缓存不得交付别的地址的数据）
            if (u_cpu.IFU_valid) begin
                if (prev_fetch_vld && (u_cpu.IFU_pc === prev_fetch_pc)
                                   && (u_cpu.IFU_inst !== prev_fetch_inst)) begin
                    fetch_bad = fetch_bad + 1;
                    $display("[CHK] cyc=%0d FAIL fetch-align: pc=%h inst changed %h -> %h while pc held",
                             cycle, u_cpu.IFU_pc, prev_fetch_inst, u_cpu.IFU_inst);
                end
                prev_fetch_pc   = u_cpu.IFU_pc;
                prev_fetch_inst = u_cpu.IFU_inst;
                prev_fetch_vld  = 1'b1;
            end else begin
                prev_fetch_vld = 1'b0;
            end

            // load 请求发生在 LSU 的 M2 级（DCache 的 cpu_en 项之一）
            if (u_cpu.LSU_mem_ren_pipe) load_events = load_events + 1;

            // ---- 重定向（分支预测失败 / jal / jalr / ecall / mret / 中断）----
            if (u_cpu.dnpc_flag) begin
                redirect_cnt = redirect_cnt + 1;
                $display("[RDR] cyc=%0d dnpc=%h mispredict=%b ecall=%b mret=%b intr=%b",
                         cycle, u_cpu.dnpc, u_cpu.bp_mispredict,
                         u_cpu.IDU_ecall_flag, u_cpu.IDU_mret_flag, u_cpu.intr_take);
            end

            // ---- 程序结束标志：ecall 出现在译码级 ----
            if (u_cpu.IDU_ecall_flag && ecall_cycle < 0) begin
                ecall_cycle   = cycle;
                ecall_pc_at_id = u_cpu.IFU_pc;
                $display("[END] ecall reached ID at cyc=%0d id_pc=%h (snapshot after DRAIN=%0d cycles)",
                         cycle, u_cpu.IDU_pc, drain_cycles);
            end

            // ---- 断言③：ecall 之后逐拍跟踪 IFU_pc，必须见到 mtvec ----
            //   同时把 dnpc_flag / ready 打出来：如果 PC 没被拨走，这两个量直接
            //   告诉我们"重定向请求根本没来"还是"来了但被 ready 吃掉"。
            if (ecall_cycle >= 0) begin
                if (ecall_redir_polls < ECALL_REDIR_CYCLES) begin
                    ecall_pc_trace[ecall_redir_polls] = u_cpu.IFU_pc;
                    $display("[EPC] cyc=%0d +%0d ifu_pc=%h dnpc_flag=%b dnpc=%h ifu_ready=%b ifu_valid=%b ifu_stall=%b ecall=%b trap_take=%b mtvec=%h",
                             cycle, ecall_redir_polls + 1, u_cpu.IFU_pc,
                             u_cpu.dnpc_flag, u_cpu.dnpc, u_cpu.IDU_ready,
                             u_cpu.IFU_valid, u_cpu.IFU_stall, u_cpu.IDU_ecall_flag,
                             u_cpu.trap_take, p_mtvec);
                    if (u_cpu.IFU_pc === p_mtvec && ecall_redir_first < 0) begin
                        ecall_redir_ok    = 1;
                        ecall_redir_first = ecall_redir_polls + 1;
                    end
                    ecall_redir_polls = ecall_redir_polls + 1;
                end
            end

            // ---- 停止条件 ----
            if (ecall_cycle >= 0) begin
                drain_cnt = drain_cnt + 1;
                // 在"旧版 report 的那一拍"取报告快照：此后程序会从 mtvec 重新执行，
                //   再做任何现场读取都会读到第二轮的值。
                if (drain_cnt == drain_cycles && !snap_done) take_snapshot;
                if (drain_cnt >= drain_cycles + ECALL_REDIR_CYCLES) begin
                    frozen = 1'b1;
                    final_report;
                end
            end else if (cycle >= max_cycles) begin
                $display("[END] reached max cycles %0d without seeing ecall", max_cycles);
                frozen = 1'b1;
                final_report;
            end
        end
    end

`ifdef RAS_DBG
    // 临时探针：确认 call/ret 分类与 bp_update_en 的**相位**（见 v11 S4）
    always @(posedge clk) begin
        if (u_cpu.bp_update_en)
            $display("[RAS] cyc=%0d pc=%h idu_inst=%h call=%b ret=%b sp=%0d taken=%b",
                     cycle, u_cpu.EXU_pc, u_cpu.IDU_inst_d,
                     u_cpu.bp_is_call, u_cpu.bp_is_ret, u_cpu.BPU_inst.ras_sp,
                     u_cpu.bp_update_taken);
        if (u_cpu.IFU_fetch_pc == 32'h54)
            $display("[PRED] cyc=%0d tgt=%h taken=%b is_ret=%b kind=%b sp=%0d top=%h",
                     cycle, u_cpu.bp_pred_target, u_cpu.bp_pred_taken,
                     u_cpu.BPU_inst.pred_is_ret, u_cpu.BPU_inst.btb_kind[6'h15],
                     u_cpu.BPU_inst.ras_sp, u_cpu.BPU_inst.ras_top);
    end
`endif

endmodule
