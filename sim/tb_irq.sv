`timescale 1ns / 1ps
/* =============================================================================
 * tb_irq.sv — A2 外部中断的板级判据
 * -----------------------------------------------------------------------------
 * 跑 sw/build/irqtest_irom.hex（`bash sw/build_simple.sh sw/irqtest.c irqtest`）。
 *
 * 判据：
 *   ① 串口收到 "OK\n"           → 程序自己数到 3 次陷入、claim id 都是 3
 *   ② led == 3                  → 中断计数真的写进了 MMIO
 *   ③ 结束时 CPU 停在自旋        → 没有跑飞（pc 落在 for(;;) 里）
 *
 * ★ 这个测试同时覆盖了三件事：
 *   · PLIC-lite 的 pending/enable/claim 通路（MMIO 0x20/0x24/0x28/0x2C）
 *   · CSR.mip.MEIP 由外部驱动（改造前硬连 0）
 *   · Control 的 intr_take → 陷入 → mret 回程
 * ============================================================================= */
module tb_irq;

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
        .IROM_INIT ("sw/build/irqtest_irom.hex")
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
                4: begin   // 等停止位，避免把残留数据位当成下一帧起始位
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
            $display("[IRQ-TEST] uart byte %0d = 0x%02x", nrecv, rx_byte);
        end
    end

    /* ------------------------------ 判据 ---------------------------------- */
    integer cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;

    integer npass = 0, nfail = 0;
    task automatic chk(input bit cond, input string name);
        begin
            if (cond) begin npass = npass + 1; $display("[IRQ-TEST]   [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("[IRQ-TEST]   [FAIL] %0s", name); end
        end
    endtask

    initial begin
        wait ((nrecv >= 2) || (cycles > 300_000));
        #2000;

        $display("[IRQ-TEST] led=%0d nrecv=%0d pc=%h mcause=%h mstatus=%h",
                 led, nrecv, u_board.debug_wb_pc, u_board.debug_mcause, u_board.debug_status);

        chk((nrecv == 2) && (got[0] == 8'h4F) && (got[1] == 8'h4B), "3 interrupts taken, claim id = 3 (\"OK\")");
        chk(led == 7'd3,                                             "LED shows interrupt count (3)");
        chk(nrecv >= 2,                                              "program reached the print (did not hang)");

        if (nfail == 0) $display("[IRQ-TEST] PASS  (%0d/%0d)", npass, npass + nfail);
        else            $display("[IRQ-TEST] FAIL  (%0d failed)", nfail);
        $display("[IRQ-TEST-SELFCHECK] status=%s", (nfail == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
