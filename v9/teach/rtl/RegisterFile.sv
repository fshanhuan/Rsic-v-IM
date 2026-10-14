`include "para.sv"
// 通用整数寄存器堆：两个读口、一个写口。
// 这里保持最朴素的实现，便于教学时把注意力放在流水协同而不是寄存器堆优化上。
// v9 上板改造：补上复位分支（reset 已由 Reg_Stack 接好），保证 x0 恒为 0。
module RegisterFile #(ADDR_WIDTH = 32, DATA_WIDTH = 5) (
    input                          clock,
    input      [DATA_WIDTH-1:0]    wdata,
    input      [ADDR_WIDTH-1:0]    waddr,
    input                          wen,
    input                          reset,
    input      [ADDR_WIDTH-1:0]    rs1_addr,
    input      [ADDR_WIDTH-1:0]    rs2_addr,

    output     [DATA_WIDTH-1:0]    rs1_value,
    output     [DATA_WIDTH-1:0]    rs2_value,
    output     [DATA_WIDTH-1:0]    a0_value
);
    logic [DATA_WIDTH-1:0] rf [2**ADDR_WIDTH-1:0];

    // 写回在时钟上升沿生效，读口保持组合直读。
    // reset 必须真正清空整个寄存器堆：否则 4 态仿真下 rf[0]（x0）恒为 x，
    // 任何以 x0 为源操作数的指令都会把 x 传播到全通路；
    // 上板时 BRAM 上电虽通常为 0，但显式复位才能保证与仿真同语义。
    // （复位分支里给 i 赋 0，满足“for 条件必须用到索引”的可综合写法要求。）
    integer i;
    always_ff @(posedge clock) begin
        if (reset) begin
            for (i = 0; i < 2**ADDR_WIDTH; i = i + 1)
                rf[i] <= {DATA_WIDTH{1'b0}};
        end else if (wen) begin
            rf[waddr] <= wdata;
        end
    end

    assign rs1_value = rf[rs1_addr];
    assign rs2_value = rf[rs2_addr];
    assign a0_value  = rf[10];

endmodule
