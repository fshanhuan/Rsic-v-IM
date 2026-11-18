`timescale 1ns / 1ps

/* =============================================================================
 * rec_mmio.sv — 记录仪外设的 MMIO 块（挂在 board_top 的扩展口上）
 * -----------------------------------------------------------------------------
 * 为什么要有这一层，而不是直接在 board_top 里加寄存器：
 *   board_top 是全工程共用的 SoC（v9_boot / v9_rec / PS 版都在用）。记录仪的
 *   外设只属于这个项目，所以 board_top 只开一个**通用扩展口**（EXT_MMIO），
 *   具体寄存器全部落在这里。这样 v9_boot 的网表逐位不变，而记录仪想加多少
 *   寄存器就加多少（6 位索引还有 48 个空位）。
 *
 * 寄存器表（idx 是 6 位索引，地址 = 0x1000_0000 + idx*4）：
 *   0x40 / idx16  HDMI I2C CTRL    WO  bit0 START bit1 BYTE bit2 STOP bit3 R/W bit4 NACK
 *   0x44 / idx17  HDMI I2C TXDATA  WO
 *   0x48 / idx18  HDMI I2C RXDATA  RO
 *   0x4C / idx19  HDMI I2C STATUS  RO  bit0 busy bit1 done bit2 ack bit3 SCL bit4 SDA
 *   0x50 / idx20  HDMI I2C CLR     WO  写 1 清 done
 *   0x54 / idx21  音频 I2C CTRL    （同上，四条一组）
 *   0x58 / idx22  音频 I2C TXDATA
 *   0x5C / idx23  音频 I2C RXDATA
 *   0x60 / idx24  音频 I2C STATUS
 *   0x64 / idx25  音频 I2C CLR
 *   0x68 / idx26  HDMI 探测位图   RO  [15:0] found
 *   0x6C / idx27  HDMI 探测结果   RO  {7'b0,addr[6:0], id00, idf5, idf6}
 *   0x70 / idx28  音频 探测位图   RO
 *   0x74 / idx29  音频 探测结果   RO
 *   0x78 / idx30  探测状态        RO  bit0 hdmi_done bit1 aud_done
 *                                     bit2 hdmi_busy bit3 aud_busy
 *   0x7C / idx31  线路健康度      RO  {aud_scl, aud_sda, hdmi_scl, hdmi_sda} 各 2 位
 *   0x80 / idx32  S3 列缓冲写     WO  {2'b0, max[9:0], min[9:0], col[9:0]}
 *   0x84 / idx33  显示状态        RO  bit0 = 当前该写哪一块 bank
 *   0x88 / idx34  DAC 码值        WO  {24'b0, dac[7:0]} → DAC0832（直通，立即生效）
 *   0x8C / idx35  ADC 队头        RO  {16'b0, adc[15:0]}（只窥视，不弹）
 *   0x90 / idx36  ADC 状态        RO  bit0 full bit1 overflow bit2 有数据
 *   0x94 / idx37  ADC 深度        RO  FIFO 里现成的样本数
 *   0x98 / idx38  ADC 控制        RW  bit0 en bit1 clr_ovf bit2 pop（弹出一个）
 *   0x9C / idx39  ADC 通道        RW  {ch1_en, ch1[6:0], ch0[6:0]}（默认 0x1B / 0x16）
 *   0xA0 / idx40  ADC 样本计数    RO  32 位，会回卷
 *   0xA4 / idx41  ADC 最新值      RO  {16'b0, adc_last}（FIFO 满了也照样更新）
 *   0xA8 / idx42  显示提交        WO  写 1 = 提交一帧（下一次帧同步才翻 bank，防撕裂）
 *   0xAC / idx43  触发阈值        RW  16 位
 *   0xB0 / idx44  触发控制        RW  bit0 en bit1 clear bit3:2 mode
 *   0xB4 / idx45  触发状态        RO  bit0 fired bit1 above
 *   0xB8 / idx46  触发计数        RO
 *   0xBC / idx47  窗内最小值      RO  （S6，1024 样本窗口）
 *   0xC0 / idx48  窗内最大值      RO
 *   0xC4 / idx49  窗内均值        RO
 *   0xC8 / idx50  窗口计数        RO
 *
 * ★ 为什么既保留上电自动探测、又给 MMIO：
 *   自动探测只跑一次（上电 2.6 ms 后，约 4 ms 完成），之后总线就空闲了；
 *   软件随时可以用 MMIO 重新访问。两者对 SCL/SDA 的驱动是**开漏或**
 *   （`|`），而且时间上不重叠，所以共用一条总线是安全的。
 *   保留自动探测的价值：插上 USB 串口就能 `x s` 看结果，不需要先灌程序。
 * ============================================================================= */
module rec_mmio (
    input  logic        clk,
    input  logic        rst,

    /* ---- 通用扩展口（来自 board_top.sv 的 EXT_MMIO）---- */
    input  logic        we,
    input  logic [5:0]  idx,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    /* ---- HDMI 那一路 I2C 引脚 ---- */
    output logic        h_scl_oe,
    output logic        h_sda_oe,
    input  logic        h_sda_rd,

    /* ---- 音频那一路 I2C 引脚 ---- */
    output logic        a_scl_oe,
    output logic        a_sda_oe,
    input  logic        a_sda_rd,

    /* ---- 上电自动探测的结果（外部 i2c_probe 给）---- */
    input  logic [15:0] f_h,   input logic [6:0] addr_h,
    input  logic [ 7:0] id00_h, idf5_h, idf6_h,
    input  logic        pd_h,  input logic h_busy,
    input  logic [15:0] f_a,   input logic [6:0] addr_a,
    input  logic [ 7:0] id00_a, idf5_a, idf6_a,
    input  logic        pd_a,  input logic a_busy,
    input  logic [ 7:0] health,

    /* ---- S3 显示子系统：列缓冲写口（50 MHz 域）---- */
    output logic        col_wr,
    output logic [ 9:0] col_col,
    output logic [ 9:0] col_min,
    output logic [ 9:0] col_max,
    input  logic        col_wr_bank,
    output logic        disp_commit,   // 单拍：CPU 提交一帧（0xA8 写 1）

    /* ---- S6 文本层：单个字符单元写口 ---- */
    output logic        text_we,
    output logic [ 5:0] text_addr,
    output logic [ 4:0] text_data,

    /* ---- S2：DAC0832 直通输出 ---- */
    output logic        dac_wr,
    output logic [ 7:0] dac_data,

    /* ---- S2：XADC 采样器控制/读出 ---- */
    output logic        adc_en,        // bit0：启动轮询
    output logic        adc_clr_ovf,   // 写 1 清溢出（单拍）
    output logic        adc_rd_en,     // 写 1 弹出一个样本（单拍）
    output logic [ 6:0] adc_ch0,
    output logic [ 6:0] adc_ch1,
    output logic        adc_ch1_en,
    input  logic [15:0] adc_rd_data,   // FIFO 队头（只窥视，不弹）
    input  logic [15:0] adc_last,      // 最新一次转换结果（不受 FIFO 满影响）
    input  logic [10:0] adc_level,
    input  logic        adc_full,
    input  logic        adc_ovf,
    input  logic [31:0] adc_cnt,

    /* ---- S4：触发单元配置与结果 ---- */
    output logic [15:0] trig_th,
    output logic [ 1:0] trig_mode,
    output logic        trig_en,
    output logic        trig_clear,     // 单拍
    input  logic        trig_fired,
    input  logic        trig_above,
    input  logic [31:0] trig_cnt,

    /* ---- S6：窗内测量结果 ---- */
    input  logic [15:0] meas_min,
    input  logic [15:0] meas_max,
    input  logic [15:0] meas_mean,
    input  logic [31:0] meas_cnt
);

    /* ------------------------------ 两路 I2C ------------------------------ */
    logic [31:0] rd_h, rd_a;
    logic        h_done, h_ack, a_done, a_ack;

    i2c_mmio #(
        .CLK_HZ (50_000_000),
        .SCL_HZ (100_000)
    ) u_i2c_hdmi (
        .clk    (clk),
        .rst    (rst),
        .we     (we),
        .idx    (idx),
        .base   (6'd16),
        .wdata  (wdata),
        .rdata  (rd_h),
        .scl_oe (h_scl_oe),
        .sda_oe (h_sda_oe),
        .sda_rd (h_sda_rd),
        .m_busy (),
        .m_done (h_done),
        .m_ack  (h_ack)
    );

    i2c_mmio #(
        .CLK_HZ (50_000_000),
        .SCL_HZ (100_000)
    ) u_i2c_aud (
        .clk    (clk),
        .rst    (rst),
        .we     (we),
        .idx    (idx),
        .base   (6'd21),
        .wdata  (wdata),
        .rdata  (rd_a),
        .scl_oe (a_scl_oe),
        .sda_oe (a_sda_oe),
        .sda_rd (a_sda_rd),
        .m_busy (),
        .m_done (a_done),
        .m_ack  (a_ack)
    );

    /* ------------------------------ S3 列缓冲写口 ------------------------------
     * idx32 = {2'b0, max[9:0], min[9:0], col[9:0]} —— 一次写一个列。
     * 800 列 x 一次 200ns（MMIO 写）约 160us/帧，相对 16.7ms 帧周期只有 1%，
     * 比"先写地址、再写 min、再写 max、再提交"的四次写划算得多。
     * ---------------------------------------------------------------------- */
    always_ff @(posedge clk) begin
        if (rst) begin
            col_wr      <= 1'b0;
            col_col     <= 10'd0;
            col_min     <= 10'd0;
            col_max     <= 10'd0;
            disp_commit <= 1'b0;
            text_we     <= 1'b0;
            text_addr   <= 6'd0;
            text_data   <= 5'd0;
        end else begin
            col_wr      <= 1'b0;
            disp_commit <= 1'b0;
            text_we     <= 1'b0;
            if (we && (idx == 6'd32)) begin
                col_wr  <= 1'b1;
                col_col <= wdata[9:0];
                col_min <= wdata[19:10];
                col_max <= wdata[29:20];
            end
            /* 0xA8 写 1 = 这一帧写完了，可以换 bank（下一次帧同步才真正翻） */
            if (we && (idx == 6'd42) && wdata[0]) disp_commit <= 1'b1;

            /* 0xCC：写一个字符单元 {line, col[4:0], ch[4:0]} */
            if (we && (idx == 6'd51)) begin
                text_we   <= 1'b1;
                text_addr <= {wdata[10], wdata[9:5]};
                text_data <= wdata[4:0];
            end
        end
    end

    /* ------------------------------ 探测结果寄存器 ------------------------------ */
    logic [31:0] rd_probe;

    /* ------------------------------ S2：DAC / XADC ------------------------------
     * ★ 读 ADC_DATA 只是"窥视队头"，不会弹出 —— 和其它只读寄存器一致。
     *   真正的弹出是写 ADC_CTL 的 bit2，和 UART 的 RXDATA/RXPOP 是同一套用法：
     *   读操作在本设计里没有读选通信号（扩展口只有 ext_we），所以"读即弹"
     *   根本没法实现，改成显式 POP 位反而更清楚。
     * ---------------------------------------------------------------------- */
    logic        adc_en_r, adc_ch1_en_r, adc_clr_ovf_r, adc_rd_en_r;
    logic [6:0]  adc_ch0_r, adc_ch1_r;
    logic [7:0]  dac_data_r;
    logic [31:0] rd_adc;

    always_ff @(posedge clk) begin
        if (rst) begin
            dac_wr        <= 1'b0;
            dac_data_r    <= 8'hFF;   // 反相输出 → 0xFF 才是 0 V，见 dac0832.sv
            adc_en_r      <= 1'b1;   // 默认自由采样：这样不打软件也能从 JTAG 看到样本
            adc_clr_ovf_r <= 1'b0;
            adc_rd_en_r   <= 1'b0;
            /* 默认通道：AD11 = VAUX11 = DRP 0x1B（7 系列 XADC：VAUXn 地址 = 7'h10 + n）。
             * ch1 默认关掉 —— AD6(V13/W13) 在 bank 35 上是 1.8 V 专用，3.3 V 板子上
             * 用不了（place 会报 BIVC-1），所以自环只用 AD11 一个通道。 */
            adc_ch0_r     <= 7'h1B;
            adc_ch1_r     <= 7'h16;
            adc_ch1_en_r  <= 1'b0;
        end else begin
            /* 单拍请求，默认全清 */
            dac_wr        <= 1'b0;
            adc_clr_ovf_r <= 1'b0;
            adc_rd_en_r   <= 1'b0;

            if (we) begin
                case (idx)
                    6'd34: begin
                        dac_data_r <= wdata[7:0];
                        dac_wr     <= 1'b1;
                    end
                    6'd38: begin
                        /* ★ 2026-11-17 上板实测抓到的真 bug（症状：上电 5 s 后采样永久停住）
                         *   ADC_CTL 的 bit2 是**单拍弹出选通**，不是配置位。原来这一句写成
                         *       adc_en_r <= wdata[0];
                         *   于是软件想"弹出 1 个样本"就写 4 → bit0=0 → 顺手把采样器关了。
                         *   板上表现：adc_cnt 停在 1024（= FIFO 深度，引导窗口里灌满就再没增加）、
                         *   adc_level 恒 0、meas_cnt 不再增长，而 CPU 其实一直在正常跑。
                         *   这就是"看起来软件在跑、其实一个样本都没进来"的经典陷阱。
                         *   规则：**只有不含 bit2 的写才改 en**；弹出永远不动 en。 */
                        if (!wdata[2]) adc_en_r  <= wdata[0];
                        adc_clr_ovf_r <= wdata[1];
                        adc_rd_en_r   <= wdata[2];   // 单拍选通，下一拍自动清（见上面默认赋值）
                    end
                    6'd39: begin
                        adc_ch1_en_r <= wdata[15];
                        adc_ch1_r    <= wdata[14:8];
                        adc_ch0_r    <= wdata[6:0];
                    end
                    default: ;
                endcase
            end
        end
    end

    assign dac_data     = dac_data_r;
    assign adc_en       = adc_en_r;
    assign adc_clr_ovf  = adc_clr_ovf_r;
    assign adc_rd_en    = adc_rd_en_r;
    assign adc_ch0      = adc_ch0_r;
    assign adc_ch1      = adc_ch1_r;
    assign adc_ch1_en   = adc_ch1_en_r;

    /* S4 触发寄存器 */
    always_ff @(posedge clk) begin
        if (rst) begin
            trig_th    <= 16'h0800;     // 默认阈值 = 半量程（12 位 0x800 附近）
            trig_mode  <= 2'd0;         // 上升沿
            trig_en    <= 1'b0;
            trig_clear <= 1'b0;
        end else begin
            trig_clear <= 1'b0;
            if (we) begin
                case (idx)
                    6'd43: trig_th <= wdata[15:0];
                    6'd44: begin
                        trig_en    <= wdata[0];
                        trig_mode  <= wdata[3:2];
                        if (wdata[1]) trig_clear <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        rd_adc = 32'b0;
        case (idx)
            6'd35: rd_adc = {16'b0, adc_rd_data};
            6'd36: rd_adc = {29'b0, (adc_level != 11'd0), adc_ovf, adc_full};
            6'd37: rd_adc = {21'b0, adc_level};
            6'd40: rd_adc = adc_cnt;
            6'd41: rd_adc = {16'b0, adc_last};
            6'd45: rd_adc = {30'b0, trig_above, trig_fired};
            6'd46: rd_adc = trig_cnt;
            6'd47: rd_adc = {16'b0, meas_min};
            6'd48: rd_adc = {16'b0, meas_max};
            6'd49: rd_adc = {16'b0, meas_mean};
            6'd50: rd_adc = meas_cnt;
            default: rd_adc = 32'b0;
        endcase
    end

    always_comb begin
        rd_probe = 32'b0;
        case (idx)
            6'd26: rd_probe = {16'b0, f_h};
            6'd27: rd_probe = {1'b0, addr_h, id00_h, idf5_h, idf6_h};
            6'd28: rd_probe = {16'b0, f_a};
            6'd29: rd_probe = {1'b0, addr_a, id00_a, idf5_a, idf6_a};
            6'd30: rd_probe = {28'b0, a_busy, h_busy, pd_a, pd_h};
            6'd31: rd_probe = {24'b0, health};
            6'd33: rd_probe = {31'b0, col_wr_bank};   // 当前该写哪一块
            default: rd_probe = 32'b0;
        endcase
    end

    /* 三块互不重叠，直接或起来即可（没命中的那块输出 0） */
    assign rdata = rd_h | rd_a | rd_probe | rd_adc;

endmodule
