`timescale 1ns / 1ps

/* =============================================================================
 * meas_unit.sv — 窗内测量：min / max / Vpp / 均值（S6）
 * -----------------------------------------------------------------------------
 * 为什么放在硬件里：
 *   这些量是"每来一个样本更新一次"的滚动统计。放在软件里就要逐样本读 MMIO，
 *   200 kHz 下 CPU 根本跟不上；放在硬件里 CPU 只需要**每隔一段时间读一次结果**。
 *   另外一个好处：窗口是**严格的 1024 个样本**（不依赖软件时序），
 *   同一段信号谁来测都是同一个数 —— 这对"可复现"很重要。
 *
 * 窗口：固定 1024 个样本（2 的幂，均值直接用移位，不需要除法器）。
 *   @200 kHz 采样率 → 一个窗口 = 5.12 ms（约 195 Hz 更新率）。
 *
 * 数据格式：直接对 XADC 的原始 16 位值做统计（12 位结果左对齐在 raw[15:4]）。
 *   软件换算：V = (raw>>4)/4096 × 1.0 V（AD11 量程 0~1 V）。
 *
 * 溢出：sum 用 32 位累加 1024 个 16 位数，最大 1024×65535 = 67 100 640 < 2^32，
 *   安全。均值 = sum >> 10。
 * ============================================================================= */
module meas_unit #(
    parameter int WIN_LOG2 = 10          // 窗口 = 2^10 = 1024 个样本
) (
    input  logic        clk,
    input  logic        rst,

    /* ---- 采样流 ---- */
    input  logic [15:0] sample,
    input  logic        sample_stb,

    /* ---- 控制 ---- */
    input  logic        clr,             // 单拍：清窗口（统计重新开始）

    /* ---- 结果（每 1024 个样本更新一次，整窗保持不变）---- */
    output logic [15:0] min_v,
    output logic [15:0] max_v,
    output logic [15:0] vpp,             // max - min
    output logic [15:0] mean_v,          // sum >> WIN_LOG2
    output logic [31:0] win_cnt          // 已完成的窗口数
);

    localparam int WIN = (1 << WIN_LOG2);

    logic [15:0] mn, mx;
    logic [31:0] acc;
    logic [WIN_LOG2-1:0] cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            mn      <= 16'hFFFF;
            mx      <= 16'h0000;
            acc     <= 32'd0;
            cnt     <= '0;
            min_v   <= 16'h0000;
            max_v   <= 16'h0000;
            vpp     <= 16'h0000;
            mean_v  <= 16'h0000;
            win_cnt <= 32'd0;
        end else if (clr) begin
            mn      <= 16'hFFFF;
            mx      <= 16'h0000;
            acc     <= 32'd0;
            cnt     <= '0;
        end else if (sample_stb) begin
            /* 逐样本更新极值与累加 */
            if (sample < mn) mn <= sample;
            if (sample > mx) mx <= sample;
            acc <= acc + {16'd0, sample};
            cnt <= cnt + 1'b1;

            /* 窗口满：锁存结果并重新开始 */
            if (cnt == WIN[WIN_LOG2-1:0] - 1'b1) begin
                /* 注意极值要把本样本也算进去，所以用组合后的值 */
                min_v  <= (sample < mn) ? sample : mn;
                max_v  <= (sample > mx) ? sample : mx;
                /* 均值：本样本也要加进去 */
                mean_v <= (acc + {16'd0, sample}) >> WIN_LOG2;
                vpp    <= ((sample > mx) ? sample : mx) - ((sample < mn) ? sample : mn);
                win_cnt <= win_cnt + 32'd1;

                mn  <= 16'hFFFF;
                mx  <= 16'h0000;
                acc <= 32'd0;
                cnt <= '0;
            end
        end
    end

endmodule
