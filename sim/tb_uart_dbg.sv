`timescale 1ns / 1ps
// 最小 UART RX 验证：只关心"字节能不能收到"，不涉及 CPU/BRAM。
module tb_uart_dbg;
    localparam integer BIT_NS = 8680;

    logic clk = 0;
    always #10 clk = ~clk;          // 50 MHz

    logic rst_n = 0;
    logic rx = 1;
    logic [7:0] d;
    logic       v;

    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) dut (
        .clk (clk),
        .rst (~rst_n),
        .rx  (rx),
        .data(d),
        .valid(v)
    );

    task automatic uart_tx(input logic [7:0] b);
        integer k;
        begin
            rx = 1'b0; #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                rx = b[k];
                #(BIT_NS);
            end
            rx = 1'b1;
            #(BIT_NS);
        end
    endtask

    integer n = 0;
    always @(posedge clk) begin
        if (v) begin
            n = n + 1;
            $display("  [%0t ns] BYTE %02x", $time, d);
        end
    end

    initial begin
        #200 rst_n = 1'b1;
        #2000;
        $display("--- send 0x42 0xA5 0x00 0xFF ---");
        uart_tx(8'h42);
        uart_tx(8'hA5);
        uart_tx(8'h00);
        uart_tx(8'hff);
        #20000;
        $display("RESULT bytes_received = %0d / 4", n);
        $finish;
    end
endmodule
