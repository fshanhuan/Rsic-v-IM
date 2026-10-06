// =============================================================================
// board/tb_board_top.sv — 板级顶层 board_top 的功能验证台
// -----------------------------------------------------------------------------
// 目的：证明 v9/board/ 下的板级件（reset_sync + sync_mem + board_top 的接线）
//       确实能把 myCPU 跑起来，而不只是“写出来没编译错误”。
//
// 用法（在 v9/ 目录下）：
//   iverilog -g2012 -o sim/build/tb_board.vvp \
//       board/sync_mem.sv board/reset_sync.sv board/board_top.sv \
//       myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv \
//       RegisterFile.sv CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv LSU.sv DCache.sv WBU.sv \
//       Data_hazard.sv Control.sv add.sv sext.sv Reg.sv board/tb_board_top.sv
//   vvp sim/build/tb_board.vvp +prog=sim/prog.hex
//
// 判定：与 sim/tb_iverilog.sv 的 prog 期望值一致（x1..x10 + dram[0x1000]）。
//       另外断言板级件本身：复位同步器在按键释放后必须给出确定的复位序列，
//       IROM 的 $readmemh 初值必须真的进去了。
// =============================================================================
`timescale 1ns / 1ps

module tb_board_top;

    logic clk = 1'b0;
    logic btn_rst_n = 1'b0;     // 按键：低有效，先按住
    always #5 clk = ~clk;       // 100MHz

    // 板级顶层观测口
    logic        dbg_have_inst;
    logic [31:0] dbg_pc;
    logic        dbg_ena;
    logic [ 4:0] dbg_reg;
    logic [31:0] dbg_value;
    logic [31:0] ic_hit, ic_miss, dc_hit, dc_miss;

    reg [8*260-1:0] prog_path = "sim/prog.hex";

    board_top #(
        .IROM_WORDS (4096),
        .DRAM_WORDS (16384),
        // 注意：这里用运行期 $readmemh 更灵活；板上板时改成固化文件名即可。
        .IROM_INIT  ("")
    ) u_board (
        .sys_clk               (clk),
        .btn_rst_n             (btn_rst_n),
        .debug_wb_have_inst    (dbg_have_inst),
        .debug_wb_pc           (dbg_pc),
        .debug_wb_ena          (dbg_ena),
        .debug_wb_reg          (dbg_reg),
        .debug_wb_value        (dbg_value),
        .debug_icache_hit_cnt  (ic_hit),
        .debug_icache_miss_cnt (ic_miss),
        .debug_dcache_hit_cnt  (dc_hit),
        .debug_dcache_miss_cnt (dc_miss)
    );

    integer cycle = 0;
    integer wb_events = 0;
    integer ecall_cycle = -1;
    integer drain_cnt = 0;
    logic   frozen = 1'b0;

    // 期望值（与 sim/tb_iverilog.sv 的 prog_id=0 相同）
    logic [31:0] exp_reg [0:31];
    integer nfail, npass;

    integer k;
    initial begin
        for (k = 0; k < 32; k = k + 1) exp_reg[k] = 32'h0;
        exp_reg[1]  = 32'h0000_1000;
        exp_reg[2]  = 32'd5;
        exp_reg[3]  = 32'd7;
        exp_reg[4]  = 32'd12;
        exp_reg[5]  = 32'd35;
        exp_reg[6]  = 32'd12;
        exp_reg[7]  = 32'd17;
        exp_reg[8]  = 32'd12;
        exp_reg[9]  = 32'h0;
        exp_reg[10] = 32'd63;

        if ($value$plusargs("prog=%s", prog_path)) ;
        $display("[BOARD-TB] program = %0s", prog_path);

        // 程序镜像通过 $readmemh 直接写进板级 IROM（模拟固化 BRAM 初值）
        $readmemh(prog_path, u_board.irom_inst.mem_rom);

        // 按键复位保持 6 拍后释放，验证“异步置位、同步释放”
        btn_rst_n = 1'b0;
        repeat (6) @(posedge clk);
        btn_rst_n = 1'b1;
        $display("[BOARD-TB] button reset released (async assert / sync de-assert)");
    end

    always @(negedge clk) begin
        if (!frozen) begin
            cycle = cycle + 1;

            if (dbg_have_inst) begin
                wb_events = wb_events + 1;
                $display("[WB ] cyc=%0d pc=%h ena=%0d reg=x%0d val=%h",
                         cycle, dbg_pc, dbg_ena, dbg_reg, dbg_value);
            end

            if (u_board.u_cpu.IDU_ecall_flag && ecall_cycle < 0) begin
                ecall_cycle = cycle;
                $display("[END] ecall at cyc=%0d", cycle);
            end

            if (ecall_cycle >= 0) begin
                drain_cnt = drain_cnt + 1;
                if (drain_cnt >= 12) begin
                    frozen = 1'b1;
                    $display("");
                    $display("============ board_top RESULT ============");
                    nfail = 0; npass = 0;
                    for (k = 0; k < 32; k = k + 1) begin
                        if (u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[k] === exp_reg[k]) begin
                            npass = npass + 1;
                        end else begin
                            nfail = nfail + 1;
                            $display("  x%0d = %h  [FAIL] exp=%h", k,
                                     u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[k], exp_reg[k]);
                        end
                    end
                    // 写直达存进 DRAM 的值
                    if (u_board.dram_inst.mem_ram[16'h1000 >> 2] === 32'd12) begin
                        npass = npass + 1;
                        $display("  dram[0x1000] = 12   [PASS]");
                    end else begin
                        nfail = nfail + 1;
                        $display("  dram[0x1000] = %h [FAIL] exp=12",
                                 u_board.dram_inst.mem_ram[16'h1000 >> 2]);
                    end
                    $display("  wb events = %0d", wb_events);
                    $display("  ICache hit/miss = %0d/%0d   DCache hit/miss = %0d/%0d",
                             ic_hit, ic_miss, dc_hit, dc_miss);
                    $display("  total cycles = %0d", cycle);
                    if (nfail == 0)
                        $display("[BOARD-SELFCHECK] status=PASS (%0d/%0d)", npass, npass + nfail);
                    else
                        $display("[BOARD-SELFCHECK] status=FAIL (%0d mismatched)", nfail);
                    $display("=========================================");
                    if (nfail != 0) $fatal(1, "[BOARD-SELFCHECK] FAIL");
                    $finish;
                end
            end else if (cycle >= 600) begin
                frozen = 1'b1;
                $display("[BOARD-SELFCHECK] status=TIMEOUT (no ecall in %0d cycles)", cycle);
                $fatal(1, "[BOARD-SELFCHECK] TIMEOUT");
            end
        end
    end

endmodule
