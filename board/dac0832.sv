`timescale 1ns / 1ps

/* =============================================================================
 * dac0832.sv — DAC0832 直通驱动（S2 自环测试的信号源）
 * -----------------------------------------------------------------------------
 * 板上 DAC 模块（EES-331 手册 §17）：
 *   主芯片 DAC0832，后接 LM324 **反相**输出，运放供电 ±5 V，
 *   参考电压由电阻分压得到 DAC_VREF = 5V × 4.7k/(4.7k+1.2k) ≈ 3.98 V。
 *
 * 引脚（手册"器件型号/类别：DAC0832 管脚 IO 分配"）：
 *   CS#   H17    WR1#  D17    WR2#  F16    XFER# D16    BYTE2 E16
 *   D7..D0 = E15 D15 G15 G16 F18 E18 G17 F17
 *
 * ★ 用"直通（transparent）"接法，不做双缓冲：
 *   CS#=0、WR1#=0、WR2#=0、XFER#=0、BYTE2/ILE=1 时，输入锁存器是透明的，
 *   DAC 输出直接跟随 D7..D0。这样"写一个寄存器"就等于"改变输出电平"，
 *   没有任何握手，最适合当测试信号源。
 *   代价：输出端会看到写操作瞬间的跳变（本来就是要看阶跃，正好）。
 *
 * ★ 注意输出是**反相**的：写 0x00 得到接近 +3.98 V，写 0xFF 得到接近 0 V。
 *   做 XADC 自环时这个反相不影响功能（只是波形上下颠倒），但**读数解释**时
 *   必须记得这一点，否则会以为 ADC 接反了。
 *
 * ★ 未知项（上板第一件事就验它）：
 *   手册把 U24-19 标成 DAC_BYTE2，而 DAC0832 同位置的标准名字是 ILE（输入锁存使能）。
 *   这里按 ILE 处理给 1。若上板发现 DAC 输出恒为 0，先把 DIP 的这根改 0 再试，
 *   或直接量 U24-19 电平 —— 这是本模块唯一没法靠仿真确认的地方。
 * ============================================================================= */
module dac0832 (
    input  logic       clk,
    input  logic       rst,

    input  logic [7:0] data,      // 要输出的码值（来自 MMIO）
    input  logic       wr,        // 单拍写脉冲

    output logic [7:0] dac_d,     // 对应 D7..D0
    output logic       dac_cs_n,
    output logic       dac_wr1_n,
    output logic       dac_wr2_n,
    output logic       dac_xfer_n,
    output logic       dac_ile
);

    /* ★ 复位值必须是 8'hFF，不能是 0：
     *   输出经 LM324 反相，码值 0x00 对应**满量程 3.98 V**。如果复位时是 0，
     *   上电瞬间 DAC 就把接近 4 V 顶到输出脚上 —— 而 XADC 的 AD11/AD6 只允许
     *   0~1 V，自环线一接上去就有过压风险。
     *   复位给 0xFF → 输出约 0 V，任何接线顺序都是安全的。
     *   （同理 rec_mmio 的 dac_data 复位值也是 0xFF。） */
    always_ff @(posedge clk) begin
        if (rst)     dac_d <= 8'hFF;
        else if (wr) dac_d <= data;
    end

    /* 直通模式：控制脚恒定有效 */
    assign dac_cs_n   = 1'b0;
    assign dac_wr1_n  = 1'b0;
    assign dac_wr2_n  = 1'b0;
    assign dac_xfer_n = 1'b0;
    assign dac_ile    = 1'b1;

endmodule
