`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * sync_mem_dp.sv — 双读口同步 BRAM 模型（IROM 专用：取指 + 数据窗口）
 * -----------------------------------------------------------------------------
 * 为什么需要它（v14）：本核是哈佛结构 —— 取指走 irom_*，访存走 perip_*。
 *   代码只能从 IROM 取，而 `lw` 读不到 IROM（读 IROM 地址实际查到的是 DRAM 数组，
 *   所以"烧进 IROM 的镜像"用 lw 读出来全是 0）。要给软件一条"读自己的代码/常量"的
 *   通路，最便宜的解法就是给 IROM 加**第二个读口**并映射到数据地址空间：
 *     · Xilinx BRAM36 本来就是两个独立端口，多用一口**不增加 BRAM 数量**
 *       （64KB 仍是 15 个 tile）；
 *     · 只多一级地址译码和一条数据 mux，不动流水线、不动 DCache；
 *     · 端口 A = 取指（只读），端口 B = CPU 数据读 **或** 引导器写（互斥：引导期间
 *       CPU 被 cpu_rst_eff 按住，永远不会同时来）。
 *   ⇒ 2R1W 恰好落在一个真双口 BRAM 的模板上（A 口只读、B 口读/写复用）。
 *
 * ★ 接口契约（与 sync_mem.sv 完全一致，改前先读那份头部）：
 *   - 读：请求那一拍给 addr 且 ren=1，下一拍（T+1）rdata 才有效；ren=0 时保持旧值。
 *     两条读口各自独立保持。
 *   - 写：T 拍给 addr/wdata/mask 且 wen=1 同步写入，wen 是**单拍脉冲**。
 *     写口挂在 B 口上（BRAM 的端口本来就是读/写复用），所以**同拍不能既读又写 B 口**。
 *   - 同拍 A 口读 B 口写是允许的（不同端口、不同地址）；同址则读到旧值。
 *   - reset 只清两个读数据寄存器，**不清存储阵列**。
 *
 * ★ 综合（Vivado）推断要点：两个读口 + 一个写口必须写在**同一个 always_ff、同一个
 *   时钟**里，Vivado 才会推成 "True Dual Port RAM"（端口 A 只读、端口 B 读/写）。
 *   拆成两个 always_ff 会被推成两块 RAM（占用翻倍）——这是本轮最容易踩的坑。
 * =========================================================================== */
module sync_mem_dp #(
    // 字数（地址位宽 = $clog2(WORDS)）
    parameter WORDS = 16384,
    // 存储器初值文件（空字符串表示不加载）
    parameter INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        reset,

    /* ---- 端口 A：取指（只读） ---- */
    input  logic [31:0] a_addr,
    input  logic        a_ren,
    output logic [31:0] a_rdata,

    /* ---- 端口 B：数据读（CPU）/ 写（引导器），读与写同拍互斥 ---- */
    input  logic [31:0] b_addr,
    input  logic        b_ren,
    output logic [31:0] b_rdata,
    input  logic        b_wen,
    input  logic [31:0] b_wdata,
    input  logic [ 1:0] b_mask
);

    localparam ADDR_BITS = $clog2(WORDS);
    // 初始化循环上限：与 sync_mem 同一个坑（Quartus 对 initial/for 有 5000 次上限），
    //   这里把被清零的字数限制到 ≤4096；仿真里真正的初值由 $readmemh 决定。
    localparam INIT_WORDS = (WORDS < 4096) ? WORDS : 4096;

    (* rom_style = "block" *) logic [31:0] mem [0:WORDS-1];

    // ★ 不变量：字地址口径 = addr[ADDR_BITS+1:2]（低 2 位是字内偏移）
    logic [ADDR_BITS-1:0] a_word;
    logic [ADDR_BITS-1:0] b_word;
    assign a_word = a_addr[ADDR_BITS+1:2];
    assign b_word = b_addr[ADDR_BITS+1:2];

    logic [1:0] byte_offset;
    assign byte_offset = b_addr[1:0];

    // 写数据按 mask 对齐（与 sync_mem 逐字一致）
    logic [31:0] wdata_merge;
    always_comb begin
        case (b_mask)
            2'b00:   wdata_merge = {24'b0, b_wdata[7:0]};
            2'b01:   wdata_merge = {16'b0, b_wdata[15:0]};
            default: wdata_merge = b_wdata;
        endcase
    end

    integer i;
    initial begin
        for (i = 0; i < INIT_WORDS; i = i + 1) mem[i] = 32'h0000_0000;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // ★★ 两个读口 + 一个写口必须在**同一个 always_ff** 里（见头部综合要点）
    always_ff @(posedge clk) begin
        if (reset) begin
            a_rdata <= 32'b0;
            b_rdata <= 32'b0;
        end else begin
            if (a_ren) a_rdata <= mem[a_word];
            if (b_ren) b_rdata <= mem[b_word];
            if (b_wen) begin
                case (b_mask)
                    2'b00: begin
                        case (byte_offset)
                            2'b00: mem[b_word][7:0]   <= wdata_merge[7:0];
                            2'b01: mem[b_word][15:8]  <= wdata_merge[7:0];
                            2'b10: mem[b_word][23:16] <= wdata_merge[7:0];
                            default: mem[b_word][31:24] <= wdata_merge[7:0];
                        endcase
                    end
                    2'b01: begin
                        if (byte_offset[1] == 1'b0) mem[b_word][15:0]  <= wdata_merge[15:0];
                        else                        mem[b_word][31:16] <= wdata_merge[15:0];
                    end
                    default: mem[b_word] <= wdata_merge;
                endcase
            end
        end
    end

endmodule
