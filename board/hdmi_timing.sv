`timescale 1ns / 1ps

/* =============================================================================
 * hdmi_timing.sv — 800×600@60 视频时序发生器 + 彩条发生器（S1b）
 * -----------------------------------------------------------------------------
 * 输出给 ADV7511 的 16 位 YCbCr 4:2:2 接口（板上只接了 D0..D15，手册 §23 明确写
 * "仅支持 16 位 YCbCr 4:2:2"），**分离同步**（HSYNC/VSYNC/DE），不嵌同步码。
 *
 * ★ 为什么是 800×600@60：
 *   像素时钟 40.000 MHz，可以**精确**从板上 100 MHz 整数分频得到
 *   （MMCM：VCO = 100×10 = 1000 MHz，CLKOUT0 = 1000/25 = 40.000 MHz）。
 *   640×480@60 要 25.175 MHz（小数分频），1080p60 要 148.5 MHz（VCO 超范围）。
 *   这是本板唯一"不将就"的分辨率。
 *
 * 时序参数（VESA 800×600@60）：
 *   H：有效 800 + 前沿 40 + 同步 128 + 后沿 88 = 1056 像素
 *   V：有效 600 + 前沿  1 + 同步   4 + 后沿 23 =  628 行
 *   帧率 = 40e6 / (1056 × 628) = 60.30 Hz （VESA 标称 60，实际 60.3，显示器通吃）
 *   同步极性：负极性（低有效），与 VESA 该模式一致。
 *
 * ★ 4:2:2 的色度半带宽正好适合示波器：
 *   Y 每像素都变（波形亮度），Cb/Cr 两个像素共享一个 —— 单色波形 + 彩色标注
 *   完全够用，还省一半引脚。
 *   字节序按 BT.656 惯例：**每对像素的第一个送 Cb，第二个送 Cr**。
 *   （ADV7511 数据手册 Table 6/7/8 给出 4:2:2 的几种映射，靠 0x48[4:3] 选择；
 *    本模块按"Y 在高字节、C 在低字节、Cb 在前"来排，配寄存器时以此为准。）
 *
 * ★ 内容：8 条竖彩条（每条约 100 像素），用 BT.601 的 8 位 YCbCr 标准值。
 *   它的作用不是"好看"，而是**能一眼看出错在哪**：
 *     颜色顺序错 → 字节序 / Cb/Cr 反了
 *     竖条位置偏 → H 时序参数错
 *     整屏偏色   → 色彩空间或 CSC 配置错
 *     只有黑白   → 色度通道没接上 / 4:2:2 配置错
 *   比任何测试图都好诊断。
 *
 * ★ frame_tick 每帧在 vcnt 回卷时给一拍脉冲，给上层做"乒乓换页"的同步点
 *   （列缓冲双缓冲靠它切换，避免撕裂）。
 * ============================================================================= */
module hdmi_timing #(
    parameter int H_ACTIVE = 800,
    parameter int H_FP     = 40,
    parameter int H_SYNC   = 128,
    parameter int H_BP     = 88,
    parameter int V_ACTIVE = 600,
    parameter int V_FP     = 1,
    parameter int V_SYNC   = 4,
    parameter int V_BP     = 23
) (
    input  logic        pix_clk,
    input  logic        rst,          // 同步高有效，与 pix_clk 同域

    output logic        hsync,        // 负极性
    output logic        vsync,        // 负极性
    output logic        de,           // 数据有效（高）
    output logic [15:0] vdata,        // {Y[7:0], C[7:0]}

    output logic        frame_tick,   // 每帧一拍

    /* 像素坐标（给扫描渲染用；de=0 时也有效，等于当前计数器值） */
    output logic [10:0] pix_x,
    output logic [ 9:0] pix_y
);

    localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 1056
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 628
    localparam int BAR_W   = H_ACTIVE / 8;                      // 100

    logic [10:0] hcnt;      // 0..1055 需要 11 位
    logic [ 9:0] vcnt;      // 0..627  需要 10 位

    always_ff @(posedge pix_clk) begin
        if (rst) begin
            hcnt       <= 11'd0;
            vcnt       <= 10'd0;
            frame_tick <= 1'b0;
        end else begin
            frame_tick <= 1'b0;
            if (hcnt == (H_TOTAL - 1)) begin
                hcnt <= 11'd0;
                if (vcnt == (V_TOTAL - 1)) begin
                    vcnt       <= 10'd0;
                    frame_tick <= 1'b1;
                end else begin
                    vcnt <= vcnt + 10'd1;
                end
            end else begin
                hcnt <= hcnt + 11'd1;
            end
        end
    end

    /* ------------------------------ 同步与数据有效 ------------------------------ */
    wire h_sync_zone = (hcnt >= (H_ACTIVE + H_FP)) &&
                       (hcnt <  (H_ACTIVE + H_FP + H_SYNC));
    wire v_sync_zone = (vcnt >= (V_ACTIVE + V_FP)) &&
                       (vcnt <  (V_ACTIVE + V_FP + V_SYNC));

    assign pix_x = hcnt;
    assign pix_y = vcnt;

    assign hsync = ~h_sync_zone;
    assign vsync = ~v_sync_zone;
    assign de    = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

    /* ------------------------------ 彩条 ------------------------------
     * 8 条竖条，每条约 100 像素；BT.601 8 位值。
     *   white 235/128/128   yellow 210/16/146   cyan 170/166/16
     *   green 145/54/34     magenta 106/202/222  red 81/90/240
     *   blue 41/240/110     black 16/128/128
     * ---------------------------------------------------------------- */
    logic [2:0] bar;
    always_comb begin
        if      (hcnt < BAR_W * 1) bar = 3'd0;
        else if (hcnt < BAR_W * 2) bar = 3'd1;
        else if (hcnt < BAR_W * 3) bar = 3'd2;
        else if (hcnt < BAR_W * 4) bar = 3'd3;
        else if (hcnt < BAR_W * 5) bar = 3'd4;
        else if (hcnt < BAR_W * 6) bar = 3'd5;
        else if (hcnt < BAR_W * 7) bar = 3'd6;
        else                       bar = 3'd7;
    end

    function automatic logic [23:0] color_of(input logic [2:0] b);
        case (b)
            3'd0: color_of = {8'd235, 8'd128, 8'd128};  // white
            3'd1: color_of = {8'd210, 8'd 16, 8'd146};  // yellow
            3'd2: color_of = {8'd170, 8'd166, 8'd 16};  // cyan
            3'd3: color_of = {8'd145, 8'd 54, 8'd 34};  // green
            3'd4: color_of = {8'd106, 8'd202, 8'd222};  // magenta
            3'd5: color_of = {8'd 81, 8'd 90, 8'd240};  // red
            3'd6: color_of = {8'd 41, 8'd240, 8'd110};  // blue
            default: color_of = {8'd 16, 8'd128, 8'd128};  // black
        endcase
    endfunction

    /* ★ 不能对函数调用结果直接做位选（color_of(bar)[23:16] 在 iverilog 里是语法错），
     *   先落到一根线上再切。 */
    wire [23:0] col  = color_of(bar);
    wire [7:0]  y_v  = col[23:16];
    wire [7:0]  cb_v = col[15:8];
    wire [7:0]  cr_v = col[7:0];

    /* ★ BT.656 惯例：每对像素第一个送 Cb、第二个送 Cr。
     *   hcnt[0] 为 0 → Cb，为 1 → Cr。 */
    assign vdata = de ? {y_v, (hcnt[0] ? cr_v : cb_v)} : 16'h0000;

endmodule
