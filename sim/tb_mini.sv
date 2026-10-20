`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_mini.sv — 最小 CPU 观察台（无外设、无 UART）：跑一个 hex，把寄存器打出来
 * -----------------------------------------------------------------------------
 * 用途：查"某条指令到底有没有执行"这类问题。board_top 那一套（UART/LED/FIFO）
 *   会把现场搅浑，这里只留 myCPU + IROM + 一个 DRAM 模型。
 *
 * 结束条件（先到者为准）：
 *   · 看到 `x10` 被写成 0x600D（约定好的"程序走到尾"标记）→ 再等 6 拍读现场；
 *   · 或者跑满 +cycles=N（默认 4000）拍 → 打印 TIMEOUT 并 dump。
 *
 * 用法：
 *   vvp tb_mini.vvp +prog=sim/xxx.hex            # 只看寄存器
 *   vvp tb_mini.vvp +prog=sim/xxx.hex +trace      # 同时逐条打印写回
 *
 * 只打印**写回过**的寄存器（值仍是 x 的不打），避免一屏 x。
 * ============================================================================= */
module tb_mini;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #10 clk = ~clk;        // 50MHz，与板上同频

    // ------------------------------------------------------------ CPU 接口
    logic [31:0] irom_addr, irom_data;
    logic        irom_en;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic        perip_wen, perip_ren;
    logic [ 1:0] perip_mask;

    logic        dbg_have_inst, dbg_ena;
    logic [31:0] dbg_pc, dbg_value;
    logic [ 4:0] dbg_reg;
    logic [31:0] dbg_mcause, dbg_mepc, dbg_mtval;
    logic        dbg_trap_take;

    // ------------------------------------------------------------ 存储器
    localparam IROM_WORDS = 4096;
    localparam DRAM_WORDS = 4096;
    logic [31:0] irom [0:IROM_WORDS-1];
    logic [31:0] dram [0:DRAM_WORDS-1];

    always_ff @(posedge clk) irom_data <= irom[irom_addr[13:2]];

    logic [15:0] dram_wa;
    assign dram_wa = perip_addr[15:2];
    always_ff @(posedge clk) begin
        if (perip_ren) perip_rdata <= dram[dram_wa];
    end
    always @(posedge clk) if (perip_wen) dram[dram_wa] <= perip_wdata;

    myCPU u_cpu (
        .cpu_clk            (clk),
        .cpu_rst            (rst),
        .irom_addr          (irom_addr),
        .irom_data          (irom_data),
        .irom_en            (irom_en),
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
        .debug_wb_value     (dbg_value),
        .debug_icache_hit_cnt  (),
        .debug_icache_miss_cnt (),
        .debug_dcache_hit_cnt  (),
        .debug_dcache_miss_cnt (),
        .debug_mcause       (dbg_mcause),
        .debug_mepc         (dbg_mepc),
        .debug_mtval        (dbg_mtval),
        .debug_trap_take    (dbg_trap_take)
    );

    // ------------------------------------------------------------ 运行控制
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg [8*260-1:0] prog_path = "sim/prog.hex";
    integer max_cycles = 4000;
    integer k;
    logic   done = 1'b0;
    integer nwb = 0;

    initial begin
        for (k = 0; k < IROM_WORDS; k = k + 1) irom[k] = 32'h0000_0000;
        for (k = 0; k < DRAM_WORDS; k = k + 1) dram[k] = 32'h0000_0000;
        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("cycles=%d", max_cycles)) ;
        $readmemh(prog_path, irom);
        $display("================================================================");
        $display(" tb_mini : %0s   (max %0d cycles)", prog_path, max_cycles);
        $display("================================================================");
        rst = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk);
        #1 rst = 1'b0;
    end

    // 逐条写回（+trace）
    always @(posedge clk) begin
        if (!rst && dbg_have_inst && dbg_ena) begin
            nwb <= nwb + 1;
            if ($test$plusargs("trace"))
                $display("  [WB] cyc=%0d pc=%h x%0d = %h",
                         cyc, dbg_pc, dbg_reg, dbg_value);
        end
    end

    // 分支/重定向现场（+bp）：查"误预测到底判没判、重定向发没发"
    //   ★ 只打**控制流相关**的拍（EX 级是分支/跳转，或本拍有 dnpc_flag），
    //     否则一屏几万行。
    always @(posedge clk) begin
        if (!rst && $test$plusargs("bp")) begin
            if ((u_cpu.EXU_valid && (u_cpu.EXU_branch_flag || u_cpu.EXU_jump_flag))
                || u_cpu.dnpc_flag) begin
                $display("  [BP ] cyc=%0d EXU_pc=%h br=%b jmp=%b taken=%b pred=%b predtgt=%h dnpc=%b flag=%b det=%b pend=%b misp=%b intr=%b sysred=%b hold=%b",
                         cyc, u_cpu.EXU_pc, u_cpu.EXU_branch_flag, u_cpu.EXU_jump_flag,
                         u_cpu.Control_inst0.actual_taken,
                         u_cpu.EXU_pred_taken, u_cpu.EXU_pred_target,
                         u_cpu.dnpc, u_cpu.dnpc_flag,
                         u_cpu.Control_inst0.bp_misp_det,
                         u_cpu.Control_inst0.bp_misp_pend,
                         u_cpu.bp_mispredict,
                         u_cpu.intr_take, u_cpu.system_redirect,
                         u_cpu.bp_hold_exu);
            end
        end
    end

    // 密集窗口（+win=<起始拍>）：把每个流水级、IFU 队列、dnpc 全打出来。
    //   查"某条指令到底有没有被取到"只能这样看 —— 只盯 EXU_pc 会漏掉"它根本没进流水"。
    integer win = -1;
    initial if ($value$plusargs("win=%d", win)) ;
    always @(posedge clk) begin
        if (!rst && win >= 0 && cyc >= win && cyc < win + 60) begin
            $display("[W] cyc=%0d IFU_pc=%h IDU_pc=%h EXU_pc=%h | IFU_v=%b IDU_v=%b EXU_v=%b IDU_rdy=%b IFU_stall=%b | dnpc=%h flag=%b misp=%b intr=%b sysred=%b clr=%b",
                     cyc, u_cpu.IFU_pc, u_cpu.IDU_pc, u_cpu.EXU_pc,
                     u_cpu.IFU_valid, u_cpu.IDU_valid, u_cpu.EXU_valid,
                     u_cpu.IDU_ready, u_cpu.IFU_stall,
                     u_cpu.dnpc, u_cpu.dnpc_flag, u_cpu.bp_mispredict,
                     u_cpu.intr_take, u_cpu.system_redirect, u_cpu.EXU_inst_clear);
        end
    end

    // 访存通路的逐拍追踪（+dc）：查 store→load 冒险这类问题只能盯 DCache 的请求拍。
    //   打印：请求（en/wen/addr）· 命中判定（hit_addr/hold/store_fire/store_hit）
    //         · 回来的数据（rdata）。
    always @(posedge clk) begin
        if (!rst && $test$plusargs("dc") && (cyc >= 20 && cyc < 120)) begin
            $display("[DC] c=%0d en=%b wen=%b adv=%b addr=%h mask=%b wd=%h | hit=%b hold=%b rdata=%h | sfire=%b shit=%b mem_en=%b mem_wen=%b",
                     cyc,
                     u_cpu.DCache_inst.cpu_en, u_cpu.DCache_inst.cpu_wen, u_cpu.DCache_inst.cpu_adv,
                     u_cpu.DCache_inst.cpu_addr, u_cpu.DCache_inst.cpu_mask, u_cpu.DCache_inst.cpu_wdata,
                     u_cpu.DCache_inst.hit_now, u_cpu.DCache_inst.hold, u_cpu.DCache_inst.cpu_rdata,
                     u_cpu.DCache_inst.store_fire, u_cpu.DCache_inst.store_hit_now,
                     u_cpu.DCache_inst.mem_en, u_cpu.DCache_inst.mem_wen);
        end else if (!rst && cyc == 25) begin
            $display("[DC] MARK25 (plusarg dc=%0d)", $test$plusargs("dc"));
        end
    end

    // 结束判定 + dump
    always @(posedge clk) begin
        if (!rst && !done) begin
            if (dbg_have_inst && dbg_ena && dbg_reg == 5'd10 && dbg_value == 32'h600D) begin
                done <= 1'b1;
                repeat (8) @(posedge clk);
                dump("marker x10=0x600D");
            end else if (cyc > max_cycles) begin
                done <= 1'b1;
                dump("TIMEOUT / no marker");
            end
        end
    end

    task dump(input [8*40-1:0] why);
        integer i;
        integer nchk, nbad, ev;
        logic [31:0] got;
        begin
            $display("");
            $display("-------- dump (%0s) at cyc=%0d, wb=%0d --------", why, cyc, nwb);
            $write("  ");
            for (i = 0; i < 32; i = i + 1) begin
                if (u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[i] !== 32'hx) begin
                    if (i % 4 == 0 && i != 0) $write("\n  ");
                    $write("x%-2d=%h  ", i,
                           u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[i]);
                end
            end
            $write("\n");
            $display("  mcause=%h mepc=%h mtval=%h", dbg_mcause, dbg_mepc, dbg_mtval);

            // 可选期望值：+x5=<dec> … +x10=<dec>，只检查给出来的那几个。
            //   ★ 用十进制，避免 plusargs 里再解析 0x 前缀。
            nchk = 0; nbad = 0;
            for (i = 5; i <= 10; i = i + 1) begin
                case (i)
                    5:  if ($value$plusargs("x5=%d",  ev)) begin
                            nchk = nchk + 1;
                            got  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5];
                            if (got !== ev) begin nbad = nbad + 1;
                                $display("  [FAIL] x5 = %0d, expect %0d", got, ev); end
                            else $display("  [PASS] x5 = %0d", got);
                        end
                    6:  if ($value$plusargs("x6=%d",  ev)) begin
                            nchk = nchk + 1;
                            got  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[6];
                            if (got !== ev) begin nbad = nbad + 1;
                                $display("  [FAIL] x6 = %0d, expect %0d", got, ev); end
                            else $display("  [PASS] x6 = %0d", got);
                        end
                    7:  if ($value$plusargs("x7=%d",  ev)) begin
                            nchk = nchk + 1;
                            got  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[7];
                            if (got !== ev) begin nbad = nbad + 1;
                                $display("  [FAIL] x7 = %0d, expect %0d", got, ev); end
                            else $display("  [PASS] x7 = %0d", got);
                        end
                    8:  if ($value$plusargs("x8=%d",  ev)) begin
                            nchk = nchk + 1;
                            got  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[8];
                            if (got !== ev) begin nbad = nbad + 1;
                                $display("  [FAIL] x8 = %0d, expect %0d", got, ev); end
                            else $display("  [PASS] x8 = %0d", got);
                        end
                    9:  if ($value$plusargs("x9=%d",  ev)) begin
                            nchk = nchk + 1;
                            got  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[9];
                            if (got !== ev) begin nbad = nbad + 1;
                                $display("  [FAIL] x9 = %0d, expect %0d", got, ev); end
                            else $display("  [PASS] x9 = %0d", got);
                        end
                    default: if ($value$plusargs("x10=%d", ev)) begin
                            nchk = nchk + 1;
                            got  = u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[10];
                            if (got !== ev) begin nbad = nbad + 1;
                                $display("  [FAIL] x10 = %0d, expect %0d", got, ev); end
                            else $display("  [PASS] x10 = %0d", got);
                        end
                endcase
            end

            if (nchk > 0) begin
                if (nbad == 0)
                    $display("[MINI-SELFCHECK] status=PASS (%0d checks)", nchk);
                else
                    $display("[MINI-SELFCHECK] status=FAIL (%0d failed, %0d passed)",
                             nbad, nchk - nbad);
            end
            $display("==================================================");
            $finish;
        end
    endtask

endmodule
