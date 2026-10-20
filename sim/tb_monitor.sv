`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_monitor.sv -- sw/monitor.c 的 RX 命令通路测试（P3）
 * -----------------------------------------------------------------------------
 * 为什么单独一个测试台：monitor 的**输出**在 tb_cm 里已经验证过（横幅/帮助/提示符），
 *   但它还依赖一条完全不同的通路 —— 串口**收**：
 *     uart_rx -> 8 深 FIFO -> MMIO 0x1000_0008/0x1000_000C -> 软件轮询 -> 命令解析。
 *   这条通路以前只在 v12 的 tb_console 里被"发几个字节看回显"验过，而 monitor 是
 *   第一条真正**解析命令**的程序，值得有自己的回归项。
 *
 * 测什么（第一条命令在横幅还没打完时就塞进 RX FIFO，靠 8 深 FIFO 缓冲，省仿真时间）：
 *   M1 启动横幅出现          -> 程序真的跑起来了
 *   M2 `l 3f` 有回复         -> RX FIFO + 轮询 + 十六进制解析 + 外设写
 *   M3 `p 10000` 有回复      -> peek 命令 + 地址/数据格式
 *
 * 用法：
 *   iverilog -g2012 -I rtl -I board -o _diag/tb_monitor.vvp \
 *       sim/tb_monitor.sv board/board_top.sv board/sync_mem.sv board/reset_sync.sv \
 *       board/uart_tx.sv board/uart_rx.sv board/boot_loader.sv rtl/(all).sv
 *   vvp -n _diag/tb_monitor.vvp +prog=sw/build/monitor_irom.hex \
 *       +dram=sw/build/monitor_dram.hex
 * ============================================================================= */
module tb_monitor;

    localparam integer BIT_NS   = 8680;    // 115200 bps
    localparam integer CLK_HALF = 10;      // 50 MHz

    logic clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    logic rst_n   = 1'b0;
    logic rx_stim = 1'b1;                  // TB-driven host TX line
    logic uart_tx_line;

    logic [31:0] dbg_status, dbg_mcycle;

    reg [8*260-1:0] prog_path = "sw/build/monitor_irom.hex";
    reg [8*260-1:0] dram_path = "sw/build/monitor_dram.hex";

    board_top #(
        .IROM_WORDS (16384),
        .DRAM_WORDS (32768),
        .IROM_INIT  (""),
        .IROM_BOOT  (0)
    ) u_board (
        .sys_clk      (clk),
        .btn_rst_n    (rst_n),
        .uart_rx      (rx_stim),
        .uart_tx      (uart_tx_line),
        .debug_status (dbg_status),
        .debug_mcycle (dbg_mcycle)
    );

    /* ---------------- host -> board : bit level ---------------- */
    task automatic host_send(input [7:0] b);
        integer k;
        begin
            @(negedge clk);
            rx_stim = 1'b0;                    // start bit
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                rx_stim = b[k];                // LSB first
                #(BIT_NS);
            end
            rx_stim = 1'b1;                    // stop bit
            #(BIT_NS);
        end
    endtask

    // Right-aligned packed string; stop at the first NUL from the left.
    task automatic host_send_str(input [8*64-1:0] s);
        integer i;
        reg [7:0] ch;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                ch = s[8*(63-i) +: 8];
                if (ch != 8'h00) host_send(ch);
            end
        end
    endtask

    /* ---------------- board -> host : reuse a verified receiver ---------------- */
    logic [7:0] rx_data;
    logic       rx_valid;

    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) u_term (
        .clk   (clk),
        .rst   (~rst_n),
        .rx    (uart_tx_line),
        .data  (rx_data),
        .valid (rx_valid)
    );

    localparam integer RBUF = 8192;
    logic [7:0] rbuf [0:RBUF-1];
    integer     rlen = 0;

    always @(posedge clk) begin
        if (rst_n && rx_valid) begin
            if (rlen < RBUF) rbuf[rlen] = rx_data;
            rlen = rlen + 1;
        end
    end

    // ---------------------------------------------------------------------
    // 子串匹配：用**显式字节数组**而不是 packed 字符串。
    //   为什么：把 "BigBird" 当 packed vector 传进 function，iverilog 对
    //   partial-select / 对齐的处理与预期不一致（实测横幅明明在缓冲里却判 0）。
    //   显式数组没有任何对齐歧义，1 个字节 1 个元素。
    // ---------------------------------------------------------------------
    reg [7:0] pat [0:31];
    integer   pat_len;
    integer   pat_hit;

    function automatic integer search_pat;
        integer i, j;
        reg     hit;
        begin
            search_pat = 0;
            for (i = 0; i + pat_len <= rlen; i = i + 1) begin
                hit = 1'b1;
                for (j = 0; j < pat_len; j = j + 1)
                    if (rbuf[i + j] != pat[j]) hit = 1'b0;
                if (hit) search_pat = 1;
            end
        end
    endfunction

    // 便捷装载：一次拷入 len 个字节
    task automatic load_pat(input integer len,
                            input [7:0] b0, b1, b2, b3, b4, b5, b6, b7,
                            input [7:0] b8, b9, b10, b11, b12, b13, b14, b15,
                            input [7:0] b16, b17);
        begin
            pat_len = len;
            pat[0]=b0;  pat[1]=b1;  pat[2]=b2;  pat[3]=b3;
            pat[4]=b4;  pat[5]=b5;  pat[6]=b6;  pat[7]=b7;
            pat[8]=b8;  pat[9]=b9;  pat[10]=b10; pat[11]=b11;
            pat[12]=b12; pat[13]=b13; pat[14]=b14; pat[15]=b15;
            pat[16]=b16; pat[17]=b17;
        end
    endtask
    integer npass = 0, nfail = 0;
    task automatic chk(input [8*60-1:0] name, input cond);
        begin
            if (cond) begin npass = npass + 1; $display("  [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    /* ---------------- RXDATA 读取/弹出计数（定位"每读一个丢一个"） ---------------- */
    integer n_pop = 0, n_rd = 0;
    logic   rd_prev = 1'b0;
    always @(posedge clk) begin
        if (u_board.rx_pop) n_pop <= n_pop + 1;
        if (u_board.perip_ren && u_board.mmio_sel && (u_board.mmio_idx == 3'd2)) begin
            n_rd = n_rd + 1;
            if ($test$plusargs("poptrace"))
                $display("  [RD] c=%0t ren=%b pop=%b rp=%0d cnt=%0d rd=%02x pc=%h en=%b adv=%b mrr=%b idx=%0d a=%h",
                         $time, u_board.perip_ren, u_board.rx_pop,
                         u_board.rx_rp, u_board.rx_cnt, u_board.rx_fifo[u_board.rx_rp],
                         u_board.u_cpu.debug_wb_pc,
                         u_board.u_cpu.DCache_inst.cpu_en,
                         u_board.u_cpu.DCache_inst.cpu_adv,
                         u_board.u_cpu.DCache_inst.mem_req_r,
                         u_board.mmio_idx,
                         u_board.u_cpu.DCache_inst.cpu_addr);
        end
    end

    /* ---------------- main ---------------- */
    integer i;
    logic   m1, m2, m3, m4, m5, m6;

    initial begin
        $display("================================================================");
        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("dram=%s", dram_path)) ;
        $display(" tb_monitor : prog=%0s dram=%0s", prog_path, dram_path);
        $display("================================================================");

        for (i = 0; i < 16384; i = i + 1) u_board.dram_inst.mem_ram[i] = 32'h0;
        $readmemh(prog_path, u_board.g_irom_rom.irom_inst.mem);
        // DRAM image at word offset 0x4000 (address 0x1_0000, link.ld ORIGIN(dram))
        $readmemh(dram_path, u_board.dram_inst.mem_ram, 32'h4000);

        #200 rst_n = 1'b1;

        // Send the first command early: the 8-deep RX FIFO holds it while the
        // monitor is still printing its banner + help.
        #1_000_000;
        host_send_str("l 3f");  host_send(8'h0D);

        // Banner is now 3 short lines (~110 chars = ~10 ms at 115200), then the
        // queued command runs.  Keep this tight: every ms here costs iverilog real
        // minutes (68 ms was ~15 min; 15 ms is ~3 min).
        #15_000_000;
        // "BigBird" = 42 69 67 42 69 72 64
        load_pat(7, 8'h42,8'h69,8'h67,8'h42,8'h69,8'h72,8'h64,
                 0,0,0,0,0,0,0,0,0,0,0);
        m1 = search_pat();
        // "LED <- 0x0000003f" = 4C 45 44 20 3C 2D 20 30 78 30 30 30 30 30 30 33 66
        load_pat(17, 8'h4C,8'h45,8'h44,8'h20,8'h3C,8'h2D,8'h20,8'h30,8'h78,
                 8'h30,8'h30,8'h30,8'h30,8'h30,8'h30,8'h33,8'h66,8'h00);
        m2 = search_pat();
        // v14: "code-win OK" —— 开机自检 IROM 数据窗口（= "lw 读得到自己的代码"）
        //   c o d e - w i n _ O K
        load_pat(11, 8'h63,8'h6F,8'h64,8'h65,8'h2D,8'h77,8'h69,8'h6E,
                 8'h20,8'h4F,8'h4B,0,0,0,0,0,0,0);
        m4 = search_pat();

        host_send_str("p 10000");  host_send(8'h0D);
        #6_000_000;
        // "[00010000] = 0x" = 5B 30 30 30 31 30 30 30 30 5D 20 3D 20 30 78
        load_pat(15, 8'h5B,8'h30,8'h30,8'h30,8'h31,8'h30,8'h30,8'h30,8'h30,
                 8'h5D,8'h20,8'h3D,8'h20,8'h30,8'h78,0,0,0);
        m3 = search_pat();

        // ---- v16: load/run（软件写代码区 + 跳过去执行）----------------------
        //   往 IROM 窗口 0x2_3000（取指地址 0x3000）写 4 条指令，再 `r 3000`：
        //     lui  a0,0x10000    0x10000537
        //     addi a1,zero,42    0x02A00593   ('*')
        //     sw   a1,0(a0)      0x00B52023   -> UART TXDATA
        //     jalr zero,0(ra)    0x00008067   返回 monitor
        //   判据：monitor 打出 "loaded 16 bytes"，返回后打出 " returned"
        //   （后者只在应用**真的执行完并返回**时才出现）。
        host_send_str("L 4000");  host_send(8'h0D);
        #2_000_000;
        host_send_str("10000537"); host_send(8'h0D); #1_500_000;
        host_send_str("02A00593"); host_send(8'h0D); #1_500_000;
        host_send_str("00B52023"); host_send(8'h0D); #1_500_000;
        host_send_str("00008067"); host_send(8'h0D); #1_500_000;
        host_send_str(".");        host_send(8'h0D); #12_000_000;
        host_send_str("p 24000");  host_send(8'h0D); #4_000_000;
        host_send_str("r 4000");   host_send(8'h0D); #8_000_000;

        // "loaded 16 bytes" = 6C 6F 61 64 65 64 20 31 36 20 62 79 74 65 73
        load_pat(15, 8'h6C,8'h6F,8'h61,8'h64,8'h65,8'h64,8'h20,8'h31,
                 8'h36,8'h20,8'h62,8'h79,8'h74,8'h65,8'h73,0,0,0);
        m5 = search_pat();
        // "* returned" = 2A 20 72 65 74 75 72 6E 65 64  —— 星号是**应用自己**写的
        //   （proves 它真的执行了：lui/addi/sw 三条都生效）
        load_pat(10, 8'h2A,8'h20,8'h72,8'h65,8'h74,8'h75,8'h72,8'h6E,8'h65,8'h64,
                 0,0,0,0,0,0,0,0);
        m6 = search_pat();

        $display("---- board output (%0d bytes) ----", rlen);
        for (i = 0; i < rlen && i < RBUF; i = i + 1) begin
            if (rbuf[i] >= 8'h20 && rbuf[i] < 8'h7F) $write("%c", rbuf[i]);
            else if (rbuf[i] == 8'h0A)               $write("\n");
            else if (rbuf[i] == 8'h0D)               ;
            else                                     $write(".");
        end
        $display("\n----------------------------------");

        $display("  [COUNT] RXDATA reads=%0d  rx_pop pulses=%0d  (bytes received=%0d)", n_rd, n_pop, rlen);
        chk("M1 banner printed",        m1);
        chk("M2 'l 3f' replied",        m2);
        chk("M3 'p 10000' replied",     m3);
        chk("M4 IROM window readable", m4);
        chk("M5 load wrote 16 bytes", m5);
        chk("M6 run executed app", m6);

        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[MONITOR-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[MONITOR-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
        $finish;
    end

endmodule
