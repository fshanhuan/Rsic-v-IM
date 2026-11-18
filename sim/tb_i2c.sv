`timescale 1ns / 1ps

/* =============================================================================
 * tb_i2c.sv — i2c_master + i2c_probe 的自检台（含一个 ADV7511 从机模型）
 * -----------------------------------------------------------------------------
 * 为什么值得写这个台子：
 *   上板一次 20~40 分钟，而这个台子跑一轮 1 秒以内。I2C 的坑（重复 START 的
 *   时序、ACK 在第 9 拍采样、SCL 高时改数据）全是"仿真一秒能抓、上板一天抓不到"
 *   的类型。先在这里把协议跑对，上板那次才有意义。
 *
 * 仿真时钟故意用 4 MHz（不是 50 MHz）：SCL 仍是 100 kHz，HALF=20 拍，
 *   既保留"半周期内要有几次采样"的真实比例，又把 3 ms 的探测压到 12000 拍。
 *
 * 从机模型：
 *   · 只应答一个地址（默认 0x72），其余 NACK —— 这样能验证"扫描位图"的分辨率；
 *   · 寄存器 0x00/0xF5/0xF6 预置成 ADV7511 的真实值 0x13/'A'/'D'；
 *   · 严格按 SCL 上升沿采样、下降沿换数据，START/STOP 由 SDA 在 SCL 高时跳变识别。
 * ============================================================================= */
module tb_i2c;

    /* ------------------------------ 时钟与复位 ------------------------------ */
    localparam int CLK_HZ = 4_000_000;
    localparam int SCL_HZ = 100_000;
    localparam int HALF   = CLK_HZ / (SCL_HZ * 2);   // 20

    logic clk = 1'b0;
    logic rst = 1'b1;

    always #125 clk = ~clk;      // 4 MHz

    /* ------------------------------ DUT 接口 ------------------------------ */
    logic        start_pulse = 1'b0;
    logic        done_pulse;
    logic [15:0] found;
    logic        any_found;
    logic [6:0]  addr_lo;
    logic [7:0]  id00, idf5, idf6;
    logic [2:0]  rd_ok;
    logic        busy;

    logic        scl_oe, sda_oe;
    logic        slave_low;                                   // 从机拉低（必须先声明：
                                                              // xvlog 不允许先用后声明，
                                                              // iverilog 却放行 —— 别依赖它）
    wire         scl_w = scl_oe ? 1'b0 : 1'b1;               // 理想上拉
    wire         sda_w = (sda_oe | slave_low) ? 1'b0 : 1'b1; // 开漏"线与"

    i2c_probe #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .start_pulse (start_pulse),
        .done_pulse  (done_pulse),
        .found       (found),
        .any_found   (any_found),
        .addr_lo     (addr_lo),
        .id00        (id00),
        .idf5        (idf5),
        .idf6        (idf6),
        .rd_ok       (rd_ok),
        .busy        (busy),
        .scl_oe      (scl_oe),
        .sda_oe      (sda_oe),
        .sda_i       (sda_w)
    );

    /* =========================================================================
     * 从机模型：只应答 SLAVE_ADDR
     * ====================================================================== */
    localparam logic [6:0] SLAVE_ADDR = 7'h39;   // ADV7511 真实 7 位地址（8 位写地址 0x72）

    logic [7:0] regs [0:255];

    initial begin
        regs[8'h00] = 8'h13;   // 版本
        regs[8'hF5] = 8'h41;   // 'A'
        regs[8'hF6] = 8'h44;   // 'D'
    end

    localparam logic [1:0] A_IDLE = 2'd0, A_ADDR = 2'd1, A_REG = 2'd2, A_RDATA = 2'd3;

    logic [1:0] ast      = A_IDLE;
    logic [3:0] bc       = 4'd0;      // 已采样的数据位数 0..7；8 = 正在 ACK 位（★ 必须 4 位，3'd8 会被截成 0）
    logic [7:0] sh       = 8'd0;
    logic [7:0] regptr   = 8'd0;
    logic       scl_d    = 1'b1;
    logic       sda_d    = 1'b1;

    /* ★ 必须给初值：slave_low 若从 X 开始，sda_w 就是 X，
     *   sda_fall 也跟着变 X → 从机永远看不到 START（第一版就栽在这里）。
     *   仿真里"X 被当假"是最贵的一类 bug，给初值是最便宜的解法。 */
    initial slave_low = 1'b0;

    wire scl_rise = scl_w & ~scl_d;
    wire scl_fall = ~scl_w & scl_d;
    wire sda_fall = ~sda_w & sda_d;    // START
    wire sda_rise = sda_w & ~sda_d;    // STOP

    /* 调试开关：+verbose 打印每个操作；+noslave 让从机完全不应答（模拟接错/没接） */
    logic dbg      = 1'b0;
    logic slave_en = 1'b1;
    initial begin
        if ($test$plusargs("verbose")) dbg      = 1'b1;
        if ($test$plusargs("noslave")) slave_en = 1'b0;
    end

    always @(posedge clk) begin
        scl_d <= scl_w;
        sda_d <= sda_w;

        if (sda_fall && scl_w) begin
            /* START / 重复 START */
            ast      <= A_ADDR;
            bc       <= 4'd0;
            slave_low <= 1'b0;
        end else if (sda_rise && scl_w) begin
            /* STOP */
            ast      <= A_IDLE;
            slave_low <= 1'b0;
        end else begin
            if (scl_fall) begin
                /* 下降沿：准备下一位（数据只在 SCL 低时变化）*/
                if (bc < 4'd8) begin
                    if (ast == A_RDATA) slave_low <= ~regs[regptr][7 - bc];
                    else                slave_low <= 1'b0;
                end else begin
                    /* 第 9 拍（ACK）之前决定要不要拉低 */
                    case (ast)
                        A_ADDR:  begin
                            slave_low <= (slave_en && (sh[7:1] == SLAVE_ADDR));
                            if (dbg) $display("[SLAVE-ACK] t=%0t byte=%02h addr=%02h match=%b",
                                     $time, sh, sh[7:1], (slave_en && (sh[7:1] == SLAVE_ADDR)));
                        end
                        A_REG:   slave_low <= 1'b1;
                        default: slave_low <= 1'b0;   // 读字节的 ACK 由主机发
                    endcase
                end
            end

            if (scl_rise) begin
                if (bc < 4'd8) begin
                    if (ast == A_ADDR || ast == A_REG) sh <= {sh[6:0], sda_w};
                    bc <= bc + 4'd1;
                end else begin
                    /* 第 9 拍结束 = 一个字节（含 ACK）完成。
                     * ★ 这里**不能**释放 slave_low：ACK 必须在整个 SCL 高电平期间保持，
                     *   主机是在高电平末尾才采样的。释放动作留到下一个 SCL 下降沿
                     *   （下面 scl_fall 的 else 分支统一做），否则主机永远读到 NACK。 */
                    bc        <= 4'd0;
                    case (ast)
                        A_ADDR:  ast <= (slave_en && (sh[7:1] == SLAVE_ADDR))
                                        ? (sh[0] ? A_RDATA : A_REG) : A_IDLE;
                        A_REG:   begin regptr <= sh; ast <= A_REG; end
                        A_RDATA: ast <= A_IDLE;
                        default: ast <= A_IDLE;
                    endcase
                end
            end
        end
    end

    /* =========================================================================
     * 激励与检查
     * ====================================================================== */
    int errors = 0;

    /* 逐操作追踪（+verbose）：每完成一个 I2C 操作打一行，协议问题一眼定位 */
    always @(posedge clk) begin
        if (dbg && dut.m_done)
            $display("[OP] t=%0t step=%0d ack=%b rx=%02h tx=%02h found=%04h",
                     $time, dut.step, dut.m_ack, dut.m_rx, dut.m_tx, dut.found_r);
    end

    task automatic chk(input string name, input logic cond);
        if (cond) $display("[PASS] %s", name);
        else begin $display("[FAIL] %s", name); errors++; end
    endtask

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("wave/tb_i2c.vcd");
            $dumpvars(0, tb_i2c);
        end

        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);

        $display("---- 启动一轮探测 ----");
        @(posedge clk);
        start_pulse <= 1'b1;
        @(posedge clk);
        start_pulse <= 1'b0;

        // 等 done_pulse（最多等 4 ms 仿真时间）
        fork : wait_done
            begin
                wait (done_pulse === 1'b1);
                disable wait_done;
            end
            begin
                #4_000_000;
                $display("[FAIL] 探测超时（没有 done_pulse）");
                errors++;
                disable wait_done;
            end
        join

        @(posedge clk);

        $display("---- 结果 ----");
        $display("  found   = %04h  (期望 bit1 = 0x39)", found);
        $display("  any     = %0b", any_found);
        $display("  addr_lo = %02h  (期望 39)", addr_lo);
        $display("  id00    = %02h  (期望 13)", id00);
        $display("  idf5    = %02h  (期望 41 'A')", idf5);
        $display("  idf6    = %02h  (期望 44 'D')", idf6);
        $display("  rd_ok   = %03b", rd_ok);

        if ($test$plusargs("noslave")) begin
            /* 接错线/器件没供电：必须能正常收尾，而不是卡死或误判有器件 */
            chk("无应答时 any_found=0",  any_found === 1'b0);
            chk("无应答时位图全 0",      found == 16'h0000);
            chk("无应答时不读寄存器",    rd_ok == 3'b000);
            chk("无应答时仍能收尾",      busy === 1'b0);
        end else begin
            chk("扫描只应答 0x39",      found  == 16'h0002);
            chk("any_found=1",          any_found === 1'b1);
            chk("选到 0x39",            addr_lo == 7'h39);
            chk("reg 0x00 = 0x13",      id00 == 8'h13);
            chk("reg 0xF5 = 'A'",       idf5 == 8'h41);
            chk("reg 0xF6 = 'D'",       idf6 == 8'h44);
            chk("三个寄存器都读完",      rd_ok == 3'b111);
        end

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    /* 全局看门狗 */
    initial begin
        #20_000_000;
        $display("[FAIL] 仿真总超时");
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
