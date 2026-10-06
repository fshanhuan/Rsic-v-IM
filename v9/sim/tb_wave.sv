// =============================================================================
// tb_wave.sv — 用于生成「可读波形」的自包含测试台
// -----------------------------------------------------------------------------
// 目的：回归测试台的 VCD 会把内部信号与 debug_wb_* 端口别名掉，导致波形里
//       看不到 PC / 各阶段 valid。这里用一个自包含的小 SoC，并把 CPU 内部
//       关键信号引到顶层探针，保证波形里每个信号都有独立 id。
//
// 用法：
//   构建命令见 sim/README.md（不要在本注释里写 "verilator" 开头的行，
//   那会被工具当成特殊注释指令）。
// =============================================================================
`timescale 1ns / 1ps

module tb_wave #(
    parameter PROG_FILE = "prog.hex"
);

    logic clk = 0;
    logic rst = 1;
    integer cycle = 0;

    // ---- CPU <-> IROM / DRAM ----
    logic [31:0] irom_addr, irom_data;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic        perip_wen;
    logic [ 1:0] perip_mask;

    logic        dbg_have_inst;
    logic [31:0] dbg_pc;
    logic        dbg_ena;
    logic [ 4:0] dbg_reg;
    logic [31:0] dbg_value;

    // 指令存储器（字地址）
    logic [31:0] irom [0:1023];
    assign irom_data = irom[irom_addr[11:2]];

    // 数据存储器（字节寻址，支持按 mask 写）
    logic [31:0] dram [0:1023];
    logic [31:0] dram_rdata;
    always_ff @(posedge clk) begin
        if (perip_wen) begin
            if (perip_mask == 2'b10)      dram[perip_addr[11:2]] <= perip_wdata;
            else if (perip_mask == 2'b01) dram[perip_addr[11:2]][15:0]  <= perip_wdata[15:0];
            else if (perip_mask == 2'b00) dram[perip_addr[11:2]][7:0]   <= perip_wdata[7:0];
        end
        dram_rdata <= dram[perip_addr[11:2]];
    end
    assign perip_rdata = dram_rdata;

    // ---- 被测 CPU ----
    myCPU u_cpu (
        .cpu_clk            (clk),
        .cpu_rst            (rst),
        .irom_addr          (irom_addr),
        .irom_data          (irom_data),
        .perip_addr         (perip_addr),
        .perip_wen          (perip_wen),
        .perip_mask         (perip_mask),
        .perip_wdata        (perip_wdata),
        .perip_rdata        (perip_rdata),
        .debug_wb_have_inst (dbg_have_inst),
        .debug_wb_pc        (dbg_pc),
        .debug_wb_ena       (dbg_ena),
        .debug_wb_reg       (dbg_reg),
        .debug_wb_value     (dbg_value)
    );

    // ---- 顶层探针（独立 id，保证波形完整） ----
    wire [31:0] p_if_pc      = u_cpu.IFU_pc;
    wire [31:0] p_if_inst    = u_cpu.IFU_inst;
    wire [31:0] p_if_snpc    = u_cpu.IFU_snpc;
    wire [31:0] p_id_pc      = u_cpu.IDU_pc;
    wire        p_id_valid   = u_cpu.IDU_valid;
    wire [ 4:0] p_id_rs1     = u_cpu.IDU_rs1;
    wire [ 4:0] p_id_rs2     = u_cpu.IDU_rs2;
    wire [31:0] p_id_rs1v    = u_cpu.IDU_rs1_value;
    wire [31:0] p_id_rs2v    = u_cpu.IDU_rs2_value;
    wire [ 4:0] p_ex_rd      = u_cpu.EXU_rd;
    wire [31:0] p_ex_pc      = u_cpu.EXU_pc;
    wire [31:0] p_ex_res     = u_cpu.EXU_Ex_result;
    wire        p_ex_valid   = u_cpu.EXU_valid;
    wire        p_ex_branch  = u_cpu.EXU_branch_flag;
    wire        p_ex_jump    = u_cpu.EXU_jump_flag;
    wire        p_ex_brtaken = u_cpu.EXU_branch_flag & u_cpu.EXU_Ex_result[0];
    wire        p_mem_valid  = u_cpu.LSU_valid;
    wire [31:0] p_mem_addr   = u_cpu.lsu_bus_addr;
    wire        p_mem_wen    = u_cpu.lsu_bus_wen;
    wire [ 4:0] p_wb_rd      = u_cpu.WBU_rd;
    wire [31:0] p_wb_pc      = u_cpu.WBU_pc;
    wire [31:0] p_wb_val     = u_cpu.WBU_rd_value;
    wire        p_wb_valid   = u_cpu.WBU_valid;
    wire        p_stall      = u_cpu.IFU_stall;
    wire        p_dnpc_flag  = u_cpu.dnpc_flag;
    wire [31:0] p_dnpc       = u_cpu.dnpc;
    wire        p_pred_taken = u_cpu.bp_pred_taken;
    wire [31:0] p_pred_tgt   = u_cpu.bp_pred_target;
    wire        p_mispredict = u_cpu.bp_mispredict;
    wire [31:0] p_icache_hit = u_cpu.icache_hit_cnt;
    wire [31:0] p_icache_mis = u_cpu.icache_miss_cnt;

    // 寄存器堆观测（x1..x10）
    wire [31:0] p_r1  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[1];
    wire [31:0] p_r2  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[2];
    wire [31:0] p_r3  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[3];
    wire [31:0] p_r4  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[4];
    wire [31:0] p_r5  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5];
    wire [31:0] p_r6  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[6];
    wire [31:0] p_r7  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[7];
    wire [31:0] p_r8  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[8];

    // ---- 时钟 / 复位 / 程序加载 ----
    initial begin
        $dumpfile("tb_wave.vcd");
        $dumpvars(0, tb_wave);
        $readmemh(PROG_FILE, irom);
        for (int i = 0; i < 1024; i++) dram[i] = 32'b0;
    end

    always #5 clk = ~clk;          // 周期 10ns = 100MHz

    initial begin
        repeat (6) @(posedge clk);
        rst = 0;
        repeat (150) @(posedge clk);
        $finish;
    end

endmodule
