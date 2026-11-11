`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_ps_ctrl.sv — 双核协同 第 1/2/3 步的 RTL 级证据（不需要真的 PS）
 * -----------------------------------------------------------------------------
 * 它扮演"AXI 主机"（就是 PS 的角色），把第 1 步的装载流程完整走一遍：
 *
 *   P1 ps_ctrl 在位（STATUS 的 MAGIC = 0xB155）
 *   P2 HOLD 默认 = 1（CPU 被按在复位里，html 不会去执行空镜像）
 *   P3 PS 把镜像灌进 DRAM 0xA000（描述符 + 11 个字）+ .rodata
 *   P4 HOLD=0 放行 → stage-0 stub 把 DRAM 抄进 IMEM 代码窗口 → 跳过去
 *      ⇒ LED = 0x2A（镜像真的跑起来了）
 *   P5 stub 报平安：STATUS.ALIVE = 1
 *   P6 CPU 写 CTL.bit0 ⇒ dcache_inval 出现**一拍**脉冲（第 2 步的触发通路）
 *   P7 CPU 写 CTL.bit1 ⇒ irq_ps 拉高、STATUS 回读一致（第 3 步的 CPU→PS 方向）
 *   P8 PS 写 CTL.bit3 ⇒ irq_ps 被清（"收下中断"的握手）
 *   P9 PS 写 CTL.bit1 ⇒ PLIC 源 4 挂起（第 3 步的 PS→CPU 方向）
 *   P10 控制窗口不会别名到 DRAM[0]
 *
 * ★ 镜像有两层：IROM 里固化的是 sw/ps/stub.S 汇编出来的 ps_stub.hex（几百字节），
 *   DRAM 0xA000 里这份 11 个字的小程序是替身（真正的 monitor 由 PS 灌，本台子不重复造）。
 * ============================================================================= */
module tb_ps_ctrl;

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
        .IROM_INIT  (""),               // 镜像由本台子 $readmemh 载入（见下）
        .IROM_BOOT  (2),                // ★ PS 装载模式：没有串口引导器、没有 5 s 等待
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

    task automatic axi_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            araddr = a; arvalid = 1'b1;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid = 1'b0;
            rready = 1'b1;
            do @(posedge clk); while (!rvalid);
            d = rdata;
            @(negedge clk); rready = 1'b0;
        end
    endtask

    integer npass = 0, nfail = 0;
    task automatic chk(input string name, input bit cond);
        begin
            if (cond) begin npass = npass + 1; $display("  [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    // ---------------- 观测：dcache_inval 的脉冲计数 ----------------
    integer inval_pulses = 0;
    always @(posedge clk) if (rst_n && u_board.dcache_inval) inval_pulses = inval_pulses + 1;

    integer i;
    logic [31:0] rdval;

    localparam [31:0] REG_CTRL    = 32'h0002_0000;
    localparam [31:0] REG_STATUS  = 32'h0002_0004;
    localparam [31:0] IMG_DRAM    = 32'h0000_A000;
    localparam [31:0] RODATA_ADDR = 32'h0001_0000;

    // 替身镜像（手汇编，见 sw/ps/stub.S 的装载约定）
    //   li t0,42 ; li t1,0x10000010 ; sw t0,0(t1)      -> LED = 0x2A
    //   li t2,0x1000001C ; li t3,1 ; sw t3,0(t2)       -> CTL=1 (dcache invalidate)
    //   li t3,2 ; sw t3,0(t2)                          -> CTL=2 (irq_ps = 1)
    //   1: j 1b
    localparam integer IMG_N = 11;
    logic [31:0] img [0:IMG_N-1];
    initial begin
        img[0]  = 32'h02A00293;   // addi t0, zero, 42
        img[1]  = 32'h10000337;   // lui  t1, 0x10000   -> 0x1000_0000
        img[2]  = 32'h01030313;   // addi t1, t1, 0x10  -> 0x1000_0010 (LED)
        img[3]  = 32'h00532023;   // sw   t0, 0(t1)
        img[4]  = 32'h100003B7;   // lui  t2, 0x10000
        img[5]  = 32'h01C38393;   // addi t2, t2, 0x1C  -> 0x1000_001C (CTL)
        img[6]  = 32'h00100E13;   // addi t3, zero, 1
        img[7]  = 32'h01C3A023;   // sw   t3, 0(t2)
        img[8]  = 32'h00200E13;   // addi t3, zero, 2
        img[9]  = 32'h01C3A023;   // sw   t3, 0(t2)
        img[10] = 32'h0000006F;   // 1: j 1b
    end

    initial begin
        #8_000_000;
        $display("[PSCTRL] WATCHDOG fired: simulation did not finish");
        $display("[PS-CTRL-SELFCHECK] status=FAIL (watchdog)");
        $finish;
    end

    initial begin
        $display("================================================================");
        $display(" tb_ps_ctrl : PS(AXI) loads RISC-V image -> stub -> shell");
        $display("================================================================");

        // IROM 固化 stage-0 stub（ps_stub.hex）；DRAM 全清（sync_mem 只清前 4096 字）
        $readmemh("sw/build/ps_stub.hex", u_board.irom_inst.mem);
        for (i = 0; i < 32768; i = i + 1)
            u_board.g_dram_axil.dram_inst.mem[i] = 32'h0;

        repeat (4) @(posedge clk);
        axil_rst_n = 1'b1;
        #200 rst_n = 1'b1;
        wait (u_board.boot_busy !== 1'bx);
        repeat (10) @(posedge clk);

        // ---- P1 / P2：控制窗口在位，且 CPU 默认被按住 ----
        axi_read(REG_STATUS, rdval);
        chk("P1 ps_ctrl present (MAGIC=0xB155)", rdval[31:16] == 16'hB155);
        chk("P2 HOLD defaults to 1", rdval[0] == 1'b1);
        chk("P2b cpu_rst_eff asserted while HOLD", u_board.cpu_rst_eff === 1'b1);
        chk("P2c LED stays 0 (CPU not running)", led == 7'h00);

        // ---- P3：PS 灌镜像（描述符 + N 个字）+ 一段 .rodata ----
        axi_write(IMG_DRAM, IMG_N[31:0]);
        for (i = 0; i < IMG_N; i = i + 1)
            axi_write(IMG_DRAM + 32'h4 + i * 4, img[i]);
        axi_write(RODATA_ADDR, 32'hCAFE_0001);
        axi_read(IMG_DRAM + 32'h4, rdval);
        chk("P3 image word 0 reaches DRAM", rdval == img[0]);

        // ---- P4：放行 → stub 搬运 → 跳到 word 0 ----
        axi_write(REG_CTRL, 32'h0);
        repeat (4000) @(posedge clk);
        chk("P4 stub copied image and jumped (LED=0x2A)", led == 7'h2A);

        // ---- P5：stub 报平安 ----
        axi_read(REG_STATUS, rdval);
        chk("P5 ALIVE set by stub (STATUS[6])", rdval[6] == 1'b1);
        chk("P5b HOLD reads 0", rdval[0] == 1'b0);

        // ---- P6：第 2 步的触发通路（CPU 写 CTL.bit0 → 一拍 inval）----
        chk("P6 dcache_inval pulsed at least once", inval_pulses >= 1);

        // ---- P7 / P8：第 3 步 CPU→PS 方向（电平 + 由 PS 清零）----
        axi_read(REG_STATUS, rdval);
        chk("P7 irq_ps reads 1 (STATUS[2])", rdval[2] == 1'b1);
        chk("P7b irq_ps output high", irq_ps === 1'b1);
        axi_write(REG_CTRL, 32'h8);          // bit3 = CLR_IRQ_PS
        repeat (10) @(posedge clk);
        axi_read(REG_STATUS, rdval);
        chk("P8 PS clears irq_ps (bit3)", rdval[2] == 1'b0 && irq_ps === 1'b0);

        // ---- P9：第 3 步 PS→CPU 方向（CTL.bit1 → PLIC 源 4 挂起）----
        axi_write(REG_CTRL, 32'h2);
        repeat (10) @(posedge clk);
        chk("P9 PS_IRQ sets PLIC source 4 pending", u_board.plic_pend[4] === 1'b1);

        // ---- P10：控制窗口不别名到 DRAM[0] ----
        axi_read(32'h0000_0000, rdval);
        chk("P10 CTRL writes do not alias DRAM[0]", rdval == 32'h0);

        $display("  [DBG] led=%02x status=%h inval_pulses=%0d", led, dbg_status, inval_pulses);
        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[PS-CTRL-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[PS-CTRL-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $finish;
    end

endmodule
