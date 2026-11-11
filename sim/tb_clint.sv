`timescale 1ns / 1ps
/* =============================================================================
 * tb_clint.sv — A3 判据：CLINT 是**唯一**的 mtime/mtimecmp 计数源
 * -----------------------------------------------------------------------------
 * 跑 sw/build/clinttest_irom.hex（`bash sw/build_simple.sh sw/clinttest.c clinttest`）。
 *
 * 判据：
 *   ① 串口收到 "OK\n"
 *   ② led == 0x7F（七条检查全过）：
 *        bit0 csrw mtime,0 → lw 0x30 读到 0
 *        bit1 隔一段再读，值变大
 *        bit2 CSR 写 → 总线读（0xABCD_0000）
 *        bit3 总线写 → CSR 读（0x1357_0000）
 *        bit4 mtimecmp 双向（0x1234_5678）
 *        bit5 一次定时器中断（mie.MTIE + mtimecmp）
 *        bit6 高半字恒 0（0x34 / 0x3C）
 * ============================================================================= */
module tb_clint;

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
        .IROM_INIT ("sw/build/clinttest_irom.hex")
    ) u_board (
        .sys_clk   (clk),
        .btn_rst_n (rst_n),
        .uart_rx   (1'b1),
        .uart_tx   (uart_tx),
        .led       (led)
    );

    /* --------------------------- UART 接收模型 ----------------------------- */
    localparam integer BIT = 434;
    integer  st = 0, cnt = 0, nbit = 0;
    logic [7:0] sh = 8'h00, rx_byte = 8'h00;
    logic       rx_valid = 1'b0;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        if (!rst_n) begin
            st <= 0; cnt <= 0; nbit <= 0;
        end else begin
            case (st)
                0: if (!uart_tx) begin st <= 1; cnt <= 0; nbit <= 0; end
                1: if (cnt == (BIT / 2 - 1)) begin st <= 2; cnt <= 0; end
                   else                       cnt <= cnt + 1;
                2: if (cnt == (BIT - 1)) begin
                       cnt <= 0;
                       sh[nbit] <= uart_tx;
                       if (nbit == 7) st <= 3;
                       else           nbit <= nbit + 1;
                   end else cnt <= cnt + 1;
                3: begin rx_byte <= sh; rx_valid <= 1'b1; st <= 4; cnt <= 0; end
                4: begin
                       if (!uart_tx)      cnt <= 0;
                       else if (cnt == (BIT / 2)) begin st <= 0; cnt <= 0; end
                       else               cnt <= cnt + 1;
                   end
                default: st <= 0;
            endcase
        end
    end

    logic [7:0] got [0:7];
    integer nrecv = 0;
    always @(posedge clk) begin
        if (rx_valid && nrecv < 8) begin
            got[nrecv] <= rx_byte;
            nrecv      <= nrecv + 1;
            $display("[CLINT-TEST] uart byte %0d = 0x%02x", nrecv, rx_byte);
        end
    end

    /* ------------------------------ 判据 ---------------------------------- */
    integer cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;

    integer npass = 0, nfail = 0;
    task automatic chk(input bit cond, input string name);
        begin
            if (cond) begin npass = npass + 1; $display("[CLINT-TEST]   [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("[CLINT-TEST]   [FAIL] %0s", name); end
        end
    endtask

    initial begin
        wait ((nrecv >= 2) || (cycles > 2_000_000));
        #2000;

        $display("[CLINT-TEST] led=0x%02x nrecv=%0d mtime=%h mtimecmp=%h",
                 led, nrecv, u_board.clint_mtime, u_board.clint_mtimecmp);

        chk(led == 7'h7F,                                             "all 7 CLINT checks (CSR <-> MMIO single source)");
        chk((nrecv == 2) && (got[0] == 8'h4F) && (got[1] == 8'h4B),    "printed OK");
        chk((led & 7'h04) != 0,                                       "csrw mtime -> lw 0x30 same value");
        chk((led & 7'h08) != 0,                                       "sw 0x30 -> csrr mtime same value");
        chk((led & 7'h20) != 0,                                       "timer interrupt fired once (MTI)");

        if (nfail == 0) $display("[CLINT-TEST] PASS  (%0d/%0d)", npass, npass + nfail);
        else            $display("[CLINT-TEST] FAIL  (%0d failed)", nfail);
        $display("[CLINT-TEST-SELFCHECK] status=%s", (nfail == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
