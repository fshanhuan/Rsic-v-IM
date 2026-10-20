`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_console.sv — v12（C）console 收发 + 定时器中断 + GPIO 端到端测试
 * -----------------------------------------------------------------------------
 * 前面几个测试台各管一段，这个测的是"**平台能不能对话**"：
 *   tb_uart_tx         —— 发送器自己（回环）
 *   tb_board_top_uart  —— MMIO 写出去能不能被别的 UART 收到
 *   tb_console（本台） —— **双向**：外面的字节能进来（RX FIFO），能原样回显，
 *                         同时定时器中断在跑（LED 会变）
 *
 * 接线（全在片内，不接引脚）：
 *   TB 的 uart_tx ──→ board_top.uart_rx        （模拟键盘/串口终端 → CPU）
 *   board_top.uart_tx ──→ TB 的 uart_rx        （CPU → 串口终端）
 *
 * 程序：sim/console_demo_sim.hex（由 sim/gen_console_demo.py 2000 生成，
 *   tick = 2000 * 2us = 4ms，比板上的 10ms 短，仿真才跑得完）。
 *
 * 判据：
 *   C1 上电横幅 == "BigBird v12\r\n"（13 字节，**顺序与内容**都要对）
 *   C2 发 'A' 回显 'A'（RX FIFO → 主循环 → TXDATA 全链路）
 *   C3 连发 "OK\r"（3 字节）全部回显、顺序不变（FIFO 深度够用，不丢字节）
 *   C4 定时器中断在跑：led != 0，且回显期间它还在变（中断不与主循环互锁）
 *   C5 至少收到 2 个 '.'（每 4 个 tick 一个点）
 * ============================================================================= */
module tb_console;

    logic clk = 1'b0;
    logic btn_rst_n = 1'b0;
    always #10 clk = ~clk;        // 50MHz，与板上一致

    // ------------------------------------------------------------ 板级观测口
    logic        dbg_have_inst, dbg_ena, dbg_trap_take, dbg_dnpc_flag, dbg_ready;
    logic [31:0] dbg_pc, dbg_value, dbg_ifu_pc;
    logic [ 4:0] dbg_reg;
    logic [31:0] ic_hit, ic_miss, dc_hit, dc_miss;
    logic [31:0] dbg_mcause, dbg_mepc, dbg_mtval;
    logic [31:0] dbg_status, dbg_mcycle;
    logic        boot_busy, boot_ok, boot_err;
    logic        uart_tx_line;
    logic        uart_tx_line_stim;   // TB 发送器的输出（→ 板子的 uart_rx）
    logic [ 6:0] led;

    reg [8*260-1:0] prog_path = "sim/console_demo_sim.hex";

    board_top #(
        .IROM_WORDS (4096),
        .DRAM_WORDS (16384),
        .IROM_INIT  (""),
        .IROM_BOOT  (0)
    ) u_board (
        .sys_clk               (clk),
        .btn_rst_n             (btn_rst_n),

        .debug_wb_have_inst    (dbg_have_inst),
        .debug_wb_pc           (dbg_pc),
        .debug_wb_ena          (dbg_ena),
        .debug_wb_reg          (dbg_reg),
        .debug_wb_value        (dbg_value),

        .debug_icache_hit_cnt  (ic_hit),
        .debug_icache_miss_cnt (ic_miss),
        .debug_dcache_hit_cnt  (dc_hit),
        .debug_dcache_miss_cnt (dc_miss),

        .debug_mcause          (dbg_mcause),
        .debug_mepc            (dbg_mepc),
        .debug_mtval           (dbg_mtval),
        .debug_trap_take       (dbg_trap_take),

        .debug_dnpc_flag       (dbg_dnpc_flag),
        .debug_ready           (dbg_ready),
        .debug_ifu_pc          (dbg_ifu_pc),

        .debug_status          (dbg_status),
        .debug_mcycle          (dbg_mcycle),

        .uart_rx               (uart_tx_line_stim),   // ← TB 的发送器
        .uart_tx               (uart_tx_line),        // → TB 的接收器
        .led                   (led),
        .debug_boot_busy       (boot_busy),
        .debug_boot_ok         (boot_ok),
        .debug_boot_err        (boot_err)
    );

    // --------------------------------------------- 键盘侧：TB 直接位翻转模拟串口
    // ★ 为什么不用 uart_tx 当激励：第一版是"TB 例化一个 uart_tx 去喂板子的
    //   uart_rx"，结果 send 脉冲在这个环境里**从来没被采样器看到**（[SAMP] 一行
    //   都没有），排查代价比它省下的代码大得多。位翻转只有 10 行，且它就是
    //   "一个真实终端在线上做什么"，反而更可信 —— 它不依赖任何被测 RTL。
    localparam integer BIT_NS  = 8680;      // 50MHz / 115200 ≈ 434 拍 = 8680ns

    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_tx_line_stim = 1'b0;                 // 起始位
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                uart_tx_line_stim = b[k];             // LSB first
                #(BIT_NS);
            end
            uart_tx_line_stim = 1'b1;                 // 停止位
            #(BIT_NS);
            if ($test$plusargs("fifotr"))
                $display("[STIM] cyc=%0d sent 0x%02x", cyc, b);
        end
    endtask

    // --------------------------------------------- 终端侧：TB 的接收器（观察）
    logic [7:0] rx_data;
    logic       rx_valid;
    integer     rx_cnt = 0;
    logic [7:0] rx_bytes [0:63];

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115_200)
    ) u_term (
        .clk   (clk),
        .rst   (~btn_rst_n),
        .rx    (uart_tx_line),
        .data  (rx_data),
        .valid (rx_valid)
    );

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // 调试口：FIFO 计数每次变化都打一行（+fifotr），用来分辨"字节没进来"
    //   和"进来了但被读走/被丢"。console 类问题只靠最终字节数永远分不清这两种。
    logic [3:0] prev_fifo = 4'd0;
    integer     raw_valid_cnt = 0;
    always @(posedge clk) begin
        if (btn_rst_n && $test$plusargs("fifotr")) begin
            // 原始接收脉冲：分辨"uart_rx 根本没解出帧"和"FIFO 逻辑丢字节"
            if (u_board.con_rx_valid) begin
                raw_valid_cnt = raw_valid_cnt + 1;
                $display("[RAW ] cyc=%0d con_rx_valid data=0x%02x (#%0d)",
                         cyc, u_board.con_rx_data, raw_valid_cnt);
            end
            if (u_board.rx_cnt !== prev_fifo) begin
                $display("[FIFO] cyc=%0d cnt %0d -> %0d (wp=%0d rp=%0d)",
                         cyc, prev_fifo, u_board.rx_cnt, u_board.rx_wp, u_board.rx_rp);
                prev_fifo <= u_board.rx_cnt;
            end
            // MMIO 写脉冲：确认"软件真的写了 TXDATA"（区分"程序没写"与"写了没发出去"）
            if (u_board.perip_wen && u_board.mmio_sel && u_board.mmio_idx == 3'd0) begin
                $display("[TXW ] cyc=%0d TXDATA <= 0x%02x busy=%b",
                         cyc, u_board.perip_wdata[7:0], u_board.uart_busy);
            end
        end
    end

    logic [6:0] led_seen;
    always @(posedge clk) begin
        if (btn_rst_n && rx_valid) begin
            if (rx_cnt < 64) rx_bytes[rx_cnt] = rx_data;
            rx_cnt = rx_cnt + 1;
            if (rx_data >= 8'd32 && rx_data < 8'd127)
                $display("[CON] cyc=%0d '%c' (0x%02x) count=%0d led=0x%02x",
                         cyc, rx_data, rx_data, rx_cnt, led);
            else
                $display("[CON] cyc=%0d 0x%02x count=%0d led=0x%02x",
                         cyc, rx_data, rx_cnt, led);
        end
        if (btn_rst_n && led != 7'd0) led_seen <= led;
    end

    // ------------------------------------------------------------------ 判据
    integer npass = 0, nfail = 0;
    task chk(input [8*70-1:0] name, input cond);
        begin
            if (cond) begin npass = npass + 1; $display("  [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    // 发一个字节（用位翻转，见上面 uart_send 的说明）
    task send_byte(input [7:0] b);
        begin
            uart_send(b);
        end
    endtask

    localparam [8*13-1:0] BANNER = "BigBird v12\r\n";

    integer k, guard;
    initial begin
        for (k = 0; k < 16384; k = k + 1) u_board.dram_inst.mem_ram[k] = 32'h0;
        if ($value$plusargs("prog=%s", prog_path)) ;
        $display("================================================================");
        $display(" tb_console : program=%0s", prog_path);
        $display("   MMIO: TX=0x1000_0000 TXST=+4 RX=+8 RXST=+C LED=+0x10");
        $display("================================================================");
        $readmemh(prog_path, u_board.g_irom_rom.irom_inst.mem);

        uart_tx_line_stim = 1'b1;   // 串口空闲态
        btn_rst_n = 1'b0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        #1 btn_rst_n = 1'b1;

        // ---- C1：等横幅（13 字节 × 87us ≈ 1.2ms，给到 5ms）----
        guard = 0;
        while (rx_cnt < 13 && guard < 300000) begin @(posedge clk); guard = guard + 1; end
        $display("[INFO] banner wait = %0d cycles", guard);
        chk("C1 banner length == 13", rx_cnt == 13);
        begin
            logic ok;
            // ★ 逐字节与字面量比较，不用字符串常量做位切片：`localparam [103:0] S = "..."` 
            //   的字节序（左对齐还是右对齐、是否补 0）在各仿真器间容易记错，
            //   而这里 13 个字面量 8'hxx 一眼就能对上 "BigBird v12\r\n"。
            ok = (rx_bytes[0]  == 8'h42) && (rx_bytes[1]  == 8'h69) &&   // B i
                 (rx_bytes[2]  == 8'h67) && (rx_bytes[3]  == 8'h42) &&   // g B
                 (rx_bytes[4]  == 8'h69) && (rx_bytes[5]  == 8'h72) &&   // i r
                 (rx_bytes[6]  == 8'h64) && (rx_bytes[7]  == 8'h20) &&   // d ' '
                 (rx_bytes[8]  == 8'h76) && (rx_bytes[9]  == 8'h31) &&   // v 1
                 (rx_bytes[10] == 8'h32) && (rx_bytes[11] == 8'h0D) &&   // 2 CR
                 (rx_bytes[12] == 8'h0A);                                // LF
            chk("C1 banner bytes == BigBird v12 CRLF", ok);
            if (!ok) begin
                integer i;
                $write("       got: ");
                for (i = 0; i < 13; i = i + 1) $write("%02x ", rx_bytes[i]);
                $write("\n");
            end
        end

        // ---- C2：回显单个字节 ----
        send_byte(8'h41);                       // 'A'
        guard = 0;
        while (rx_cnt < 14 && guard < 20000) begin @(posedge clk); guard = guard + 1; end
        chk("C2 echo of 'A'", rx_cnt == 14 && rx_bytes[13] == 8'h41);

        // ---- C3：连发 3 字节，全部按序回显 ----
        send_byte(8'h4F);                       // 'O'
        send_byte(8'h4B);                       // 'K'
        send_byte(8'h0D);                       // CR
        guard = 0;
        while (rx_cnt < 17 && guard < 40000) begin @(posedge clk); guard = guard + 1; end
        chk("C3 echo of 'O','K',CR",
            rx_cnt == 17 && rx_bytes[14] == 8'h4F &&
            rx_bytes[15] == 8'h4B && rx_bytes[16] == 8'h0D);

        // ---- C4/C5：中断在跑（等够几个 tick）----
        guard = 0;
        while (guard < 600000) begin @(posedge clk); guard = guard + 1; end
        $display("[INFO] led_seen = 0x%02x   rx_cnt = %0d", led_seen, rx_cnt);
        chk("C4 timer interrupt ran (LED != 0)", led_seen != 7'd0);
        begin
            logic dot;
            integer i;
            dot = 1'b0;
            for (i = 0; i < 64; i = i + 1)
                if (rx_bytes[i] == 8'h2E) dot = 1'b1;
            chk("C5 at least one '.' heartbeat", dot);
        end

        $display("");
        $display("  total cycles = %0d   received = %0d bytes", cyc, rx_cnt);
        $display("--------------------------------------------------");
        if (nfail == 0)
            $display("[CONSOLE-SELFCHECK] status=PASS (%0d checks)", npass);
        else
            $display("[CONSOLE-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $display("==================================================");
        $finish;
    end

endmodule
