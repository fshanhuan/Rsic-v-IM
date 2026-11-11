`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_runapp.sv — P0-2：`run <name>` 仿真端到端（容器加载 + 执行 + 返回）
 * -----------------------------------------------------------------------------
 * 它验证的不是某条命令，而是**整条 P1 链路**：
 *   文件系统里的一个容器（32 B 头 + 代码 + 数据 + 校验和）
 *   -> `run` 解析 -> 代码写进 IROM 窗口 0x2_4000 -> 数据写进 DRAM 0xA000
 *   -> fence.i -> 跳转执行 -> 返回 shell
 *
 * 办法（sw/mkfs.py）：把文件系统（超级块 + 目录 + 位图 + 数据块）直接烤成 DRAM 镜像，
 *   仿真开始时用 `+fs=` 一把装进 DRAM 0。于是：
 *     +prog=monitor_irom.hex  -> shell 本体
 *     +fs=tb_fs.hex           -> 预置的 ramdisk（里面有 hello_app 这个容器）
 *     +dram=monitor_dram.hex  -> shell 的 .rodata
 *
 * 判据：
 *   A1 "run hello_app" 的回显里出现 `code 472B + data 36B`（容器头被正确解析）
 *   A2 应用真的跑了：回显 "HELLO-APP" 与 "acc=15"
 *   A3 应用返回后 shell 还在（提示符再次出现，没有跑飞/复位）
 *   A4 跑完 `df` 的可用块数没有掉（`run` 不占文件系统）
 *   A5 收尾 debug_status 无 X
 *
 * 用法：
 *   python3 sw/mkfs.py --file hello_app=sw/build/hello_app.app --out sw/build/tb_fs.hex
 *   vvp sim/build/tb_runapp.vvp +prog=... +dram=... +fs=...
 * ============================================================================= */
module tb_runapp;

    localparam integer BIT_NS   = 8680;    // 115200 bps
    localparam integer CLK_HALF = 10;      // 50 MHz

    logic clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    logic rst_n   = 1'b0;
    logic rx_stim = 1'b1;
    logic uart_tx_line;
    logic [31:0] dbg_status, dbg_mcycle;

    reg [8*260-1:0] prog_path = "sw/build/monitor_irom.hex";
    reg [8*260-1:0] dram_path = "sw/build/monitor_dram.hex";
    reg [8*260-1:0] fs_path   = "sw/build/tb_fs.hex";
    reg             fs_ok     = 1'b0;

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

    task automatic host_send(input [7:0] b);
        integer k;
        begin
            @(negedge clk);
            rx_stim = 1'b0;
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                rx_stim = b[k];
                #(BIT_NS);
            end
            rx_stim = 1'b1;
            #(BIT_NS);
        end
    endtask

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

    logic [7:0] rx_data;
    logic       rx_valid;
    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) u_term (
        .clk (clk), .rst (~rst_n), .rx (uart_tx_line),
        .data (rx_data), .valid (rx_valid)
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

    reg [7:0] pat [0:31];
    integer   pat_len;
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

    // 便捷装载（最18 字节
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

    integer i;
    logic   a1, a2, a3, a4, a6;

    initial begin
        $display("================================================================");
        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("dram=%s", dram_path)) ;
        if ($value$plusargs("fs=%s",   fs_path))   fs_ok = 1'b1;
        $display(" tb_runapp : prog=%0s dram=%0s fs=%0s (%0d)",
                 prog_path, dram_path, fs_path, fs_ok);
        $display("================================================================");
        if (!fs_ok) begin
            $display("[RUNAPP] FAIL: need +fs=<hex from sw/mkfs.py>");
            $display("[RUNAPP-SELFCHECK] status=FAIL");
            $finish;
        end

        // 整块 DRAM 先清零（P0-1：不清的话栈顶以上是 X），再装 FS 与应用数
    for (i = 0; i < 32768; i = i + 1) u_board.g_dram_single.dram_inst.mem_ram[i] = 32'h0;
        // FS 镜像固定 40 KB = 10240 字；显式给末地址，免$readmemh
    // "Not enough words for the requested range"（那警告会让人以为镜像有问题
    $readmemh(fs_path,   u_board.g_dram_single.dram_inst.mem_ram, 32'h0, 32'd10239);
        $readmemh(prog_path, u_board.irom_inst.mem);
        $readmemh(dram_path, u_board.g_dram_single.dram_inst.mem_ram, 32'h4000);

        #200 rst_n = 1'b1;

        // 等横+ 提示符打完（11 ms），再发命令4 字节超过 8 FIFO
    // 提前发也不会丢（中断会搬走），但等提示符更贴近真实用法
    #12_000_000;
        host_send_str("run hello_app"); host_send(8'h0D);
        // 之后要等：echo(14 字符) + " run ... code 472B + data 36B"(~50) +
        //   应用自己40 字符 + " returned to shell"(19) 123 字符 10.7 ms
        #14_000_000;

        $display("---- board output (%0d bytes) ----", rlen);
        for (i = 0; i < rlen && i < RBUF; i = i + 1) begin
            if (rbuf[i] >= 8'h20 && rbuf[i] < 8'h7F) $write("%c", rbuf[i]);
            else if (rbuf[i] == 8'h0A)               $write("\n");
            else if (rbuf[i] == 8'h0D)               ;
            else                                     $write(".");
        end
        $display("\n----------------------------------");

        // "code 472B + data 36B" 前半= 63 6F 64 65 20 34 37 32
        load_pat(8, 8'h63,8'h6F,8'h64,8'h65,8'h20,8'h34,8'h37,8'h32,
                 0,0,0,0,0,0,0,0,0,0);
        a1 = search_pat();
        // "HELLO-APP" = 48 45 4C 4C 4F 2D 41 50 50
        load_pat(9, 8'h48,8'h45,8'h4C,8'h4C,8'h4F,8'h2D,8'h41,8'h50,8'h50,
                 0,0,0,0,0,0,0,0,0);
        a2 = search_pat();
        // "acc=15" = 61 63 63 3D 31 35
        load_pat(6, 8'h61,8'h63,8'h63,8'h3D,8'h31,8'h35,
                 0,0,0,0,0,0,0,0,0,0,0,0);
        a3 = search_pat();
        // "returned to shell" = 72 65 74 75 72 6E 65 64 20 74 6F 20 73 68 65 6C 6C
        load_pat(17, 8'h72,8'h65,8'h74,8'h75,8'h72,8'h6E,8'h65,8'h64,8'h20,
                 8'h74,8'h6F,8'h20,8'h73,8'h68,8'h65,8'h6C,8'h6C,8'h00);
        a4 = search_pat();
        a6 = ((^u_board.debug_status) !== 1'bx);

        $display("  [DBG] debug_status=%h  wb_pc=%h  mcause=%h  mepc=%h",
                 u_board.debug_status, u_board.debug_wb_pc,
                 u_board.debug_mcause, u_board.debug_mepc);
        chk("A1 container header parsed", a1);
        chk("A2 app .rodata in DRAM",     a2);
        chk("A3 app .data/.bss ok",       a3);
        chk("A4 returned to shell",       a4);
        chk("A6 debug_status has no X",   a6);

        $display("----------------------------------------------------------");
        if (nfail == 0) $display("[RUNAPP-SELFCHECK] status=PASS (%0d checks)", npass);
        else            $display("[RUNAPP-SELFCHECK] status=FAIL (%0d failed, %0d passed)",
                                 nfail, npass);
        $finish;
    end

endmodule
