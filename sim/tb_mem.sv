`timescale 1ns / 1ps

/* =============================================================================
 * tb_mem.sv — 存储器模块级波形台（IROM / DRAM 的端口级检查）
 * -----------------------------------------------------------------------------
 * 和板级 TB 的区别：这里直接看 **BRAM 实例的端口**，不经过 CPU/总线。
 * 用途：
 *   1. 抓"读写使能/字节掩码/地址索引"这一层的时序（WaveDrom 图就是从这来的）；
 *   2. 覆盖 `sync_mem` / `sync_mem_dp` 的读延迟契约（ren 那拍给地址，rdata 下一拍有效）。
 *
 * ★ 为什么用 wire 把端口引出来：WaveDrom 图要求"全部输入输出都在模块边界上"，
 *   层次化引用（u_board.irom_inst.xxx）不能直接画图，所以这里一根根接出来。
 * ★ 本台子例化时 IROM_BOOT=0，IROM 实例现在在 board_top 顶层（不在 generate 里）。
 * ============================================================================= */
module tb_mem;

    localparam real TCLK_NS = 20.0;          // 50 MHz（与板上 clk_sys 一致）

    logic sys_clk   = 1'b0;
    logic btn_rst_n = 1'b0;
    always #(TCLK_NS / 2.0) sys_clk = ~sys_clk;

    /* ---------------- board_top 端口 ---------------- */
    logic        debug_wb_have_inst;
    logic [31:0] debug_wb_pc;
    logic        debug_wb_ena;
    logic [ 4:0] debug_wb_reg;
    logic [31:0] debug_wb_value;
    logic [31:0] debug_icache_hit_cnt, debug_icache_miss_cnt;
    logic [31:0] debug_dcache_hit_cnt, debug_dcache_miss_cnt;
    logic [31:0] debug_mcause, debug_mepc, debug_mtval;
    logic        debug_trap_take;
    logic        debug_dnpc_flag, debug_ready;
    logic [31:0] debug_ifu_pc;
    logic [31:0] debug_status, debug_mcycle;
    logic        uart_tx;
    logic [ 6:0] led;
    logic        debug_boot_busy, debug_boot_ok, debug_boot_err;

    board_top #(
        .IROM_WORDS (16384),                 // 64 KB
        .DRAM_WORDS (32768),                 // 128 KB
        .IROM_INIT  ("sim/mem_demo.hex"),
        .IROM_BOOT  (0),
        .BOOT_TMO_MS (1), .BOOT_GAP_MS (1), .BOOT_SILENCE_MS (0)
    ) u_board (
        .sys_clk             (sys_clk),
        .btn_rst_n           (btn_rst_n),
        .debug_wb_have_inst  (debug_wb_have_inst),
        .debug_wb_pc         (debug_wb_pc),
        .debug_wb_ena        (debug_wb_ena),
        .debug_wb_reg        (debug_wb_reg),
        .debug_wb_value      (debug_wb_value),
        .debug_icache_hit_cnt(debug_icache_hit_cnt),
        .debug_icache_miss_cnt(debug_icache_miss_cnt),
        .debug_dcache_hit_cnt(debug_dcache_hit_cnt),
        .debug_dcache_miss_cnt(debug_dcache_miss_cnt),
        .debug_mcause        (debug_mcause),
        .debug_mepc          (debug_mepc),
        .debug_mtval         (debug_mtval),
        .debug_trap_take     (debug_trap_take),
        .debug_dnpc_flag     (debug_dnpc_flag),
        .debug_ready         (debug_ready),
        .debug_ifu_pc        (debug_ifu_pc),
        .debug_status        (debug_status),
        .debug_mcycle        (debug_mcycle),
        .uart_rx             (1'b1),          // 空闲高：不灌镜像
        .uart_tx             (uart_tx),
        .led                 (led),
        .debug_boot_busy     (debug_boot_busy),
        .debug_boot_ok       (debug_boot_ok),
        .debug_boot_err      (debug_boot_err)
    );

    /* =========================================================================
     * 观测探针（全部是台子wiredumpvars(1, tb_mem) 就能全导出）
     *   命名：FM_ = 取指侧存储器口（IROM 端口 A     *           DM_ = 数据侧总线（IROM 端口 B / DRAM / MMIO 共用一根）
     *           DEC_= 同一根数据总线上的三路译码
     * ========================================================================= */
    // ---- 取指口（IROM 端口 A---
    wire [31:0] FM_addr  = u_board.irom_addr;
    wire        FM_en    = u_board.irom_en;
    wire [31:0] FM_rdata = u_board.irom_data;
    wire [31:0] CPU_pc   = u_board.debug_ifu_pc;
    wire        CPU_fetch_vld = u_board.u_cpu.icache_resp_valid;

    // ---- 数据口（board_top perip_* 总线---
    wire [31:0] DM_addr  = u_board.perip_addr;
    wire        DM_en    = u_board.perip_en;
    wire        DM_ren   = u_board.perip_ren;
    wire        DM_wen   = u_board.perip_wen;
    wire [ 1:0] DM_mask  = u_board.perip_mask;
    wire [31:0] DM_wdata = u_board.perip_wdata;
    wire [31:0] DM_rdata = u_board.perip_rdata;

    // ---- 三路译码（同一根数据总线的三个目的地---
    wire        DEC_mmio = u_board.mmio_sel;
    wire        DEC_win  = u_board.irom_win_sel;
    wire [ 2:0] DEC_idx  = u_board.mmio_idx;

    // ---- IROM 端口 B（数据窗/ 引导器写---
    wire        IROM_B_ren   = u_board.irom_inst.b_ren;
    wire        IROM_B_wen   = u_board.irom_inst.b_wen;
    wire [31:0] IROM_B_addr  = u_board.irom_inst.b_addr;
    wire [31:0] IROM_B_rdata = u_board.irom_d_rdata;

    // ---- DRAM 端口 ----
    wire        DRAM_ren   = u_board.dram_inst.ren;
    wire        DRAM_wen   = u_board.dram_inst.wen;
    wire [31:0] DRAM_addr  = u_board.dram_inst.addr;
    wire [31:0] DRAM_wdata = u_board.dram_inst.wdata;
    wire [ 1:0] DRAM_mask  = u_board.dram_inst.mask;
    wire [31:0] DRAM_rdata = u_board.dram_rdata;

    // ---- DCache / LSU 握手 ----
    wire        DC_hit   = u_board.u_cpu.dcache_hit;
    wire        DC_miss  = u_board.u_cpu.dcache_miss;
    wire        DC_hold  = u_board.u_cpu.dcache_hold;
    wire        LSU_M1   = u_board.u_cpu.LSU_valid;        // LSU 第 1 级
    wire        LSU_M2   = u_board.u_cpu.LSU_valid_pipe;   // 第 2 级（发总线的那一级）
    wire        LSU_M3   = u_board.u_cpu.LSU_valid_wb;     // 3 WBU
    wire        CPU_stall = u_board.u_cpu.IFU_stall;

    // ---- 外设输出 ----
    wire        UART_busy = u_board.uart_busy;

    /* ---- IROM 模块级全部端口（sync_mem_dp，实irom_inst---
     *   逐根直接引用模块端口，而不board_top 里加工过irom_* / irom_d_*     *   WaveDrom 图要全部输入输出"，必须是模块边界上的那一组信号*/
    wire        IR_a_ren   = u_board.irom_inst.a_ren;
    wire [31:0] IR_a_addr  = u_board.irom_inst.a_addr;
    wire [31:0] IR_a_rdata = u_board.irom_inst.a_rdata;
    wire        IR_b_ren   = u_board.irom_inst.b_ren;
    wire        IR_b_wen   = u_board.irom_inst.b_wen;
    wire [31:0] IR_b_addr  = u_board.irom_inst.b_addr;
    wire [31:0] IR_b_wdata = u_board.irom_inst.b_wdata;
    wire [ 1:0] IR_b_mask  = u_board.irom_inst.b_mask;
    wire [31:0] IR_b_rdata = u_board.irom_inst.b_rdata;
    wire        IR_rst     = u_board.irom_inst.reset;

    /* ---- DCache 模块级全部端口（rtl/myCPU.sv:706  DCache_inst--- */
    wire        DF_en     = u_board.u_cpu.DCache_inst.cpu_en;
    wire        DF_wen    = u_board.u_cpu.DCache_inst.cpu_wen;
    wire [31:0] DF_addr   = u_board.u_cpu.DCache_inst.cpu_addr;
    wire [31:0] DF_wdata  = u_board.u_cpu.DCache_inst.cpu_wdata;
    wire [ 1:0] DF_mask   = u_board.u_cpu.DCache_inst.cpu_mask;
    wire        DF_adv    = u_board.u_cpu.DCache_inst.cpu_adv;
    wire        DF_seq    = u_board.u_cpu.DCache_inst.req_seq;
    wire        DF_m1en   = u_board.u_cpu.DCache_inst.m1_en;
    wire [31:0] DF_m1addr = u_board.u_cpu.DCache_inst.m1_addr;
    wire        DF_m1hit  = u_board.u_cpu.DCache_inst.m1_hit;
    wire [31:0] DF_m1rd   = u_board.u_cpu.DCache_inst.m1_rdata;
    wire [31:0] DF_memrd  = u_board.u_cpu.DCache_inst.mem_rdata;
    wire [31:0] DF_cpurd  = u_board.u_cpu.DCache_inst.cpu_rdata;
    wire        DF_men    = u_board.u_cpu.DCache_inst.mem_en;
    wire        DF_mwen   = u_board.u_cpu.DCache_inst.mem_wen;
    wire [31:0] DF_maddr  = u_board.u_cpu.DCache_inst.mem_addr;
    wire [31:0] DF_mwdata = u_board.u_cpu.DCache_inst.mem_wdata;
    wire [ 1:0] DF_mmask  = u_board.u_cpu.DCache_inst.mem_mask;
    wire [31:0] DF_hitcnt = u_board.u_cpu.DCache_inst.hit_cnt;
    wire [31:0] DF_misscnt= u_board.u_cpu.DCache_inst.miss_cnt;
    wire        DF_rst    = u_board.u_cpu.DCache_inst.reset;

    /* =========================================================================
     * 拍计+ CSV 记录（下降沿采样，与波形渲染/分析脚本口径一致）
     * ========================================================================= */
    int cycle = 0;
    int STOP  = 700;
    int trace_fd = 0;
    string dump_mode = "all";
    string wave_file = "sim/build/mem_wave.vcd";
    // v17.1：允许换程序 / CSV / 关自检 —新增W3(DRAM)/W4(MMIO) 两张    //   要用另一份演示程序（sb/sh TXDATA 写），又不想mem_demo 的既trace
    //     +prog=<hex>   #1 覆盖 IROM 镜像（此时复位还按着 200 ns，CPU 取不到旧指令
    //     +csv=<path>   CSV 输出路径（默sim/build/mem_trace.csv
    //     +nochk        跳过收尾自检（check_all 里是 mem_demo 专用的期望值）
    string prog_override = "";
    string csv_path = "sim/build/mem_trace.csv";

    `define CSVFMT "%0d,%0d,%08x,%08x,%08x,%0d,%0d,%0d,%0d,%08x,%0d,%08x,%08x,%0d,%0d,%0d,%0d,%08x,%0d,%0d,%08x,%0d,%08x,%08x,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d"
    // 追加段：IROM 模块端口 + DCache 模块端口（与上段分开写，新增列不牵动既有列序
    `define CSVFMT2 ",%0d,%08x,%08x,%0d,%0d,%08x,%08x,%0d,%08x,%0d,%0d,%08x,%08x,%0d,%0d,%0d,%0d,%08x,%0d,%08x,%08x,%08x,%0d,%0d,%08x,%08x,%0d,%08x,%08x,%0d,%0d\n"

    task automatic rec();
        if (trace_fd != 0) begin
            $fwrite(trace_fd, `CSVFMT,
                cycle,
                FM_en, FM_addr, FM_rdata, CPU_pc, CPU_fetch_vld,
                DM_en, DM_ren, DM_wen, DM_addr, DM_mask, DM_wdata, DM_rdata,
                DEC_mmio, DEC_win,
                IROM_B_ren, IROM_B_wen, IROM_B_rdata,
                DRAM_ren, DRAM_wen, DRAM_addr, DRAM_mask, DRAM_wdata, DRAM_rdata,
                DC_hit, DC_miss, DC_hold, LSU_M1, LSU_M2, LSU_M3, CPU_stall,
                UART_busy, uart_tx, led);
            $fwrite(trace_fd, `CSVFMT2,
                IR_a_ren, IR_a_addr, IR_a_rdata,
                IR_b_ren, IR_b_wen, IR_b_addr, IR_b_wdata, IR_b_mask, IR_b_rdata,
                DF_en, DF_wen, DF_addr, DF_wdata, DF_mask, DF_adv, DF_seq,
                DF_m1en, DF_m1addr, DF_m1hit, DF_m1rd, DF_memrd, DF_cpurd,
                DF_men, DF_mwen, DF_maddr, DF_mwdata, DF_mmask, DF_hitcnt, DF_misscnt,
                IR_rst, DF_rst);
        end
    endtask

    initial begin
        if (!$value$plusargs("stop=%d", STOP)) STOP = 700;
        if (!$value$plusargs("vcd=%s", dump_mode)) dump_mode = "all";
        if (!$value$plusargs("wave=%s", wave_file)) wave_file = "sim/build/mem_wave.vcd";
        if ($value$plusargs("csv=%s", csv_path)) ;
        if ($test$plusargs("no_trace")) trace_fd = 0;
        else trace_fd = $fopen(csv_path, "w");
        if ($value$plusargs("prog=%s", prog_override)) begin
            #1;
            // 注意路径：本台子例化IROM_BOOT=0，IROM generate g_irom_rom 分支
    $readmemh(prog_override, u_board.irom_inst.mem);
            $display("[sim] IROM override -> %0s", prog_override);
        end
        if (trace_fd != 0)
            $fwrite(trace_fd, "cycle,FM_en,FM_addr,FM_rdata,CPU_pc,CPU_fetch_vld,DM_en,DM_ren,DM_wen,DM_addr,DM_mask,DM_wdata,DM_rdata,DEC_mmio,DEC_win,IROM_B_ren,IROM_B_wen,IROM_B_rdata,DRAM_ren,DRAM_wen,DRAM_addr,DRAM_mask,DRAM_wdata,DRAM_rdata,DC_hit,DC_miss,DC_hold,LSU_M1,LSU_M2,LSU_M3,CPU_stall,UART_busy,UART_tx,LED,IR_a_ren,IR_a_addr,IR_a_rdata,IR_b_ren,IR_b_wen,IR_b_addr,IR_b_wdata,IR_b_mask,IR_b_rdata,DF_en,DF_wen,DF_addr,DF_wdata,DF_mask,DF_adv,DF_seq,DF_m1en,DF_m1addr,DF_m1hit,DF_m1rd,DF_memrd,DF_cpurd,DF_men,DF_mwen,DF_maddr,DF_mwdata,DF_mmask,DF_hitcnt,DF_misscnt,IR_rst,DF_rst\n");
        $dumpfile(wave_file);
        if (dump_mode == "tb") $dumpvars(1, tb_mem);
        else                   $dumpvars(0, tb_mem);
        #200 btn_rst_n = 1'b1;          // 异步置位00 ns 后释
    end

    always @(negedge sys_clk) begin
        cycle++;
        rec();
        if (cycle >= STOP) begin
            if (!$test$plusargs("nochk")) check_all();
            $finish;
        end
    end

    /* =========================================================================
     * 收尾自检（先仿真再上板；数字进文档）
     * ========================================================================= */
    `define R(n) u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[n]
    // 宏参数名不要exp —宏是**文本替换**，会把格式串里的 "exp" 也换
    `define CHK(nm, got, want) \
        $display("  [%0s] %-10s = 0x%08x   期望 0x%08x", \
                 ((got) === (want)) ? "PASS" : "FAIL", nm, got, want)

    task automatic check_all();
        $display("");
        $display("================ 收尾自检（cycle=%0d0 MHz===============", cycle);
        `CHK("x0",   `R(0),  32'h0);
        `CHK("t3",   `R(28), 32'h5A5A_A5A5);   // 写进 DRAM 的原
    `CHK("t4",   `R(29), 32'h5A5A_A5A5);   // load miss 读回
        `CHK("t5",   `R(30), 32'h5A5A_A5A5);   // load hit 读回
        `CHK("t6",   `R(31), 32'h0001_02B7);   // 窗口读到 IROM[0] = lui t0,0x10
        `CHK("s0",   `R(8),  32'h1234_5678);
        `CHK("s1",   `R(9),  32'h1234_5678);   // 窗口回读
        `CHK("a0",   `R(10), 32'h0);           // TXSTAT 空闲
        `CHK("a1",   `R(11), 32'h41);          // 'A'
        `CHK("a2",   `R(12), 32'h0);           // 轮询结束（busy 已清
    `CHK("a3",   `R(13), 32'h2A);
    // LED
        `CHK("a4",   `R(14), 32'h0);           // 数据addr=0 DRAM[0]
        `CHK("a5",   `R(15), 32'h7B);          // 执行自己写进的指
    `CHK("s2",   `R(18), 32'h07B0_0793);
        `CHK("s3",   `R(19), 32'h0000_006F);
        `CHK("s5",   `R(21), 32'h0002_1000);
        `CHK("s6",   `R(22), 32'h07B0_0793);   // 写完立刻经数据窗口回
    `CHK("IROM[0x400]", u_board.irom_inst.mem[14'h400], 32'h07B0_0793);
        `CHK("IROM[0x401]", u_board.irom_inst.mem[14'h401], 32'h0000_006F);
        `CHK("IROM[0x100]", u_board.irom_inst.mem[14'h100], 32'h1234_5678);
        // 这一条是"偏移量必须落±2KB"的护栏：第一版程序把 0x1000 塞进 sw 的立即数
    //   被截0，正好写IROM[0]（第一条指令）。没有这条断言，a5 碰巧"等于 0x7b
    `CHK("IROM[0]",      u_board.irom_inst.mem[14'h000], 32'h0001_02B7);
        `CHK("DRAM[0x4000]", u_board.g_dram_single.dram_inst.mem_ram[15'h4000], 32'h5A5A_A5A5);
        $display("  LED=0x%02x  dcache hit/miss=%0d/%0d  uart_tx=%b  boot_busy=%b",
                 led, debug_dcache_hit_cnt, debug_dcache_miss_cnt, uart_tx, debug_boot_busy);
        $display("============================================================");
        if (trace_fd != 0) $fclose(trace_fd);
        trace_fd = 0;
    endtask

endmodule
