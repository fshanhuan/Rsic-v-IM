`timescale 1ns / 1ps
/* =============================================================================
 * tb_prog.sv — 通用"跑一份 hex 程序、看 LED 判据"的板级 TB
 * -----------------------------------------------------------------------------
 * 为什么要通用版：S3/S4/S5 每加一个软件测试都要一个 TB，而它们的判据其实一样 ——
 *   "程序跑完把结果写进 LED，TB 看 LED"。以后加测试只写 .c + 用 +prog= 指过来即可。
 *
 * 用法：
 *   vvp sim/build/tb_prog.vvp +prog=sw/build/fstest_irom.hex [+pass=2a] [+timeout=2000000]
 *
 * 判据：`led` 等于 +pass（默认 0x2A）→ PASS；等于 0x7F → FAIL；超时 → FAIL。
 * 另外把 UART 输出原样打在日志里，方便人眼核对。
 * ============================================================================= */
module tb_prog;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        #200;
        rst_n = 1'b1;
    end

    logic       uart_tx;
    logic [6:0] led;

    board_top #(
        .IROM_INIT ("")                 // 镜像稍后+prog= 载入
    ) u_board (
        .sys_clk   (clk),
        .btn_rst_n (rst_n),
        .uart_rx   (1'b1),
        .uart_tx   (uart_tx),
        .led       (led)
    );

    /* --------------------------- 载入程序 ---------------------------------- */
    string prog_path;
    initial begin
        if (!$value$plusargs("prog=%s", prog_path)) prog_path = "sw/build/fstest_irom.hex";
        #1;
        $readmemh(prog_path, u_board.irom_inst.mem);
        $display("[PROG] loaded %0s", prog_path);
    end

    /* 必须能载 DRAM 镜像：`.rodata`（字符串常量）和 `.data` 都在 DRAM 0x1_0000。
     *   不装的话它们在仿真里是 **X** —— 表现是"字符串拷到一半就卡住"（实测踩过）。
     *   字偏移 0x4000 = 字节 0x1_0000 / 4。 */
    string dram_path;
    initial begin
        if ($value$plusargs("dram=%s", dram_path)) begin
            #1;
            $readmemh(dram_path, u_board.g_dram_single.dram_inst.mem_ram, 32'h4000);
            $display("[PROG] loaded %0s", dram_path);
        end
    end

    /* --------------------------- UART 打印（仅观察------------------------ */
    localparam integer BIT = 434;
    integer st = 0, cnt = 0, nbit = 0;
    logic [7:0] sh = 8'h00;

    always @(posedge clk) begin
        if (!rst_n) begin st <= 0; cnt <= 0; nbit <= 0; end
        else case (st)
            0: if (!uart_tx) begin st <= 1; cnt <= 0; nbit <= 0; end
            1: if (cnt == (BIT / 2 - 1)) begin st <= 2; cnt <= 0; end
               else                       cnt <= cnt + 1;
            2: if (cnt == (BIT - 1)) begin
                   cnt <= 0; sh[nbit] <= uart_tx;
                   if (nbit == 7) st <= 3; else nbit <= nbit + 1;
               end else cnt <= cnt + 1;
            3: begin
                   $write("%c", sh);
                   st <= 4; cnt <= 0;
               end
            4: begin
                   if (!uart_tx) cnt <= 0;
                   else if (cnt == (BIT / 2)) begin st <= 0; cnt <= 0; end
                   else cnt <= cnt + 1;
               end
            default: st <= 0;
        endcase
    end

    /* --------------------------- 判据 -------------------------------------- */
    integer cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;

    integer pass_val = 8'h2A;
    integer tmo      = 2_000_000;
    integer dummy;

    initial begin
        dummy = $value$plusargs("pass=%h", pass_val);
        dummy = $value$plusargs("timeout=%d", tmo);

        wait ((led == pass_val[6:0]) || (led == 7'h7F) || (cycles > tmo));
        #5000;

        if (led == pass_val[6:0])      $display("\n[PROG] PASS  (led=0x%02x, cycles=%0d)", led, cycles);
        else if (led == 7'h7F)         $display("\n[PROG] FAIL  (led=0x7F, cycles=%0d)", cycles);
        else                           $display("\n[PROG] TIMEOUT (led=0x%02x, cycles=%0d)", led, cycles);

        $display("[PROG-SELFCHECK] status=%s",
                 (led == pass_val[6:0]) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
