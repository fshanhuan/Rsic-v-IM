`timescale 1ns / 1ps

/* =============================================================================
 * async_fifo.sv — 极简异步 FIFO（格雷码指针 + 两级同步器）
 * -----------------------------------------------------------------------------
 * 为什么需要它（S6 文本层踩过的坑）：
 *   文本 RAM 的写口在 cpu_clk（50 MHz）、读口在 pix_clk（40 MHz）。第一版把读口做成
 *   "组合读 + 直接进 pix 域寄存器"，Vivado 把阵列实现成带同步输出的分布式 RAM，
 *   于是那条路径变成 cpu_clk → pix_clk 的跨时钟路径，5 ns 预算差 0.896 ns：
 *
 *     Slack (VIOLATED) : -0.896ns
 *       Source: u_disp/text_mem_reg_XX/RAMA/CLK     (clk_sys)   ← 注释里不能出现 星号+斜杠
 *       Destination: u_disp/vdata_o_reg[12]/R       (clk_pix)
 *
 *   正确做法是让 RAM **完全待在一个时钟域**里：cpu 侧的写请求先进这个异步 FIFO，
 *   到 pix 侧再写 RAM。这样 RAM 的读写都在 pix_clk，跨时钟只剩 FIFO 本身
 *   （而 FIFO 是标准结构，指针用格雷码，每拍只变一位，两级同步即可）。
 *
 * 规格：深度 8（2^3），宽度 11（{addr[5:0], data[4:0]}）。
 *   写侧速率 = 软件写 MMIO（最快约每 100 ns 一次）；
 *   读侧速率 = pix_clk 每拍可吞一个（25 ns）。
 *   读比写快 4 倍，所以正常情况**永远不会满**；满了就丢（text 丢一格只是少一个字符）。
 *
 * ★ 满/空判定用"多一位"的二进制指针：wbin 比 rbin 多一位，差 1 = 满，
 *   相减靠格雷码转换后的二进制比较，避免格雷码不能直接做减法的问题。
 * ============================================================================= */
module async_fifo #(
    parameter int WIDTH = 11,
    parameter int AW    = 3           // 深度 = 2^AW
) (
    /* ---- 写侧 ---- */
    input  logic             wclk,
    input  logic             wrst,     // 写域复位（高有效）
    input  logic [WIDTH-1:0] wdata,
    input  logic             wpush,
    output logic             wfull,

    /* ---- 读侧 ---- */
    input  logic             rclk,
    input  logic             rrst,     // 读域复位（高有效）
    output logic [WIDTH-1:0] rdata,
    input  logic             rpop,
    output logic             rempty
);

    localparam int DEPTH = (1 << AW);

    logic [WIDTH-1:0] mem [0:DEPTH-1];

    logic [AW:0] wbin, wgray;
    logic [AW:0] rbin, rgray;

    /* 读指针同步到写域、写指针同步到读域 */
    logic [AW:0] rgray_s1, rgray_s2;
    logic [AW:0] wgray_s1, wgray_s2;

    /* ---------------- 格雷码 ⇄ 二进制 ---------------- */
    function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
        logic [AW:0] b;
        b = g;
        for (int i = 1; i <= AW; i++) b = b ^ (g >> i);
        gray2bin = b;
    endfunction

    /* ---------------- 写侧 ---------------- */
    wire [AW:0] wbin_next  = wbin + 1'b1;
    wire [AW:0] wgray_next = bin2gray(wbin_next);
    wire [AW:0] rbin_sync  = gray2bin(rgray_s2);
    wire        wfull_now  = (wgray_next == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});

    assign wfull = wfull_now;

    always_ff @(posedge wclk) begin
        if (wrst) begin
            wbin  <= '0;
            wgray <= '0;
            rgray_s1 <= '0;
            rgray_s2 <= '0;
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
            if (wpush && !wfull_now) begin
                mem[wbin[AW-1:0]] <= wdata;
                wbin  <= wbin_next;
                wgray <= wgray_next;
            end
        end
    end

    /* ---------------- 读侧 ---------------- */
    wire [AW:0] rbin_next  = rbin + 1'b1;
    wire [AW:0] rgray_next = bin2gray(rbin_next);
    wire        rempty_now = (rgray == wgray_s2);

    assign rempty = rempty_now;
    assign rdata  = mem[rbin[AW-1:0]];

    always_ff @(posedge rclk) begin
        if (rrst) begin
            rbin  <= '0;
            rgray <= '0;
            wgray_s1 <= '0;
            wgray_s2 <= '0;
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
            if (rpop && !rempty_now) begin
                rbin  <= rbin_next;
                rgray <= rgray_next;
            end
        end
    end

endmodule
