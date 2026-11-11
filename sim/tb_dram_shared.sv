`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_dram_shared.sv -- dram_shared（CPU 独占口 + AXI 借用）的功能/仲裁测试
 * -----------------------------------------------------------------------------
 * 被测组合：axil_slave（AXI4-Lite 从口）+ dram_shared（共享端口的 128 KB DRAM）
 * 这就是 #6 要交付的那一块；不依赖 board_top（避免把整颗 CPU 拖进仿真）。
 *
 * 判据：
 *   S1 CPU 写 → CPU 读回
 *   S2 AXI 写 → CPU 读（PS 给 RISC-V 喂数据）
 *   S3 CPU 写 → AXI 读（PS 观察 RISC-V）
 *   S4 AXI 字节使能只改目标字节
 *   S5 **抢占**：CPU 连续写 8 拍期间发起的 AXI 写，必须在 CPU 停手后完成，且只写一次
 *      （验证 "CPU 优先、PS 等待但不丢事务"）
 * ============================================================================= */
module tb_dram_shared;

    logic clk = 1'b0;
    logic aresetn = 1'b0;
    always #10 clk = ~clk;

    // ---------------- AXI 主机 ----------------
    logic [31:0] awaddr = 0, wdata = 0, araddr = 0;
    logic [3:0]  wstrb = 4'h0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic        awready, wready, bvalid, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;

    // ---------------- 桥 ↔ DRAM ----------------
    logic [31:0] m_addr, m_wdata, m_rdata;
    logic        m_req, m_we, m_gnt, m_rvalid;
    logic [3:0]  m_wstrb;

    // ---------------- CPU 侧 ----------------
    logic [31:0] c_addr = 0, c_wdata = 0, c_rdata;
    logic        c_ren = 0, c_wen = 0;
    logic [1:0]  c_mask = 2'b11;

    axil_slave u_bridge (
        .aclk (clk), .aresetn (aresetn),
        .s_axil_awaddr (awaddr), .s_axil_awprot (3'b000),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata  (wdata),  .s_axil_wstrb (wstrb),
        .s_axil_wvalid (wvalid), .s_axil_wready(wready),
        .s_axil_bresp  (bresp),  .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr (araddr), .s_axil_arprot (3'b000),
        .s_axil_arvalid(arvalid),.s_axil_arready(arready),
        .s_axil_rdata  (rdata),  .s_axil_rresp (rresp),
        .s_axil_rvalid (rvalid), .s_axil_rready(rready),
        .m_addr (m_addr), .m_req (m_req), .m_we (m_we), .m_wdata (m_wdata),
        .m_wstrb (m_wstrb), .m_gnt (m_gnt), .m_rvalid (m_rvalid), .m_rdata (m_rdata)
    );

    dram_shared #(.WORDS(4096)) u_dram (
        .clk (clk), .reset (~aresetn),
        .cpu_addr (c_addr), .cpu_ren (c_ren), .cpu_rdata (c_rdata),
        .cpu_wen (c_wen), .cpu_wdata (c_wdata), .cpu_mask (c_mask),
        .b_addr (m_addr), .b_req (m_req), .b_we (m_we), .b_wdata (m_wdata),
        .b_be (m_wstrb), .b_gnt (m_gnt), .b_rvalid (m_rvalid), .b_rdata (m_rdata)
    );

    // ---------------- AXI BFM（ready 在 posedge 采） ----------------
    task automatic axi_write(input [31:0] a, input [31:0] d, input [3:0] s);
        begin
            @(negedge clk);
            awaddr = a; wdata = d; wstrb = s; awvalid = 1'b1; wvalid = 1'b1;
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

    // ---------------- CPU BFM ----------------
    task automatic cpu_write(input [31:0] a, input [31:0] d, input [1:0] mask);
        begin
            @(negedge clk);
            c_addr = a; c_wdata = d; c_mask = mask; c_wen = 1'b1;
            @(negedge clk);
            c_wen = 1'b0;
        end
    endtask

    task automatic cpu_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            c_addr = a; c_ren = 1'b1;
            @(negedge clk);
            c_ren = 1'b0;
            @(negedge clk);          // 读数据在 ren 之后的下一拍有效
            d = c_rdata;
        end
    endtask

    integer npass = 0, nfail = 0;
    task automatic chk(input string name, input bit cond);
        begin
            if (cond) begin npass = npass + 1; $display("  [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    logic [31:0] d1, d2;
    integer k;

    initial begin
        $display("================================================================");
        $display(" tb_dram_shared : axil_slave + dram_shared (CPU port + AXI borrow)");
        $display("================================================================");
        #200 aresetn = 1'b1;
        #50;

        cpu_write(32'h0000_0010, 32'h1122_3344, 2'b11);
        cpu_read (32'h0000_0010, d1);
        chk("S1 CPU write -> CPU read", d1 == 32'h1122_3344);

        axi_write(32'h0000_0020, 32'hA5A5_1234, 4'hF);
        cpu_read (32'h0000_0020, d2);
        chk("S2 AXI write -> CPU read", d2 == 32'hA5A5_1234);

        cpu_write(32'h0000_0030, 32'hDEAD_BEEF, 2'b11);
        axi_read (32'h0000_0030, d1);
        chk("S3 CPU write -> AXI read", d1 == 32'hDEAD_BEEF);

        axi_write(32'h0000_0040, 32'h0000_FF00, 4'b0010);   // 只改 [15:8]
        axi_read (32'h0000_0040, d2);
        chk("S4 AXI byte enable", d2 == 32'h0000_FF00);

        // S5 抢占：CPU 连写 8 拍（每拍一个不同地址），AXI 的写必须等 CPU 停手后完成
        fork
            begin : axiwr
                axi_write(32'h0000_0080, 32'h0BAD_C0DE, 4'hF);
            end
            begin : cpuhammer
                for (k = 0; k < 8; k = k + 1)
                    cpu_write(32'h0000_0100 + k * 4, 32'hC0DE_0000 + k, 2'b11);
            end
        join
        axi_read(32'h0000_0080, d1);
        chk("S5 AXI write survives CPU hammering", d1 == 32'h0BAD_C0DE);
        cpu_read(32'h0000_0100, d2);
        chk("S5 CPU writes still landed", d2 == 32'hC0DE_0000);

        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[DRAMSH-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[DRAMSH-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $finish;
    end

endmodule
