`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_dcache_stale.sv — 双核协同 第 2 步：**复现**共享 DRAM 的"陈旧读"，再验证修复
 * -----------------------------------------------------------------------------
 * 为什么必须复现（而不是直接加个 invalidate 就完事）：
 *   DCache 是**写直达**，写入不脏、不需要回写，所以 PS（AXI 主机）改 DRAM 之后
 *   唯一会错的方向是"**CPU 读到旧行**"：那一行 valid 还在、tag 还匹配，
 *   于是 CPU 看到的是 PS 改之前的值。这是共享内存系统的经典一致性缺口，
 *   没有复现就等于没有验证过修复。
 *
 * 时序（程序与测试台各跑各的，用 mtime 拉开窗口）：
 *
 *   CPU：  lw  x5, [0x1000]        <- 读到 TB 预置的 0x1111，**缓存这一行**
 *          mtime 忙等 ~1000 次
 *   TB ：  在忙等期间用 AXI 把 [0x1000] 改成 0x2222
 *   CPU：  lw  x6, [0x1000]        <- **陈旧读**：仍然是 0x1111  ← 这就是缺陷现场
 *          sw  [0x1000_001C] = 1   <- MMIO bit0：D-cache 整表无效
 *          lw  x7, [0x1000]        <- 现在应该读到 0x2222（修复生效）
 *
 * 判据：
 *   S1 x5 = 0x1111 （首次读，正常）
 *   S2 x6 = 0x1111 （**陈旧读被复现** —— 没有这条，说明这个台子根本没测到点子上）
 *   S3 x7 = 0x2222 （invalidate 之后读到新值）
 *   S4 dcache_inval 恰好出现 1 拍
 * ============================================================================= */
module tb_dcache_stale;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic axil_rst_n = 1'b0;
    always #10 clk = ~clk;

    // ---------------- AXI4-Lite 主机 BFM ----------------
    logic [31:0] awaddr = 0, wdata = 0, araddr = 0;
    logic [3:0]  wstrb = 4'h0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic        awready, wready, bvalid, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;

    logic [6:0]  led;
    logic        uart_tx, irq_ps;
    logic [31:0] dbg_status, dbg_mcycle;
    logic        dbg_boot_busy, dbg_boot_ok, dbg_boot_err;
    logic [31:0] dbg_wb_pc, dbg_mcause, dbg_mepc, dbg_mtval, dbg_ifu_pc;
    logic        dbg_wb_have, dbg_wb_ena, dbg_trap, dbg_dnpc, dbg_ready;
    logic [4:0]  dbg_wb_reg;
    logic [31:0] dbg_wb_val, dbg_ic_hit, dbg_ic_miss, dbg_dc_hit, dbg_dc_miss;

    board_top #(
        .IROM_WORDS (16384),
        .DRAM_WORDS (32768),
        .IROM_INIT  (""),
        .IROM_BOOT  (0),
        .AXIL_EN    (1)
    ) u_board (
        .sys_clk   (clk),
        .btn_rst_n (rst_n),
        .uart_rx   (1'b1),
        .uart_tx   (uart_tx),
        .led       (led),
        .irq_ps    (irq_ps),

        .axil_aclk    (clk),
        .axil_aresetn (axil_rst_n),
        .s_axil_awaddr (awaddr), .s_axil_awprot (3'b000),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata  (wdata),  .s_axil_wstrb (wstrb),
        .s_axil_wvalid (wvalid), .s_axil_wready(wready),
        .s_axil_bresp  (bresp),  .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr (araddr), .s_axil_arprot (3'b000),
        .s_axil_arvalid(arvalid),.s_axil_arready(arready),
        .s_axil_rdata  (rdata),  .s_axil_rresp (rresp),
        .s_axil_rvalid (rvalid), .s_axil_rready(rready),

        .debug_wb_have_inst (dbg_wb_have), .debug_wb_pc (dbg_wb_pc),
        .debug_wb_ena (dbg_wb_ena), .debug_wb_reg (dbg_wb_reg),
        .debug_wb_value (dbg_wb_val),
        .debug_icache_hit_cnt (dbg_ic_hit), .debug_icache_miss_cnt (dbg_ic_miss),
        .debug_dcache_hit_cnt (dbg_dc_hit), .debug_dcache_miss_cnt (dbg_dc_miss),
        .debug_mcause (dbg_mcause), .debug_mepc (dbg_mepc),
        .debug_mtval (dbg_mtval), .debug_trap_take (dbg_trap),
        .debug_dnpc_flag (dbg_dnpc), .debug_ready (dbg_ready), .debug_ifu_pc (dbg_ifu_pc),
        .debug_status (dbg_status), .debug_mcycle (dbg_mcycle),
        .debug_boot_busy (dbg_boot_busy), .debug_boot_ok (dbg_boot_ok),
        .debug_boot_err (dbg_boot_err)
    );

    task automatic axi_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            awaddr = a; wdata = d; wstrb = 4'hF;
            awvalid = 1'b1; wvalid = 1'b1;
            do @(posedge clk); while (!(awready && wready));
            @(negedge clk); awvalid = 1'b0; wvalid = 1'b0;
            bready = 1'b1;
            do @(posedge clk); while (!bvalid);
            @(negedge clk); bready = 1'b0;
        end
    endtask

    integer npass = 0, nfail = 0;
    task automatic chk(input string name, input bit cond);
        begin
            if (cond) begin npass = npass + 1; $display("  [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    integer inval_pulses = 0;
    always @(posedge clk) if (rst_n && u_board.dcache_inval) begin
        inval_pulses = inval_pulses + 1;
        if ($test$plusargs("tr"))
            $display("  [TR] inval pulse at %0t  (cpu sees inval=%b, valid[0]=%b)",
                     $time, u_board.u_cpu.DCache_inst.inval,
                     u_board.u_cpu.DCache_inst.valid[0]);
    end

    integer viv;   // valid 位图里 1 的个数（iverilog 没有 $countones 也能算）
    integer q;
    task automatic show_valid(input string tag);
        begin
            viv = 0;
            for (q = 0; q < 256; q = q + 1)
                if (u_board.u_cpu.DCache_inst.valid[q]) viv = viv + 1;
            $display("  [TR] %0s: %0d valid lines", tag, viv);
        end
    endtask

    integer prev_hit = 0;
    always @(posedge clk) if (rst_n) begin
        if (u_board.u_cpu.dcache_hit_cnt != prev_hit) begin
            prev_hit = u_board.u_cpu.dcache_hit_cnt;
            if ($test$plusargs("tr"))
                $display("  [TR] hit_cnt=%0d at %0t", prev_hit, $time);
        end
    end

    integer i;

    initial begin
        #20_000_000;
        $display("[STALE] WATCHDOG fired");
        $display("[STALE-SELFCHECK] status=FAIL (watchdog)");
        $finish;
    end

    initial begin
        $display("================================================================");
        $display(" tb_dcache_stale : shared DRAM stale read + invalidate fix");
        $display("================================================================");

        for (i = 0; i < 16384; i = i + 1) u_board.irom_inst.mem[i] = 32'h0;
        for (i = 0; i < 32768; i = i + 1) u_board.g_dram_axil.dram_inst.mem[i] = 32'h0;

        /* 程序（手汇编，已用 riscv64-unknown-elf-gcc 反汇编核对；x5/x6/x7 是判据寄存器，
         * 忙等用 x28/x29，**不能**用 t0(=x5)，否则第一条读的值会被循环变量覆盖）
         *   0x00  lui   a0, 0x1            # a0 = 0x1000       0x00001537
         *   0x04  lw    x5, 0(a0)          # 首次读            0x00052283
         *   0x08  lui   a1, 0x10000        # 0x1000_0000       0x100005B7
         *   0x0c  addi  x28, zero, 1000                       0x3E800E13
         *   0x10  lw    x29, 0x30(a1)      # mtime（不缓存）    0x0305AE83
         *   0x14  addi  x28, x28, -1                           0xFFFE0E13
         *   0x18  bne   x28, zero, -8      # 回到 0x10          0xFE0E1CE3
         *   0x1c  lw    x6, 0(a0)          # **陈旧读**         0x00052303
         *   0x20  addi  x30, zero, 1                           0x00100F13
         *   0x24  sw    x30, 0x1C(a1)      # CTL bit0 = inval   0x01E5AE23
         *   0x28  lw    x7, 0(a0)          # 修复后            0x00052383
         *   0x2c  j     .                                       0x0000006F
         */
        u_board.irom_inst.mem[0]  = 32'h00001537;
        u_board.irom_inst.mem[1]  = 32'h00052283;
        u_board.irom_inst.mem[2]  = 32'h100005B7;
        u_board.irom_inst.mem[3]  = 32'h7D000E13;
        u_board.irom_inst.mem[4]  = 32'h0305AE83;
        u_board.irom_inst.mem[5]  = 32'hFFFE0E13;
        u_board.irom_inst.mem[6]  = 32'hFE0E1CE3;
        u_board.irom_inst.mem[7]  = 32'h00052303;
        u_board.irom_inst.mem[8]  = 32'h00100F13;
        u_board.irom_inst.mem[9]  = 32'h01E5AE23;
        u_board.irom_inst.mem[10] = 32'h00052383;
        u_board.irom_inst.mem[11] = 32'h0000006F;

        // TB 预置：DRAM[0x1000] = 0x1111（CPU 第一次读会缓存它）
        u_board.g_dram_axil.dram_inst.mem[32'h1000 >> 2] = 32'h0000_1111;

        repeat (4) @(posedge clk);
        axil_rst_n = 1'b1;
        #200 rst_n = 1'b1;
        wait (u_board.boot_busy !== 1'bx);
        repeat (10) @(posedge clk);

        // 放行 CPU（HOLD 复位值是 1，见 board/ps_ctrl.sv）
        axi_write(32'h0002_0000, 32'h0);

        // 等 CPU 完成第一次读（= 一次 miss，缓存里从此有了陈旧行），然后**立刻**用
        // AXI 改 DRAM —— CPU 之后还有 2000 次 mtime 忙等（约 200 us），窗口足够宽。
        // ★ 第一版写的是"等到命中再写"，结果 AXI 写落在第三条 load 之后，
        //   变成"根本没改过 DRAM"，白白多调了一轮。时序窗口要按"最慢写"来留。
        wait (dbg_dc_miss >= 1);
        repeat (10) @(posedge clk);
        axi_write(32'h0000_1000, 32'h0000_2222);
        $display("  [TB] wrote DRAM[0x1000] = 0x2222 via AXI (CPU cache is now stale)");

        // 等 CPU 跑完忙等 + 后续三条
        repeat (20000) @(posedge clk);
        show_valid("end of run");

        chk("S1 x5 = 0x1111 (first read, cached)",
            u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5] == 32'h1111);
        chk("S2 x6 = 0x1111 (STALE read reproduced)",
            u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[6] == 32'h1111);
        chk("S3 x7 = 0x2222 (fresh after invalidate)",
            u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[7] == 32'h2222);
        chk("S4 dcache_inval pulsed exactly once", inval_pulses == 1);

        $display("  [DBG] x5=%h x6=%h x7=%h  DRAM[0x1000]=%h  mem[0x400]=%h",
                 u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5],
                 u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[6],
                 u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[7],
                 u_board.g_dram_axil.dram_inst.mem[32'h400],
                 u_board.g_dram_axil.dram_inst.mem[32'h400]);

        $display("  [DBG] hit=%0d miss=%0d inval=%0d", dbg_dc_hit, dbg_dc_miss, inval_pulses);
        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[STALE-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[STALE-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $finish;
    end

endmodule
