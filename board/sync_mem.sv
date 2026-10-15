`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * sync_mem.sv — 可综合的同步 BRAM 模型（IROM / DRAM 共用）
 * -----------------------------------------------------------------------------
 * 为什么需要它：v9 原来假设「零延迟组合读」（assign 直读数组），仿真能过，但 FPGA 的
 *   Block RAM 是**同步读**（地址打一拍、数据下一拍才出），本模块给出与 BRAM 一致的模型。
 *
 * ★ 接口契约（全设计的核心契约，ICache/DCache 都按它写 —— 改前先读 DCache.sv）：
 *   - 读：请求**那一拍**给 addr 且 ren=1，下一拍（T+1）rdata 才有效（= mem[addr(T)]）。
 *     rdata 挂在寄存器上，ren=0 时保持上一次的值（「读使能无效」语义）；上层必须自己
 *     在有效的那一拍采样（ICache/DCache 的 cpu_valid_r 就是干这个的）。
 *   - 写：T 拍给 addr/wdata/mask 且 wen=1 同步写入。wen 是**单拍脉冲**，没有握手、没有
 *     ready —— 多给一拍就是多写一次。
 *   - 同拍读写同一地址：读口返回**旧值**（BRAM 常见语义，写优先不影响读回填）。
 *   - reset 只清 rdata 寄存器，**不清存储器阵列**：真实 BRAM 的存储内容不会因为复位被
 *     清空；IROM 由 initial/$readmemh 固化，DRAM 上电后由程序自己初始化（所以 board_top
 *     里 dram_inst 的 .reset 直接接 1'b0）。
 *   综合属性：IROM 用 (* rom_style = "block" *)、DRAM 用 (* ram_style = "block" *)，
 *     提示映射成 BRAM；对 iverilog 是透明注释，不影响仿真。
 * =========================================================================== */
module sync_mem #(
    // 字数（地址位宽 = $clog2(WORDS)），默认 4096 字 = 16KB
    parameter WORDS = 4096,
    // 1 = 只读（IROM），0 = 读写（DRAM）
    parameter READ_ONLY = 0,
    // 存储器初值文件（空字符串表示不加载，由外部 $readmemh/initial 负责）
    parameter INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        reset,

    input  logic [31:0] addr,
    input  logic        ren,
    output logic [31:0] rdata,

    input  logic        wen,
    input  logic [31:0] wdata,
    input  logic [ 1:0] mask
);

    localparam ADDR_BITS = $clog2(WORDS);
    // 初始化循环上限（原 v9 修复的踩坑点）：Quartus 对 initial/for 的循环次数有硬上限
    //   （默认 5000，**不是** QSF 设置项），DRAM 默认 16384 字直接踩线，报 "loop must
    //   terminate within 5000 iterations" → 整个 board_top 无法综合。真实 BRAM 上电内容
    //   本是 undefined，这段清零只为给 4 态仿真一个确定初值，故把**被清零的字数**限制到
    //   ≤4096（仿真里初值由测试台 $readmemh 决定，语义不变）；别改用 break/return 之类
    //   写法（Quartus 对非常规循环控制支持更差）。报错原文：syn/修复史_全量.md §SYNCMEM-1
    localparam INIT_WORDS = (WORDS < 4096) ? WORDS : 4096;

    (* rom_style = "block" *) logic [31:0] mem_rom [0:WORDS-1];
    (* ram_style = "block" *) logic [31:0] mem_ram [0:WORDS-1];

    // ★ 不变量：字地址口径固定为 addr[ADDR_BITS+1:2]（低 2 位是字内偏移，不参与字选择）。
    //   board_top 里 IROM 用 irom_addr[13:2]、DRAM 用 perip_addr[15:2]，两套独立译码。
    logic [ADDR_BITS-1:0] word_addr;
    assign word_addr = addr[ADDR_BITS+1:2];

    // 字节/半字在字内的偏移（address[1:0]），字节写靠它选字节通道。
    logic [1:0] byte_offset;
    assign byte_offset = addr[1:0];

    // 按字节掩码把写数据挪到字内对齐位置，再交给下面的写分支：mask=2'b00 只保留 1 字节
    //   （wdata[7:0]，落点由 byte_offset 决定）；2'b01 保留 2 字节（wdata[15:0]，落点由
    //   byte_offset[1] 决定）；2'b1x（default）整字 4 字节，不看 addr[1:0] —— 非对齐的字
    //   访问在 CPU 侧已经被判成异常，到不了这里。
    logic [31:0] wdata_merge;
    always_comb begin
        case (mask)
            2'b00:   wdata_merge = {24'b0, wdata[7:0]};
            2'b01:   wdata_merge = {16'b0,  wdata[15:0]};
            default: wdata_merge = wdata;
        endcase
    end

    generate
        if (READ_ONLY) begin : g_rom
            // ---- IROM：只读同步 BRAM ----
            integer i;
            initial begin
                for (i = 0; i < INIT_WORDS; i = i + 1) mem_rom[i] = 32'h0000_0000;
                if (INIT_FILE != "") $readmemh(INIT_FILE, mem_rom);
            end

            // ★ 不变量：读=「请求一拍、数据下一拍」：ren 那拍给地址，rdata 到下一个时钟沿才
            //   更新、ren=0 时保持旧值，上层自己负责采样时机。
            // ★ 不变量：reset 只清 rdata，不清 ROM 阵列（清阵列会毁掉固化进去的程序）。
            always_ff @(posedge clk) begin
                if (reset) rdata <= 32'b0;
                else if (ren) rdata <= mem_rom[word_addr];
            end
        end else begin : g_ram
            // ---- DRAM：读写同步 BRAM，按 mask 做字节写 ----
            integer j;
            initial begin
                for (j = 0; j < INIT_WORDS; j = j + 1) mem_ram[j] = 32'h0000_0000;
                if (INIT_FILE != "") $readmemh(INIT_FILE, mem_ram);
            end

            // ★ 不变量：写是**单拍脉冲 + 按 mask 做字节写**：wen 为高那一拍才写，写哪几个
            //   字节由 mask/byte_offset 决定（1/2/4 字节三种宽度）。
            // ★ 不变量：同拍读写同址时读口返回**旧值**（DCache 的回填逻辑依赖这一点）。
            // ★ 不变量：reset 只清 rdata，DRAM 阵列上电后由程序自己初始化，不被复位清空。
            always_ff @(posedge clk) begin
                if (reset) begin
                    rdata <= 32'b0;
                end else begin
                    if (ren) rdata <= mem_ram[word_addr];
                    if (wen) begin
                        case (mask)
                            2'b00: begin
                                case (byte_offset)
                                    2'b00: mem_ram[word_addr][7:0]   <= wdata_merge[7:0];
                                    2'b01: mem_ram[word_addr][15:8]  <= wdata_merge[7:0];
                                    2'b10: mem_ram[word_addr][23:16] <= wdata_merge[7:0];
                                    default: mem_ram[word_addr][31:24] <= wdata_merge[7:0];
                                endcase
                            end
                            2'b01: begin
                                if (byte_offset[1] == 1'b0) mem_ram[word_addr][15:0]  <= wdata_merge[15:0];
                                else                        mem_ram[word_addr][31:16] <= wdata_merge[15:0];
                            end
                            default: mem_ram[word_addr] <= wdata_merge;
                        endcase
                    end
                end
            end
        end
    endgenerate

endmodule
