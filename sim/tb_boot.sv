`timescale 1ns / 1ps

/* =============================================================================
 * tb_boot.sv — 串口引导的端到端仿真（三条路径一次跑完）
 * -----------------------------------------------------------------------------
 * 为什么要先仿真再上板：`jtag_axi` 那条路最大的问题是"不可仿真"，每次错了都要
 *   33 分钟构建 + 上板试。UART 引导相反 —— 这个测试台用一个假的 UART 发送器把
 *   整个协议跑通，包括**失败路径**，全部在 iverilog 里完成。
 *
 * 三个 DUT（同一个 50MHz 时钟、同时复位、各自的串口线）：
 *   u_ok  : IROM_INIT=""（空） + 灌入合法镜像 → 期望 boot_ok=1，CPU 跑到新程序
 *           （x10=42、x11=99 写回）
 *   u_bad : IROM_INIT=""（空） + 灌入**校验和错误**的镜像 → 期望 boot_err=1、
 *           boot_ok=0，且 boot_busy 最终回到 0（★ 失败不能把板子永久按住）
 *   u_tmo : IROM_INIT=prog_boot_tmo.hex + **不发**任何数据（超时 1ms）→ 期望
 *           CPU 跑 IROM 里固化的旧程序（x1=1、x2=2），即"离了主机也能启动"
 *
 * 帧格式见 board/boot_loader.sv 头部：'B' + len(4B BE) + 数据(4B/字) + cks(4B BE)，
 *   最后再补一个 'G'（GO）才会释放 CPU。
 * ============================================================================= */
module tb_boot;

    localparam integer BIT_NS = 8680;    // 115200 bps → 8.68 us/bit
    // ★ v13.3（P1）帧首静默：每个帧（magic）之前必须让线路静默 > SOF_SILENCE_MS(1 ms)。
    //   帧内字节仍然一个接一个（间隔 87 us），所以静默只出现在帧边界 —— 这正是
    //   boot_loader 区分"命令"和"载荷里的假 magic"的依据。
    localparam integer GAP_NS = 2_000_000;   // 2 ms

    logic clk = 1'b0;
    always #10 clk = ~clk;               // 50 MHz

    logic rst_n = 1'b0;                  // 低有效
    logic rx_ok = 1'b1, rx_bad = 1'b1, rx_tmo = 1'b1;

    /* ---------------- DUT 1：正常镜像 ---------------- */
    logic        ok_have, ok_ena;
    logic [31:0] ok_pc, ok_val;
    logic [ 4:0] ok_reg;
    logic        ok_busy, ok_ok, ok_err;

    board_top #(
        .IROM_BOOT   (1),
        .IROM_INIT   (""),
        // ★ v13.3（P1）：帧间空隙 2 ms > 静默门限 1 ms > 帧内字节间隔 87 us。
        //   所以"等 magic 的窗口"必须比帧间空隙长（50 ms），否则第二个帧还没来
        //   loader 就先超时释放 CPU 了。
        .BOOT_TMO_MS (50),
        .BOOT_GAP_MS (5),
        .BOOT_SILENCE_MS (1)
    ) u_ok (
        .sys_clk          (clk),
        .btn_rst_n        (rst_n),
        .uart_rx          (rx_ok),
        .debug_wb_have_inst (ok_have),
        .debug_wb_pc        (ok_pc),
        .debug_wb_ena       (ok_ena),
        .debug_wb_reg       (ok_reg),
        .debug_wb_value     (ok_val),
        .debug_boot_busy    (ok_busy),
        .debug_boot_ok      (ok_ok),
        .debug_boot_err     (ok_err)
    );

    /* ---------------- DUT 2：校验和错误 ---------------- */
    logic        bad_busy, bad_ok, bad_err;

    board_top #(
        .IROM_BOOT   (1),
        .IROM_INIT   (""),
        .BOOT_TMO_MS (50),
        .BOOT_GAP_MS (5),
        .BOOT_SILENCE_MS (1)
    ) u_bad (
        .sys_clk          (clk),
        .btn_rst_n        (rst_n),
        .uart_rx          (rx_bad),
        .debug_boot_busy  (bad_busy),
        .debug_boot_ok    (bad_ok),
        .debug_boot_err   (bad_err)
    );

    /* ---------------- DUT 3：不发数据，走超时 ---------------- */
    logic        tmo_have, tmo_ena;
    logic [31:0] tmo_pc, tmo_val;
    logic [ 4:0] tmo_reg;
    logic        tmo_busy, tmo_ok, tmo_err;

    board_top #(
        .IROM_BOOT   (1),
        .IROM_INIT   ("sim/prog_boot_tmo.hex"),
        .BOOT_TMO_MS (1),
        .BOOT_GAP_MS (5),
        .IROM_WORDS  (64),
        .DRAM_WORDS  (64)
    ) u_tmo (
        .sys_clk          (clk),
        .btn_rst_n        (rst_n),
        .uart_rx          (rx_tmo),
        .debug_wb_have_inst (tmo_have),
        .debug_wb_pc        (tmo_pc),
        .debug_wb_ena       (tmo_ena),
        .debug_wb_reg       (tmo_reg),
        .debug_wb_value     (tmo_val),
        .debug_boot_busy    (tmo_busy),
        .debug_boot_ok      (tmo_ok),
        .debug_boot_err     (tmo_err)
    );

    /* ---------------- UART 发送（LSB first，8N1） ---------------- */
    task automatic uart_tx(input integer ch, input logic [7:0] b);
        integer k;
        begin
            case (ch)
                0: rx_ok  = 1'b0;
                1: rx_bad = 1'b0;
                default: rx_tmo = 1'b0;
            endcase
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                case (ch)
                    0: rx_ok  = b[k];
                    1: rx_bad = b[k];
                    default: rx_tmo = b[k];
                endcase
                #(BIT_NS);
            end
            case (ch)
                0: rx_ok  = 1'b1;
                1: rx_bad = 1'b1;
                default: rx_tmo = 1'b1;
            endcase
            #(BIT_NS);
        end
    endtask

    task automatic send_word(input integer ch, input logic [31:0] w);
        begin
            uart_tx(ch, w[31:24]);
            uart_tx(ch, w[23:16]);
            uart_tx(ch, w[15:8]);
            uart_tx(ch, w[7:0]);
        end
    endtask

    /* ---------------- 镜像 ---------------- */
    // addi x10, x0, 42  /  addi x11, x0, 99  /  jal x0,0  /  nop
    logic [31:0] img [0:3];
    logic [31:0] cks;
    integer nw;

    task automatic send_image(input integer ch, input integer n, input logic [31:0] cksum);
        integer i;
        begin
            #(GAP_NS);                            // ★ 帧首静默
            uart_tx(ch, 8'h42);                  // magic 'B' = IROM 帧
            send_word(ch, n);                    // 字数（大端）
            for (i = 0; i < n; i = i + 1) send_word(ch, img[i]);
            send_word(ch, cksum);                // 校验和（大端）
        end
    endtask

    /* ★ v13：DRAM 帧（'C'）。只发 1 个字，用来验证"数据镜像被装到基址 0x1_0000
     *   （字偏移 0x4000）"这条约定 —— 装错位置的话 CPU 一条数据都读不到。 */
    localparam logic [31:0] DRAM_MAGIC_WORD = 32'hDEAD_BEEF;
    task automatic send_dram_frame(input integer ch);
        begin
            #(GAP_NS);                            // ★ 帧首静默
            uart_tx(ch, 8'h43);                  // magic 'C' = DRAM 帧
            send_word(ch, 32'd1);                // 1 个字
            send_word(ch, DRAM_MAGIC_WORD);
            send_word(ch, DRAM_MAGIC_WORD);      // 校验和 = 唯一的那个字
        end
    endtask

    task automatic send_go(input integer ch);
        begin
            #(GAP_NS);                            // ★ 帧首静默（GO 也算一个命令）
            uart_tx(ch, 8'h47);                  // magic 'G' = GO
        end
    endtask

    /* ---------------- 写回观测 ---------------- */
    logic ok_got_x10, ok_got_x11, tmo_got_x1, tmo_got_x2;
    logic [31:0] ok_wb_cnt, tmo_wb_cnt;

    always @(negedge clk) begin
        if (rst_n && ok_have && ok_ena) begin
            ok_wb_cnt <= ok_wb_cnt + 32'd1;
            if (ok_reg == 5'd10 && ok_val == 32'd42) ok_got_x10 <= 1'b1;
            if (ok_reg == 5'd11 && ok_val == 32'd99) ok_got_x11 <= 1'b1;
        end
        if (rst_n && tmo_have && tmo_ena) begin
            tmo_wb_cnt <= tmo_wb_cnt + 32'd1;
            if (tmo_reg == 5'd1 && tmo_val == 32'd1) tmo_got_x1 <= 1'b1;
            if (tmo_reg == 5'd2 && tmo_val == 32'd2) tmo_got_x2 <= 1'b1;
        end
    end

    /* ---------------- 主流程 ---------------- */
    integer i;
    initial begin
        ok_got_x10 = 0; ok_got_x11 = 0; tmo_got_x1 = 0; tmo_got_x2 = 0;
        ok_wb_cnt = 0; tmo_wb_cnt = 0;

        img[0] = 32'h02a00513;   // addi x10, x0, 42
        img[1] = 32'h06300593;   // addi x11, x0, 99
        img[2] = 32'h0000006f;   // jal x0, 0
        img[3] = 32'h00000013;   // nop
        nw = 4;
        cks = img[0] + img[1] + img[2] + img[3];

        // 复位 200ns，释放后 DUT 进入引导窗口（1ms）
        #200 rst_n = 1'b1;

        // ★ 两路**并行**发送：一帧 33 字节在 115200 下要 2.86 ms，串行发的话
        //   第二个 DUT 的 magic 会晚于它自己的 1 ms 超时窗口（第一版就是这么错的：
        //   把 33*86.8us 算成了 286us，实际是 2.86ms）。
        fork
            begin
                // u_bad：校验和故意加 1，期望它报错且**不**能卡住 busy
                send_image(1, nw, cks + 32'd1);
                send_go(1);
            end
            begin
                // u_ok：IROM 帧 + DRAM 帧 + GO（完整会话，和宿主脚本一致）
                send_image(0, nw, cks);
                send_dram_frame(0);
                send_go(0);
            end
        join

        // 等两个"要么成功要么超时"的 DUT 都定下来，再给 CPU 跑一会儿
        #1_000_000;

        // ---------------- 报告 ----------------
        $display("================ BOOT SIM RESULT ================");
        $display(" u_ok : busy=%0b ok=%0b err=%0b  x10=%0b x11=%0b  wb_cnt=%0d",
                 ok_busy, ok_ok, ok_err, ok_got_x10, ok_got_x11, ok_wb_cnt);
        $display(" u_bad: busy=%0b ok=%0b err=%0b", bad_busy, bad_ok, bad_err);
        $display(" u_tmo: busy=%0b ok=%0b err=%0b  x1=%0b x2=%0b  wb_cnt=%0d",
                 tmo_busy, tmo_ok, tmo_err, tmo_got_x1, tmo_got_x2, tmo_wb_cnt);
        // ★ DRAM 帧落地检查：数据必须出现在基址 0x1_0000（字偏移 0x4000），
        //   且**不能**出现在字 0（那是低 64KB 空洞）。
        $display(" u_ok : dram[0x4000]=%h  dram[0]=%h  (期望 DEADBEEF / 00000000)",
                 u_ok.dram_inst.mem_ram[32'h4000], u_ok.dram_inst.mem_ram[0]);
        $display("-------------------------------------------------");

        if (!ok_ok)        $display(" FAIL: u_ok 没有校验通过（boot_ok=0）");
        if (!ok_got_x10)   $display(" FAIL: u_ok 没跑到新程序的 addi x10,42");
        if (!ok_got_x11)   $display(" FAIL: u_ok 没跑到新程序的 addi x11,99");
        if (u_ok.dram_inst.mem_ram[32'h4000] !== DRAM_MAGIC_WORD)
            $display(" FAIL: DRAM 帧没有落到基址 0x1_0000（字偏移 0x4000）");
        if (u_ok.dram_inst.mem_ram[0] !== 32'h0)
            $display(" FAIL: DRAM 帧错误地写了字 0（低 64KB 空洞）");
        if (ok_busy)       $display(" FAIL: u_ok 成功后 busy 没有释放");
        if (bad_ok)        $display(" FAIL: u_bad 校验和错却报了 ok=1");
        if (!bad_err)      $display(" FAIL: u_bad 没有报错（err=0）");
        if (bad_busy)      $display(" FAIL: u_bad 失败后 busy 没有释放（会被永久按在复位）");
        if (!tmo_busy==0)  $display(" FAIL: u_tmo 超时后 busy 没有释放");
        if (!tmo_got_x1)   $display(" FAIL: u_tmo 超时后没跑 IROM 里的旧程序（x1=1）");
        if (!tmo_got_x2)   $display(" FAIL: u_tmo 超时后没跑 IROM 里的旧程序（x2=2）");

        if (ok_ok && ok_got_x10 && ok_got_x11 && !ok_busy &&
            !bad_ok && bad_err && !bad_busy &&
            !tmo_busy && tmo_got_x1 && tmo_got_x2)
            $display(" BOOT SIM: ALL PASS");
        else
            $display(" BOOT SIM: FAIL");
        $display("=================================================");
        $finish;
    end

endmodule
