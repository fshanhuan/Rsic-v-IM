`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * uart_rx.sv — 115200 8N1 串口接收（用于板级程序引导）
 * -----------------------------------------------------------------------------
 * 为什么自己写而不是用 axi_uartlite：
 *   1. axi_uartlite 要 AXI-lite（jtag_axi 那条路我们放弃了，见 docs/BOOT_UART.md）；
 *   2. 这里只做 RX、无校验位/流控，60 行就够，而且**能在 iverilog 里仿真**
 *      （IP 在纯 RTL 工程里很难端到端仿真）。
 *
 * ★ 接口契约：
 *   - rx 是**异步**输入，内部两级同步器消亚稳态；空闲电平必须是高。
 *   - valid 是**单拍脉冲**，valid 那一拍 data 才是有效字节（上一层必须当拍接走）。
 *   - rst 是**同步**高有效复位（本设计里接 cpu_rst，由 reset_sync 产生）。
 *   - 采样点在每个位的**中点**：起始位先等到半位中点再确认一次（去毛刺），
 *     之后每 BIT_TICKS 采样一位，最后一位是停止位；停止位不是高 → 整帧丢弃。
 *
 * ★ 时序参数：BIT_TICKS = round(CLK_FREQ/BAUD)。50MHz/115200 = 434.03 → 取 434，
 *   单帧 10 位累计误差 (434.03-434)*10/434 = 0.07%，远小于 2% 的容限。
 *   ★ 不变量：改时钟频率必须同时改 CLK_FREQ 参数，否则波特率整体跑偏。
 * ============================================================================= */
module uart_rx #(
    // 采样时钟频率（Hz）
    parameter integer CLK_FREQ = 50_000_000,
    // 波特率（bps）
    parameter integer BAUD     = 115_200
) (
    input  logic       clk,
    input  logic       rst,        // 同步复位，高有效
    input  logic       rx,         // 异步串行输入（空闲为高）
    output logic [7:0] data,       // 收到的字节
    output logic       valid       // 单拍脉冲：data 有效
);

    // 每位的时钟拍数与半位拍数
    localparam integer BIT_TICKS  = (CLK_FREQ + (BAUD / 2)) / BAUD;
    localparam integer HALF_TICKS = BIT_TICKS / 2;

    // ---- 1) 两级同步器（异步输入 → 本时钟域） ----
    (* ASYNC_REG = "TRUE" *) logic rx_m, rx_s;
    always_ff @(posedge clk) begin
        rx_m <= rx;
        rx_s <= rx_m;
    end

    // ---- 2) 接收状态机 ----
    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,   // 等起始位下降沿
        S_START = 2'd1,   // 半位中点复确认
        S_DATA  = 2'd2,   // 8 个数据位，LSB first
        S_STOP  = 2'd3    // 停止位
    } st_t;

    st_t         st;
    logic [15:0] cnt;      // 位内计时（BIT_TICKS < 65536）
    logic [ 2:0] bit_i;    // 位序号 0..7
    logic [ 7:0] sh;       // 移位寄存器

    always_ff @(posedge clk) begin
        if (rst) begin
            st    <= S_IDLE;
            cnt   <= 16'd0;
            bit_i <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;                       // 默认无输出，只在停止位那一拍拉高
            case (st)
                S_IDLE: begin
                    // rx_s 是同步后的电平，低电平即起始位候选
                    if (!rx_s) begin
                        st  <= S_START;
                        cnt <= 16'd0;
                    end
                end

                S_START: begin
                    // 等到起始位的**中点**再复确认一次，抗毛刺/抗边沿抖动
                    if (cnt == HALF_TICKS - 1) begin
                        cnt <= 16'd0;
                        if (!rx_s) begin
                            st    <= S_DATA;
                            bit_i <= 3'd0;
                        end else begin
                            st <= S_IDLE;            // 伪起始位（毛刺），丢弃
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                S_DATA: begin
                    // 每一位的中点采样
                    if (cnt == BIT_TICKS - 1) begin
                        cnt <= 16'd0;
                        // UART 是 LSB first：新采到的位移到最高位，8 次后正好对齐
                        sh <= {rx_s, sh[7:1]};
                        if (bit_i == 3'd7) begin
                            st <= S_STOP;
                        end else begin
                            bit_i <= bit_i + 3'd1;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                S_STOP: begin
                    if (cnt == BIT_TICKS - 1) begin
                        cnt <= 16'd0;
                        st  <= S_IDLE;
                        // ★ 停止位必须是高；不是高说明波特率错/帧错位，整帧丢弃（不置 valid）
                        if (rx_s) begin
                            data  <= sh;
                            valid <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
