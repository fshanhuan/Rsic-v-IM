`timescale 1ns / 1ps

/* =============================================================================
 * i2c_mmio.sv — 把 i2c_master 挂到 MMIO 上（5 个寄存器一块）
 * -----------------------------------------------------------------------------
 * 为什么必须上 MMIO，而不是把初始化序列写死在 RTL 里：
 *   1) **热插拔**：ADV7511 要求 HPD 为高才允许上电，而且 HPD 低时大部分寄存器
 *      会被复位。显示器什么时候插上是不确定的 —— 配置必须能在运行时反复做。
 *   2) **迭代速度**：ADV7511 要写几十个寄存器，写死在 RTL 里每改一个数就要重新
 *      综合（28 分钟）；挂在 MMIO 上以后改 C 代码重编只要几秒。
 *   3) 后面 ARM 侧也要配这条总线（双核协同），寄存器口比"RTL 状态机"通用。
 *
 * 寄存器（相对 base，共 5 个）：
 *   +0  0x00  CTRL    WO  bit0 START  bit1 BYTE  bit2 STOP  bit3 R/W(1=读)  bit4 NACK
 *   +1  0x04  TXDATA  WO  要发送的字节
 *   +2  0x08  RXDATA  RO  最近一次读到的字节
 *   +3  0x0C  STATUS  RO  bit0 busy  bit1 done(粘滞)  bit2 ack
 *                          bit3 SCL 引脚电平  bit4 SDA 引脚电平
 *   +4  0x10  CLR     WO  写 bit0=1 → 清 done
 *
 * ★ 为什么 done 是"粘滞位 + 显式清除"，而不是"读即清"：
 *   本工程的 DCache 对 uncacheable 读会**重复发一次**（docs/CHECKPOINT_v13 §9 的 P4），
 *   "读即清"会在那个重复读上把结果吞掉 —— 这正是 RXDATA 吃过一次的亏
 *   （board_top.sv 里 RXDATA/RXPOP 分开就是那次修复）。所以这里同样：
 *   状态只读，清除必须显式写 CLR。
 *
 * ★ 软件用法（见 sw/monitor.c 的 x 命令）：
 *     写 CTRL 前先等 STATUS.busy==0；
 *     写 CTRL 之后轮询 STATUS.done，再写 CLR 清掉。
 *   一次操作 90 us（100 kHz 下 9 个 SCL 周期），轮询完全来得及。
 * ============================================================================= */
module i2c_mmio #(
    parameter int CLK_HZ = 50_000_000,
    parameter int SCL_HZ = 100_000
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        we,          // 本拍有一次 MMIO 写
    input  logic [5:0]  idx,         // 全局 MMIO 索引
    input  logic [5:0]  base,        // 本实例基索引，占用 base..base+4
    input  logic [31:0] wdata,
    output logic [31:0] rdata,       // 只在本实例范围内非 0

    output logic        scl_oe,
    output logic        sda_oe,
    input  logic        sda_rd,

    output logic        m_busy,      // 给状态灯/调试用
    output logic        m_done,
    output logic        m_ack
);

    localparam logic [5:0] R_CTRL = 6'd0, R_TX = 6'd1, R_RX = 6'd2,
                           R_ST   = 6'd3, R_CLR = 6'd4;

    wire [5:0] off  = idx - base;
    wire       hit  = (idx >= base) && (idx < (base + 6'd5));
    wire       sel  = we && hit;

    /* ------------------------------ i2c_master ------------------------------ */
    logic       start_req, byte_req, stop_req;
    logic       byte_rw, read_nack;
    logic [7:0] tx_reg, m_rx;
    logic       m_done_i, m_ack_i;

    assign start_req = sel && (off == R_CTRL) && wdata[0];
    assign byte_req  = sel && (off == R_CTRL) && wdata[1];
    assign stop_req  = sel && (off == R_CTRL) && wdata[2];
    // byte_rw / read_nack 由 i2c_master 在 byte_req 那一拍采样，组合给出即可
    assign byte_rw   = wdata[3];
    assign read_nack = wdata[4];

    always_ff @(posedge clk) begin
        if (rst) tx_reg <= 8'd0;
        else if (sel && (off == R_TX)) tx_reg <= wdata[7:0];
    end

    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) u_master (
        .clk       (clk),
        .rst       (rst),
        .start_req (start_req),
        .byte_req  (byte_req),
        .stop_req  (stop_req),
        .byte_rw   (byte_rw),
        .read_nack (read_nack),
        .byte_tx   (tx_reg),
        .byte_rx   (m_rx),
        .ack_rx    (m_ack_i),
        .busy      (m_busy),
        .done      (m_done_i),
        .scl_oe    (scl_oe),
        .sda_oe    (sda_oe),
        .sda_i     (sda_rd)
    );

    /* ------------------------------ 状态位 ------------------------------ */
    always_ff @(posedge clk) begin
        if (rst) begin
            m_done <= 1'b0;
            m_ack  <= 1'b0;
        end else begin
            if (m_done_i) begin
                m_done <= 1'b1;
                m_ack  <= m_ack_i;
            end
            // ★ 清除放在后面：同一拍既完成又清除时，以清除为准
            if (sel && (off == R_CLR) && wdata[0]) m_done <= 1'b0;
        end
    end

    /* ------------------------------ 读回 ------------------------------ */
    always_comb begin
        rdata = 32'b0;
        if (hit) begin
            case (off)
                R_RX:  rdata = {24'b0, m_rx};
                R_ST:  rdata = {27'b0, sda_rd, scl_oe, m_ack, m_done, m_busy};
                default: rdata = 32'b0;      // CTRL/TX/CLR 读回 0
            endcase
        end
    end

endmodule
