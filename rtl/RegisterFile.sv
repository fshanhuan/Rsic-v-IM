`include "para.sv"
// RegisterFile.sv — 32×32 通用寄存器堆（两个组合读口 + 一个同步写口），由 Reg_Stack 例化。
// 读口当拍组合直读、写口在时钟沿生效；写口来自 WB 级，与读口隔 EXU/MEM/WB 三级流水（靠前递补）。
// ★ 参数陷阱：默认值 #(ADDR_WIDTH=32, DATA_WIDTH=5) 是反的；Reg_Stack 传 #(5,32) → ADDR_WIDTH=5、
//   DATA_WIDTH=32（5 位地址选 32 个 32 位寄存器），别照默认值去理解端口位宽。
// ★ 不变量：本寄存器堆没有复位 —— 上电初值由综合后的 BRAM/触发器初值决定（仿真里是 x，
//   FPGA 上是 0）。删掉下面的 reset 分支，4 态仿真下 rf[0]（x0）恒为 x，任何以 x0 为源操作数
//   的指令（连 NOP = addi x0,x0,0 都算）都会把 x 污染进 ALU→写回→整条数据通路；仿真侧靠
//   tb_iverilog 预置 rf[0:31]=0 或 RTL 复位兜住，两条路都指向"仿真里 x0 == 0"。§REGFILE-1
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

    integer i;
    always_ff @(posedge clock) begin
        if (reset) begin
            for (i = 0; i < 2**ADDR_WIDTH; i = i + 1)
                rf[i] <= {DATA_WIDTH{1'b0}};
        end else if (wen) begin
            rf[waddr] <= wdata;
        end
    end

    // a0_value 固定读 x10（ABI 的 a0），是给测试台/调试观察返回值的固定口。
    assign rs1_value = rf[rs1_addr];
    assign rs2_value = rf[rs2_addr];
    assign a0_value  = rf[10];

endmodule
