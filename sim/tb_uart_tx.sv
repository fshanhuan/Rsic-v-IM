`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_uart_tx.sv — v12（B）串口发送器单元测试（回环：tx → rx）
 * -----------------------------------------------------------------------------
 * 为什么这样测：uart_tx 的正确性只有一个外部可观测的判据 —— **别的 UART 能不能
 *   原样收到那个字节**。所以这里把 tx 直接接到 uart_rx 的输入上（同一组
 *   CLK_FREQ/BAUD 参数），用已经验证过的接收器当"标准答案生成器"。
 *   如果位宽/波特/停止位有一处不对，收到的字节就是错的或收不到。
 *
 * ★ 时钟取 50MHz 而不是 100MHz：上板跑的就是 50MHz（board_top_ila 的 MMCM 分频），
 *   BIT_TICKS(50MHz,115200)=434。用 100MHz 测出来的是 868，与板上不是同一条路径。
 *   （同时把波特从 115200 换成一个"小数值"可以加快仿真 —— 但那样验的就不是板上
 *   的真实分频比了，所以这里坚持用真参数。一帧 4340 拍 = 86.8us，三个字节 ~260us，
 *   仿真仍然很便宜。）
 *
 * 判据：
 *   T1 空闲态 tx == 1（UART 规定，反了对面永远等到一帧的起始沿）
 *   T2 单字节 0xA5 正确回环，valid 只脉冲一拍
 *   T3 连续三个字节（每次等 busy 落）都能收到，顺序与内容一致
 *   T4 busy=1 期间给的 send **被丢弃**（不排队、不串包）；随后空闲态再发仍正确
 *   T5 一帧的时长 = 10 位 × BIT_TICKS（起止位各 1 + 数据 8），误差 < 2 拍
 * ============================================================================= */
module tb_uart_tx;

    localparam integer CLK_FREQ  = 50_000_000;
    localparam integer BAUD      = 115_200;
    localparam integer BIT_TICKS = (CLK_FREQ + (BAUD / 2)) / BAUD;   // 434

    // ------------------------------------------------------------------ 时钟
    // 50MHz → 周期 20ns。半周期 10ns。
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #10 clk = ~clk;

    // ------------------------------------------------------------ DUT：发送器
    logic [7:0] tx_data;
    logic       tx_send;
    logic       tx_line;
    logic       tx_busy;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_tx (
        .clk  (clk),
        .rst  (rst),
        .data (tx_data),
        .send (tx_send),
        .tx   (tx_line),
        .busy (tx_busy)
    );

    // ------------------------------------------------- 参照接收器（回环对端）
    logic [7:0] rx_data;
    logic       rx_valid;

    uart_rx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_rx (
        .clk   (clk),
        .rst   (rst),
        .rx    (tx_line),      // ★ 回环：发送器的输出直接进接收器
        .data  (rx_data),
        .valid (rx_valid)
    );

    // ------------------------------------------------------------------ 判据
    integer npass = 0, nfail = 0;

    task chk(input [8*70-1:0] name, input cond);
        begin
            if (cond) begin
                npass = npass + 1;
                $display("  [PASS] %0s", name);
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    // 收一个字节：等 valid 脉冲，返回 data；超时返回 1（用 got_ok 标记）
    logic [7:0] got;
    logic       got_ok;
    integer     rx_cnt = 0;      // 收到的字节总数（独立于 got_ok，用于 T4）
    integer     cyc;

    always @(posedge clk) begin
        if (!rst && rx_valid) begin
            got    = rx_data;
            got_ok = 1'b1;
            rx_cnt = rx_cnt + 1;
            $display("  [RX ] byte=%h (count=%0d) @ cyc=%0d", rx_data, rx_cnt, cyc);
        end
    end

    // 发一个字节并等它收回来（先等空闲，再发，再等 valid）
    // ★ 结果放在模块级 got_ok/got 里，任务本身不带 output 参数 —— 少一处形参与
    //   实参同名（iverilog 对 task 的 ANSI output 支持不如 always 稳）。
    // 发一个单拍 send 脉冲。
    // ★ 不变量（仿真纪律）：**必须在 negedge 驱动激励**。在 posedge 之后紧跟
    //   `tx_send = 1'b0;` 会与被测模块的 always_ff（同样在 posedge 采样）形成竞争，
    //   iverilog 下表现为"send 没被看到 → busy 永远不起 → 死等超时"。
    //   第一版就是这么挂的（日志只剩两行 PASS 然后 TIMEOUT）。
    task tx_pulse(input [7:0] b);
        begin
            @(negedge clk);
            tx_data = b;
            tx_send = 1'b1;
            @(negedge clk);
            tx_send = 1'b0;
        end
    endtask

    // 等空闲（带 guard，绝不无限等）
    task wait_idle(output logic ok);
        integer g;
        begin
            g = 0;
            while (tx_busy && g < 40*BIT_TICKS) begin @(posedge clk); g = g + 1; end
            ok = !tx_busy;
        end
    endtask

    // 发一个字节并等它收回来（先等空闲，再发，再等 valid）
    // ★ 结果放在模块级 got_ok/got 里，任务本身不带 output 参数 —— 少一处形参与
    //   实参同名（iverilog 对 task 的 ANSI output 支持不如 always 稳）。
    task send_and_recv(input [7:0] b);
        integer guard;
        logic   idle_ok;
        begin
            wait_idle(idle_ok);
            got_ok  = 1'b0;
            tx_pulse(b);
            guard = 0;
            while (!got_ok && guard < 20*BIT_TICKS) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------ 主流程
    integer     t0, t1;
    logic [7:0] trio [0:2];
    logic       idle_ok;      // wait_idle 的结果

    initial begin
        $display("================================================================");
        $display(" tb_uart_tx : loopback tx -> rx   (CLK=%0d Hz, BAUD=%0d, BIT_TICKS=%0d)",
                 CLK_FREQ, BAUD, BIT_TICKS);
        $display("================================================================");

        tx_data = 8'h00;
        tx_send = 1'b0;
        rst     = 1'b1;
        repeat (20) @(posedge clk);
        @(negedge clk);
        #1 rst = 1'b0;
        repeat (5) @(posedge clk);

        // ---- T1 空闲态 ----
        chk("idle: tx == 1", tx_line == 1'b1);
        chk("idle: busy == 0", tx_busy == 1'b0);

        // ---- T2 单字节 + 帧时长 ----
        wait_idle(idle_ok);
        got_ok = 1'b0;
        tx_pulse(8'hA5);
        // 从起始位开始计时到 busy 落下（= 整帧时长）
        t0 = 0;
        while (!tx_busy && t0 < 16) begin @(posedge clk); t0 = t0 + 1; end   // 等 busy 起来
        t1 = 0;
        while (tx_busy && t1 < 40*BIT_TICKS) begin @(posedge clk); t1 = t1 + 1; end   // 整帧
        chk("0xA5: loopback byte matches", got_ok && (got == 8'hA5));
        $display("       frame length = %0d cycles (expect 10*BIT_TICKS = %0d)",
                 t1, 10*BIT_TICKS);
        chk("frame length within +-4 cycles of 10*BIT_TICKS",
            (t1 >= 10*BIT_TICKS - 4) && (t1 <= 10*BIT_TICKS + 4));

        // ---- T3 连续三个字节 ----
        trio[0] = 8'h00;   // 全 0：起始位与数据位全是低，最容易被接收器误判
        trio[1] = 8'hFF;   // 全 1：与空闲态相同，最容易"看不出帧边界"
        trio[2] = 8'h5A;
        begin
            integer k;
            for (k = 0; k < 3; k = k + 1) begin
                send_and_recv(trio[k]);
                if (k == 0) chk("back-to-back #0 (0x00)", got_ok && (got == trio[0]));
                if (k == 1) chk("back-to-back #1 (0xFF)", got_ok && (got == trio[1]));
                if (k == 2) chk("back-to-back #2 (0x5A)", got_ok && (got == trio[2]));
            end
        end

        // ---- T4 busy 期间的 send 被丢弃 ----
        //   做法：先发 0x3C，然后在**帧中间**（第 4 个位时间处）再塞一个 send 脉冲。
        //   正确行为是那个 send 被静默丢弃：总共只收到 1 个字节，且内容是 0x3C。
        begin
            integer cnt_before;
            wait_idle(idle_ok);
            got_ok  = 1'b0;
            cnt_before = rx_cnt;
            tx_pulse(8'h3C);
            // 走到帧中间（此时 busy 必须已经是 1）
            repeat (4*BIT_TICKS) @(negedge clk);
            chk("busy is high mid-frame", tx_busy == 1'b1);
            if (tx_busy) begin
                tx_data = 8'hC3;
                tx_send = 1'b1;
                @(negedge clk);
                tx_send = 1'b0;
            end
            // 等这一帧收完，再多放几个字节的时间看有没有"多出来的第二个字节"
            repeat (12*BIT_TICKS) @(negedge clk);
            chk("send while busy is dropped (only 1 byte)", (rx_cnt - cnt_before) == 1);
            chk("the delivered byte is the first one (0x3C)", got == 8'h3C);
            // 空闲态再发一次，确认发送器没被前面那次"丢弃的 send"搞坏
            send_and_recv(8'hE7);
            chk("recovers after dropped send (0xE7)", got_ok && (got == 8'hE7));
        end

        // ---- 收尾 ----
        $display("--------------------------------------------------");
        if (nfail == 0)
            $display("[UART-TX-SELFCHECK] status=PASS (%0d checks)", npass);
        else
            $display("[UART-TX-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $display("==================================================");
        $finish;
    end

    // 周期计数（只用于打印）
    initial cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // 总超时保护：真挂死了要说清楚是超时，而不是"跑完没打印"
    //   6 帧 ≈ 6 × 87us = 522us；给到 2ms（≈100k 拍）绰绰有余。
    initial begin
        #(2_000_000);
        $display("[UART-TX-SELFCHECK] status=TIMEOUT");
        $finish;
    end

endmodule
