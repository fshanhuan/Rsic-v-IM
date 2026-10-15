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
    logic [31:0] mcause1 = 32'hDEAD_BEEF;      // 第 1 次陷入时的 mcause/mtval
    logic [31:0] mtval1  = 32'hDEAD_BEEF;
    logic [31:0] mepc1   = 32'hDEAD_BEEF;

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
                $display("[cyc%0d] IFpc=%h IFv=%b | IDinst_d=%h IDvd=%b ill=%b | EXpc=%h EXv=%b exc=%b | mepc=%h mtvec=%h mcause=%h mtval=%h | tt=%b ttq=%b cause=%b",
                         cycle, u_cpu.IFU_pc, u_cpu.IFU_valid,
                         u_cpu.IDU_Inst0.inst_d, u_cpu.IDU_valid, u_cpu.IDU_illegal_flag,
                         u_cpu.EXU_pc, u_cpu.EXU_valid,
                         u_cpu.EXU_illegal_exc,
                         u_cpu.IDU_mepc_out, u_cpu.IDU_mtvec_out, u_cpu.IDU_mcause_out,
                         u_cpu.IDU_Inst0.Reg_Stack_inst0.mtval_out,
                         u_cpu.trap_take, u_cpu.trap_take_q, u_cpu.trap_cause);
                $display("          dnpc_flag=%b dnpc=%h mret=%b ecall=%b EXU_inst_clear=%b IFU_stall=%b ready=%b",
                         u_cpu.dnpc_flag, u_cpu.dnpc, u_cpu.IDU_mret_flag, u_cpu.IDU_ecall_flag,
                         u_cpu.EXU_inst_clear, u_cpu.IFU_stall, u_cpu.IDU_ready);
            end

            // trap_take 上升沿 = 确认接收一次同步异常
            if (dbg_trap_take && !prev_trap) begin
                trap_cnt = trap_cnt + 1;
                $display("[TRAP%0d] cyc=%0d mcause=%h mepc=%h mtval=%h", trap_cnt, cycle,
                         dbg_mcause, dbg_mepc, dbg_mtval);
                $display("        ex_pc=%h exu_fault_inst=%h illegal=%b memmis=%b iaddrmis=%b evalid=%b",
                         u_cpu.EXU_pc, u_cpu.EXU_fault_inst, u_cpu.EXU_illegal_exc,
                         u_cpu.EXU_mem_misalign_exc, u_cpu.EXU_iaddr_misalign_exc,
                         u_cpu.EXU_valid);
                if (trap_cnt == 1) begin
                    mcause1 = dbg_mcause;
                    mepc1   = dbg_mepc;
                    mtval1  = dbg_mtval;
                end
            end
            prev_trap = dbg_trap_take;

            // 程序末尾：x10 = 1 且已 ecall（用写回事件判断）
            if (dbg_have_inst && dbg_ena && dbg_reg == 5'd10 && dbg_value == 32'd1) begin
                // 再等几拍让流水排空，然后判定
                repeat (12) @(posedge clk);
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
        reg [31:0] r20, r21, r22, r23;
        begin
            r20 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[20];
            r21 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[21];
            r22 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[22];
            r23 = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[23];

            $display("");
            $display("------------ exception checks (expect_kind=%0s) ------------", expect_kind);
            $display("  trap events observed      = %0d", trap_cnt);
            $display("  CSR now: mcause=%h mepc=%h mtval=%h", dbg_mcause, dbg_mepc, dbg_mtval);
            $display("  handler saved: x20(mcause)=%h x21(mepc)=%h x22(mtval)=%h x23(cnt)=%0d",
                     r20, r21, r22, r23);
            $display("  first trap   : mcause=%h mepc=%h mtval=%h", mcause1, mepc1, mtval1);

            // ---- 按程序类型逐条判 ----
            if (expect_kind == "illegal") begin
                chk("trap count == 1",            trap_cnt == 1);
                chk("mcause == 2 (illegal)",      mcause1 == 32'd2);
                chk("mtval == 0 (全 0 非法指令)", mtval1  == 32'h0);
                chk("handler mcause == 2",        r20 == 32'd2);
                chk("handler mtval == 0",         r22 == 32'h0);
                chk("handler cnt == 1",           r23 == 32'd1);
                chk("recovered: x24 == 0x55",
                    u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24] == 32'h55);
            end
            else if (expect_kind == "misalign") begin
                chk("trap count == 2",            trap_cnt == 2);
                chk("first  mcause == 4 (load)",  mcause1 == 32'd4);
                chk("first  mtval  == 0x402",     mtval1  == 32'h402);
                chk("final  mcause == 6 (store)", dbg_mcause == 32'd6);
                chk("final  mtval  == 0x403",     dbg_mtval  == 32'h403);
                chk("handler x22 == 0x403",       r22 == 32'h403);
                chk("handler cnt == 2",           r23 == 32'd2);
                chk("recovered: x26 == 0x99",
                    u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[26] == 32'h99);
            end
            else if (expect_kind == "jal_misalign") begin
                chk("trap count == 1",            trap_cnt == 1);
                chk("mcause == 0 (iaddr mis)",    mcause1 == 32'd0);
                chk("mtval[1:0] == 2 (target+2)", mtval1[1:0] == 2'b10);
                chk("handler cnt == 1",           r23 == 32'd1);
                chk("wrong-path NOT taken: x24 != 0xDE",
                    u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24] != 32'hDE);
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
