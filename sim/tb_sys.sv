// =============================================================================
// sim/tb_sys.sv — v10.2 系统指令专项检查台（CSR / 中断 / fence.i / ebreak）
// -----------------------------------------------------------------------------
// 为什么单独写一个（而不是塞进 tb_iverilog 的 prog_id 期望表）：
//   tb_iverilog 判的是"程序跑完 32 个寄存器对不对"，而这些用例要判的是**过程**：
//   陷入了几次、中断收了几次、mcause 是 0x8000_0007 还是 3、mepc 指到哪、
//   fence.i 有没有把 I-Cache 清掉、有没有误跳 mtvec。
//
// 用法：
//   vvp tb_sys.vvp +prog=sim/sys_csr.hex    +kind=csr
//   vvp tb_sys.vvp +prog=sim/sys_intr.hex   +kind=intr
//   vvp tb_sys.vvp +prog=sim/sys_fencei.hex +kind=fencei
//   vvp tb_sys.vvp +prog=sim/sys_ebreak.hex +kind=ebreak
//   vvp tb_sys.vvp +prog=sim/sys_zicsr.hex  +kind=zicsr
//   vvp tb_sys.vvp +prog=sim/sys_zicntr.hex +kind=zicntr   （v12（B）Zicntr）
//
// 观测方式（全部走 myCPU 顶层 debug 端口 + 少量 XMR）：
//   * debug_trap_take 上升沿 = 一次**同步异常**被确认（ebreak 走这条）；
//   * u_cpu.intr_take 上升沿 = 一次**中断**被接收（中断不走 trap_take）；
//   * u_cpu.icache_clr 上升沿 = fence.i 清了一次 I-Cache；
//   * 程序收尾统一 `addi x10,x0,1`，测试台在**看到 x10 写回 1 的那一拍**取现场
//     （此后程序原地自跳，不会再写坏现场）。
// =============================================================================
`timescale 1ns / 1ps

module tb_sys;

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
    logic [31:0] dbg_mcause, dbg_mepc, dbg_mtval;
    logic        dbg_trap_take;
    logic [31:0] dbg_icache_miss, dbg_icache_hit;

    // ------------------------------------------------------------------ 存储
    localparam IROM_WORDS = 4096;
    localparam DRAM_WORDS = 4096;
    logic [31:0] irom [0:IROM_WORDS-1];
    logic [31:0] dram [0:DRAM_WORDS-1];

    always_ff @(posedge clk) irom_data <= irom[irom_addr[13:2]];

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
        .debug_icache_hit_cnt  (dbg_icache_hit),
        .debug_icache_miss_cnt (dbg_icache_miss),
        .debug_dcache_hit_cnt  (),
        .debug_dcache_miss_cnt (),
        .debug_mcause       (dbg_mcause),
        .debug_mepc         (dbg_mepc),
        .debug_mtval        (dbg_mtval),
        .debug_trap_take    (dbg_trap_take)
    );

    // ------------------------------------------------------------------ 采样
    integer      cycle = 0;
    integer      max_cycles = 1200;
    integer      trap_cnt = 0;      // 同步异常（trap_take）次数
    integer      intr_cnt = 0;      // 中断（intr_take）次数
    integer      clr_cnt  = 0;      // fence.i 清 I-Cache 次数
    integer      npass = 0, nfail = 0;

    logic prev_trap = 1'b0;
    logic prev_intr = 1'b0;
    logic prev_clr  = 1'b0;

    // 陷入/中断那一刻的 CSR 现场（trap_take/intr_take 当拍 CSR 还没落盘，下一拍再采）
    logic        trap_edge = 1'b0;
    logic        intr_edge = 1'b0;
    logic [31:0] mcause1 = 32'hDEAD_BEEF, mepc1 = 32'hDEAD_BEEF, mtval1 = 32'hDEAD_BEEF;
    logic [31:0] mcauseL = 32'hDEAD_BEEF;
    logic        fencei_bad_dnpc = 1'b0;   // fence.i 当拍 dnpc == mtvec（说明跳去异常入口了）

    // 程序收尾时抓的现场
    logic        snap_done = 1'b0;
    logic [31:0] s_r5, s_r6, s_r7, s_r8, s_r9, s_r11, s_r12, s_r13, s_r14, s_r15;
    logic [31:0] s_r16, s_r17, s_r18, s_r19, s_r25, s_r26;
    logic [31:0] s_r28_inst_addr;
    logic [31:0] s_r27_hartid;
    logic [31:0] s_r30_mimpid, s_r31_mconfigptr;
    logic [31:0] s_r20, s_r21, s_r22, s_r23, s_r24;

    reg [8*260-1:0] prog_path = "sim/sys_csr.hex";
    reg [8*40-1:0]  kind      = "csr";

    integer k;
    initial begin
        for (k = 0; k < IROM_WORDS; k = k + 1) irom[k] = 32'h0000_0000;
        for (k = 0; k < DRAM_WORDS; k = k + 1) dram[k] = 32'h0000_0000;
        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("kind=%s", kind))      ;
        $readmemh(prog_path, irom);
        $display("================================================================");
        $display(" tb_sys : program=%0s  kind=%0s", prog_path, kind);
        $display("================================================================");
        rst = 1'b1;
        repeat (8) @(posedge clk);
        // negedge 释放：见 tb_iverilog.sv 同处注释（沿上释放是复位竞争）
        // ★ 再延 1ns：negedge 那一沿"采样块看到 rst=1 还是 0"本身也是竞争（两套仿真器
        //   调度不同 → 计数器整体差 1，实测 dCYC=-1）。推到沿之后就没有歧义。
        //   ★ 写注释时注意：行首 `//` + 空白 + "Verilator" 会被当成 Verilator 元注释指令
        //     （大小写不敏感），Verilator 直接编译失败 —— 所以这一行不能以那个词开头。
        @(negedge clk);
        #1 rst = 1'b0;
    end

    // 逐拍采样：时钟下降沿
    always @(negedge clk) begin
        if (!rst) begin
            cycle = cycle + 1;

            if ($test$plusargs("wbtrace") && dbg_have_inst) begin
                $display("  [WB] cyc=%0d pc=%h ena=%b reg=x%0d val=%h",
                         cycle, dbg_pc, dbg_ena, dbg_reg, dbg_value);
            end

            // v12（B）调试口：打印每一次真正到达 WB 的 CSR 写（位图 + 写数据）。
            //   `csrw mcycle` 这类"写没写进去"的问题，只看寄存器结果分不清是
            //   "位图没置"还是"数据不对"，这里把两者打在同一行。
            if ($test$plusargs("csrwtr") && (u_cpu.WBU_csr_wen != 16'd0)) begin
                $display("  [CSRW] cyc=%0d wen=%h csrd=%h", cycle,
                         u_cpu.WBU_csr_wen, u_cpu.WBU_csrd);
            end
            if ($test$plusargs("cntrtr")) begin
                $display("  [CNTR] cyc=%0d mcycle=%h minstret=%h", cycle,
                         u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mcycle_reg,
                         u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.minstret_reg);
            end

            // ---- 同步异常（trap_take）----
            if (dbg_trap_take && !prev_trap) begin
                trap_cnt = trap_cnt + 1;
                $display("[TRAP%0d] cyc=%0d ex_pc=%h fault_inst=%h illegal=%b",
                         trap_cnt, cycle, u_cpu.EXU_pc, u_cpu.EXU_fault_inst,
                         u_cpu.EXU_illegal_exc);
            end
            trap_edge <= (dbg_trap_take && !prev_trap);
            prev_trap <= dbg_trap_take;
            if (trap_edge) begin
                if (trap_cnt == 1) begin
                    mcause1 = dbg_mcause; mepc1 = dbg_mepc; mtval1 = dbg_mtval;
                end
                mcauseL = dbg_mcause;
                $display("[TRAP%0d-CSR] cyc=%0d mcause=%h mepc=%h mtval=%h",
                         trap_cnt, cycle, dbg_mcause, dbg_mepc, dbg_mtval);
            end

            // ---- 中断（intr_take，不走 trap_take）----
            if (u_cpu.intr_take && !prev_intr) begin
                intr_cnt = intr_cnt + 1;
                $display("[INTR%0d] cyc=%0d IDpc=%h mcause_next=%h",
                         intr_cnt, cycle, u_cpu.IDU_pc, dbg_mcause);
            end
            intr_edge <= (u_cpu.intr_take && !prev_intr);
            prev_intr <= u_cpu.intr_take;
            if (intr_edge) begin
                if (intr_cnt == 1) begin
                    mcause1 = dbg_mcause; mepc1 = dbg_mepc; mtval1 = dbg_mtval;
                end
                mcauseL = dbg_mcause;
                $display("[INTR%0d-CSR] cyc=%0d mcause=%h mepc=%h", intr_cnt, cycle,
                         dbg_mcause, dbg_mepc);
            end

            // ---- fence.i 清 I-Cache ----
            // ★ v11（S1）：ICache 已旁路，myCPU 里不再有 icache_clr 这根线；但 Control 仍然
            //   产出它（端口保留，见 myCPU.sv），所以直接从 Control 层次取，判据不变。
            if (u_cpu.Control_inst0.icache_clr && !prev_clr) begin
                clr_cnt = clr_cnt + 1;
                $display("[FENCEI%0d] cyc=%0d EXU_pc=%h dnpc=%h dnpc_flag=%b mcause_next=%h",
                         clr_cnt, cycle, u_cpu.EXU_pc, u_cpu.dnpc, u_cpu.dnpc_flag,
                         u_cpu.IDU_mcause_out);
                // ★ 判据：fence.i 的重定向目标必须是它自己后面的那条指令，不能是 mtvec
                if (u_cpu.dnpc == u_cpu.IDU_mtvec_out)
                    fencei_bad_dnpc = 1'b1;
                if (u_cpu.dnpc != (u_cpu.EXU_pc + 32'd4))
                    fencei_bad_dnpc = 1'b1;
            end
            prev_clr <= u_cpu.Control_inst0.icache_clr;

            // ---- 程序收尾：x10 写回 1 的那一拍取现场 ----
            if (dbg_have_inst && dbg_ena && dbg_reg == 5'd10 && dbg_value == 32'd1
                && !snap_done) begin
                s_r5  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5];
                s_r6  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[6];
                s_r7  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[7];
                s_r8  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[8];
                s_r9  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[9];
                s_r11 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[11];
                s_r12 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[12];
                s_r13 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[13];
                s_r14 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[14];
                s_r15 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[15];
                s_r16 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[16];
                s_r17 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[17];
                s_r18 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[18];
                s_r19 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[19];
                s_r20 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[20];
                s_r21 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[21];
                s_r22 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[22];
                s_r23 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[23];
                s_r24 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24];
                s_r25 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[25];
                s_r26 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[26];
                s_r28_inst_addr = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[28];
                s_r27_hartid = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[27];
                s_r30_mimpid = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[30];
                s_r31_mconfigptr = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[31];
                snap_done = 1'b1;
                repeat (6) @(posedge clk);
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
        begin
            $display("");
            $display("------------ system checks (kind=%0s) ------------", kind);
            $display("  trap events = %0d   intr events = %0d   icache_clr = %0d",
                     trap_cnt, intr_cnt, clr_cnt);
            $display("  first : mcause=%h mepc=%h mtval=%h", mcause1, mepc1, mtval1);
            $display("  last  : mcause=%h", mcauseL);
            $display("  regs  : x5=%h x6=%h x7=%h x8=%h x9=%h x11=%h",
                     s_r5, s_r6, s_r7, s_r8, s_r9, s_r11);
            $display("          x12=%h x13=%h x14=%h x15=%h x16=%h x17=%h",
                     s_r12, s_r13, s_r14, s_r15, s_r16, s_r17);
            $display("          x18=%h x19=%h x20=%h x21=%h x22=%h x23=%h x24=%h x25=%h x26=%h",
                     s_r18, s_r19, s_r20, s_r21, s_r22, s_r23, s_r24, s_r25, s_r26);
            $display("          x28=%h x27=%h x30=%h x31=%h (addr/hartid/mimpid/mconfigptr, zicsr)",
                     s_r28_inst_addr, s_r27_hartid, s_r30_mimpid, s_r31_mconfigptr);
            $display("  icache: hit=%0d miss=%0d", dbg_icache_hit, dbg_icache_miss);
            $display("  total cycles = %0d", cycle);

            // ★ 判据名字只用 ASCII：iverilog 12.0 的 $display 会把 UTF-8 每个字节展开成
            //   `ff ff ff XX`（od 有证据），含中文的字符串在日志里就是一堆 0xff，
            //   而 xcheck.sh 的签名归一化又会把第一个非 ASCII 字节之后整段丢掉。
            if (kind == "csr") begin
                chk("no traps: all CSR forms legal",        trap_cnt == 0);
                chk("csrrw returns old value 0",            s_r5  == 32'h0);
                chk("csrr right after csrw sees new (fwd)", s_r7  == 32'h12345678);
                chk("csrrs returns old value",              s_r8  == 32'h12345678);
                chk("csrrs sets bits -> 0x1234F678",        s_r9  == 32'h1234F678);
                chk("csrrc returns old value",              s_r11 == 32'h1234F678);
                chk("csrrc rs1=x0 is pure read",            s_r12 == 32'h12340678);
                chk("csrrc cleared only the given bits",    s_r13 == 32'h12340678);
                chk("csrrwi returns old value",             s_r14 == 32'h12340678);
                chk("csrrwi wrote uimm=31",                 s_r15 == 32'd31);
                chk("csrrsi returns old value",             s_r16 == 32'd31);
                chk("csrrci clears bit1 -> 29",             s_r17 == 32'd29);
                chk("read-only CSR with rs1!=0 -> readval", s_r18 == 32'h79737978);
                chk("marchid is read-only",                 s_r19 == 32'h016FBCBD);
                chk("mtimecmp reset value all ones",        s_r25 == 32'hFFFFFFFF);
                chk("mstatus reset MPP=M",                  s_r26 == 32'h00001800);
            end
            else if (kind == "intr") begin
                chk("two interrupts taken",                 intr_cnt == 2);
                chk("no sync traps",                        trap_cnt == 0);
                chk("sum 55: interrupted insn re-executed", s_r5  == 32'd55);
                chk("second sum 25",                        s_r6  == 32'd25);
                chk("last mcause = MTI (0x80000007)",       mcauseL == 32'h8000_0007);
                chk("handler ran twice (x23 == 2)",         s_r23 == 32'd2);
                chk("mstatus in handler: MIE=0 MPIE=1",     s_r24 == 32'h00001880);
                chk("program continued after both mret",    s_r26 == 32'h5A);
                chk("mepc inside main program",             s_r21 < 32'h300);
            end
            else if (kind == "fencei") begin
                chk("fence.i did not jump to mtvec",        trap_cnt == 0);
                chk("icache cleared 3 times",               clr_cnt == 3);
                chk("fence.i redirect target == PC+4",      fencei_bad_dnpc == 1'b0);
                chk("execution continued after fence.i",    s_r5 == 32'd3);
                chk("fence.i inside loop works",            s_r6 == 32'd7);
            end
            else if (kind == "ebreak") begin
                chk("ebreak trapped exactly once",          trap_cnt == 1);
                chk("mcause == 3 (breakpoint)",             mcause1 == 32'd3);
                chk("mtval == mepc (both point at ebreak)", mtval1 == mepc1);
                chk("mepc 4-byte aligned and in program",   mepc1[1:0] == 2'b00 && mepc1 < 32'h300);
                chk("handler saved mcause=3",               s_r20 == 32'd3);
                // handler 把 x21 当成"mepc+4"的临时寄存器用（跳过出错指令），
                // 所以快照里 x21 = mepc+4，x22 才是原始的 mepc 值
                chk("handler saved mtval == mepc",          s_r22 == s_r21 - 32'd4);
                chk("handler counted 1 trap",               s_r23 == 32'd1);
                chk("resumed after ebreak",                 s_r5  == 32'd8);
                chk("recovery marker x26 == 0x33",          s_r26 == 32'h33);
            end
            else if (kind == "zicsr") begin
                // ---- 陷入计数：只读地址的写尝试(2) + 立即数写只读(1) + 不存在 CSR 读/写(2)
                //      + funct3=100(1) = 6。多一次少一次都说明"哪些该陷入"判错了。 ----
                chk("exactly 6 illegal-insn traps",          trap_cnt == 6);
                chk("first trap is illegal (mcause=2)",      mcause1 == 32'd2);
                chk("handler counted 6 traps",               s_r23 == 32'd6);
                chk("last mcause = 2 (funct3=100)",          s_r20 == 32'd2);
                // mtval = SYSTEM funct3=100 的那条编码 0x3400_4073；mepc 精确指向它本身
                chk("mtval = illegal insn encoding",         s_r22 == 32'h3400_4073);
                chk("mepc points at the insn itself",        s_r28_inst_addr == s_r21 - 32'd4);
                // ---- 只读 CSR：纯读合法、写尝试陷入且零副作用 ----
                chk("csrrs x0 ro-csr: legal, reads id",      s_r5  == 32'h79737978);
                chk("csrrw ro-csr trapped, rd not written",  s_r6  == 32'd0);
                chk("csrrs rs1!=0 ro-csr trapped, rd clean", s_r7  == 32'd0);
                chk("csrrsi uimm=0 on ro-csr: legal read",   s_r8  == 32'h016FBCBD);
                chk("csrrci uimm!=0 ro-csr trapped, rd clean", s_r9 == 32'd0);
                chk("trapped write left mvendorid intact",   s_r19 == 32'h79737978);
                // ---- 不存在的 CSR ----
                chk("read of non-existent CSR trapped",      s_r11 == 32'd0);
                // ---- misa ----
                chk("misa readable = RV32IM",                s_r12 == 32'h4000_1100);
                chk("csrrw misa returns old, write ignored", s_r13 == 32'h4000_1100);
                chk("misa unchanged after write",            s_r14 == 32'h4000_1100);
                chk("mhartid readable = 0, no trap",         s_r27_hartid == 32'd0);
                chk("mimpid readable = 0, no trap",          s_r30_mimpid == 32'd0);
                chk("mconfigptr readable = 0, no trap",      s_r31_mconfigptr == 32'd0);
                // ---- 可写性（v10.3 补的两个写位）----
                chk("mtval is software-writable",            s_r15 == 32'hDEADBEEF);
                chk("csrrw rd=x0 still writes the CSR",      s_r16 == 32'h55AA55AA);
                chk("mtime is software-writable",            s_r17 == 32'h1000);
                // ---- WARL ----
                chk("mip: only MSIP writable (via fwd)",      s_r18 == 32'd1);
                chk("mip: only MSIP writable (via reg)",      s_r26 == 32'd1);
                chk("resumed after all traps",               s_r25 == 32'h600D);
            end
            else if (kind == "zicntr") begin
                // ---- v12（B）Zicntr：mcycle / minstret（64 位，低高两个 CSR）----
                //   ★ 关键判据是 Z1 的 x7：直线代码里 8 条 addi 夹在两次 csrr minstret
                //     之间，差值必须**恰好 9**。这是"每条指令 +1"的唯一硬证据 —— 把停拍
                //     数进去、或按 WB 电平重复计数，都会让这个数偏大。
                chk("exactly 1 trap (write to cycle)",        trap_cnt == 1);
                chk("mcause == 2 (illegal insn)",             mcause1 == 32'd2);
                chk("handler ran once",                       s_r23 == 32'd1);
                chk("minstret delta over 8 addi == 9",        s_r7  == 32'd9);
                chk("csrw mcycle then csrr reads 0 (fwd)",    s_r8  == 32'd0);
                chk("csrw mcycleh then csrr reads 0 (fwd)",   s_r9  == 32'd0);
                chk("mcycle register really cleared (<=16)",  s_r11 <= 32'd16);
                chk("cycleh reads 0",                         s_r12 == 32'd0);
                chk("instret readable, <= minstret",          s_r14 >= s_r13 && s_r13 > 32'd0);
                chk("time readable (1MHz wall clock)",        s_r15 <= 32'd4);
                chk("timeh reads 0 (mtime is 32-bit)",        s_r16 == 32'd0);
                chk("trapped csrw cycle: rd not written",     s_r17 == 32'd0);
                chk("minstret kept counting after the trap",  s_r18 >  s_r14);
                chk("counted handler instructions too",       s_r19 == s_r18 - s_r14);
                chk("resumed after trap (x25 == 0x600D)",     s_r25 == 32'h600D);
            end

            $display("--------------------------------------------------");
            if (nfail == 0)
                $display("[SYS-SELFCHECK] status=PASS (%0d checks)", npass);
            else
                $display("[SYS-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
            $display("==================================================");
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
