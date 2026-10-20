// =============================================================================
// sim/tb_cm.sv -- Verilator bench for C programs (CoreMark / FreeRTOS / self-tests)
// -----------------------------------------------------------------------------
// Why not reuse sim/tb_mini.sv:
//   1) memory must be much bigger: 64 KB IROM + 128 KB DRAM (same as board_top
//      defaults); the DRAM image is preloaded at word offset 0x4000 (address 0x1_0000)
//   2) UART: instead of instantiating uart_tx (4340 cycles per byte at 115200) the
//      bench snoops writes to 0x1000_0000 and prints the byte directly. The CPU
//      side software is unchanged.
//   3) end of run: crt0 writes a magic to 0x1000_00F0 once main() returns
//
// Clock is driven from C++ (sim/cm_main.cpp): one loop iteration = one cycle.
//
// Built-in consistency checkers (memory is write-through, so these are invariants):
//   [HITBAD] cache hit returned data != DRAM content
//   [MBAD]   miss path returned data != DRAM content
//   [WBAD]   store did not land in DRAM as expected (mask/offset honoured)
// =============================================================================
`timescale 1ns / 1ps

module tb_cm (
    input  logic        clk,
    output logic        done,
    output logic [31:0] cyc_o
);

    // ------------------------------------------------------------------ reset
    logic [4:0] rst_cnt = 5'd0;
    logic       rst;
    always_ff @(posedge clk)
        if (rst_cnt != 5'h1F) rst_cnt <= rst_cnt + 5'd1;
    assign rst = ~rst_cnt[4];

    // ------------------------------------------------------------------ CPU
    logic [31:0] irom_addr, irom_data;
    logic        irom_en;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic        perip_wen, perip_ren;
    logic [ 1:0] perip_mask;

    logic        dbg_have_inst, dbg_ena, dbg_trap_take;
    logic [31:0] dbg_pc, dbg_value, dbg_mcause, dbg_mepc, dbg_mtval;
    logic [ 4:0] dbg_reg;
    logic [31:0] dbg_ic_hit, dbg_ic_miss, dbg_dc_hit, dbg_dc_miss;
    logic [31:0] dbg_status, dbg_mcycle;
    logic        dbg_dnpc_flag, dbg_ready;
    logic [31:0] dbg_ifu_pc;

    // ------------------------------------------------------------------ memory
    // 64 KB IROM (irom_addr[15:2]) / 128 KB DRAM (perip_addr[16:2])
    localparam int IROM_WORDS = 16384;
    localparam int DRAM_WORDS = 32768;
    localparam int DRAM_IMG_OFF = 32'h1_0000 >> 2;

    logic [31:0] irom [0:IROM_WORDS-1];
    logic [31:0] dram [0:DRAM_WORDS-1];

    reg [8*256-1:0] irom_file = "sw/build/cm_irom.hex";
    reg [8*256-1:0] dram_file = "sw/build/cm_dram.hex";
    initial begin
        if (!$value$plusargs("irom=%s", irom_file)) ;
        if (!$value$plusargs("dram=%s", dram_file)) ;
        $display("[sim] irom=%0s", irom_file);
        $display("[sim] dram=%0s (preloaded at word 0x%04x)", dram_file, DRAM_IMG_OFF);
        $readmemh(irom_file, irom);
        $readmemh(dram_file, dram, DRAM_IMG_OFF);
    end

    logic is_mmio;
    assign is_mmio = (perip_addr[31:16] == 16'h1000);

    // ★ v14：数据侧也有 IROM 窗口（board_top 用 sync_mem_dp 的第二读口实现）。
    //   存储器模型必须与 board_top 的地址译码**一致**，否则仿真通过、上板不通：
    //     0x0002_0000 .. 0x0002_FFFF → IROM 字 [perip_addr[15:2]]（只读）
    logic is_irom_win;
    assign is_irom_win = (perip_addr[31:16] == 16'h0002);

    always_ff @(posedge clk)
        if (irom_en) irom_data <= irom[irom_addr[15:2]];

    logic [31:0] irom_win_rdata;
    always_ff @(posedge clk)
        if (perip_ren && is_irom_win) irom_win_rdata <= irom[perip_addr[15:2]];

    logic [1:0]  byte_offset;
    logic [31:0] wdata_merge;
    assign byte_offset = perip_addr[1:0];

    always_comb begin
        case (perip_mask)
            2'b00:   wdata_merge = {24'b0, perip_wdata[7:0]};
            2'b01:   wdata_merge = {16'b0, perip_wdata[15:0]};
            default: wdata_merge = perip_wdata;
        endcase
    end

    always_ff @(posedge clk) begin
        if (perip_ren) perip_rdata <= is_mmio ? 32'h0
                                   : is_irom_win ? irom[perip_addr[15:2]]
                                   : dram[perip_addr[16:2]];
        if (perip_wen && !is_mmio && !is_irom_win) begin
            case (perip_mask)
                2'b00: begin
                    case (byte_offset)
                        2'b00:   dram[perip_addr[16:2]][7:0]   <= wdata_merge[7:0];
                        2'b01:   dram[perip_addr[16:2]][15:8]  <= wdata_merge[7:0];
                        2'b10:   dram[perip_addr[16:2]][23:16] <= wdata_merge[7:0];
                        default: dram[perip_addr[16:2]][31:24] <= wdata_merge[7:0];
                    endcase
                end
                2'b01: begin
                    if (!byte_offset[1]) dram[perip_addr[16:2]][15:0]  <= wdata_merge[15:0];
                    else                 dram[perip_addr[16:2]][31:16] <= wdata_merge[15:0];
                end
                default: dram[perip_addr[16:2]] <= wdata_merge;
            endcase
        end
    end

    // ------------------------------------------------------- cycle / interrupt
    logic [63:0] cyc;
    always_ff @(posedge clk) cyc <= cyc + 64'd1;
    assign cyc_o = cyc[31:0];

    integer n_intr = 0;
    always_ff @(posedge clk)
        if (!rst && u_cpu.intr_take) n_intr <= n_intr + 1;

    // ------------------------------------------------------- uart snoop / done
    logic hexout;
    initial hexout = $test$plusargs("hexout");

    always_ff @(posedge clk) begin
        if (perip_wen && is_mmio) begin
            if (perip_addr == 32'h1000_0000) begin
                if (hexout) $write("[%02x]", perip_wdata[7:0]);
                else        $write("%c", perip_wdata[7:0]);
            end
            if (perip_addr == 32'h1000_00F0) done <= 1'b1;
        end
    end

    // ------------------------------------------------------- checkers
    integer n_hitbad = 0, n_mbad = 0, n_wbad = 0;

    // hit path: returned data must equal 落盘的存储内容（写直达）
    // ★ v14：0x2_xxxx 的读取源是 IROM 第二读口，期望值要按窗口译码去 irom[] 取。
    logic [31:0] exp_hit, exp_miss;
    always_comb begin
        exp_hit  = (u_cpu.DCache_inst.cpu_addr[31:16] == 16'h0002)
                 ? irom[u_cpu.DCache_inst.cpu_addr[15:2]]
                 : dram[u_cpu.DCache_inst.cpu_addr[16:2]];
        exp_miss = (u_cpu.DCache_inst.cpu_addr_r[31:16] == 16'h0002)
                 ? irom[u_cpu.DCache_inst.cpu_addr_r[15:2]]
                 : dram[u_cpu.DCache_inst.cpu_addr_r[16:2]];
    end

    always_ff @(posedge clk) begin
        if (!rst && u_cpu.DCache_inst.hit_now && !u_cpu.DCache_inst.mem_wen
                  && !is_mmio) begin
            if (u_cpu.DCache_inst.cpu_rdata !== exp_hit) begin
                n_hitbad <= n_hitbad + 1;
                if (n_hitbad < 10)
                    $display("[HITBAD] cyc=%0d addr=%h hit=%h exp=%h", cyc,
                             u_cpu.DCache_inst.cpu_addr, u_cpu.DCache_inst.cpu_rdata,
                             exp_hit);
            end
        end
    end

    // miss path: the read return must belong to the current request
    always_ff @(posedge clk) begin
        if (!rst && u_cpu.DCache_inst.resp_for_now && !u_cpu.DCache_inst.mem_wen
                  && !u_cpu.DCache_inst.uncacheable) begin
            if (u_cpu.DCache_inst.mem_rdata !== exp_miss) begin
                n_mbad <= n_mbad + 1;
                if (n_mbad < 10)
                    $display("[MBAD] cyc=%0d addr=%h got=%h exp=%h", cyc,
                             u_cpu.DCache_inst.cpu_addr_r, u_cpu.DCache_inst.mem_rdata,
                             exp_miss);
            end
        end
    end

    // store landing: one cycle after the write pulse, DRAM must hold the merged word
    logic        chk_wen;
    logic [31:0] chk_addr, chk_data, chk_old, chk_exp;
    logic [ 1:0] chk_mask;

    always_comb begin
        chk_exp = chk_old;
        case (chk_mask)
            2'b00: case (chk_addr[1:0])
                       2'b00:   chk_exp[7:0]   = chk_data[7:0];
                       2'b01:   chk_exp[15:8]  = chk_data[7:0];
                       2'b10:   chk_exp[23:16] = chk_data[7:0];
                       default: chk_exp[31:24] = chk_data[7:0];
                   endcase
            2'b01: if (!chk_addr[1]) chk_exp[15:0]  = chk_data[15:0];
                   else             chk_exp[31:16] = chk_data[15:0];
            default: chk_exp = chk_data;
        endcase
    end

    always_ff @(posedge clk) begin
        chk_wen <= perip_wen && !is_mmio && !is_irom_win;
        if (perip_wen && !is_mmio && !is_irom_win) begin
            chk_addr <= perip_addr;
            chk_data <= perip_wdata;
            chk_mask <= perip_mask;
            chk_old  <= dram[perip_addr[16:2]];
        end
        if (chk_wen && dram[chk_addr[16:2]] !== chk_exp) begin
            n_wbad <= n_wbad + 1;
            if (n_wbad < 10)
                $display("[WBAD] cyc=%0d addr=%h mask=%b wrote=%h old=%h exp=%h dram=%h",
                         cyc, chk_addr, chk_mask, chk_data, chk_old, chk_exp,
                         dram[chk_addr[16:2]]);
        end
    end

    // ------------------------------------------------------- traces
    logic trace_on;
    integer nwb = 0;
    initial trace_on = $test$plusargs("trace");

    always_ff @(posedge clk) begin
        if (!rst && dbg_have_inst) begin
            if (trace_on && nwb < 64)
                $display("[WB] cyc=%0d pc=%h v=%h mc=%h tr=%b",
                         cyc, dbg_pc, dbg_value, dbg_mcause, dbg_trap_take);
            nwb <= nwb + 1;
        end
    end

    // register snapshot one cycle before a trap (RF may be mid-write on the trap cycle)
    logic [31:0] s8_prev, sp_prev;
    always_ff @(posedge clk) begin
        s8_prev <= u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24];
        sp_prev <= u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[2];
    end

    always_ff @(posedge clk) begin
        if (!rst && dbg_trap_take)
            $display("[TRAP] cyc=%0d pc=%h mcause=%h mepc=%h mtval=%h | sp=%h/%h s8=%h/%h",
                     cyc, dbg_pc, dbg_mcause, dbg_mepc, dbg_mtval,
                     sp_prev, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[2],
                     s8_prev, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[24]);
    end

    // interrupt acceptance trace (first 6)
    integer n_intr_dbg = 0;
    always_ff @(posedge clk) begin
        if (!rst && u_cpu.intr_take && n_intr_dbg < 6) begin
            n_intr_dbg <= n_intr_dbg + 1;
            $display("[I] cyc=%0d IDU_pc=%h EXU_pc=%h ifu_pc=%h mcause=%h",
                     cyc, u_cpu.IDU_pc, u_cpu.EXU_pc, dbg_ifu_pc, dbg_mcause);
        end
    end

    // single-address access history (+wtrace=<addr>)
    logic [31:0] waddr;
    logic        wtrace_on;
    initial wtrace_on = $value$plusargs("wtrace=%h", waddr);

    always_ff @(posedge clk) begin
        if (!rst && wtrace_on && !$isunknown(waddr)) begin
            if (u_cpu.DCache_inst.store_fire && (u_cpu.DCache_inst.cpu_addr == waddr))
                $display("[S] c=%0d addr=%h wd=%h mask=%b store_hit=%b dram=%h", cyc,
                         waddr, u_cpu.DCache_inst.cpu_wdata, u_cpu.DCache_inst.cpu_mask,
                         u_cpu.DCache_inst.store_hit_now, dram[waddr[16:2]]);
            if (u_cpu.DCache_inst.fill_now && (u_cpu.DCache_inst.cpu_addr_r == waddr))
                $display("[F] c=%0d addr=%h mem_rdata=%h blocked=%b dram=%h", cyc,
                         waddr, u_cpu.DCache_inst.mem_rdata,
                         u_cpu.DCache_inst.fill_blocked, dram[waddr[16:2]]);
            if (u_cpu.DCache_inst.mem_en && (u_cpu.DCache_inst.cpu_addr_r == waddr))
                $display("[R] c=%0d addr=%h", cyc, waddr);
            if (u_cpu.DCache_inst.hit_now && (u_cpu.DCache_inst.cpu_addr == waddr))
                $display("[L] c=%0d addr=%h rdata=%h dram=%h", cyc, waddr,
                         u_cpu.DCache_inst.cpu_rdata, dram[waddr[16:2]]);
        end
    end

    // ecall / mret boundaries with mstatus (first 8 of each) -- pins down "MIE lost after yield"
    integer n_ecall = 0, n_mret = 0;
    always_ff @(posedge clk) begin
        if (!rst && u_cpu.Control_inst0.ecall_flag && n_ecall < 8) begin
            n_ecall <= n_ecall + 1;
            $display("[E] cyc=%0d pc=%h mstatus=%h", cyc, u_cpu.IDU_pc,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mstatus_reg);
        end
        if (!rst && u_cpu.Control_inst0.mret_flag && n_mret < 8) begin
            n_mret <= n_mret + 1;
            $display("[R] cyc=%0d pc=%h mstatus=%h", cyc, u_cpu.IDU_pc,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mstatus_reg);
        end
    end

    // per-cycle window dump (P0 diagnosis: why does one ecall commit three times?)
    //   +window=<start>,<end>  -> print one line per cycle in [start,end]
    integer win_s = -1, win_e = -1;
    reg [8*64-1:0] win_str = "";
    initial begin
        if (!$value$plusargs("win_s=%d", win_s)) win_s = -1;
        if (!$value$plusargs("win_e=%d", win_e)) win_e = -1;
    end
    always_ff @(posedge clk) begin
        if (!rst && win_s >= 0 && cyc >= win_s && cyc <= win_e)
            $display("[W] c=%0d idpc=%h ifu=%h ecall=%b mret=%b tcomm=%b tblk=%0d mst=%h stall=%b dnpc=%b rdy=%b trap=%b exv=%b",
                     cyc, u_cpu.IDU_pc, u_cpu.IFU_pc,
                     u_cpu.Control_inst0.ecall_flag,
                     u_cpu.Control_inst0.mret_flag,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.trap_commit,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.trap_blank,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mstatus_reg,
                     u_cpu.Control_inst0.IFU_stall,
                     u_cpu.Control_inst0.dnpc_flag,
                     u_cpu.IDU_ready,
                     u_cpu.Control_inst0.trap_take,
                     u_cpu.Control_inst0.EXU_valid);
    end

    // periodic position report (locate hangs)
    always_ff @(posedge clk) begin
        if (cyc != 0 && (cyc % 500000) == 0)
            $display("[T] cyc=%0d wb_pc=%h nwb=%0d intr=%0d st=%h mtime=%0d mtc=%0d mie=%h mip=%h mstatus=%h pend=%b safe=%b",
                     cyc, dbg_pc, nwb, n_intr, dbg_status,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mtime_reg,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mtimecmp_reg,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mie_reg,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mip_out,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.mstatus_reg,
                     u_cpu.Control_inst0.intr_pending,
                     u_cpu.Control_inst0.intr_safe);
    end

    // -------------------------------------------------- 性能普查（+perf）：
    //   retire 口径 = minstret（进入 WB 的指令数，与 ISA 一致）。
    //   停拍按"该拍信号为高"计数，几类之间**有重叠**：IFU_stall = load_use | mdu_busy，
    //   所以"总停拍"要看 cyc - minstret，而不是把下面几列相加。
    logic perf_on;
    initial perf_on = $test$plusargs("perf");
    int unsigned c_ifu_stall = 0, c_lu = 0, c_mdu = 0, c_hold = 0;
    int unsigned c_mis = 0, c_trap = 0, c_clear = 0, c_wb = 0, c_br = 0;

    always_ff @(posedge clk) begin
        if (!rst) begin
            if (u_cpu.Control_inst0.IFU_stall)      c_ifu_stall <= c_ifu_stall + 1;
            if (u_cpu.Control_inst0.load_use_stall) c_lu        <= c_lu + 1;
            if (u_cpu.EXU_mdu_busy)                 c_mdu       <= c_mdu + 1;
            if (u_cpu.dcache_hold)                  c_hold      <= c_hold + 1;
            if (u_cpu.Control_inst0.bp_mispredict)  c_mis       <= c_mis + 1;
            if (u_cpu.Control_inst0.bp_update_en)   c_br        <= c_br + 1;
            if (u_cpu.Control_inst0.trap_take)      c_trap      <= c_trap + 1;
            if (u_cpu.Control_inst0.EXU_inst_clear) c_clear     <= c_clear + 1;
            if (dbg_have_inst)                      c_wb        <= c_wb + 1;
        end
    end

    // end of run: dump DRAM head + counters (a few extra cycles are run from C++)
    always_ff @(posedge clk) begin
        if (done) begin
            $display("\n[MEM] dram[0..7] = %h %h %h %h %h %h %h %h | cyc=%0d mcycle=%0d",
                     dram[0], dram[1], dram[2], dram[3],
                     dram[4], dram[5], dram[6], dram[7], cyc, dbg_mcycle);
            if (perf_on)
                $display("[PERF] cyc=%0d minstret=%0d wb_high=%0d | ifu_stall=%0d load_use=%0d mdu_busy=%0d dc_hold=%0d mispred=%0d branches=%0d trap=%0d inst_clear=%0d | dc_hit=%0d dc_miss=%0d",
                         cyc, u_cpu.IDU_Inst0.Reg_Stack_inst0.CSR_inst.minstret_reg,
                         c_wb, c_ifu_stall, c_lu, c_mdu, c_hold, c_mis, c_br, c_trap, c_clear,
                         dbg_dc_hit, dbg_dc_miss);
        end
    end

    // ------------------------------------------------------------------ DUT
    myCPU u_cpu (
        .cpu_clk              (clk),
        .cpu_rst              (rst),
        .irom_addr            (irom_addr),
        .irom_data            (irom_data),
        .irom_en              (irom_en),
        .perip_addr           (perip_addr),
        .perip_wen            (perip_wen),
        .perip_ren            (perip_ren),
        .perip_mask           (perip_mask),
        .perip_wdata          (perip_wdata),
        .perip_rdata          (perip_rdata),
        .debug_wb_have_inst   (dbg_have_inst),
        .debug_wb_pc          (dbg_pc),
        .debug_wb_ena         (dbg_ena),
        .debug_wb_reg         (dbg_reg),
        .debug_wb_value       (dbg_value),
        .debug_icache_hit_cnt (dbg_ic_hit),
        .debug_icache_miss_cnt(dbg_ic_miss),
        .debug_dcache_hit_cnt (dbg_dc_hit),
        .debug_dcache_miss_cnt(dbg_dc_miss),
        .debug_mcause         (dbg_mcause),
        .debug_mepc           (dbg_mepc),
        .debug_mtval          (dbg_mtval),
        .debug_trap_take      (dbg_trap_take),
        .debug_dnpc_flag      (dbg_dnpc_flag),
        .debug_ready          (dbg_ready),
        .debug_ifu_pc         (dbg_ifu_pc),
        .debug_status         (dbg_status),
        .debug_mcycle         (dbg_mcycle)
    );

endmodule
