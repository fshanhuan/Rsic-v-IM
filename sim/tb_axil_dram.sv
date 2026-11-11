`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_axil_dram.sv -- #6 端到端：AXI 主机 <-> 共享端口 DRAM <-> CPU
 * -----------------------------------------------------------------------------
 * 验证的不是桥（那是 tb_axil），而是**接进 SoC 以后**两件事：
 *   H1 AXI 写进 DRAM 的值，CPU 用普通 `lw` 读得到（PS 能给 RISC-V 喂数据）；
 *   H2 CPU 用 `sw` 写进 DRAM 的值，AXI 读得到（PS 能观察/取回结果）。
 * 这两条通了，"PS 加载/观测 RISC-V" 才有意义。
 *
 * ★ 双核协同（第 1 步）之后多了一条必经之路：
 *   AXIL_EN=1 时 CPU 默认被 `ps_hold` **按在复位里**（ps_ctrl 的 CTRL.HOLD 复位值是 1），
 *   必须先由 AXI 写 CTRL(HOLD=0) 才放行。理由见 board/ps_ctrl.sv 头部
 *   （否则 stub 会把复位向量覆盖成 0，再复位也回不来）。
 *   本 TB 因此多了一个 H0：HOLD 默认生效。
 *
 * 被测程序（手汇编，直接写进 IROM 数组，不需要 hex 文件）：
 *      lui   a0, 0x10000       # a0 = 0x1000_0000
 *      addi  a2, zero, 0x3C
 *      sw    a2, 0x44(a0)      # [0x1000_0044] = 0x3C      <- H2 用
 *      lw    a1, 0x40(a0)      # a1 = [0x1000_0040]        <- H1 用（AXI 先写）
 *      sw    a1, 0x10(a0)      # LED = a1
 *   1: j     1b
 *
 * 用法： vvp sim/build/tb_axil_dram.vvp
 * ============================================================================= */
module tb_axil_dram;

    logic clk = 1'b0;
    logic rst_n = 1'b0;       // CPU 复位（btn_rst_n）
    logic axil_rst_n = 1'b0;  // AXI 侧复位：要比 CPU 早放开，否则桥在复位里不握手
    always #10 clk = ~clk;

    // ---------------- AXI4-Lite 主机 BFM 信号 ----------------
    logic [31:0] awaddr = 0, wdata = 0, araddr = 0;
    logic [3:0]  wstrb = 4'h0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic        awready, wready, bvalid, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;

    logic [6:0]  led;
    logic [31:0] dbg_status, dbg_mcycle;
    logic        uart_tx;
    logic        dbg_boot_busy, dbg_boot_ok, dbg_boot_err;
    logic [31:0] dbg_wb_pc, dbg_mcause, dbg_mepc, dbg_mtval, dbg_ifu_pc;
    logic        dbg_wb_have, dbg_wb_ena, dbg_trap, dbg_dnpc, dbg_ready;
    logic [4:0]  dbg_wb_reg;
    logic [31:0] dbg_wb_val, dbg_ic_hit, dbg_ic_miss, dbg_dc_hit, dbg_dc_miss;
    logic        irq_ps;

    board_top #(
        .IROM_WORDS (16384),
        .DRAM_WORDS (32768),
        .IROM_INIT  (""),
        .IROM_BOOT  (0),
        .AXIL_EN    (1)                 // ★ 本次测试的主角
    ) u_board (
        .sys_clk   (clk),
        .btn_rst_n (rst_n),
        .uart_rx   (1'b1),
        .uart_tx   (uart_tx),
        .led       (led),
        .irq_ps    (irq_ps),

        .axil_aclk    (clk),            // 同源同频（见 board_top 的 AXI 时钟约束注释）
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

    // ---------------- 主机 BFM（同 tb_axil：ready 在 posedge 采） ----------------
    task automatic axi_write(input [31:0] a, input [31:0] d,
                             input [3:0] s, input bit use_strobe);
        begin
            @(negedge clk);
            awaddr = a; wdata = d;
            wstrb  = use_strobe ? s : 4'hF;
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

    integer i;
    logic [31:0] rdval;

    // ★ WATCHDOG：卡住时也要退出，不然回归会挂死（iverilog 里"时间不前进"最难查）
    initial begin
        #8_000_000;
        $display("[RUNAPP] WATCHDOG fired: simulation did not finish (stuck in a wait loop)");
        $display("[AXIL-DRAM-SELFCHECK] status=FAIL (watchdog)");
        $finish;
    end

    initial begin
        $display("================================================================");
        $display(" tb_axil_dram : AXI master <-> shared-port DRAM <-> CPU (#6)");
        $display("================================================================");

        for (i = 0; i < 16384; i = i + 1) u_board.irom_inst.mem[i] = 32'h0;
        // DRAM 整块清零：dram_shared 的 initial 只清前 4096 字（Quartus 循环上限），
        // 0x10040 在 4096 之外，不清就是 X —— 这和 P0-1 在 tb_monitor 里踩的是同一个坑。
        for (i = 0; i < 32768; i = i + 1) begin
            u_board.g_dram_axil.dram_inst.mem[i] = 32'h0;
        end

        // 被测程序：先 32 条 nop 再干活。
        // ★ 为什么要 nop：AXI 写必须发生在"CPU 已出复位、但还没走到 load"的窗口里。
        //   原先是**复位期间**就做 AXI 写 —— 那时 CPU 侧 perip_* 全是 X，
        //   dram_shared 的仲裁信号跟着变 X，仿真就卡住了（时间不前进）。
        //   加 nop 把这个窗口拉开，测试台不再依赖 X 行为。
        for (i = 0; i < 32; i = i + 1) u_board.irom_inst.mem[i] = 32'h00000013;  // nop
        u_board.irom_inst.mem[32] = 32'h00010537;  // lui   a0, 0x00010 -> 0x10000 (DRAM)
        u_board.irom_inst.mem[33] = 32'h100006B7;  // lui   a3, 0x10000 -> 0x1000_0000 (MMIO)
        u_board.irom_inst.mem[34] = 32'h03C00613;  // addi  a2, zero, 0x3C
        u_board.irom_inst.mem[35] = 32'h04C52223;  // sw    a2, 0x44(a0) -> [0x10044]
        u_board.irom_inst.mem[36] = 32'h04052583;  // lw    a1, 0x40(a0) <- [0x10040]
        u_board.irom_inst.mem[37] = 32'h00B6A823;  // sw    a1, 0x10(a3) -> LED
        u_board.irom_inst.mem[38] = 32'h0000006F;  // 1: j 1b

        // ★ 关键：AXI 侧的复位**必须先经历几个时钟沿再放开**。
        //   原来写成 "axil_rst_n = 1; repeat(4) @(posedge clk);" —— 复位在第一个时钟沿
        //   之前就撤了，桥里的触发器从来没被复位过（aw_got = X），于是
        //   awready = (st==IDLE) && !aw_got = X，主机永远等不到握手 → 事务死等。
        //   这是测试台的错，不是 RTL 的错（tb_axil / tb_dram_shared 的复位顺序是对的）。
        repeat (4) @(posedge clk);
        axil_rst_n = 1'b1;
        #200 rst_n = 1'b1;

        // ★ 必须等 boot_busy / cpu_wen 这些**定义下来**再发 AXI 写。
        //   dram_shared 的授权是 wr_gnt = b_req & b_we & ~cpu_wen，
        //   cpu_wen = boot_busy ? ... : bus_we_dram；复位刚放开时 boot_busy 是 X
        //   → wr_gnt = X → m_gnt = X → 桥的 if (m_gnt) 永远不成立 → 事务死等。
        wait (u_board.boot_busy !== 1'bx);
        repeat (20) @(posedge clk);
        $display("  [DBG] boot_busy=%b cpu_wen=%b", u_board.boot_busy, u_board.bus_we_dram);

        // ---- H0：HOLD 默认生效（CPU 被按在复位里，ps_ctrl 复位值就是 1）----
        axi_read(32'h0002_0004, rdval);          // STATUS
        chk("H0 ps_ctrl present (MAGIC=0xB155)", rdval[31:16] == 16'hB155);
        chk("H0b HOLD defaults to 1", rdval[0] == 1'b1);

        axi_write(32'h0001_0040, 32'h0000_0079, 4'hF, 1'b0);

        // ---- 放行 CPU：CTRL.HOLD = 0 ----
        axi_write(32'h0002_0000, 32'h0000_0000, 4'hF, 1'b0);
        axi_read(32'h0002_0004, rdval);
        chk("H0c HOLD cleared after write", rdval[0] == 1'b0);

        // 让 CPU 跑完
        repeat (400) @(posedge clk);

        chk("H1 AXI->DRAM->CPU (LED = 0x79)", led == 7'h79);

        axi_read(32'h0001_0044, rdval);
        chk("H2 CPU->DRAM->AXI (0x10044 = 0x3C)", rdval == 32'h0000_003C);

        // H3：AXI 用字节使能改 CPU 写过的字，CPU 侧再读要看到新值
        axi_write(32'h0001_0044, 32'h0000_AB00, 4'b0010, 1'b1);   // 只改 [15:8]
        axi_read(32'h0001_0044, rdval);
        chk("H3 byte-enable write via AXI", rdval == 32'h0000_AB3C);

        // H4：CPU 还在跑（没被 AXI 访问搞死）
        chk("H4 CPU still alive (pc in IROM)", dbg_ifu_pc < 32'h0000_1000);

        // H5：控制窗口没有踩到 DRAM（PS 写 0x2_0000 不该改 DRAM 第 0 个字）
        axi_write(32'h0002_0000, 32'h0000_0001, 4'hF, 1'b0);      // 重新 HOLD
        axi_read(32'h0000_0000, rdval);
        chk("H5 CTRL write does not alias DRAM[0]", rdval == 32'h0000_0000);
        axi_write(32'h0002_0000, 32'h0000_0000, 4'hF, 1'b0);      // 再放行

        $display("  [DBG] led=%02x status=%h pc=%h", led, dbg_status, dbg_ifu_pc);
        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[AXIL-DRAM-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[AXIL-DRAM-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $finish;
    end

endmodule
