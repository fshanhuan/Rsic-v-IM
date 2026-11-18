`timescale 1ns / 1ps

/* =============================================================================
 * hdmi_meas.sv — 在**硬件上**量 HDMI 时序（S1b 的实测手段）
 * -----------------------------------------------------------------------------
 * 为什么需要它：
 *   S1b 的验收标准是"屏幕上出现 800x600 彩条"，但那要先有显示器和 ADV7511
 *   配置成功。在那之前，唯一能证明"时序生成器是对的"的办法，就是**在片内
 *   把一帧的真实参数数出来**：一帧多少像素时钟、多少行、DE 有效多少点、
 *   hsync/vsync 各低多少个时钟。
 *
 *   这些数是可以**预言**的：800x600@60、像素时钟 40.000 MHz 时
 *     H total = 800+40+128+88 = 1056，V total = 600+1+4+23 = 628
 *     一帧 = 1056 x 628 = 663 168 像素时钟
 *     DE  = 800 x 600 = 480 000
 *     hsync 低 = 128 x 628 = 80 384
 *     vsync 低 = 4 x 1056 = 4 224
 *   硬件量出来的数只要和这组完全一致，就说明时序发生器在真板子上跑得对，
 *   与"显示器有没有插"无关。
 *
 * 跨时钟域：这一块全在 pix_clk 域。输出值在 vsync 下降沿整体更新，
 *   之后**整帧 16.7 ms 不变**，所以 50 MHz 侧直接读是安全的（不需要握手）。
 * ============================================================================= */
module hdmi_meas (
    input  logic        pix_clk,
    input  logic        rst_pix,

    input  logic        hsync,
    input  logic        vsync,
    input  logic        de,

    output logic [31:0] frame_clk,     // 上一帧的像素时钟数
    output logic [15:0] frame_lines,   // 上一帧的行数
    output logic [31:0] de_pix,        // 上一帧 DE 有效的像素数
    output logic [31:0] hs_low,        // 上一帧 hsync 低电平时钟数
    output logic [31:0] vs_low,        // 上一帧 vsync 低电平时钟数
    output logic [31:0] frame_cnt      // 已经数完的帧数（看它在涨 = 有帧）
);

    logic hs_q, vs_q;
    logic hs_fall, vs_fall;

    always_ff @(posedge pix_clk) begin
        if (rst_pix) begin
            hs_q <= 1'b1;
            vs_q <= 1'b1;
        end else begin
            hs_q <= hsync;
            vs_q <= vsync;
        end
    end

    assign hs_fall = hs_q & ~hsync;
    assign vs_fall = vs_q & ~vsync;

    logic [31:0] c_clk, c_de, c_hsl, c_vsl;
    logic [15:0] c_line;

    always_ff @(posedge pix_clk) begin
        if (rst_pix) begin
            c_clk     <= 32'd0;
            c_de      <= 32'd0;
            c_hsl     <= 32'd0;
            c_vsl     <= 32'd0;
            c_line    <= 16'd0;
            frame_clk   <= 32'd0;
            frame_lines <= 16'd0;
            de_pix      <= 32'd0;
            hs_low      <= 32'd0;
            vs_low      <= 32'd0;
            frame_cnt   <= 32'd0;
        end else begin
            /* 每个像素时钟都数 */
            c_clk <= c_clk + 32'd1;
            if (de)      c_de  <= c_de  + 32'd1;
            if (!hsync)  c_hsl <= c_hsl + 32'd1;
            if (!vsync)  c_vsl <= c_vsl + 32'd1;
            if (hs_fall) c_line <= c_line + 16'd1;

            /* 一帧结束（vsync 下降沿）：把上一帧的结果锁存出去，计数器清零。
             * 注意 c_clk 含当前这一拍，所以 latching 时用 +1 补齐，保证
             * "一帧 = 663168"这种整数关系对得上。 */
            if (vs_fall) begin
                /* 下面每个 +1 / 不加 都是被仿真逼出来的（见 tb_hdmi_meas）：
                 *  · frame_clk：本拍还没记入 c_clk，所以要 +1（663168 才对）
                 *  · frame_lines：一帧内恰好 628 个 hsync 下降沿，**不能** +1，
                 *                 加了会变成 629
                 *  · vs_low：vsync 变低那一拍既触发清零又本该计数，那一拍被清零
                 *             覆盖掉了，所以要 +1 补回来（4224 才对） */
                frame_clk   <= c_clk + 32'd1;
                frame_lines <= c_line;
                de_pix      <= c_de;
                hs_low      <= c_hsl;
                vs_low      <= c_vsl + 32'd1;
                frame_cnt   <= frame_cnt + 32'd1;

                c_clk  <= 32'd0;
                c_de   <= 32'd0;
                c_hsl  <= 32'd0;
                c_vsl  <= 32'd0;
                c_line <= 16'd0;
            end
        end
    end

endmodule
