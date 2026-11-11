`timescale 1ns / 1ps

/* =============================================================================
 * board/board_top_ps.sv -- #7：把整颗 SoC 挂到 Zynq PS 的 AXI 总线上
 * -----------------------------------------------------------------------------
 * 结构：
 *     PS7 (ARM)  --M_AXI_GP0-->  AXI Interconnect  --AXI-Lite-->  本模块
 *                                                                  └ board_top(AXIL_EN=1)
 *                                                                     ├ CPU / IROM / DRAM
 *                                                                     └ AXI 从口 → 双口 DRAM
 *
 * 时钟（**关键约束**）：FCLK_CLK0 = 50 MHz 同时驱动 `sys_clk` 与 `axil_aclk`。
 *   board_top 的 AXI 从口**不做跨时钟域**（没有异步 FIFO），两路必须同源同频。
 *   在 BD 里就是同一个 FCLK_CLK0 接到本模块的 fclk，再由内部一分为二。
 *
 * 复位：PS 的 peripheral_aresetn（低有效）同时复位 CPU 与 AXI 桥。
 *
 * 为什么用 IROM_BOOT=2（PS 装载，不再是串口引导）：
 *   PS 侧可以通过 AXI 直接改 DRAM 和控制寄存器，但**取指**必须走 IROM，而 IROM
 *   只有 CPU 自己能写（数据窗口）。所以上电流程是：
 *     PS 起来 → PS 把镜像灌进 DRAM → 写 HOLD=0 放行 CPU
 *     → CPU 的 stage-0 stub 把 DRAM 抄进代码窗口 → 跳过去跑 monitor。
 *   stub 只有 20 来条指令，固化在 IROM 顶部 1 KB，不占搬运目标区间
 *   （地址布局见 tools/gen_stub.py）。
 *
 * 引脚：led[6:0]（板载 LED）、uart_tx/uart_rx（PL 串口，RISC-V 自己的 console）。
 * ============================================================================= */
module board_top_ps #(
    parameter IROM_WORDS = 16384,
    parameter DRAM_WORDS = 32768,
    /* ★ 双核协同（第 1 步）：IROM 里固化的是**几百字节的 stage-0 stub**，不是 monitor。
     *   monitor 的镜像由 PS 通过 AXI 灌进 DRAM，stub 负责 DRAM → 代码窗口搬运。
     *   生成方式见 tools/gen_stub.py（手写汇编 + 逐字编码，不依赖工具链）。 */
    parameter IROM_INIT  = "ps_stub.hex",
    parameter IROM_BOOT  = 2
) (
    input  logic        fclk,             // PS FCLK_CLK0 = 50 MHz
    input  logic        periph_resetn,    // PS peripheral_aresetn（低有效）

    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [6:0]  led,
    // 双核协同（第 3 步）：CPU → PS 中断，BD 里接 IRQ_F2P
    output logic        irq_ps,

    // ---------------- AXI4-Lite 从口（接 PS 的 M_AXI_GP0） ----------------
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
    input  logic        s_axil_rready
);

    board_top #(
        .IROM_WORDS (IROM_WORDS),
        .DRAM_WORDS (DRAM_WORDS),
        .IROM_INIT  (IROM_INIT),
        .IROM_BOOT  (IROM_BOOT),
        .AXIL_EN    (1)
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
        .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata  (s_axil_wdata),  .s_axil_wstrb (s_axil_wstrb),
        .s_axil_wvalid (s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp  (s_axil_bresp),  .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready (s_axil_bready),
        .s_axil_araddr (s_axil_araddr), .s_axil_arprot (s_axil_arprot),
        .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata  (s_axil_rdata),  .s_axil_rresp (s_axil_rresp),
        .s_axil_rvalid (s_axil_rvalid), .s_axil_rready(s_axil_rready)
        // debug_* 输出不接：它们只是观测口（(* keep *) 保证不被优化掉）
    );

endmodule
