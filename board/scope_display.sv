`timescale 1ns / 1ps

/* =============================================================================
 * scope_display.sv — 示波器显示子系统（列缓冲 + 扫描渲染 + 网格）
 * -----------------------------------------------------------------------------
 * 这是 S3 的硬件核心：RISC-V 把"每一列有点亮的行范围"（min/max）算好后写进来，
 * PL 按 800×600@60 扫出来。**CPU 一个像素都不碰**。
 *
 * 为什么用"列摘要"而不是帧缓冲：
 *   帧缓冲 800×600×8bpp = 480 KB，超过本片 BRAM；而且 CPU 每帧要写 480 KB，
 *   经 AXI-Lite 要吃掉 86% 的 PL 总线（见方案文档 §3）。
 *   列摘要 800×{min,max} = 800×20 位 = 2 KB，扫描时实时比较即可，
 *   分辨率无关、带宽为零。
 *
 * ★ 双缓冲（乒乓），避免撕裂：
 *   两块 bank 交替 —— 扫描读 bank A 时 CPU 写 bank B，下一帧交换。
 *   交换点在 frame_tick（扫描结束、下一帧开始），CPU 通过读出 rd_bank 得知
 *   "现在该写哪一块"。
 *
 * ★ 跨时钟域：
 *   写口在 cpu_clk（50 MHz），读口在 pix_clk（40 MHz，不同 MMCM 输出）。
 *   bank 选择位从读域同步到写域（两级触发器）。这不是"数据通路 CDC"——
 *   数据只在**本 bank 不被读**的时候写，所以没有数据一致性要求，
 *   只有 bank 位这一根控制信号需要同步。
 *
 * ★ 渲染优先级：波形 > 网格 > 背景。
 *   波形只有单色（Y 变、C 恒定），正好用上 4:2:2 的半个色度通道。
 *
 * 地址约定：
 *   列缓冲深度 2048 项（2 bank × 1024 列），地址 = {bank, col[9:0]}
 *   col 直接就是屏幕 x（0..799），超出部分不用。
 * ============================================================================= */
module scope_display #(
    parameter int H_ACTIVE = 800,
    parameter int H_FP     = 40,
    parameter int H_SYNC   = 128,
    parameter int H_BP     = 88,
    parameter int V_ACTIVE = 600,
    parameter int V_FP     = 1,
    parameter int V_SYNC   = 4,
    parameter int V_BP     = 23,
    /* 网格间距 */
    parameter int GRID_X   = 80,
    parameter int GRID_Y   = 50
) (
    input  logic        pix_clk,      // 40 MHz
    input  logic        cpu_clk,      // 50 MHz
    input  logic        rst_pix,
    input  logic        rst_cpu,

    /* ---- CPU 写口（50 MHz 域）---- */
    input  logic        wr_en,
    input  logic [9:0]  wr_col,       // 0..1023（有效范围 0..799）
    input  logic [9:0]  wr_min,       // 该列点亮的起始行（0..599）
    input  logic [9:0]  wr_max,       // 该列点亮的结束行
    /* ---- S6 文本层写口（cpu_clk 域）----
     * ★ 注意：这两个口**不能**直接去读 pix 域的数组。第一版就是那样写的，
     *   结果 Vivado 把文本 RAM 实现成 cpu 时钟的同步读 RAM，跨时钟路径差 0.896 ns
     *   直接失败。现在先过一层 async_fifo，到 pix 域再写 RAM。 */
    input  logic        text_we,
    input  logic [ 5:0] text_addr,   // {line[0], col[4:0]}
    input  logic [ 4:0] text_data,   // font5x7 的字符索引

    input  logic        commit,       // 单拍（cpu_clk）：CPU 说"这一帧写完了，可以换"
    output logic        wr_bank,      // 当前应该写哪一块（= 扫描的反面）

    /* ---- 视频输出（40 MHz 域）---- */
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic [15:0] vdata,
    output logic        frame_tick,
    output logic        rd_bank       // 当前正在扫描哪一块（调试/软件可见）
);

    /* -------------------------------------------------------------------------
     * 1) 时序发生器
     * ---------------------------------------------------------------------- */
    logic [10:0] px;
    logic [ 9:0] py;

    logic hsync_i, vsync_i, de_i;
    hdmi_timing #(
        .H_ACTIVE (H_ACTIVE), .H_FP (H_FP), .H_SYNC (H_SYNC), .H_BP (H_BP),
        .V_ACTIVE (V_ACTIVE), .V_FP (V_FP), .V_SYNC (V_SYNC), .V_BP (V_BP)
    ) u_timing (
        .pix_clk    (pix_clk),
        .rst        (rst_pix),
        .hsync      (hsync_i),
        .vsync      (vsync_i),
        .de         (de_i),
        .vdata      (),              // 像素数据由本模块生成，下面的 mux 决定
        .frame_tick (frame_tick),
        .pix_x      (px),
        .pix_y      (py)
    );

    /* -------------------------------------------------------------------------
     * 2) 乒乓 bank：**由 CPU 提交驱动**，不是自己乱翻
     * -------------------------------------------------------------------------
     * ★ 为什么必须改（2026-11-17 实测到的问题）：
     *   原来 bank 每帧自己翻一次。可是 CPU 写满 800 列要约 16 ms，正好等于
     *   一个显示帧（16.58 ms），所以写的过程中几乎必然被翻走一次 —— 那几列
     *   会写进正在被扫描的 bank，屏幕上表现为一条竖直撕裂。
     *   改成：CPU 写完一帧写 commit（0xA8），这里只在**下一个帧同步**才翻，
     *   于是"写"和"翻"的节奏就锁上了，撕裂消失。
     *   代价：如果 CPU 不提交，画面就停住不动（这正是我们要的"冻结"语义）。
     * ---------------------------------------------------------------------- */
    logic bank_r;
    logic bank_r_s1, bank_r_s2;

    /* commit 是 cpu_clk 域的单拍脉冲 → 先变成电平翻转，过域后再变回事件 */
    logic commit_tgl;
    always_ff @(posedge cpu_clk) begin
        if (rst_cpu) commit_tgl <= 1'b0;
        else if (commit) commit_tgl <= ~commit_tgl;
    end

    logic commit_s1, commit_s2, commit_s3, commit_pend;
    always_ff @(posedge pix_clk) begin
        if (rst_pix) begin
            bank_r      <= 1'b0;
            commit_s1   <= 1'b0;
            commit_s2   <= 1'b0;
            commit_s3   <= 1'b0;
            commit_pend <= 1'b0;
        end else begin
            commit_s1 <= commit_tgl;
            commit_s2 <= commit_s1;
            commit_s3 <= commit_s2;
            if (commit_s2 != commit_s3) commit_pend <= 1'b1;
            if (frame_tick && commit_pend) begin
                bank_r      <= ~bank_r;
                commit_pend <= 1'b0;
            end
        end
    end


    always_ff @(posedge cpu_clk) begin
        if (rst_cpu) begin
            bank_r_s1 <= 1'b0;
            bank_r_s2 <= 1'b0;
        end else begin
            bank_r_s1 <= bank_r;
            bank_r_s2 <= bank_r_s1;
        end
    end

    assign rd_bank = bank_r;
    assign wr_bank = ~bank_r_s2;     // 写扫描的反面那一块

    /* -------------------------------------------------------------------------
     * 3) 列缓冲：2048 × 20 位（2 bank × 1024 列 × {min[9:0], max[9:0]}）
     * ---------------------------------------------------------------------- */
    logic [19:0] mem [0:2047];

    /* 写口（cpu_clk） */
    always_ff @(posedge cpu_clk) begin
        if (wr_en) mem[{wr_bank, wr_col}] <= {wr_min, wr_max};
    end

    /* 读口（pix_clk）：同步读，1 拍延迟 —— 渲染时必须把 x 也延迟一拍对齐 */
    logic [19:0] rd_q;
    always_ff @(posedge pix_clk) begin
        rd_q <= mem[{bank_r, px[9:0]}];
    end

    /* 延迟一拍的控制信号，与 rd_q 对齐 */
    logic        de_d;
    logic [10:0] px_d;
    logic [ 9:0] py_d;

    always_ff @(posedge pix_clk) begin
        if (rst_pix) begin
            de_d <= 1'b0;
            px_d <= 11'd0;
            py_d <= 10'd0;
        end else begin
            de_d <= de_i;
            px_d <= px;
            py_d <= py;
        end
    end

    /* -------------------------------------------------------------------------
     * 4) 渲染
     * ---------------------------------------------------------------------- */
    wire [9:0] col_min = rd_q[19:10];
    wire [9:0] col_max = rd_q[9:0];

    wire trace_on = (py_d >= col_min) && (py_d <= col_max) && (col_min <= col_max);

    /* 网格：直接对**已对齐的** px_d / py_d 取模。
     *
     * ★ 一开始想省掉除法器，用两个计数器跟着 px/py 走，结果踩了两个坑：
     *   1) 计数器是寄存的，天然比 px 晚一拍，而列缓冲的同步读也晚一拍 ——
     *      两者相消后"该用 gx 还是 gx_d"恰好反了，横向网格整整偏一格；
     *   2) 纵向那个计数器写在同一个 always 块里，变成了"每像素加 1"而不是
     *      "每行加 1"，gy 根本不对应行号。
     *   取模版本一眼就是对的，而且 40 MHz（25 ns）下 10 位除常数完全跑得动，
     *   综合成一个常数乘法器，代价几十个 LUT —— 比"省逻辑省出一个错"划算。
     */
    wire grid_on = ((px_d[9:0] % GRID_X) == 0) || ((py_d % GRID_Y) == 0);

    /* 颜色（BT.601 8 位）：波形亮白，网格暗灰，背景近黑 */
    localparam logic [7:0] Y_TRACE = 8'd235, C_TRACE = 8'd128;
    localparam logic [7:0] Y_GRID  = 8'd 70, C_GRID  = 8'd128;
    localparam logic [7:0] Y_BG    = 8'd 16, C_BG    = 8'd128;

    logic [7:0] y_out;
    always_comb begin
        if      (trace_on) y_out = Y_TRACE;
        else if (grid_on)  y_out = Y_GRID;
        else               y_out = Y_BG;
    end
    /* -------------------------------------------------------------------------
     * 4b) S6 文本叠加层（**全部在 pix_clk 域**）
     * -------------------------------------------------------------------------
     * cpu 写 → async_fifo → pix 域写 text_mem → 组合读 → 叠加到 vdata。
     * 过了 FIFO 之后 RAM 的读写都在 pix_clk：路径预算 25 ns，不再有跨时钟问题。
     * 面板：2 行 x 32 列，字符格 8x8，字形 5x7，左上角 (16,16)。
     * ---------------------------------------------------------------------- */
    localparam logic [10:0] TX0 = 11'd16;
    localparam logic [10:0] TX1 = 11'd272;
    localparam logic [ 9:0] TY0 = 10'd16;
    localparam logic [ 9:0] TY1 = 10'd32;
    localparam logic [ 7:0] Y_PANEL = 8'd24;
    localparam logic [ 7:0] Y_TEXT  = 8'd235;

    logic [10:0] fifo_rdata;
    logic        fifo_rempty, fifo_wfull;
    logic        text_pop;

    async_fifo #(.WIDTH(11), .AW(3)) u_text_fifo (
        .wclk  (cpu_clk),
        .wrst  (rst_cpu),
        .wdata ({text_addr, text_data}),
        .wpush (text_we),
        .wfull (fifo_wfull),
        .rclk  (pix_clk),
        .rrst  (rst_pix),
        .rdata (fifo_rdata),
        .rpop  (text_pop),
        .rempty(fifo_rempty)
    );

    assign text_pop = ~fifo_rempty;      // 读侧每拍尽量吞，速率必然快于写侧

    logic [4:0] text_mem [0:63];

    /* ★ 复位要清零：否则上电时面板会显示随机字模（数组在 FPGA 里是未定义的）。
     *   5'd0 = 空格，所以复位后整块面板是干净的底色。 */
    always_ff @(posedge pix_clk) begin
        if (rst_pix) begin
            for (int i = 0; i < 64; i++) text_mem[i] <= 5'd0;
        end else if (text_pop) begin
            text_mem[fifo_rdata[10:5]] <= fifo_rdata[4:0];
        end
    end

    wire in_panel = (px_d >= TX0) && (px_d < TX1) && (py_d >= TY0) && (py_d < TY1);

    /* (px-16)>>3 = (px>>3)-2（16 是 8 的倍数，纯移位）；行号同理 */
    wire [4:0] tcol = px_d[7:3] - 5'd2;
    wire [4:0] trow = py_d[4:3] - 2'd2;

    wire [4:0] tch = text_mem[{trow[0], tcol}];
    wire [2:0] gx  = px_d[2:0];
    wire [2:0] gy  = py_d[2:0];

    logic [4:0] frow;
    font5x7 u_font (.ch(tch), .row(gy), .bits(frow));

    wire glyph_on = (gx < 3'd5) && (gy < 3'd7) && frow[4 - gx];

    logic hsync_o, vsync_o, de_o;
    logic [15:0] vdata_o;

    /* -------------------------------------------------------------------------
     * 5) 输出寄存：把同步信号也延迟一拍，保证"de 高的那一拍 vdata 就是有效数据"
     *
     *   ★ 这一步不能省。列缓冲是同步读，数据比地址晚一拍；如果只延迟数据不延迟
     *     de/hsync/vsync，送到 ADV7511 的就是"数据和同步差一个像素"——
     *     屏幕上表现为整幅图横向错 1 像素，而且 HSYNC 与 DE 的关系也错了。
     *     第一版就是这么写的，仿真里一抽样就露馅（de 高时 vdata 还是上一列的）。
     *
     *   代价：整幅画面右移 1 个像素 —— 无所谓，显示器不关心。
     * ---------------------------------------------------------------------- */
    always_ff @(posedge pix_clk) begin
        if (rst_pix) begin
            hsync_o <= 1'b1;
            vsync_o <= 1'b1;
            de_o    <= 1'b0;
            vdata_o <= 16'h0000;
        end else begin
            hsync_o <= hsync_i;
            vsync_o <= vsync_i;
            de_o    <= de_d;   // ★ 必须和数据通路同深（2 级）：列缓冲同步读 1 级 + 输出寄存 1 级
            /* 色度恒定 128：波形是单色的，正好用满 4:2:2 的半个色度带宽。 */
            /* 叠加优先级：文字 > 面板底色 > 原有的 波形/网格/背景 */
            if (in_panel) vdata_o <= de_d ? {(glyph_on ? Y_TEXT : Y_PANEL), 8'd128} : 16'h0000;
            else          vdata_o <= de_d ? {y_out, 8'd128} : 16'h0000;
        end
    end

    assign hsync = hsync_o;
    assign vsync = vsync_o;
    assign de    = de_o;
    assign vdata = vdata_o;

endmodule
