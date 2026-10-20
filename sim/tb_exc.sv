// =============================================================================
// sim/tb_exc.sv — 异常体系（C4）专项检查测试台
// -----------------------------------------------------------------------------
// 为什么单独写一个：
//   sim/tb_msim.sv 是"通用指令回归"（比对 32 个寄存器的期望值表），判据是
//   "结果对不对"。而异常体系要检查的是"过程对不对"—— 陷入了没有、mcause 是
//   不是该有的码、mepc 指向出错指令、mtval 里是出错指令编码还是出错地址。
//   这些都要读 CSR，所以单独写一个只做异常检查的台子，判据更直接。
//
// 用法：
//   vlib work
//   vlog -sv -work work +incdir+. +incdir+experimental <RTL...> sim/tb_exc.sv
//   vsim -c -L work work.tb_exc +prog=sim/exc_illegal.hex +expect_kind=illegal
//
// 支持的程序（由 sim/gen_exc_progs.py 生成）：
//   +expect_kind=illegal     : 非法指令，  期望 trap 次数=1, mcause=2,  mtval=00000000
//   +expect_kind=misalign    : 非对齐访存，期望 trap 次数=2, mcause 序列 4→6,
//                          mtval 序列 0x402→0x403
//   +expect_kind=jal_misalign: 非对齐跳转，期望 trap 次数=1, mcause=0,  mtval=0x...26
//
// 观测方式（**不依赖层次化引用**，全部走 myCPU 的顶层 debug 端口）：
//   * debug_trap_take 的上升沿 = 一次陷入被确认；
//   * debug_mcause / debug_mepc / debug_mtval = 当前登记值。
//   陷阱处理程序把每次的 mcause/mtval 抄进 x20..x23，所以也可以直接看寄存器。
// =============================================================================
`timescale 1ns / 1ps

module tb_exc;

    // ------------------------------------------------------------------ 时钟
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;          // 10ns 周期 = 100MHz

    // ------------------------------------------------------- DUT 接口
    logic [31:0] irom_addr, irom_data;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic        perip_wen, perip_ren;
    logic [ 1:0] perip_mask;

    logic        dbg_have_inst, dbg_ena;
    logic [31:0] dbg_pc, dbg_value;
    logic [ 4:0] dbg_reg;

    // v9 新增（C4）：异常现场观察口
    logic [31:0] dbg_mcause, dbg_mepc, dbg_mtval;
    logic        dbg_trap_take;

    // ------------------------------------------------------------------ 存储
    // IROM：同步读（1 拍延迟），与 ICache 的时序假设一致
    localparam IROM_WORDS = 4096;
    logic [31:0] irom [0:IROM_WORDS-1];
    always_ff @(posedge clk) irom_data <= irom[irom_addr[13:2]];

    // DRAM：同步读写，按 mask 合并（够本测试用；异常程序只做非对齐探测，不依赖内容）
    localparam DRAM_WORDS = 4096;
    logic [31:0] dram [0:DRAM_WORDS-1];
    logic [15:0] dram_wa;
    logic [ 1:0] dram_off;
    logic [31:0] dram_raw, dram_din;
    assign dram_wa  = perip_addr[15:2];
    assign dram_off = perip_addr[1:0];
    assign dram_raw = dram[dram_wa];
    always_comb begin
        case (perip_mask)
            2'b00: case (dram_off)
                       2'b00:   dram_din = {dram_raw[31:8],  perip_wdata[7:0]};
                       2'b01:   dram_din = {dram_raw[31:16], perip_wdata[7:0], dram_raw[7:0]};
                       2'b10:   dram_din = {dram_raw[31:24], perip_wdata[7:0], dram_raw[15:0]};
                       default: dram_din = {perip_wdata[7:0], dram_raw[23:0]};
                   endcase
            2'b01: case (dram_off[1])
                       1'b0:    dram_din = {dram_raw[31:16], perip_wdata[15:0]};
                       default: dram_din = {perip_wdata[15:0], dram_raw[15:0]};
                   endcase
            default: dram_din = perip_wdata;
        endcase
    end
    always_ff @(posedge clk) begin
        if (rst)             perip_rdata <= 32'b0;
        else if (perip_ren)  perip_rdata <= dram[dram_wa];
    end
    always @(posedge clk) if (perip_wen) dram[dram_wa] <= dram_din;

    // ------------------------------------------------------------------ DUT
    myCPU u_cpu (
        .cpu_clk            (clk),
        .cpu_rst            (rst),
        .irom_addr          (irom_addr),
        .irom_data          (irom_data),
        .irom_en            (),
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
        .debug_wb_value     (dbg_value),
        .debug_icache_hit_cnt  (),
        .debug_icache_miss_cnt (),
        .debug_dcache_hit_cnt  (),
        .debug_dcache_miss_cnt (),
        .debug_mcause       (dbg_mcause),
        .debug_mepc         (dbg_mepc),
        .debug_mtval        (dbg_mtval),
        .debug_trap_take    (dbg_trap_take)
    );

    // ------------------------------------------------------------------ 运行
    integer      cycle = 0;
    integer      max_cycles = 400;
    integer      trap_cnt = 0;                 // 观察到的 trap_take 上升沿次数
    integer      npass = 0, nfail = 0;
    logic        prev_trap = 1'b0;
    // ★ 采样时序修正（v10）：trap_take 是**当拍**确认、CSR 在那一拍的时钟沿才落盘，
    //   所以在上升沿那一拍读 dbg_mcause 读到的是**陷当前**的旧值。改为检测到上升沿后
    //   **下一拍**再采（用 trap_edge 打一拍）。原写法在这套 RTL 上从没验证过（此前
    //   一次陷入都产生不了），所以这个 off-by-one 一直没暴露。
    logic        trap_edge = 1'b0;
    logic [31:0] mcause1 = 32'hDEAD_BEEF;      // 第 1 次陷入时的 mcause/mtval
    logic [31:0] mtval1  = 32'hDEAD_BEEF;
    logic [31:0] mepc1   = 32'hDEAD_BEEF;
    // 第 1 次陷入**那一拍**的 x24（用于 jal_misalign 的"错路径未被提前执行"检查）。
    //   ★ 检查口径修正：原判据是程序跑完后 x24 != 0xDE，但本测试的处理程序统一做
    //   `mepc += 4` 后 mret —— 对非对齐 jal（在 0x1c）来说 mepc+4 正好落在 0x20 的那条
    //   `addi x24,x0,0xDE` 上，所以**陷入处理完后它本来就会合法执行**，跑完后 x24 必然
    //   等于 0xDE。判据改成"陷入那一刻 x24 还没被写"才是这句话真正想验的东西。
    logic [31:0] trap_r24 = 32'h0;
    // ★ 每次陷入落盘后的 CSR 现场（末次 = 最后一个异常）。用它做"final mcause"检查 ——
    //   不能等到程序末尾再看：本测试程序的收尾是 `ecall`，而 ecall 的 mcause 写发生在
    //   **译码级**（比它自己的写回早 5 拍），所以程序末尾读到的一定是 0xb 而不是异常码。
    logic [31:0] mcauseL = 32'hDEAD_BEEF;
    logic [31:0] mtvalL  = 32'hDEAD_BEEF;

    // ★ 采样时序修正（v10）：程序末尾那条 `ecall` 在正常 RISC-V 语义下**就是**一次陷入
    //   （跳 mtvec）。而本测试程序的 mtvec 指向异常处理程序本身，所以 ecall 之后处理器
    //   会再进一次 handler，把 x20/x23 改掉。原来"看到 x10 写回后再等 12 拍才取现场"
    //   在旧前端（3 拍/条）下恰好赶在 handler 落地之前，现在前端快了 3 倍就赶不上了。
    //   改为在 **x10 写回那一拍立即取现场**（那正是"程序跑完"的时刻），再等几拍让流水
    //   排空后出结论。
    logic        snap_done = 1'b0;
    logic [31:0] s_r20, s_r21, s_r22, s_r23, s_r24, s_r26, s_mcause, s_mtval;

    reg [8*260-1:0] prog_path = "sim/exc_illegal.hex";
    reg [8*40-1:0]  expect_kind    = "illegal";

    integer k;
    initial begin
        for (k = 0; k < IROM_WORDS; k = k + 1) irom[k] = 32'h0000_0000;
        for (k = 0; k < DRAM_WORDS; k = k + 1) dram[k] = 32'h0000_0000;
        if ($value$plusargs("prog=%s",   prog_path)) ;
        if ($value$plusargs("expect_kind=%s", expect_kind))    ;
        if ($test$plusargs("max=%d")) ;             // 保持简单：默认 400 拍足够
        $readmemh(prog_path, irom);
        $display("================================================================");
        $display(" tb_exc : program=%0s  expect_kind=%0s", prog_path, expect_kind);
        $display("================================================================");
        rst = 1'b1;
        repeat (8) @(posedge clk);
        // ★ negedge 释放：见 tb_iverilog.sv 同处注释（沿上释放是复位竞争，
        //   iverilog 与 Verilator 因此整体差 1 拍）。
        @(negedge clk);
        rst = 1'b0;
    end

    // 逐拍采样：时钟下降沿（与 tb_msim 的采样时刻一致）
    always @(negedge clk) begin
        if (!rst) begin
            cycle = cycle + 1;

            // +wbtrace：把每一个"提交"事件打印出来 —— 这是定位"PC 到底跑到哪去了"
            // 最直接的手段（写回端口带有 pc/reg/val）。
            if ($test$plusargs("wbtrace") && dbg_have_inst) begin
                $display("  [WB] cyc=%0d pc=%h ena=%b reg=x%0d val=%h",
                         cycle, dbg_pc, dbg_ena, dbg_reg, dbg_value);
            end

            // 调试开关：+trace 打印每拍关键信号
            if ($test$plusargs("trace") && (cycle < 60 || (cycle > 80 && cycle < 92))) begin
                $display("[cyc%0d] IFpc=%h IFv=%b | IDinst_d=%h IDvd=%b ill=%b | EXpc=%h EXv=%b exc=%b | mepc=%h mtvec=%h mcause=%h mtval=%h | tt=%b fpc=%h cause=%b",
                         cycle, u_cpu.IFU_pc, u_cpu.IFU_valid,
                         u_cpu.IDU_Inst0.inst_d, u_cpu.IDU_valid, u_cpu.IDU_illegal_flag,
                         u_cpu.EXU_pc, u_cpu.EXU_valid,
                         u_cpu.EXU_illegal_exc,
                         u_cpu.IDU_mepc_out, u_cpu.IDU_mtvec_out, u_cpu.IDU_mcause_out,
                         u_cpu.IDU_Inst0.Reg_Stack_inst0.mtval_out,
                         // v10：trap_take_q（补发拍）已整体删除，改看 fault_pc（写 mepc 的源）
                         u_cpu.trap_take, u_cpu.fault_pc, u_cpu.trap_cause);
                $display("          dnpc_flag=%b dnpc=%h mret=%b ecall=%b EXU_inst_clear=%b IFU_stall=%b ready=%b",
                         u_cpu.dnpc_flag, u_cpu.dnpc, u_cpu.IDU_mret_flag, u_cpu.IDU_ecall_flag,
                         u_cpu.EXU_inst_clear, u_cpu.IFU_stall, u_cpu.IDU_ready);
                // v10.2：CSR 读口通路（csrs 原值 / 独热选通 / 前递命中 / 前递后读值）
                $display("          csrs=%h csr_sel=%h csrs_rd=%h rdv=%h fwden=%b fwd=%h",
                         u_cpu.IDU_Inst0.csrs, u_cpu.IDU_Inst0.csr_sel,
                         u_cpu.IDU_Inst0.csrs_rd, u_cpu.IDU_Inst0.rd_value_next,
                         u_cpu.csr_rd_fwd_en, u_cpu.csr_rd_fwd_val);
            end

            // trap_take 上升沿 = 确认接收一次同步异常。CSR 现场在**下一拍**才更新（见 trap_edge）
            if (dbg_trap_take && !prev_trap) begin
                trap_cnt = trap_cnt + 1;
                $display("[TRAP%0d] cyc=%0d (CSR 现场下一拍采) ex_pc=%h fault_inst=%h illegal=%b memmis=%b iaddrmis=%b evalid=%b",
                         trap_cnt, cycle, u_cpu.EXU_pc, u_cpu.EXU_fault_inst,
                         u_cpu.EXU_illegal_exc, u_cpu.EXU_mem_misalign_exc,
                         u_cpu.EXU_iaddr_misalign_exc, u_cpu.EXU_valid);
                if (trap_cnt == 1) trap_r24 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24];
            end
            // 上升沿打一拍：trap_edge 在下一拍为 1，那时 CSR 已经落盘
            trap_edge <= (dbg_trap_take && !prev_trap);
            prev_trap <= dbg_trap_take;
            if (trap_edge) begin
                if (trap_cnt == 1) begin
                    mcause1 = dbg_mcause;
                    mepc1   = dbg_mepc;
                    mtval1  = dbg_mtval;
                end
                mcauseL = dbg_mcause;
                mtvalL  = dbg_mtval;
                $display("[TRAP%0d-CSR] cyc=%0d mcause=%h mepc=%h mtval=%h",
                         trap_cnt, cycle, dbg_mcause, dbg_mepc, dbg_mtval);
            end

            // 程序末尾：x10 = 1 且已 ecall（用写回事件判断）
            if (dbg_have_inst && dbg_ena && dbg_reg == 5'd10 && dbg_value == 32'd1) begin
                // 立即取现场：这一刻正是"程序跑完"的那一拍（之后那条 ecall 会再进 handler）
                s_r20 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[20];
                s_r21 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[21];
                s_r22 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[22];
                s_r23 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[23];
                s_r24 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24];
                s_r26 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[26];
                s_mcause = dbg_mcause;
                s_mtval  = dbg_mtval;
                snap_done = 1'b1;
                repeat (6) @(posedge clk);   // 让流水排空（此时已不影响已取的现场）
                check_and_report();
            end

            if (cycle > max_cycles) begin
                $display("[SELFCHECK] status=TIMEOUT after %0d cycles", cycle);
                nfail = nfail + 1;
                check_and_report();
            end
        end
    end

    task check_and_report();
        reg [31:0] r20, r21, r22, r23, r24, r26, cmcause, cmtval;
        begin
            if (snap_done) begin
                r20 = s_r20; r21 = s_r21; r22 = s_r22; r23 = s_r23; r24 = s_r24; r26 = s_r26;
                cmcause = s_mcause; cmtval = s_mtval;
            end else begin
                r20 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[20];
                r21 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[21];
                r22 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[22];
                r23 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[23];
                r24 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24];
                r26 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[26];
                cmcause = dbg_mcause; cmtval = dbg_mtval;
            end

            $display("");
            $display("------------ exception checks (expect_kind=%0s) ------------", expect_kind);
            $display("  trap events observed      = %0d", trap_cnt);
            $display("  CSR now: mcause=%h mepc=%h mtval=%h", cmcause, dbg_mepc, cmtval);
            $display("  handler saved: x20(mcause)=%h x21(mepc)=%h x22(mtval)=%h x23(cnt)=%0d",
                     r20, r21, r22, r23);
            $display("  first trap   : mcause=%h mepc=%h mtval=%h", mcause1, mepc1, mtval1);
            $display("  last  trap   : mcause=%h mtval=%h   (x24@trap=%h)",
                     mcauseL, mtvalL, trap_r24);

            // ---- 按程序类型逐条判 ----
            if (expect_kind == "illegal") begin
                chk("trap count == 1",            trap_cnt == 1);
                chk("mcause == 2 (illegal)",      mcause1 == 32'd2);
                chk("mtval == 0 (全 0 非法指令)", mtval1  == 32'h0);
                chk("handler mcause == 2",        r20 == 32'd2);
                chk("handler mtval == 0",         r22 == 32'h0);
                chk("handler cnt == 1",           r23 == 32'd1);
                chk("recovered: x24 == 0x55",     r24 == 32'h55);
            end
            else if (expect_kind == "misalign") begin
                chk("trap count == 2",            trap_cnt == 2);
                chk("first  mcause == 4 (load)",  mcause1 == 32'd4);
                chk("first  mtval  == 0x402",     mtval1  == 32'h402);
                chk("final  mcause == 6 (store)", mcauseL == 32'd6);
                chk("final  mtval  == 0x403",     mtvalL  == 32'h403);
                chk("handler x22 == 0x403",       r22 == 32'h403);
                chk("handler cnt == 2",           r23 == 32'd2);
                chk("recovered: x26 == 0x99",     r26 == 32'h99);
            end
            else if (expect_kind == "jal_misalign") begin
                chk("trap count == 1",            trap_cnt == 1);
                chk("mcause == 0 (iaddr mis)",    mcause1 == 32'd0);
                chk("mtval[1:0] == 2 (target+2)", mtval1[1:0] == 2'b10);
                chk("handler cnt == 1",           r23 == 32'd1);
                // 口径见 trap_r24 声明处：验"陷入那一刻错路径还没落地"
                chk("wrong-path NOT committed before trap: x24@trap != 0xDE", trap_r24 != 32'hDE);
            end

            $display("------------------------------------------------------");
            if (nfail == 0)
                $display("[EXC-SELFCHECK] status=PASS (%0d checks)", npass);
            else
                $display("[EXC-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
            $display("======================================================");
            $finish;
        end
    endtask

    task chk(input [8*60-1:0] name, input cond);
        begin
            if (cond) begin
                npass = npass + 1;
                $display("  [PASS] %0s", name);
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

endmodule
