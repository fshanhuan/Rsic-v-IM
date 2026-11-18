`timescale 1ns / 1ps

/* =============================================================================
 * uart_report.sv — 把两组 I2C 探测结果压成一条**紧凑 hex 记录**打到串口
 * -----------------------------------------------------------------------------
 * 格式（31 字节，每 200 ms 重复一次）：
 *     'R' + 28 个 hex 字符 + CR + LF
 *
 * 28 个 nibble 的排列（从最高位开始，每个字段按 nibble 对齐）：
 *     0..3   found_hdmi[15:0]     HDMI 总线扫描位图
 *     4..5   addr_hdmi[6:0]       最低应答地址
 *     6..7   id00_hdmi[7:0]       寄存器 0x00
 *     8..9   idf5_hdmi[7:0]       寄存器 0xF5（应为 41 = 'A'）
 *    10..11  idf6_hdmi[7:0]       寄存器 0xF6（应为 44 = 'D'）
 *    12      rd_ok_hdmi[2:0]      三个读事务走完的位图
 *    13..16  found_aud[15:0]      ADAU1761 总线扫描位图（0x38..0x3F）
 *    17..18  addr_aud[6:0]
 *    19..20  id00_aud, 21..22 idf5_aud, 23..24 idf6_aud
 *    25      rd_ok_aud[2:0]
 *    26..27  health[7:0]          {aud_scl, aud_sda, hdmi_scl, hdmi_sda} 各 2 位
 *    28      dib[1:0]             SW1..SW0
 *
 * 为什么这版改成"纯 hex 记录"而不是可读文本：
 *   要同时上报两条总线的十几项结果，可读格式会到 70+ 字符、字符表维护成本高，
 *   而且任何一处下标错位都只表现为"文字有点怪"，很难发现。
 *   压成定长 nibble 记录后，RTL 只是一个 116 位常量拼接 + 查表，
 *   PC 侧按字段切开即可 —— 错位会在解码时立刻暴露，不会悄悄混过去。
 *   等 HDMI 打通、只剩一条总线要报时再换回可读格式。
 *
 * health（每根线 2 位）：
 *   0 = 从没见它高过（没上拉 / 没供电 / 接错脚 / 被别的器件按住）
 *   1 = 见过高也见过低（总线是活的）
 *   2 = 一直是高（从机从没驱动过它 = 没有 ACK）
 *
 * ★★ 曾经的 bug（务必保留）：第一版把 tx_send<=1 和 idx<=idx+1 放在同一个
 *   `!tx_busy` 条件下，而 uart_tx.busy 是下一拍才起来的 → 下一拍又发一次，
 *   被 uart_tx 在忙状态静默丢弃，idx 却加了两格。上板现象是"每隔一个字符丢一个"。
 *   修法：每次发送后强制冷却 8 拍。
 * ============================================================================= */
module uart_report #(
    parameter integer CLK_FREQ   = 50_000_000,
    parameter integer BAUD       = 115_200,
    parameter integer PERIOD_CYC = 10_000_000   // 200 ms @50MHz
) (
    input  logic        clk,
    input  logic        rst,

    /* ---- HDMI 那条总线（ADV7511）---- */
    input  logic [15:0] f_hdmi,
    input  logic [ 6:0] addr_hdmi,
    input  logic [ 7:0] id00_hdmi,
    input  logic [ 7:0] idf5_hdmi,
    input  logic [ 7:0] idf6_hdmi,
    input  logic [ 2:0] ok_hdmi,

    /* ---- 音频那条总线（ADAU1761，对照组）---- */
    input  logic [15:0] f_aud,
    input  logic [ 6:0] addr_aud,
    input  logic [ 7:0] id00_aud,
    input  logic [ 7:0] idf5_aud,
    input  logic [ 7:0] idf6_aud,
    input  logic [ 2:0] ok_aud,

    input  logic [ 7:0] health,   // {aud_scl, aud_sda, hdmi_scl, hdmi_sda} 各 2 位
    input  logic [ 1:0] dib,

    output logic        tx
);

    localparam int MSG_LEN = 32;
    localparam logic [31:0] PERIOD = PERIOD_CYC;

    /* 112 位记录：28 个 nibble，按 nibble 对齐 */
    logic [115:0] rec;
    assign rec = {f_hdmi,      {1'b0, addr_hdmi}, id00_hdmi, idf5_hdmi, idf6_hdmi,
                  {1'b0, ok_hdmi},
                  f_aud,       {1'b0, addr_aud},  id00_aud,  idf5_aud,  idf6_aud,
                  {1'b0, ok_aud},
                  health, {2'b00, dib}};

    function automatic logic [7:0] hexch(input logic [3:0] v);
        hexch = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
    endfunction

    function automatic logic [7:0] msg_ch(input logic [5:0] i);
        logic [3:0] v;
        if (i == 6'd0) msg_ch = "R";
        else if (i <= 6'd29) begin
            v = rec[(29 - i) * 4 +: 4];      // i=1 → 最高 nibble
            msg_ch = hexch(v);
        end else if (i == 6'd30) msg_ch = 8'h0D;
        else                     msg_ch = 8'h0A;
    endfunction

    logic [5:0]  idx;
    logic        sending;
    logic [31:0] gap;
    logic [3:0]  cool;
    logic [7:0]  tx_byte;
    logic        tx_send;
    logic        tx_busy;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_tx (
        .clk  (clk),
        .rst  (rst),
        .data (tx_byte),
        .send (tx_send),
        .tx   (tx),
        .busy (tx_busy)
    );

    assign tx_byte = msg_ch(idx);

    always_ff @(posedge clk) begin
        if (rst) begin
            idx     <= 6'd0;
            sending <= 1'b0;
            gap     <= 32'd0;
            cool    <= 4'd0;
            tx_send <= 1'b0;
        end else begin
            tx_send <= 1'b0;
            if (cool != 4'd0) cool <= cool - 4'd1;

            if (!sending) begin
                if (gap >= PERIOD) begin
                    gap     <= 32'd0;
                    sending <= 1'b1;
                    idx     <= 6'd0;
                    cool    <= 4'd0;
                end else begin
                    gap <= gap + 32'd1;
                end
            end else if ((cool == 4'd0) && !tx_busy) begin
                tx_send <= 1'b1;
                cool    <= 4'd8;          // 8 拍后 busy 一定已经起来
                if (idx == (MSG_LEN - 1)) sending <= 1'b0;
                else                      idx     <= idx + 6'd1;
            end
        end
    end

endmodule
