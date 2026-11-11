`timescale 1ns / 1ps

/* =============================================================================
 * board/dram_shared.sv -- 128 KB DRAM：CPU 独占的"单写口 + 单读口" + AXI 主机借用
 * -----------------------------------------------------------------------------
 * 为什么不是真双口：Vivado 对"双口 + 两口字节使能"的阵列推断不出来
 * （Synth 8-3391 / 8-2914，三种写法都试过），而 xvlog 编译 4×32768×8 的阵列要
 * 400 s 以上，把 lint/SVA 门禁拖死。于是改成**共享端口 + 组合 mux**：
 *
 *       mem 只有 1 个写口、1 个读口（就是 sync_mem 那种最简单的模板）
 *       写口：cpu_wen 优先；CPU 不写的拍，AXI 主机才可以写（wr_gnt）
 *       读口：cpu_ren 优先；CPU 不读的拍，AXI 主机才可以读（rd_gnt）
 *
 *   ★ 关键：CPU **永远不会被拖慢** —— 它俩本来就很少访问（store/load 只占几个百分点），
 *     而且 mux 是组合的，CPU 的访问当拍就通。AXI 主机是慢速设备（一次事务几十拍），
 *     等待由桥（axil_slave）的 m_req/m_gnt 握手吸收，不丢事务。
 *   ★ 代价：CPU 与 PS **同拍写同一地址**时 CPU 赢，PS 那一拍被忽略 —— 所以软件必须
 *     约定"同一个区域不要两边同时写"。共享内存的常规约定。
 *
 * 时序：
 *   CPU 口：与 board/sync_mem.sv 完全一致（ren 那拍给地址、rdata 下一拍有效；
 *           wen 那拍按字节掩码写）。换掉它不改变 CPU 行为。
 *   AXI 口：b_req 保持到 b_gnt；被授权那拍执行；
 *           写：下一拍落盘；读：再下一拍 b_rvalid=1、b_rdata 有效（单拍脉冲）。
 * ============================================================================= */
module dram_shared #(
    parameter integer WORDS     = 32768,
    parameter         INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        reset,

    // ---------------- CPU 口（与 sync_mem 一致） ----------------
    input  logic [31:0] cpu_addr,
    input  logic        cpu_ren,
    output logic [31:0] cpu_rdata,
    input  logic        cpu_wen,
    input  logic [31:0] cpu_wdata,
    input  logic [ 1:0] cpu_mask,      // 00=字节 01=半字 1x=整字

    // ---------------- AXI 主机口（请求/授权） ----------------
    input  logic [31:0] b_addr,
    input  logic        b_req,
    input  logic        b_we,
    input  logic [31:0] b_wdata,
    input  logic [ 3:0] b_be,          // AXI wstrb 原样
    output logic        b_gnt,
    output logic        b_rvalid,
    output logic [31:0] b_rdata
);

    localparam ADDR_BITS  = $clog2(WORDS);
    localparam INIT_WORDS = (WORDS < 4096) ? WORDS : 4096;

    (* ram_style = "block" *) logic [31:0] mem [0:WORDS-1];

    // ---------------- CPU 字节掩码 → 4 位写使能 ----------------
    logic [1:0] cpu_byte_off;
    assign cpu_byte_off = cpu_addr[1:0];

    logic [3:0] cpu_be;
    always_comb begin
        case (cpu_mask)
            2'b00:   cpu_be = 4'b0001 << cpu_byte_off;
            2'b01:   cpu_be = cpu_byte_off[1] ? 4'b1100 : 4'b0011;
            default: cpu_be = 4'b1111;
        endcase
    end

    // 字节/半字写时数据在低位 —— 复制到对应字节通道（由 cpu_be 选哪几路）
    logic [31:0] cpu_wd;
    always_comb begin
        case (cpu_mask)
            2'b00:   cpu_wd = {4{cpu_wdata[7:0]}};
            2'b01:   cpu_wd = {2{cpu_wdata[15:0]}};
            default: cpu_wd = cpu_wdata;
        endcase
    end

    // ---------------- 端口借用（CPU 优先） ----------------
    logic wr_gnt, rd_gnt;
    assign wr_gnt = b_req &  b_we & ~cpu_wen;
    assign rd_gnt = b_req & ~b_we & ~cpu_ren;
    assign b_gnt  = wr_gnt | rd_gnt;

    logic        we;
    logic [31:0] waddr, wdata;
    logic [3:0]  wbe;
    always_comb begin
        we    = cpu_wen | wr_gnt;
        waddr = cpu_wen ? cpu_addr  : b_addr;
        wdata = cpu_wen ? cpu_wd    : b_wdata;
        wbe   = cpu_wen ? cpu_be    : b_be;
    end

    logic        re;
    logic [31:0] raddr;
    always_comb begin
        re    = cpu_ren | rd_gnt;
        raddr = cpu_ren ? cpu_addr : b_addr;
    end

    integer i;
    initial begin
        for (i = 0; i < INIT_WORDS; i = i + 1) mem[i] = 32'h0000_0000;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // 单一写口 + 单一读口（最标准的 BRAM 模板）
    logic [31:0] rdata_q;
    always_ff @(posedge clk) begin
        if (we) begin
            if (wbe[0]) mem[waddr[ADDR_BITS+1:2]][7:0]   <= wdata[7:0];
            if (wbe[1]) mem[waddr[ADDR_BITS+1:2]][15:8]  <= wdata[15:8];
            if (wbe[2]) mem[waddr[ADDR_BITS+1:2]][23:16] <= wdata[23:16];
            if (wbe[3]) mem[waddr[ADDR_BITS+1:2]][31:24] <= wdata[31:24];
        end
        if (re) rdata_q <= mem[raddr[ADDR_BITS+1:2]];
    end

    // ★ 读数据只打**一拍**（rdata_q），两侧都直接取它 —— 不能再加一级寄存器：
    //   CPU 侧的契约是"ren 那拍给地址、rdata 下一拍有效"（DCache 就在下一拍采样），
    //   多打一拍会让 load 拿到上一拍的旧数据/X（第一版就是这么错的：tb 里 led 直接变 X）。
    //   AXI 侧同样只要"授权后下一拍 b_rvalid"，所以 rvalid 也只是 rd_gnt 打一拍。
    assign cpu_rdata = rdata_q;
    assign b_rdata   = rdata_q;

    logic rd_gnt_q;
    always_ff @(posedge clk) begin
        if (reset) rd_gnt_q <= 1'b0;
        else       rd_gnt_q <= rd_gnt;
    end
    assign b_rvalid = rd_gnt_q;

endmodule
