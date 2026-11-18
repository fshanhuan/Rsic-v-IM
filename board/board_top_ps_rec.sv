`timescale 1ns / 1ps

/* =============================================================================
 * board/board_top_ps_rec.sv -- S5：把**记录仪的 MMIO** 挂到 Zynq PS 的 AXI 上
 * -----------------------------------------------------------------------------
 * 目的：让 A9（ARM）能通过 AXI 读记录仪的寄存器/FIFO —— 这是"ARM 排空 + CSV"的
 *       硬件前提。现有的 `board_top_ps` 只把 **DRAM** 挂出去，MMIO 还在 CPU 私有总线上，
 *       ARM 看不见（原因见 docs/记录仪_HDMI_方案.md §31）。
 *
 * 结构：
 *     PS7 M_AXI_GP0 ──┬─ axi_interconnect M00 ─> s_axil_*       ─> board_top(AXIL_EN=1) ─> DRAM
 *                     └─ axi_interconnect M01 ─> s_axil_mmio_*  ─> axil_slave ─> rec_mmio
 *
 * 两个关键取舍（都为了"先跑通、可验证"）：
 *   1. **CPU 不进这个回路**：board_top 用 EXT_MMIO=0，记录仪寄存器只由 PS 访问，
 *      避免"CPU 和 PS 同时写同一个寄存器"的仲裁问题。IROM 里放 v18 的小程序（prog.hex），
 *      IROM_BOOT=0，CPU 跑它自己的演示，不影响 AXI。
 *   2. **ADC 用假 DRP**（方波码值），不接 XADC 原语：这样不占模拟引脚、不需要 DMA，
 *      也能稳定产生 200 kHz 的样本流供 ARM 排空。真器件接法见 board_top_rec.sv。
 *
 * 时钟/复位（**S5 的硬约束**）：fclk 与 periph_resetn 都来自 PS。
 *   必须先让 PS 把 FCLK0 打开、把 peripheral_aresetn 释放，ARM 才能访问 —— 否则
 *   从端不出响应。axil_slave 现在有 64 拍超时保护（回 SLVERR），不会再锁死 PS 互连。
 * ============================================================================= */
module board_top_ps_rec #(
    parameter IROM_WORDS = 16384,
    parameter DRAM_WORDS = 32768,
    parameter IROM_INIT  = "prog.hex",
    parameter IROM_BOOT  = 0,
    parameter int CLK_HZ  = 50_000_000,   // = PS 的 FCLK_CLK0
    parameter int POLL_HZ = 200_000
) (
    input  logic        fclk,             // PS FCLK_CLK0（本设计按 50 MHz 约束）
    input  logic        periph_resetn,    // PS peripheral_aresetn

    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [6:0]  led,
    output logic        irq_ps,

    // ---------------- AXI4-Lite 从口 0：DRAM（接 board_top 的存储口） ----------------
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

    // ---------------- AXI4-Lite 从口 1：记录仪 MMIO（rec_mmio 的寄存器） ----------------
    input  logic [31:0] s_axil_mmio_awaddr,
    input  logic [2:0]  s_axil_mmio_awprot,
    input  logic        s_axil_mmio_awvalid,
    output logic        s_axil_mmio_awready,
    input  logic [31:0] s_axil_mmio_wdata,
    input  logic [3:0]  s_axil_mmio_wstrb,
    input  logic        s_axil_mmio_wvalid,
    output logic        s_axil_mmio_wready,
    output logic [1:0]  s_axil_mmio_bresp,
    output logic        s_axil_mmio_bvalid,
    input  logic        s_axil_mmio_bready,
    input  logic [31:0] s_axil_mmio_araddr,
    input  logic [2:0]  s_axil_mmio_arprot,
    input  logic        s_axil_mmio_arvalid,
    output logic        s_axil_mmio_arready,
    output logic [31:0] s_axil_mmio_rdata,
    output logic [1:0]  s_axil_mmio_rresp,
    output logic        s_axil_mmio_rvalid,
    input  logic        s_axil_mmio_rready
);

    localparam int unsigned MMIO_IDX_W = 6;   // 只用低 6 位当寄存器索引（m_addr[7:2]）

    logic rst;
    assign rst = ~periph_resetn;

    /* ================= 1. SoC 本体（CPU + IROM/DRAM + DRAM 的 AXI 从口） ================= */
    logic        ext_we;
    logic [5:0]  ext_idx;
    logic [31:0] ext_wdata;
    logic [31:0] ext_rdata;

    board_top #(
        .IROM_WORDS (IROM_WORDS),
        .DRAM_WORDS (DRAM_WORDS),
        .IROM_INIT  (IROM_INIT),
        .IROM_BOOT  (IROM_BOOT),
        .AXIL_EN    (1),        // 打开 DRAM 的 AXI 从口
        .EXT_MMIO   (0)         // ★ 记录仪寄存器不从 CPU 侧走（见文件头取舍 1）
    ) u_top (
        .sys_clk   (fclk),
        .btn_rst_n (periph_resetn),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx),
        .led       (led),
        .irq_ps    (irq_ps),

        .axil_aclk    (fclk),
        .axil_aresetn (periph_resetn),
        .s_axil_awaddr (s_axil_awaddr), .s_axil_awprot (s_axil_awprot),
        .s_axil_awvalid(s_axil_awvalid),.s_axil_awready(s_axil_awready),
        .s_axil_wdata  (s_axil_wdata),  .s_axil_wstrb (s_axil_wstrb),
        .s_axil_wvalid (s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp  (s_axil_bresp),  .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready (s_axil_bready),
        .s_axil_araddr (s_axil_araddr), .s_axil_arprot (s_axil_arprot),
        .s_axil_arvalid(s_axil_arvalid),.s_axil_arready(s_axil_arready),
        .s_axil_rdata  (s_axil_rdata),  .s_axil_rresp (s_axil_rresp),
        .s_axil_rvalid (s_axil_rvalid), .s_axil_rready(s_axil_rready),

        .ext_we    (ext_we),
        .ext_idx   (ext_idx),
        .ext_wdata (ext_wdata),
        .ext_rdata (ext_rdata)
    );

    assign ext_rdata = 32'h0;   // EXT_MMIO=0 时 CPU 不读这段

    /* ================= 2. AXI-Lite → rec_mmio 的桥 ================= */
    logic [31:0] m_addr, m_wdata, m_rdata;
    logic        m_req, m_we, m_gnt, m_rvalid;
    logic [3:0]  m_wstrb;
    logic [31:0] mmio_rdata_comb;      // rec_mmio 的组合读数据

    axil_slave #(.GNT_TMO(64)) u_mmio_bridge (
        .aclk (fclk), .aresetn (periph_resetn),
        .s_axil_awaddr (s_axil_mmio_awaddr), .s_axil_awprot (s_axil_mmio_awprot),
        .s_axil_awvalid(s_axil_mmio_awvalid),.s_axil_awready(s_axil_mmio_awready),
        .s_axil_wdata  (s_axil_mmio_wdata),  .s_axil_wstrb (s_axil_mmio_wstrb),
        .s_axil_wvalid (s_axil_mmio_wvalid), .s_axil_wready(s_axil_mmio_wready),
        .s_axil_bresp  (s_axil_mmio_bresp),  .s_axil_bvalid(s_axil_mmio_bvalid),
        .s_axil_bready (s_axil_mmio_bready),
        .s_axil_araddr (s_axil_mmio_araddr), .s_axil_arprot (s_axil_mmio_arprot),
        .s_axil_arvalid(s_axil_mmio_arvalid),.s_axil_arready(s_axil_mmio_arready),
        .s_axil_rdata  (s_axil_mmio_rdata),  .s_axil_rresp (s_axil_mmio_rresp),
        .s_axil_rvalid (s_axil_mmio_rvalid), .s_axil_rready(s_axil_mmio_rready),
        .m_addr (m_addr), .m_req (m_req), .m_we (m_we),
        .m_wdata (m_wdata), .m_wstrb (m_wstrb),
        .m_gnt (m_gnt), .m_rvalid (m_rvalid), .m_rdata (m_rdata)
    );

    /* ---- 简单总线从端：rec_mmio（当拍收，读打一拍） ---- */
    logic        mmio_rvalid_q;
    logic [31:0] mmio_rdata_q;
    logic [5:0]  mmio_idx;

    assign mmio_idx = m_addr[7:2];
    assign m_gnt    = m_req;                 // rec_mmio 当拍就能收

    always_ff @(posedge fclk) begin
        if (rst) begin
            mmio_rvalid_q <= 1'b0;
            mmio_rdata_q  <= 32'h0;
        end else begin
            mmio_rvalid_q <= m_req & ~m_we;
            if (m_req & ~m_we) mmio_rdata_q <= mmio_rdata_comb;
        end
    end
    assign m_rvalid = mmio_rvalid_q;
    assign m_rdata  = mmio_rdata_q;

    /* ================= 3. 记录仪 MMIO + 采样 + 假 DRP ================= */
    logic [15:0] adc_rd_data, adc_last;
    logic [10:0] adc_level;
    logic        adc_full, adc_ovf;
    logic [31:0] adc_cnt;
    logic        adc_en, adc_clr_ovf, adc_rd_en;
    logic [6:0]  adc_ch0, adc_ch1;
    logic        adc_ch1_en;

    logic [6:0]  drp_daddr;
    logic        drp_den, drp_dwe;
    logic [15:0] drp_di, drp_do;
    logic        drp_drdy;

    rec_mmio u_rec (
        .clk (fclk), .rst (rst),
        .we (m_req & m_we), .idx (mmio_idx), .wdata (m_wdata),
        .rdata (mmio_rdata_comb),

        // I2C：本工程不接器件，全部钉住
        .h_scl_oe (), .h_sda_oe (), .h_sda_rd (1'b1),
        .a_scl_oe (), .a_sda_oe (), .a_sda_rd (1'b1),
        .f_h (16'h0000), .addr_h (7'h00),
        .id00_h (8'h00), .idf5_h (8'h00), .idf6_h (8'h00),
        .pd_h (1'b0), .h_busy (1'b0),
        .f_a (16'h0000), .addr_a (7'h00),
        .id00_a (8'h00), .idf5_a (8'h00), .idf6_a (8'h00),
        .pd_a (1'b0), .a_busy (1'b0),
        .health (8'h55),

        // 显示/DAC/文本：本工程不接，输出悬空
        .col_wr (), .col_col (), .col_min (), .col_max (),
        .col_wr_bank (1'b0), .disp_commit (),
        .text_we (), .text_addr (), .text_data (),
        .dac_wr (), .dac_data (),

        // ADC / FIFO
        .adc_en (adc_en), .adc_clr_ovf (adc_clr_ovf), .adc_rd_en (adc_rd_en),
        .adc_ch0 (adc_ch0), .adc_ch1 (adc_ch1), .adc_ch1_en (adc_ch1_en),
        .adc_rd_data (adc_rd_data), .adc_last (adc_last),
        .adc_level (adc_level), .adc_full (adc_full), .adc_ovf (adc_ovf),
        .adc_cnt (adc_cnt),

        // 触发/测量：不做
        .trig_th (), .trig_mode (), .trig_en (), .trig_clear (),
        .trig_fired (1'b0), .trig_above (1'b0), .trig_cnt (32'h0),
        .meas_min (16'h0), .meas_max (16'h0), .meas_mean (16'h0), .meas_cnt (32'h0)
    );

    xadc_sampler #(
        .CLK_HZ  (CLK_HZ),
        .POLL_HZ (POLL_HZ),
        .FIFO_AW (10)
    ) u_adc (
        .clk (fclk), .rst (rst),
        .en (adc_en), .ch0 (adc_ch0), .ch1 (adc_ch1), .ch1_en (adc_ch1_en),
        .daddr (drp_daddr), .den (drp_den), .dwe (drp_dwe), .di (drp_di),
        .do_ (drp_do), .drdy (drp_drdy),
        .rd_en (adc_rd_en), .clr_ovf (adc_clr_ovf),
        .rd_data (adc_rd_data), .level (adc_level),
        .full (adc_full), .overflow (adc_ovf), .sample_cnt (adc_cnt),
        .last_data (adc_last), .sample_stb ()
    );

    /* ---- 假 DRP：3 拍后给数据，码值在 0x8000±0x200 之间方波跳（≈±32 码） ---- */
    logic [2:0]  drp_dly;
    logic [7:0]  drp_sq;
    logic [15:0] drp_val;

    always_ff @(posedge fclk) begin
        if (rst) begin
            drp_dly  <= 3'd0;
            drp_sq   <= 8'd0;
            drp_do   <= 16'h8000;
            drp_drdy <= 1'b0;
        end else begin
            drp_drdy <= 1'b0;
            if (drp_den) begin
                drp_dly <= 3'd3;
            end else if (drp_dly != 3'd0) begin
                drp_dly <= drp_dly - 3'd1;
                if (drp_dly == 3'd1) begin
                    drp_drdy <= 1'b1;
                    drp_do   <= drp_val;
                    drp_sq   <= drp_sq + 8'd1;
                end
            end
        end
    end

    // 方波：低 128 个样本 -512，高 128 个样本 +512（XADC 结果左对齐，故左移 4 位）
    assign drp_val = drp_sq[7] ? (16'h8000 + 16'h0200) : (16'h8000 - 16'h0200);

    // 未使用的 DRP 边带
    wire _unused_drp = &{1'b0, drp_daddr, drp_dwe, drp_di};

endmodule
