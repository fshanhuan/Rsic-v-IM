// tb_mdu.sv —— MDU_pipelined 的乘/除实测：几拍出结果、边界语义对不对
// 只看 MDU 一个模块（不跑整机），50 MHz（20 ns），与板上 clk_sys 同周期。
`timescale 1ns / 1ps

module tb_mdu;
    localparam real TCLK_NS = 20.0;

    logic        clk = 0, reset = 1, start = 0;
    logic [31:0] d1 = 0, d2 = 0, res;
    logic [ 4:0] op = 0;
    logic        busy, done;

    always #(TCLK_NS / 2.0) clk = ~clk;

    MDU_pipelined u_mdu (
        .clk(clk), .reset(reset), .start(start), .d1(d1), .d2(d2), .op(op),
        .res(res), .busy(busy), .done(done)
    );

    // op 编码（para.sv §ALU 编码）：op[4]=1 才是 M；op[2]=0 乘 / 1 除；op[1:0] 选具体操作
    localparam [4:0] OP_MUL = 5'b10000, OP_MULH = 5'b10001, OP_MULHSU = 5'b10010, OP_MULHU = 5'b10011;
    localparam [4:0] OP_DIV = 5'b10100, OP_DIVU = 5'b10101, OP_REM = 5'b10110, OP_REMU = 5'b10111;

    int busy_cycles = 0, wait_cycles = 0;
    logic [31:0] got = 0;

    // 发一条 M 指令：start 一拍脉冲，然后数到 done
    task automatic run(input [31:0] a, input [31:0] b, input [4:0] o);
        begin
            // 上一次的 done（乘法的 mul_stb）可能还挂着，先等它落下去
            while (done) @(negedge clk);
            @(negedge clk);
            d1 = a; d2 = b; op = o; start = 1;
            busy_cycles = 0; wait_cycles = 0;
            @(negedge clk);
            start = 0;
            // 从 start 那拍起逐拍采样，数到 done 那一拍（done 只高 1 拍，结果同拍有效）
            while (!done && wait_cycles < 200) begin
                if (busy) busy_cycles++;
                @(negedge clk);
                wait_cycles++;
            end
            got = res;
        end
    endtask

    task automatic chk(input string nm, input [31:0] a, input [31:0] b,
                       input [4:0] o, input [31:0] want, input int want_busy);
        run(a, b, o);
        $display("%-24s a=%08x b=%08x op=%b -> res=%08x want=%08x %s | wait=%0d busy=%0d %s",
                 nm, a, b, o, got, want, (got === want) ? "PASS" : "FAIL",
                 wait_cycles, busy_cycles,
                 (busy_cycles == want_busy) ? "" : $sformatf("(busy 期望 %0d)", want_busy));
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        repeat (2) @(negedge clk);

        $display("================ MDU_pipelined 实测（50 MHz，1 拍 = 20 ns）================");
        chk("mul      3*5",        32'd3, 32'd5, OP_MUL, 32'd15, 0);
        chk("mulh  (-7)*3 >>32",   32'hFFFF_FFF9, 32'd3, OP_MULH, 32'hFFFF_FFFF, 0);
        chk("mulhu 0xFFFFFFFF^2",  32'hFFFF_FFFF, 32'hFFFF_FFFF, OP_MULHU, 32'hFFFF_FFFE, 0);
        chk("div   -1/10 (|a|<|b|)", 32'hFFFF_FFFF, 32'd10, OP_DIV, 32'd0, 0);
        chk("rem   -1%10",      32'hFFFF_FFFF, 32'd10, OP_REM, 32'hFFFF_FFFF, 0);
        chk("div   -7/2 (截断)", 32'hFFFF_FFF9, 32'd2, OP_DIV, 32'hFFFF_FFFD, 16);
        chk("rem   -7%2",          32'hFFFF_FFF9, 32'd2, OP_REM, 32'hFFFF_FFFF, 0); // 配对缓存命中
        chk("div   x/0",           32'h1234_5678, 32'd0, OP_DIV, 32'hFFFF_FFFF, 0);
        chk("rem   x%0",           32'h1234_5678, 32'd0, OP_REM, 32'h1234_5678, 0);
        chk("div   3/10 (|a|<|b|)",32'd3, 32'd10, OP_DIV, 32'd0, 0);
        chk("div   INT_MIN/-1",    32'h8000_0000, 32'hFFFF_FFFF, OP_DIV, 32'h8000_0000, 0);
        chk("divu  0xFFFFFFFF/10", 32'hFFFF_FFFF, 32'd10, OP_DIVU, 32'h1999_9999, 16);
        $display("==========================================================================");
        $finish;
    end
endmodule
