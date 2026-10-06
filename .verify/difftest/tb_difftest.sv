// =============================================================================
// tb_difftest.sv — 差分测试专用测试台（独立于工程自带 tb_iverilog.sv）
// -----------------------------------------------------------------------------
// 与自带测试台的关键区别：
//   1. 结束条件不依赖 ecall。ecall 会把 PC 重定向到 mtvec(复位值 0)，程序会
//      从头重跑；自带测试台靠「ecall 进 ID 后再等 8 拍」取快照，排空窗口是否
//      足够取决于 ecall 前那条指令要走多深，本身有截断风险。
//      这里改成：程序末尾用一条 magic store（sw 到 0x3FFC，值 0x123）报完工，
//      之后是一条 `jal x0,0` 自跳循环（只写 x0，架构状态从此冻结）。
//      测试台在总线上看到这笔写后，再多跑 +post 拍（默认 60）确保更老的指令
//      全部写回，然后导出终态。
//   2. 导出机器可读的全量状态：32 个 GPR + 全部非零数据存储器字（含 x 值，
//      用 !== 判断，X 传播不会被漏掉），供外部参考模型逐项比对。
//
// 用法：
//   iverilog -g2012 -o tb.vvp <RTL...> tb_difftest.sv
//   vvp tb.vvp +prog=tests/x.hex [+max=20000] [+post=60] [+vcd=wave/x.vcd]
// =============================================================================
`timescale 1ns / 1ps

module tb_difftest;

    localparam MAGIC_ADDR = 32'h0000_3FFC;
    localparam MAGIC_VAL  = 32'h0000_0123;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    integer cycle = 0;

    // ---------------- CPU 接口 ----------------
    logic [31:0] irom_addr, irom_data;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic        perip_wen, perip_ren;
    logic [ 1:0] perip_mask;

    logic        dbg_have_inst;
    logic [31:0] dbg_pc;
    logic        dbg_ena;
    logic [ 4:0] dbg_reg;
    logic [31:0] dbg_value;

    // ---------------- IROM：同步读（与 FPGA BRAM 语义一致） ----------------
    localparam IROM_WORDS = 4096;
    logic [31:0] irom [0:IROM_WORDS-1];

    always_ff @(posedge clk) begin
        irom_data <= irom[irom_addr[13:2]];
    end

    // ---------------- DRAM：同步读 + 同步写（按 mask 合并） ----------------
    localparam DRAM_WORDS = 16384;
    logic [31:0] dram [0:DRAM_WORDS-1];
    logic [15:0] dram_word_addr;
    logic [ 1:0] dram_offset;
    logic [31:0] dram_raw, dram_din;

    assign dram_word_addr = perip_addr[15:2];
    assign dram_offset    = perip_addr[1:0];
    assign dram_raw       = dram[dram_word_addr];

    always_comb begin
        case (perip_mask)
            2'b00:   case (dram_offset)
                         2'b00:   dram_din = {dram_raw[31:8],  perip_wdata[7:0]};
                         2'b01:   dram_din = {dram_raw[31:16], perip_wdata[7:0], dram_raw[7:0]};
                         2'b10:   dram_din = {dram_raw[31:24], perip_wdata[7:0], dram_raw[15:0]};
                         default: dram_din = {perip_wdata[7:0], dram_raw[23:0]};
                     endcase
            2'b01:   case (dram_offset[1])
                         1'b0:    dram_din = {dram_raw[31:16], perip_wdata[15:0]};
                         default: dram_din = {perip_wdata[15:0], dram_raw[15:0]};
                     endcase
            default: dram_din = perip_wdata;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst)            perip_rdata <= 32'b0;
        else if (perip_ren) perip_rdata <= dram[dram_word_addr];
    end

    always_ff @(posedge clk) begin
        if (perip_wen) dram[dram_word_addr] <= dram_din;
    end

    // ---------------- 被测 CPU ----------------
    myCPU u_cpu (
        .cpu_clk            (clk),
        .cpu_rst            (rst),
        .irom_addr          (irom_addr),
        .irom_data          (irom_data),
        .perip_addr         (perip_addr),
        .perip_wen          (perip_wen),
        .perip_ren          (perip_ren),
        .perip_mask         (perip_mask),
        .perip_wdata        (perip_wdata),
        .perip_rdata        (perip_rdata),
        .debug_wb_have_inst (dbg_have_inst),
        .debug_wb_pc        (dbg_pc),
        .debug_wb_ena       (dbg_ena),
        .debug_wb_reg       (dbg_reg),
        .debug_wb_value     (dbg_value)
    );

    // ---------------- 运行期状态 ----------------
    integer         max_cycles  = 20000;
    integer         post_cycles = 60;
    reg [8*260-1:0] prog_path;
    reg [8*260-1:0] vcd_path;
    integer         magic_cycle = -1;
    integer         post_cnt    = 0;
    logic           done        = 1'b0;
    integer         i, k;

    task dump_state;
        begin
            $display("DIFFTEST_BEGIN");
            if (magic_cycle < 0) begin
                $display("TIMEOUT");
            end else begin
                $display("MAGIC_CYC %0d", magic_cycle);
            end
            $display("TOTAL_CYC %0d", cycle);
            for (i = 0; i < 32; i = i + 1)
                $display("GPR %0d %08h", i,
                         u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[i]);
            for (i = 0; i < DRAM_WORDS; i = i + 1)
                if (dram[i] !== 32'b0)
                    $display("MEMW %08h %08h", i * 4, dram[i]);
            $display("DIFFTEST_END");
        end
    endtask

    initial begin
        for (k = 0; k < IROM_WORDS; k = k + 1) irom[k] = 32'h0000_0000;
        for (k = 0; k < DRAM_WORDS; k = k + 1) dram[k] = 32'h0000_0000;

        prog_path = "tests/prog.hex";
        vcd_path  = "";
        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("max=%d",  max_cycles)) ;
        if ($value$plusargs("post=%d", post_cycles)) ;
        if ($value$plusargs("vcd=%s",  vcd_path)) ;

        $readmemh(prog_path, irom);

        if (vcd_path[8*260-1 -: 8] != 8'h00) begin
            $dumpfile(vcd_path);
            $dumpvars(0, u_cpu);
            $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[0]);
            $dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[31]);
        end

        rst = 1'b1;
        repeat (8) @(posedge clk);
        rst = 1'b0;
    end

    always @(negedge clk) begin
        if (!rst && !done) begin
            cycle = cycle + 1;

            if (perip_wen && (perip_addr === MAGIC_ADDR) &&
                (perip_wdata === MAGIC_VAL) && (magic_cycle < 0)) begin
                magic_cycle = cycle;
            end

            if (magic_cycle >= 0) begin
                post_cnt = post_cnt + 1;
                if (post_cnt >= post_cycles) begin
                    done = 1'b1;
                    dump_state;
                    $finish;
                end
            end else if (cycle >= max_cycles) begin
                done = 1'b1;
                $display("DIFFTEST_NO_MAGIC after %0d cycles", cycle);
                dump_state;
                $fatal(1, "difftest: magic store never observed (timeout)");
            end
        end
    end

endmodule
