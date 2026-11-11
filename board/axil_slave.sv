`timescale 1ns / 1ps

/* =============================================================================
 * board/axil_slave.sv -- AXI4-Lite 从口 → 本 SoC 的"简单总线"（#6 / #7 的桥）
 * -----------------------------------------------------------------------------
 * 作用：AXI4-Lite 从口 ↔ 我们那套"简单总线"，让 PS / 任何 AXI 主机能读写 128 KB DRAM。
 *   · #6：外设/存储从此有标准入口；
 *   · #7：PS（Zynq 的 AXI 主机）通过它读写 RISC-V 的 DRAM。
 *
 * 协议子集（够用、好验、边界写清）：
 *   · 一次一笔事务（无 outstanding、无 ID），只支持单拍（AXI4-Lite 无 burst）；
 *   · resp 恒 OKAY；忽略 prot/cache/qos；不做跨时钟域。
 *   · **AW 与 W 是两个独立通道**，各自握手、各自锁存，凑齐才发起写事务（见下）。
 *
 * ★★ 2026-11-11 上板抓到的真 bug（务必保持这个结构）：
 *   最初写成"awvalid 与 wvalid 必须**同拍**才受理"（awready=wready=(st==IDLE)）。
 *   仿真里我自己的 BFM 就是同拍给两个通道，所以一路绿灯；
 *   但真实主机（PS 的 M_AXI_GP0 经 axi_protocol_converter）是
 *   **先给 AW、握手完成后再给 W**：
 *       第1拍 AWVALID=1，看到 AWREADY=1 → 主机认为 AW 已完成，撤掉 AWVALID
 *       第2拍 WVALID=1  → 从端还在等"两个同时为 1"，永远等不到 → 事务卡死
 *   板上现象：PS 读 0x4001_0044 正常打印，写 0x4001_0040 时卡住，后续都不打印。
 *   修法：AW、W 各自握手并各自锁存（aw_got / w_got），两者齐了才进写状态。
 *
 * ★ 简单总线侧是**请求/授权**契约（不是"发一拍就当成了"）：
 *     m_req 保持到 m_gnt；被授权后：写下一拍 bvalid，读下一拍 m_rvalid 后 rvalid。
 *   这样桥能接"当拍就收"的 BRAM，也能接带借用仲裁的 board/dram_shared.sv。
 * ============================================================================= */
module axil_slave (
    // ---------------- AXI4-Lite 从口 ----------------
    input  logic        aclk,
    input  logic        aresetn,

    input  logic [31:0] s_axil_awaddr,
    input  logic [2:0]  s_axil_awprot,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,

    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,

    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,

    input  logic [31:0] s_axil_araddr,
    input  logic [2:0]  s_axil_arprot,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,

    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    // ---------------- 本 SoC 简单总线侧 ----------------
    output logic [31:0] m_addr,
    output logic        m_req,
    output logic        m_we,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wstrb,
    input  logic        m_gnt,
    input  logic        m_rvalid,
    input  logic [31:0] m_rdata
);

    localparam logic [2:0] S_IDLE = 3'd0,
                           S_WRQ  = 3'd1,   // 写请求等 m_gnt
                           S_WB   = 3'd2,   // bvalid 等 bready
                           S_RDQ  = 3'd3,   // 读请求等 m_gnt
                           S_RW   = 3'd4,   // 等 m_rvalid
                           S_RB   = 3'd5;   // rvalid 等 rready

    logic [2:0]  st;

    // 写通道：AW / W 各自锁存
    logic        aw_got, w_got;
    logic [31:0] awaddr_r, wdata_q;
    logic [3:0]  wstrb_q;

    // 读通道
    logic [31:0] araddr_r;
    logic [31:0] rdata_r;

    // ---------------- 通道握手 ----------------
    assign s_axil_awready = (st == S_IDLE) && !aw_got;
    assign s_axil_wready  = (st == S_IDLE) && !w_got;
    // 读只在"没有待处理的写"时受理
    assign s_axil_arready = (st == S_IDLE) && !(aw_got && w_got) && !w_got;

    assign s_axil_bvalid  = (st == S_WB);
    assign s_axil_rvalid  = (st == S_RB);
    assign s_axil_bresp   = 2'b00;             // OKAY
    assign s_axil_rresp   = 2'b00;
    assign s_axil_rdata   = rdata_r;

    assign m_addr  = (st == S_WRQ) ? awaddr_r : araddr_r;
    assign m_req   = (st == S_WRQ) || (st == S_RDQ);
    assign m_we    = (st == S_WRQ);
    assign m_wdata = wdata_q;
    assign m_wstrb = wstrb_q;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            st       <= S_IDLE;
            aw_got   <= 1'b0;
            w_got    <= 1'b0;
            awaddr_r <= 32'h0;
            wdata_q  <= 32'h0;
            wstrb_q  <= 4'h0;
            araddr_r <= 32'h0;
            rdata_r  <= 32'h0;
        end else begin
            // ---- 两个写通道各自握手（可以相隔很多拍）----
            if (s_axil_awvalid && s_axil_awready) begin
                awaddr_r <= s_axil_awaddr;
                aw_got   <= 1'b1;
            end
            if (s_axil_wvalid && s_axil_wready) begin
                wdata_q  <= s_axil_wdata;
                wstrb_q  <= s_axil_wstrb;
                w_got    <= 1'b1;
            end

            case (st)
                S_IDLE: begin
                    if (s_axil_arvalid && s_axil_arready) begin
                        araddr_r <= s_axil_araddr;
                        st       <= S_RDQ;
                    end else if (aw_got && w_got) begin
                        st       <= S_WRQ;
                    end
                end
                S_WRQ: begin
                    if (m_gnt) begin
                        aw_got <= 1'b0;        // 事务已发起，释放两个通道
                        w_got  <= 1'b0;
                        st     <= S_WB;
                    end
                end
                S_WB:   if (s_axil_bready) st <= S_IDLE;
                S_RDQ:  if (m_gnt) st <= S_RW;
                S_RW:   if (m_rvalid) begin rdata_r <= m_rdata; st <= S_RB; end
                S_RB:   if (s_axil_rready) st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end

    // 未使用的 AXI 边带：显式忽略（lint 干净，也表明我们知道它们存在）
    wire _unused = &{1'b0, s_axil_awprot, s_axil_arprot};

endmodule
