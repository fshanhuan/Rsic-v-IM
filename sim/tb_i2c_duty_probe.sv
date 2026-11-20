`timescale 1ns / 1ps

/* =============================================================================
 * tb_i2c_duty_probe.sv — 控制实验：**正确接线**时 SCL/SDA 的占空比会不会相同？
 * -----------------------------------------------------------------------------
 * 板上实测（2026-11-20，三个不同窗口）：
 *     SCL = 65.17%  SDA = 65.17%
 *     SCL = 87.95%  SDA = 87.95%
 *     SCL = 14.21%  SDA = 14.21%
 *   三个窗口的值天差地别（自由窗口落在 200 ms 重试周期的不同位置），
 *   但**每一对都逐拍相同**。独立的两根线做不到这件事。
 *
 * 这个 TB 回答一个问题：在**正确接线、芯片不应答**（= 板上现象）的条件下，
 * 我们的逻辑让两根线的高电平拍数应该相差多少？
 *   → 若仿真里两者明显不同，则板上"完全相同"只能是**它们本来就是同一个电节点**
 *     （板上短路 / 桥连 / 座子 15-16 脚相连）。
 *
 * 跑法：vvp tb_i2c_duty_probe.vvp
 * ============================================================================= */
module tb_i2c_duty_probe;

    localparam int CLK_HZ = 4_000_000;
    localparam int SCL_HZ = 100_000;
    localparam int RETRY_CY = 200_000;      // 50 ms @4 MHz（与板上 200 ms 重试同一量级）

    logic clk = 1'b0;
    always #125 clk = ~clk;

    logic rst = 1'b1, start = 1'b0;
    logic scl_oe, sda_oe, sda_i;
    logic busy, done, no_dev;
    logic [4:0]  cur_idx;
    logic [7:0]  last_reg, last_val;
    logic [15:0] ack_err;

    /* 总线上没有从机（= 板上 ADV7511 一直不应答） */
    wire scl_w = scl_oe ? 1'b0 : 1'b1;
    wire sda_w = sda_oe ? 1'b0 : 1'b1;
    assign sda_i = sda_w;

    adv7511_init #(
        .CLK_HZ   (CLK_HZ),
        .SCL_HZ   (SCL_HZ),
        .RETRY_CY (RETRY_CY)
    ) dut (
        .clk(clk), .rst(rst), .start(start),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_i(sda_i),
        .busy(busy), .done(done), .no_dev(no_dev),
        .cur_idx(cur_idx), .last_reg(last_reg), .last_val(last_val),
        .ack_err(ack_err)
    );

    /* 统计两个完整重试周期的占空比 */
    longint n_scl_hi = 0, n_sda_hi = 0, n_cyc = 0;
    longint both_lo = 0, only_scl_lo = 0, only_sda_lo = 0;
    always @(posedge clk) begin
        n_cyc <= n_cyc + 1;
        if (scl_w) n_scl_hi <= n_scl_hi + 1;
        if (sda_w) n_sda_hi <= n_sda_hi + 1;
        if (!scl_w && !sda_w)      both_lo     <= both_lo + 1;
        else if (!scl_w)           only_scl_lo <= only_scl_lo + 1;
        else if (!sda_w)           only_sda_lo <= only_sda_lo + 1;
    end

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        /* 跑 3 个重试周期，再把统计窗口对齐到"最后 2 个周期"没有意义，
         * 直接看总体：两个数相差越大，"板上完全相同"越是异常。 */
        repeat (3 * RETRY_CY) @(posedge clk);
        $display("cycles            = %0d", n_cyc);
        $display("SCL high          = %0d (%.2f%%)", n_scl_hi, 100.0*n_scl_hi/n_cyc);
        $display("SDA high          = %0d (%.2f%%)", n_sda_hi, 100.0*n_sda_hi/n_cyc);
        $display("both low          = %0d", both_lo);
        $display("only SCL low      = %0d", only_scl_lo);
        $display("only SDA low      = %0d", only_sda_lo);
        if (n_scl_hi != n_sda_hi)
            $display("RESULT duty_differs delta=%0d  (正确接线下两根线不可能逐拍相同)",
                     n_scl_hi - n_sda_hi);
        else
            $display("RESULT duty_equal  (逻辑把两根线绑成了一条)");
        $finish;
    end

endmodule
