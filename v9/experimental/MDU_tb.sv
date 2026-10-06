// MDU_pipelined 的独立测试台顶层（配合 C++ 参考模型使用）
// 构建示例：
//   verilator --cc --exe --build -Wno-lint -Wno-style \
//     --top-module mdu_tb_top MDU_tb.sv MDU_pipelined.sv ../../para.sv main.cpp
`timescale 1ns / 1ps
module mdu_tb_top (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [31:0] d1,
    input  logic [31:0] d2,
    input  logic [ 4:0] op,
    output logic [31:0] res,
    output logic        busy,
    output logic        done
);
    MDU_pipelined dut (
        .clk(clk), .reset(rst), .start(start), .d1(d1), .d2(d2), .op(op),
        .res(res), .busy(busy), .done(done)
    );
endmodule
