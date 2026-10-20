`timescale 1ns / 1ps

/* =============================================================================
 * uart_tx.sv — 115200 8N1 串口发送器（v12（B）新增）
 * -----------------------------------------------------------------------------
 * 用途：把 CPU 的一句 `sw` 变成板上一串字节 —— 这是"能打印"的最小实现，也是 RTOS
 *   场景下 console/printf 的物理前提。板上的 J8 是 USB-TTL 桥（CP210x，宿主机看到
 *   COM9），J8-2 = PL_RS232_TX = 引脚 A17，正好和已经接好的 J8-1(RX,A16) 配对。
 *
 * ★ 与 uart_rx.sv 的口径完全对齐：CLK_FREQ / BAUD 两个参数、BIT_TICKS 同一个公式。
 *   两个模块必须用同一组参数，否则收发不同步（发 115200 收 9600 这种错误在波形上
 *   表现为"偶发错一个字节"，很难查）。
 *
 * ★ 接口契约：
 *   - send 是**单拍脉冲**，只在 busy=0 时被接收；busy=1 期间的 send 被**静默丢弃**
 *     （外设寄存器语义：写了就写，不排队）。软件要可靠连续发送必须轮询 status 的忙位
 *     —— 这正是下面 MMIO 里 STATUS 那个寄存器的意义。
 *   - 一帧 = 1 个起始位(0) + 8 个数据位(LSB first) + 1 个停止位(1) = 10 位
 *     = 10 × 434 拍 ≈ 4340 拍 @50MHz ≈ 86.8 us/字节，即 115200 的 11.5KB/s 上限。
 *   - tx 空闲态为 1（UART 的规定，不能反）。
 *
 * ★ 为什么不做 FIFO：本项目用它的场景是"打印调试字符串"，一个字节 87us 已经够慢，
 *   加 FIFO 只是让软件能更快地塞满它，不改变可观测行为。等真需要高速输出（比如把
 *   整个 trace 打出来）再加。
 * =========================================================================== */
module uart_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115_200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] data,   // 要发送的字节（send 那拍有效）
    input  logic       send,   // 单拍发送请求（busy=0 时被接收）
    output logic       tx,     // 串行输出（空闲为 1）
    output logic       busy    // 1 = 正在发送一帧（软件轮询用）
);

    // 每位占的时钟拍数，四舍五入：434 拍 @50MHz / 115200 ≈ 434.03 → 434
    //   误差 0.007%，远小于 UART 允许的 ±2%，所以不需要分数分频。
    localparam integer BIT_TICKS = (CLK_FREQ + (BAUD / 2)) / BAUD;
    // ★ 比较阈值单独做成**16 位**常量：直接写 `tick >= BIT_TICKS - 1` 时，
    //   BIT_TICKS 是 32 位 integer、tick 是 16 位，Verilator 会报
    //   WIDTHEXPAND（"Operator GTE expects 32 bits on the LHS"）。
    //   功能上没错（434 装得下 16 位），但 -Wall 下它会升级成 Error，
    //   让 lint 变成"永远红"的摆设 —— 那样下次真有问题就没人看了。
    //   ★ 这里的 lint_off 是有意的：初值表达式是 32 位的（参数算术），
    //     赋给 16 位 localparam 必然"截断"，而截断是安全的（值域已核算过）。
    /* verilator lint_off WIDTHTRUNC */
    localparam logic [15:0] BIT_LAST = BIT_TICKS - 1;
    /* verilator lint_on WIDTHTRUNC */

    // 状态：IDLE → START → D0..D7 → STOP → IDLE
    //   用"位计数 + tick 计数"两件寄存器实现，比写 11 个状态更省，也更不容易漏位。
    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_START = 2'd1,
        S_DATA  = 2'd2,
        S_STOP  = 2'd3
    } state_t;

    state_t       state;
    logic [ 2:0]  bit_idx;     // 当前正在发第几位（0..7，LSB first）
    logic [15:0]  tick;        // 当前位内的拍计数
    logic [ 7:0]  shift;       // 数据移位寄存器（LSB first）

    assign tx   = (state == S_IDLE) ? 1'b1 :
                  (state == S_START) ? 1'b0 :
                  (state == S_DATA) ? shift[0] :
                  /* S_STOP */        1'b1;
    assign busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            bit_idx <= 3'd0;
            tick    <= 16'd0;
            shift   <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tick <= 16'd0;
                    if (send) begin
                        shift   <= data;
                        bit_idx <= 3'd0;
                        state   <= S_START;   // 起始位从**下一拍**开始（tx 当拍还是 1）
                    end
                end

                S_START: begin
                    if (tick >= BIT_LAST) begin
                        tick  <= 16'd0;
                        state <= S_DATA;
                    end else tick <= tick + 16'd1;
                end

                S_DATA: begin
                    if (tick >= BIT_LAST) begin
                        tick <= 16'd0;
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else begin
                            bit_idx <= bit_idx + 3'd1;
                            shift   <= {1'b0, shift[7:1]};  // 右移，LSB first
                        end
                    end else tick <= tick + 16'd1;
                end

                S_STOP: begin
                    if (tick >= BIT_LAST) begin
                        tick  <= 16'd0;
                        state <= S_IDLE;      // 停止位走完才能接下一帧
                    end else tick <= tick + 16'd1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
