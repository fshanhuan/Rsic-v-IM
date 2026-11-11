`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_axil.sv -- axil_slave 的协议/功能测试（#6）
 * -----------------------------------------------------------------------------
 * 测的是"桥"本身，不接我们的 SoC：一个 AXI4-Lite 主机 BFM + 一个带字节使能的
 * 同步 RAM 从端，把 AXI 侧的行为和"简单总线"侧的时序**分开**验证。这样桥接错了
 * 就是桥的错，不会和 soc_bus/DCache 的时序混在一起。
 *
 * 判据：
 *   T1 写字 → 读回一致
 *   T2 字节写（wstrb=0010）只改对应字节，其余字节保持
 *   T3 两个地址互不干扰
 *   T4 握手规矩：bvalid/rvalid 在 bready/rready 之前不许自己掉
 *   T5 背靠背：写紧跟读（同一个 RTL 状态机回到 IDLE）
 *   T6 未写过的地址读回 0
 *
 * 用法： vvp sim/build/tb_axil.vvp
 * ============================================================================= */
module tb_axil;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;
    always #10 aclk = ~aclk;

    // ---------------- AXI4-Lite 主机侧 ----------------
    logic [31:0] awaddr = 32'h0, wdata = 32'h0, araddr = 32'h0;
    logic [3:0]  wstrb  = 4'h0;
    logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0;
    logic        arvalid = 1'b0, rready = 1'b0;
    logic        awready, wready, bvalid, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;

    // ---------------- 简单总线侧（请求/授权） ----------------
    logic [31:0] m_addr, m_wdata, m_rdata;
    logic        m_req, m_we, m_gnt, m_rvalid;
    logic [3:0]  m_wstrb;

    axil_slave u_bridge (
        .aclk (aclk), .aresetn (aresetn),
        .s_axil_awaddr (awaddr), .s_axil_awprot (3'b000),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata  (wdata),  .s_axil_wstrb (wstrb),
        .s_axil_wvalid (wvalid), .s_axil_wready(wready),
        .s_axil_bresp  (bresp),  .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr (araddr), .s_axil_arprot (3'b000),
        .s_axil_arvalid(arvalid),.s_axil_arready(arready),
        .s_axil_rdata  (rdata),  .s_axil_rresp (rresp),
        .s_axil_rvalid (rvalid), .s_axil_rready(rready),
        .m_addr  (m_addr), .m_req (m_req), .m_we (m_we),
        .m_wdata (m_wdata), .m_wstrb (m_wstrb),
        .m_gnt (m_gnt), .m_rvalid (m_rvalid), .m_rdata (m_rdata)
    );

    // ---------------- 从端：同步 RAM（字节使能 + 读打一拍 + 可暂停授权） ----------------
    logic [31:0] mem [0:255];
    logic [31:0] rdata_q;
    logic        gnt_enable = 1'b1;      // TB 可以拉低，测试桥是否保持 m_req
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) mem[i] = 32'h0;
        rdata_q = 32'h0;
    end

    assign m_gnt = m_req & gnt_enable;

    always @(posedge aclk) begin
        m_rvalid <= 1'b0;
        if (m_req && m_gnt) begin
            if (m_we) begin
                if (m_wstrb[0]) mem[m_addr[9:2]][7:0]   <= m_wdata[7:0];
                if (m_wstrb[1]) mem[m_addr[9:2]][15:8]  <= m_wdata[15:8];
                if (m_wstrb[2]) mem[m_addr[9:2]][23:16] <= m_wdata[23:16];
                if (m_wstrb[3]) mem[m_addr[9:2]][31:24] <= m_wdata[31:24];
            end else begin
                rdata_q  <= mem[m_addr[9:2]];
                m_rvalid <= 1'b1;
            end
        end
    end
    assign m_rdata = rdata_q;

    // ---------------- 主机 BFM ----------------
    // ★ 握手的关键：ready 要在**posedge 采样**（那一刻的组合值就是"本拍会被接收"），
    //   驱动/撤销放在 negedge。最初写成"在 negedge 等 ready"直接死锁：桥在 posedge
    //   受理后 ready 立刻变低，BFM 永远等不到它回来（B 通道还没握手）。
    task automatic axi_write(input [31:0] a, input [31:0] d, input [3:0] s);
        begin
            @(negedge aclk);
            awaddr = a; wdata = d; wstrb = s; awvalid = 1'b1; wvalid = 1'b1;
            do @(posedge aclk); while (!(awready && wready));
            @(negedge aclk);
            awvalid = 1'b0; wvalid = 1'b0;
            bready  = 1'b1;
            do @(posedge aclk); while (!bvalid);
            @(negedge aclk);
            bready  = 1'b0;
        end
    endtask

    task automatic axi_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge aclk);
            araddr = a; arvalid = 1'b1;
            do @(posedge aclk); while (!arready);
            @(negedge aclk);
            arvalid = 1'b0;
            rready  = 1'b1;
            do @(posedge aclk); while (!rvalid);
            d = rdata;
            @(negedge aclk);
            rready  = 1'b0;
        end
    endtask

    // ★ 真实主机（PS 经 axi_protocol_converter）是**先给 AW、握手完成后再给 W**。
    //   这个任务专门测通道分离：AW 与 W 之间故意隔 gap 拍。
    //   原来"两个通道必须同拍"的实现会在这里死锁（板上实测就卡在这）。
    task automatic axi_write_split(input [31:0] a, input [31:0] d, input [3:0] s,
                                   input integer gap);
        begin
            @(negedge aclk);
            awaddr = a; awvalid = 1'b1;
            do @(posedge aclk); while (!awready);
            @(negedge aclk); awvalid = 1'b0;
            for (k = 0; k < gap; k = k + 1) @(posedge aclk);
            @(negedge aclk);
            wdata = d; wstrb = s; wvalid = 1'b1;
            do @(posedge aclk); while (!wready);
            @(negedge aclk); wvalid = 1'b0;
            bready = 1'b1;
            do @(posedge aclk); while (!bvalid);
            @(negedge aclk); bready = 1'b0;
        end
    endtask

    integer npass = 0, nfail = 0;
    task automatic chk(input string name, input bit cond);
        begin
            if (cond) begin npass = npass + 1; $display("  [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    // T4：valid 一旦出现，就必须**保持到对方 ready**（AXI 的硬规定；掉了就是从端违约）
    //   做法：故意延迟 ready，在延迟的每一拍检查 bvalid/rvalid 是否又掉了。
    logic hold_b_ok, hold_r_ok, b_seen, r_seen;
    integer k;

    task automatic axi_write_slow_b(input [31:0] a, input [31:0] d, input [3:0] s,
                                    input integer stall);
        begin
            @(negedge aclk);
            awaddr = a; wdata = d; wstrb = s; awvalid = 1'b1; wvalid = 1'b1;
            do @(posedge aclk); while (!(awready && wready));
            @(negedge aclk); awvalid = 1'b0; wvalid = 1'b0;
            for (k = 0; k < stall; k = k + 1) begin
                @(posedge aclk);
                if (bvalid) b_seen = 1'b1;
                else if (b_seen) hold_b_ok = 1'b0;   // 没握手就掉了 -> 违约
            end
            @(negedge aclk); bready = 1'b1;
            do @(posedge aclk); while (!bvalid);
            @(negedge aclk); bready = 1'b0;
        end
    endtask

    task automatic axi_read_slow_r(input [31:0] a, output [31:0] d, input integer stall);
        begin
            @(negedge aclk);
            araddr = a; arvalid = 1'b1;
            do @(posedge aclk); while (!arready);
            @(negedge aclk); arvalid = 1'b0;
            for (k = 0; k < stall; k = k + 1) begin
                @(posedge aclk);
                if (rvalid) r_seen = 1'b1;
                else if (r_seen) hold_r_ok = 1'b0;
            end
            @(negedge aclk); rready = 1'b1;
            do @(posedge aclk); while (!rvalid);
            d = rdata;
            @(negedge aclk); rready = 1'b0;
        end
    endtask

    logic [31:0] d1, d2, d3, d4;
    initial begin
        $display("================================================================");
        $display(" tb_axil : axil_slave protocol / function test");
        $display("================================================================");
        #200 aresetn = 1'b1;
        #50;
        hold_b_ok = 1'b1; hold_r_ok = 1'b1;
        b_seen = 1'b0; r_seen = 1'b0;

        axi_write(32'h0000_0010, 32'hDEAD_BEEF, 4'hF);
        axi_read (32'h0000_0010, d1);
        chk("T1 word write/read back", d1 == 32'hDEAD_BEEF);

        axi_write(32'h0000_0010, 32'h0000_5500, 4'b0010);   // 只写 [15:8]
        axi_read (32'h0000_0010, d2);
        chk("T2 byte-lane write keeps other bytes", d2 == 32'hDEAD_55EF);

        axi_write(32'h0000_0020, 32'h1234_5678, 4'hF);
        axi_read (32'h0000_0010, d3);
        axi_read (32'h0000_0020, d4);
        chk("T3 addresses independent", (d3 == 32'hDEAD_55EF) && (d4 == 32'h1234_5678));

        // T5：背靠背（写之后立刻读另一个地址）
        axi_write(32'h0000_0030, 32'hA5A5_5A5A, 4'hF);
        axi_read (32'h0000_0030, d1);
        chk("T5 back-to-back write->read", d1 == 32'hA5A5_5A5A);

        axi_read (32'h0000_00C0, d2);
        chk("T6 unwritten address reads 0", d2 == 32'h0000_0000);

        // T4：故意把 bready/rready 延迟 4 拍，检查 valid 在没握手前不许掉
        axi_write_slow_b(32'h0000_0040, 32'h0BAD_F00D, 4'hF, 4);
        axi_read_slow_r (32'h0000_0040, d3, 4);
        chk("T4 write/read with delayed ready", d3 == 32'h0BAD_F00D);
        // T8：AW 与 W 相隔 3 拍（真实主机的时序）
        axi_write_split(32'h0000_0060, 32'h5A5A_1234, 4'hF, 3);
        axi_read(32'h0000_0060, d1);
        chk("T8 split AW/W channels", d1 == 32'h5A5A_1234);

        chk("T4 bvalid held until bready", hold_b_ok && b_seen);
        chk("T4 rvalid held until rready", hold_r_ok && r_seen);

        // T7：授权被拖住时（模拟 DRAM 仲裁里 CPU 占着口），桥必须保持 m_req，
        //     而且事务只发生**一次**（不能重复写）。
        gnt_enable = 1'b0;
        fork
            axi_write(32'h0000_0050, 32'hFEED_FACE, 4'hF);
            begin
                repeat (6) @(posedge aclk);
                gnt_enable = 1'b1;
            end
        join
        axi_read(32'h0000_0050, d4);
        chk("T7 write survives delayed grant", d4 == 32'hFEED_FACE);

        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[AXIL-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[AXIL-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $finish;
    end

endmodule
