// 通用符号扩展模块，负责把 load/立即数等较窄数据扩成目标位宽。
// 纯组合、无时钟：sext_data = {{(OUT_WIDTH-DATA_WIDTH){data[DATA_WIDTH-1]}},data}，高 (OUT_WIDTH-DATA_WIDTH) 位用复制运算符铺满 data 的最高位（符号位），低 DATA_WIDTH 位原样搬运；两个参数在例化点确定，所以每个实例各生成一份固定位宽的连线，没有运行期 mux。★ 不变量：OUT_WIDTH >= DATA_WIDTH >= 1（否则复制次数为负/位选越界）。
// 被谁例化：LSU.sv 4 个实例（reg 级 sext_i8/sext_i16、reg2 级 sext_i8_2/sext_i16_2，即 lb/lh 的符号扩展；lbu/lhu 不走本模块，直接高位补 0）、WBU.sv 2 个实例（写回级 sext_i8/sext_i16 —— 写回值才是最终值，只修 LSU 不改 WBU，写回值仍然是错的，见 WBU-1）。
// 端口/参数名 data / sext_data / DATA_WIDTH / OUT_WIDTH 不要改：所有例化点都用命名端口 + 命名参数，改名会静默断开连接（端口不匹配不一定报错）。
module sext#
(
    parameter DATA_WIDTH=1,
    parameter OUT_WIDTH=2
)
(
    input [DATA_WIDTH-1:0]data,
    output [OUT_WIDTH-1:0]sext_data
);

assign sext_data = {{(OUT_WIDTH-DATA_WIDTH){data[DATA_WIDTH-1]}},data};



// 例化点前那句 `verilator lint_off PINMISSING` 是构建期告警抑制，与本模块的端口定义无关，别顺手去改例化处的端口连接。
endmodule
