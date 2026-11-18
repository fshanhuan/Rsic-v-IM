`timescale 1ns / 1ps

/* =============================================================================
 * trigger_unit.sv — 记录仪的边沿/电平触发（S4）
 * -----------------------------------------------------------------------------
 * 为什么"触发"要单独做一块硬件，而不是丢给软件判断：
 *   XADC 是 200 kHz 连续采样的，软件轮询 MMIO 读样本的间隔是"微秒级不确定"，
 *   一旦错过就永远补不回来。真实的示波器/记录仪必须**在采样节拍上**判定触发，
 *   软件只负责事后读结果。所以触发判定放在硬件里，一拍都不漏。
 *
 * 语义（与台式示波器一致）：
 *   mode 0 = 上升沿：prev < TH 且 now >= TH
 *   mode 1 = 下降沿：prev >= TH 且 now <  TH
 *   mode 2 = 任意边沿：上面两种都算
 *   mode 3 = 电平  ：now >= TH 期间一直有效
 *
 * 两个防抖/防刷屏机制：
 *   · fired 粘滞：触发一次置位，直到软件写 clear 才清 —— 软件可以慢慢处理
 *   · holdoff：触发后再等 HOLDOFF 个样本才允许下一次触发，等价于示波器的
 *     holdoff 旋钮，防止在噪声上连续触发把缓冲冲掉
 *
 * ★ 无触发时 prev 也必须跟着走：否则信号在阈值附近抖动时会连续误触发。
 * ============================================================================= */
module trigger_unit #(
    parameter int HOLDOFF = 64          // 两次触发之间至少要过多少个样本
) (
    input  logic        clk,
    input  logic        rst,

    /* ---- 采样流（来自 xadc_sampler 的有效拍）---- */
    input  logic [15:0] sample,
    input  logic        sample_valid,

    /* ---- 配置（MMIO）---- */
    input  logic [15:0] threshold,
    input  logic [ 1:0] mode,
    input  logic        enable,
    input  logic        clear,          // 单拍：清 fired / 计数

    /* ---- 结果 ---- */
    output logic        trig,           // 单拍脉冲：本样本触发
    output logic        fired,          // 粘滞：触发过（等 clear）
    output logic [31:0] trig_cnt,       // 累计触发次数
    output logic [15:0] last_sample,    // 最近一个样本（便于软件对照）
    output logic        above           // 当前是否 >= 阈值（调试/显示用）
);

    logic [15:0] prev;
    logic        above_r;
    logic [15:0] hold_cnt;

    wire [15:0] hold_max = (HOLDOFF < 1) ? 16'd0 : (HOLDOFF[15:0] - 16'd1);

    /* 边沿判定用 prev 与当前样本比较；电平判定只看当前 */
    wire rise  = (prev <  threshold) && (sample >= threshold);
    wire fall  = (prev >= threshold) && (sample <  threshold);
    wire any_e = rise | fall;

    wire cond =
        (mode == 2'd0) ? rise  :
        (mode == 2'd1) ? fall  :
        (mode == 2'd2) ? any_e :
                         (sample >= threshold);

    wire hold_ok = (hold_cnt == 16'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            prev        <= 16'd0;
            above_r     <= 1'b0;
            trig        <= 1'b0;
            fired       <= 1'b0;
            trig_cnt    <= 32'd0;
            last_sample <= 16'd0;
            hold_cnt    <= 16'd0;
        end else begin
            trig <= 1'b0;

            if (clear) begin
                fired    <= 1'b0;
                trig_cnt <= 32'd0;
                hold_cnt <= 16'd0;
            end

            if (sample_valid) begin
                /* ★ holdoff 必须以**样本**为单位递减，不能每拍都减：
                 *   sample_valid 之间隔着好几拍，按拍递减会把 holdoff
                 *   偷偷缩短成 1/N（TB 里实测 24 个样本期望 3 次、实际 6 次）。 */
                if (hold_cnt != 16'd0) hold_cnt <= hold_cnt - 16'd1;
                last_sample <= sample;
                above_r     <= (sample >= threshold);

                if (enable && cond && hold_ok) begin
                    trig     <= 1'b1;
                    fired    <= 1'b1;
                    trig_cnt <= trig_cnt + 32'd1;
                    hold_cnt <= hold_max;
                end

                /* ★ prev 每个样本都要更新（不管是否触发） */
                prev <= sample;
            end
        end
    end

    assign above = above_r;

endmodule
