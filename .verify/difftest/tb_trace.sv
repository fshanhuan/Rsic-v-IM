// tb_trace.sv — 逐拍 PC/重定向轨迹（只为看清循环为什么提前退出）
`timescale 1ns / 1ps

module tb_trace;
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;
    integer cycle = 0;

    logic [31:0] irom_addr, irom_data;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic        perip_wen, perip_ren;
    logic [ 1:0] perip_mask;

    logic        dbg_have_inst;
    logic [31:0] dbg_pc;
    logic        dbg_ena;
    logic [ 4:0] dbg_reg;
    logic [31:0] dbg_value;

    localparam IROM_WORDS = 4096;
    logic [31:0] irom [0:IROM_WORDS-1];
    always_ff @(posedge clk) irom_data <= irom[irom_addr[13:2]];

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

    myCPU u_cpu (
        .cpu_clk(clk), .cpu_rst(rst),
        .irom_addr(irom_addr), .irom_data(irom_data),
        .perip_addr(perip_addr), .perip_wen(perip_wen), .perip_ren(perip_ren),
        .perip_mask(perip_mask),
        .perip_wdata(perip_wdata), .perip_rdata(perip_rdata),
        .debug_wb_have_inst(dbg_have_inst), .debug_wb_pc(dbg_pc),
        .debug_wb_ena(dbg_ena), .debug_wb_reg(dbg_reg), .debug_wb_value(dbg_value)
    );

    integer max_cycles = 200;
    reg [8*260-1:0] prog_path;
    integer k;

    // 统计"本应重定向"的分支判定：
    //   actual_taken=1 而流水线里带的预测方向 expt=0 时，(raw 的) 判定条件为真。
    //   注意：不能用"raw=1 却被压成 0"来统计 —— raw 的连续赋值里已经含 ~mem_stall，
    //   被屏蔽的那一拍 raw 本来就直接是 0，那种探针恒为 0（假阴性）。
    integer n_decide  = 0;   // 判定条件为真的拍数
    integer n_masked  = 0;   // 其中因 mem_stall 被屏蔽、且没有产生重定向的
    integer n_redir   = 0;   // 其中真正产生了重定向的
    logic   prev_masked = 1'b0;

    initial begin
        for (k = 0; k < IROM_WORDS; k = k + 1) irom[k] = 32'b0;
        for (k = 0; k < DRAM_WORDS; k = k + 1) dram[k] = 32'b0;
        prog_path = "tests/loop_min_ecall.hex";
        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("max=%d", max_cycles)) ;
        $readmemh(prog_path, irom);
        rst = 1'b1;
        repeat (8) @(posedge clk);
        rst = 1'b0;
    end

    always @(negedge clk) begin
        if (!rst) begin
            cycle = cycle + 1;

            // 判定条件为真：这条分支实际跳、但流水线带的预测是不跳
            if (u_cpu.EXU_valid && u_cpu.Control_inst0.actual_taken &&
                !u_cpu.EXU_pred_taken) begin
                n_decide = n_decide + 1;
                if (u_cpu.bp_mispredict)      n_redir  = n_redir + 1;
                else if (u_cpu.IFU_mem_stall) n_masked = n_masked + 1;
            end

            $display("TRC %0d IFpc=%h dnpc=%h flg=%b mis=%b raw=%b pend=%b pred=%b ptgt=%h expt=%b exptgt=%h act=%b bflg=%b exv=%b expc=%h exres0=%b ifstall=%b memstall=%b ich=%b dch=%b x1=%h",
                     cycle, u_cpu.IFU_pc, u_cpu.dnpc,
                     u_cpu.dnpc_flag, u_cpu.bp_mispredict,
                     u_cpu.Control_inst0.bp_mispredict_raw,
                     u_cpu.Control_inst0.bp_redirect_pending,
                     u_cpu.bp_pred_taken,
                     u_cpu.bp_pred_target,
                     u_cpu.EXU_pred_taken, u_cpu.EXU_pred_target,
                     u_cpu.Control_inst0.actual_taken,
                     u_cpu.Control_inst0.branch_flag,
                     u_cpu.EXU_valid, u_cpu.EXU_pc, u_cpu.EXU_Ex_result[0],
                     u_cpu.IFU_stall, u_cpu.IFU_mem_stall,
                     u_cpu.icache_hold, u_cpu.dcache_hold,
                     u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[1]);

            // ---- MDU 握手探针（追 B3：多拍 div/rem 结果与 rd 错位）----
            $display("MDUD %0d opc=%b rd=%h v=%b stall=%b start=%b done=%b state=%b busy=%b res=%h resreg=%h execres=%h lsu_rd=%h lsu_Rw=%b lsu_v=%b",
                     cycle, u_cpu.EXU_Inst0.alu_opcode_reg, u_cpu.EXU_Inst0.rd_reg,
                     u_cpu.EXU_valid, u_cpu.EXU_Inst0.mdu_stall,
                     u_cpu.EXU_Inst0.mdu_start, u_cpu.EXU_Inst0.mdu_done_i,
                     u_cpu.EXU_Inst0.mdu_state, u_cpu.EXU_mdu_busy,
                     u_cpu.EXU_Inst0.mdu_res, u_cpu.EXU_Inst0.mdu_res_reg,
                     u_cpu.EXU_Inst0.exec_res,
                     u_cpu.LSU_rd, u_cpu.LSU_R_wen, u_cpu.LSU_valid);

            if (cycle >= max_cycles) begin
                $display("SUMMARY 判定为真的拍数=%0d  真正重定向=%0d  被 mem_stall 吞掉=%0d",
                         n_decide, n_redir, n_masked);
                $finish;
            end

            // ---- store 通路探针（追 B5：store 数据来自紧邻 load 时整笔丢失）----
            $display("STP %0d IDpc=%h IDv=%b IDrs2=%h ch2=%b | EXv=%b EXmr=%b EXrd=%h | MEM: v=%b mr=%b rd=%h | PIPE: v=%b mr=%b rd=%h | MEM2: v=%b rw=%b rd=%h | bus wen=%b wd=%h | clr=%b exu_lu=%b mem_lu=%b pipe_lu=%b lus=%b",
                     cycle, u_cpu.IDU_pc, u_cpu.IDU_valid, u_cpu.IDU_rs2,
                     u_cpu.Control_inst0.IDU_rs2_choice,
                     u_cpu.EXU_valid, u_cpu.EXU_mem_ren, u_cpu.EXU_rd,
                     u_cpu.LSU_valid, u_cpu.LSU_mem_ren, u_cpu.LSU_rd,
                     u_cpu.LSU_valid_pipe, u_cpu.LSU_mem_ren_pipe, u_cpu.LSU_rd_pipe,
                     u_cpu.LSU_valid_wb, u_cpu.LSU_R_wen_wb, u_cpu.LSU_rd_wb,
                     u_cpu.lsu_bus_wen, u_cpu.lsu_bus_wdata,
                     u_cpu.Control_inst0.EXU_inst_clear,
                     u_cpu.Control_inst0.exu_load_use,
                     u_cpu.Control_inst0.mem_load_use,
                     u_cpu.Control_inst0.pipe_load_use,
                     u_cpu.Control_inst0.load_use_stall);
        end
    end
endmodule
