`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * sync_mem.sv — 可综合的同步 BRAM 模型（IROM / DRAM 共用）
 * -----------------------------------------------------------------------------
 * 为什么需要它：
 *   原来 v9 的存储器假设是「零延迟组合读」：
 *     - IROM  : assign irom_data = irom[addr[13:2]];
 *     - DRAM  : assign dram_raw  = dram[word_addr];   （组合读 + 上升沿写）
 *   仿真能过，但 FPGA 的 Block RAM 是**同步读**（地址打一拍、数据下一拍才出），
 *   真实存储器不可能同拍返回数据。本模块给出与 BRAM 时序一致的模型。
 *
 * 读时序（固定 1 拍延迟，带读使能）：
 *   T   : 给出 addr，且 ren=1
 *   T+1 : rdata 有效（= mem[addr(T)]）
 *   注意 rdata 挂在寄存器上，ren=0 时保持上一次的值，属于「读使能无效」语义；
 *   上层必须自己在有效的那一拍采样（ICache/DCache 的 cpu_valid_r 就是干这个的）。
 *
 * 写时序（同步写，按 mask 做字节写）：
 *   T   : 给出 addr/wdata/mask，且 wen=1
 *   T+1 : mem[addr] 的 mask 选中的字节被更新
 *   同拍读写同一地址时，读口返回**旧值**（BRAM 常见语义，写优先不影响读回填）。
 *
 * 复位策略（重要）：
 *   reset 只清 rdata 寄存器，**不清存储器内容**。真实 BRAM 的存储阵列不会因为
 *   复位被清空；IROM 由 initial/$readmemh 固化（Vivado 可综合 initial 到 BRAM
 *   初值），DRAM 上电后由程序自己初始化。
 *
 * 综合属性：
 *   - IROM 用 (* rom_style = "block" *) 提示映射成 BRAM；
 *   - DRAM 用 (* ram_style = "block" *) 提示映射成 BRAM。
 *   这些属性对 iverilog 是透明注释，不影响仿真。
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

    (* rom_style = "block" *) logic [31:0] mem_rom [0:WORDS-1];
    (* ram_style = "block" *) logic [31:0] mem_ram [0:WORDS-1];

    logic [ADDR_BITS-1:0] word_addr;
    assign word_addr = addr[ADDR_BITS+1:2];

    // 字节/半字在字内的偏移（address[1:0]），字节写靠它选字节通道。
    logic [1:0] byte_offset;
    assign byte_offset = addr[1:0];

    // 按字节掩码合并写数据：mask=00/01/10 分别写 1/2/4 字节。
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
                for (i = 0; i < WORDS; i = i + 1) mem_rom[i] = 32'h0000_0000;
                if (INIT_FILE != "") $readmemh(INIT_FILE, mem_rom);
            end

            always_ff @(posedge clk) begin
                if (reset) rdata <= 32'b0;
                else if (ren) rdata <= mem_rom[word_addr];
            end
        end else begin : g_ram
            // ---- DRAM：读写同步 BRAM，按 mask 做字节写 ----
            integer j;
            initial begin
                for (j = 0; j < WORDS; j = j + 1) mem_ram[j] = 32'h0000_0000;
                if (INIT_FILE != "") $readmemh(INIT_FILE, mem_ram);
            end

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
