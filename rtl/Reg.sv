// Reg.sv — 参数化通用可写寄存器模板（WIDTH 位宽 / RESET_VAL 复位值）；复位优先于 wen。
// 用途：**单个**寄存器的模板（不是寄存器堆，堆见 RegisterFile.sv；核内当前没有例化点）。
// 例化：Reg #(.WIDTH(32), .RESET_VAL(32'h0)) u_x (.clock(clock), .reset(reset), .din(d), .dout(q), .wen(wen));
//   按位置传参顺序是 (WIDTH, RESET_VAL)；默认 WIDTH=1 / RESET_VAL=0。
// ★ 不变量：if (reset) 必须排在 else if (wen) 之前 —— RESET_VAL 是唯一初值来源。
module Reg #(WIDTH = 1, RESET_VAL = 0) (
    input               clock,
    input               reset,
    input      [WIDTH-1:0] din,
    output logic [WIDTH-1:0] dout,
    input               wen
);
always_ff @(posedge clock) begin
    if (reset) 
        dout <= RESET_VAL;
    else if (wen) 
        dout <= din;
end
endmodule
