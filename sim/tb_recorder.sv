// =============================================================================
// sim/tb_recorder.sv -- 记录仪"软件 ↔ XADC/FIFO/显示"契约的仿真台（2026-11-17 新增）
// -----------------------------------------------------------------------------
// 为什么要这个台子（这是这轮唯一能定位问题的手段）：
//   板上 VIO 只能看到 60 个只读探针、采样一次要 150 ms，而问题发生在**微秒级**的
//   排空时序里。实测矛盾是：
//       · meas_cnt 稳定增长（≈195/s = 200 kHz/1024）→ XADC 确实在 200 kHz 转换
//       · adc_cnt  只涨约 150/s，而"每帧排空 1024 个样本"应该是 61 k/s
//       · adc_level 8/8 次采样都是 1024（FIFO 一直满）
//   静态读代码（反汇编 + RTL）两头都对得上，所以必须在**仿真里逐帧看**：
//   每一次弹出到底有没有发生、FIFO 计数有没有减。
//
// 台子结构（故意不用 XADC 原语，iverilog 跑不了）：
//   board_top(IROM_BOOT=0, EXT_MMIO=1)  ← 真 CPU + 真总线 + 真 IROM/DRAM 初值
//     └─ 真程序 project_src/boot_rec.hex（就是烧进比特流的那个）
//   rec_mmio                            ← 真 MMIO 译码（ADC_CTL 的 pop 就在这里）
//   xadc_sampler                        ← 真轮询/FIFO 逻辑（200 kHz）
//     └─ 假 DRP 源：den 后一拍给 drdy，do_ 给锯齿波（不需要 XADC 原语）
//   显示桩：disp_commit 后下一次"帧同步"翻 bank（代替 scope_display）
//     └─ 帧周期用参数 FRAME_CLK（默认 100_000 拍 = 2 ms，比真 16.6 ms 快 8 倍，
//        只为缩短仿真时间；排空逻辑与帧长无关）
//
// 判据（台子自己打印）：
//   [FRAME n] level / cnt(+Δ) / pops(+Δ) / col / bank / pc
//   正常应有：level 在 0..1024 之间大幅摆动、pops/帧 ≈ 该帧产生的样本数、
//   cnt 增量 ≈ pops 增量。若 pops/帧 ≈ 0 而 cnt 不涨，就是软件根本没弹出。
//
// 跑法：
//   iverilog -g2012 -I rtl -o sim/build/tb_recorder.vvp <文件列表> sim/tb_recorder.sv
//   vvp sim/build/tb_recorder.vvp
// =============================================================================
`timescale 1ns/1ps

module tb_recorder;

    localparam int FRAME_CLK = 100_000;   // 桩帧周期（拍）
    localparam int NFRAME    = 6;         // 观察多少帧后结束

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk = ~clk;               // 50 MHz
    wire  rst = ~rst_n;

    /* ---------------- DUT 互连 ---------------- */
    logic        ext_we;
    logic [5:0]  ext_idx;
    logic [31:0] ext_wdata, ext_rdata;
    logic [31:0] d_wb_pc;
    logic        d_have_inst;
    logic [31:0] d_wb_value;
    logic [6:0]  led;
    logic        uart_tx;

    logic        h_scl_oe, h_sda_oe, a_scl_oe, a_sda_oe;
    logic        col_wr, col_wr_bank, disp_commit;
    logic [9:0]  col_col, col_min, col_max;
    logic        text_we;
    logic [5:0]  text_addr;
    logic [4:0]  text_data;
    logic        dac_wr;
    logic [7:0]  dac_data;
    logic        adc_en, adc_clr_ovf, adc_rd_en;
    logic [6:0]  adc_ch0, adc_ch1;
    logic        adc_ch1_en;
    logic [15:0] adc_rd_data, adc_last;
    logic [10:0] adc_level;
    logic        adc_full, adc_ovf;
    logic [31:0] adc_cnt;
    logic [15:0] trig_th;
    logic [1:0]  trig_mode;
    logic        trig_en, trig_clear;
    logic [15:0] meas_min, meas_max, meas_mean, meas_vpp;   // 真 meas_unit 的输出（自动量程要用）
    logic [31:0] meas_cnt;
    logic [6:0]  xadc_daddr;
    logic        xadc_den, xadc_dwe;
    logic [15:0] xadc_di, xadc_do;
    logic        xadc_drdy, adc_stb;

/* 镜像选择：默认用烧进比特流的那份；-DSINGLE_IMG 改用"MMIO 单读"版，
 * 专门用来判定 RTL 的不可缓存读时序有没有修好（软件不连读两次也能读到正确值）。 */
`ifdef SINGLE_IMG
`define IMG_IROM "project_src/boot_single.hex"
`define IMG_DRAM "project_src/boot_single_dram.hex"
`else
`define IMG_IROM "project_src/boot_rec.hex"
`define IMG_DRAM "project_src/boot_rec_dram.hex"
`endif

    /* ---------------- 真 SoC（带固化镜像） ---------------- */
    board_top #(
        .IROM_WORDS (16384),
        .DRAM_WORDS (32768),
        .IROM_INIT  (`IMG_IROM),
        .DRAM_INIT  (`IMG_DRAM),
        .IROM_BOOT  (0),
        .AXIL_EN    (0),
        .EXT_MMIO   (1)
    ) u_soc (
        .sys_clk               (clk),
        .btn_rst_n             (rst_n),
        .debug_wb_have_inst    (d_have_inst),
        .debug_wb_pc           (d_wb_pc),
        .debug_wb_ena          (),
        .debug_wb_reg          (),
        .debug_wb_value        (d_wb_value),
        .debug_icache_hit_cnt  (),
        .debug_icache_miss_cnt (),
        .debug_dcache_hit_cnt  (),
        .debug_dcache_miss_cnt (),
        .debug_mcause          (),
        .debug_mepc            (),
        .debug_mtval           (),
        .debug_trap_take       (),
        .debug_dnpc_flag       (),
        .debug_ready           (),
        .debug_ifu_pc          (),
        .debug_status          (),
        .debug_mcycle          (),
        .uart_rx               (1'b1),
        .uart_tx               (uart_tx),
        .led                   (led),
        .debug_boot_busy       (),
        .debug_boot_ok         (),
        .debug_boot_err        (),
        .irq_ps                (),
        .axil_aclk             (clk),
        .axil_aresetn          (rst_n),
        .s_axil_awaddr         (32'd0), .s_axil_awprot (3'd0), .s_axil_awvalid (1'b0),
        .s_axil_awready        (), .s_axil_wdata (32'd0), .s_axil_wstrb (4'd0),
        .s_axil_wvalid         (1'b0), .s_axil_wready (), .s_axil_bresp (),
        .s_axil_bvalid         (), .s_axil_bready (1'b0), .s_axil_araddr (32'd0),
        .s_axil_arprot         (3'd0), .s_axil_arvalid (1'b0), .s_axil_arready (),
        .s_axil_rdata          (), .s_axil_rresp (), .s_axil_rvalid (),
        .s_axil_rready         (1'b0),
        .ext_we                (ext_we),
        .ext_idx               (ext_idx),
        .ext_wdata             (ext_wdata),
        .ext_rdata             (ext_rdata)
    );

    /* ---------------- 真 MMIO ---------------- */
    rec_mmio u_rec (
        .clk (clk), .rst (rst),
        .we (ext_we), .idx (ext_idx), .wdata (ext_wdata), .rdata (ext_rdata),
        .h_scl_oe (h_scl_oe), .h_sda_oe (h_sda_oe), .h_sda_rd (1'b1),
        .a_scl_oe (a_scl_oe), .a_sda_oe (a_sda_oe), .a_sda_rd (1'b1),
        .f_h (16'd0), .addr_h (7'd0), .id00_h (8'd0), .idf5_h (8'd0), .idf6_h (8'd0),
        .pd_h (1'b0), .h_busy (1'b0),
        .f_a (16'd0), .addr_a (7'd0), .id00_a (8'd0), .idf5_a (8'd0), .idf6_a (8'd0),
        .pd_a (1'b0), .a_busy (1'b0),
        .health (8'h55),
        .col_wr (col_wr), .col_col (col_col), .col_min (col_min), .col_max (col_max),
        .col_wr_bank (col_wr_bank), .disp_commit (disp_commit),
        .text_we (text_we), .text_addr (text_addr), .text_data (text_data),
        .dac_wr (dac_wr), .dac_data (dac_data),
        .adc_en (adc_en), .adc_clr_ovf (adc_clr_ovf), .adc_rd_en (adc_rd_en),
        .adc_ch0 (adc_ch0), .adc_ch1 (adc_ch1), .adc_ch1_en (adc_ch1_en),
        .adc_rd_data (adc_rd_data), .adc_last (adc_last),
        .adc_level (adc_level), .adc_full (adc_full), .adc_ovf (adc_ovf),
        .adc_cnt (adc_cnt),
        .trig_th (trig_th), .trig_mode (trig_mode), .trig_en (trig_en),
        .trig_clear (trig_clear),
        .trig_fired (1'b0), .trig_above (1'b0), .trig_cnt (32'd0),
        .meas_min (meas_min), .meas_max (meas_max), .meas_mean (meas_mean), .meas_cnt (meas_cnt),
        // S2b 扫描器：本台子不测它（有专门的 tb_adc_sweep），输入钉 0 避免 X 扩散
        .sweep_start (), .sweep_abort (),
        .sweep_ptr (), .sweep_settle (), .sweep_avg (),
        .sweep_busy (1'b0), .sweep_done (1'b0), .sweep_ndone (9'd0),
        .sweep_cur_code (8'd0), .sweep_rd_avg (16'd0), .sweep_rd_ok (1'b0),
        .dac_byte_eff (dac_data)
    );

    /* ---------------- 真采样器 + 假 DRP ---------------- */
    xadc_sampler #(
        .CLK_HZ (50_000_000), .POLL_HZ (200_000), .FIFO_AW (10)
    ) u_xadc (
        .clk (clk), .rst (rst),
        .en (adc_en), .ch0 (adc_ch0), .ch1 (adc_ch1), .ch1_en (adc_ch1_en),
        .daddr (xadc_daddr), .den (xadc_den), .dwe (xadc_dwe), .di (xadc_di),
        .do_ (xadc_do), .drdy (xadc_drdy),
        .rd_en (adc_rd_en), .clr_ovf (adc_clr_ovf),
        .rd_data (adc_rd_data), .level (adc_level), .full (adc_full),
        .overflow (adc_ovf), .sample_cnt (adc_cnt),
        .last_data (adc_last), .sample_stb (adc_stb)
    );

    // 假 DRP：den 后一拍给 drdy；信号用"小幅方波"（±32 码，周期 256 样本 = 1.28 ms），
    // 故意做成**小幅**：这样能验证自动量程有没有把 64 码的摆动铺满 1024 行屏幕。
    // （早先用的是连续锯齿，5 ms 扫完 4096 码 —— 对自动量程是病态输入，测不出东西。）
    localparam logic [15:0] FK_BASE = 16'h1800;
    logic [15:0] fake_val;
    logic [15:0] fk_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            xadc_drdy <= 1'b0;
            fake_val  <= FK_BASE;
            fk_i      <= 16'd0;
        end else begin
            xadc_drdy <= xadc_den;
            if (xadc_den) begin
                fk_i <= fk_i + 16'd1;
                // 方波：高 128 个样本、低 128 个样本 → 摆幅 32 个 12 位码
                fake_val <= FK_BASE + (fk_i[7] ? 16'd512 : 16'd0);
            end
        end
    end
    assign xadc_do = fake_val;

    /* 真 meas_unit：自动量程用的是它给的 min/max，不能像以前那样接 0 */
    meas_unit u_meas (
        .clk (clk), .rst (rst),
        .sample (adc_last), .sample_stb (adc_stb), .clr (1'b0),
        .min_v (meas_min), .max_v (meas_max), .vpp (meas_vpp),
        .mean_v (meas_mean), .win_cnt (meas_cnt)
    );

    /* ---------------- 显示桩：提交 → 下一次帧边沿翻 bank ---------------- */
    logic [19:0] frm_ph;
    logic        disp_bank, commit_pending;
    assign col_wr_bank = disp_bank;

    always_ff @(posedge clk) begin
        if (rst) begin
            frm_ph         <= 20'd0;
            disp_bank      <= 1'b0;
            commit_pending <= 1'b0;
        end else begin
            if (disp_commit) commit_pending <= 1'b1;
            if (frm_ph == FRAME_CLK - 1) begin
                frm_ph <= 20'd0;
                if (commit_pending) begin
                    disp_bank      <= ~disp_bank;
                    commit_pending <= 1'b0;
                end
            end else begin
                frm_ph <= frm_ph + 20'd1;
            end
        end
    end

    /* ---------------- 观测 ---------------- */
    longint unsigned pops = 0;        // 已发出的 pop 选通（不管 FIFO 空不空）
    longint unsigned pops_eff = 0;    // 真的弹出了样本（FIFO 非空）
    longint unsigned xfer = 0;        // COL_PUSH 次数
    int              lvl_min = 4096, lvl_max = -1;
    int              frm_ymin = 4095, frm_ymax = 0;      // 一帧内所有列的 y 范围（自动量程是否铺满）

    always_ff @(posedge clk) begin
        if (rst) begin
            pops <= 0; pops_eff <= 0; xfer <= 0;
        end else begin
            if (ext_we && ext_idx == 6'd38 && ext_wdata[2]) begin
                pops <= pops + 1;
                if (adc_level != 11'd0) pops_eff <= pops_eff + 1;
            end
            if (col_wr) begin
                xfer <= xfer + 1;
                if (col_min < frm_ymin) frm_ymin = col_min;
                if (col_max > frm_ymax) frm_ymax = col_max;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (adc_level < lvl_min) lvl_min = adc_level;
            if (adc_level > lvl_max) lvl_max = adc_level;
        end
    end

    /* ---------------- 窗口跟踪：0x1000_0094 那次读前后 14 拍（LSU 侧） ----------------
     * 目的：§25 已经把范围压到"DCache 之后"。这里把 LSU 的 hold / rdata / rdata_reg2
     * 逐拍打出来，看 lw 的结果到底在哪一拍被锁成错误的值。 */
    int  win_n = 0;
    logic win_on = 1'b0;
    always @(posedge clk) begin
        if (!rst) begin
            if (!win_on && (u_soc.perip_addr == 32'h1000_0094)) begin
                win_on <= 1'b1;
                $display("[WIN] ---- 0x1000_0094 读窗口开始 ----");
            end
            if (win_on && win_n < 14) begin
                $display("[WIN %0d] t=%0t hold=%b LSU.rdata=0x%08h LSU.rdata_reg2=0x%08h perip_rdata=0x%08h resp=%b addr_r=0x%08h pc=0x%08h",
                         win_n, $time,
                         u_soc.u_cpu.dcache_hold,
                         u_soc.u_cpu.LSU_Inst0.rdata,
                         u_soc.u_cpu.LSU_Inst0.rdata_reg2,
                         u_soc.perip_rdata,
                         u_soc.u_cpu.DCache_inst.resp_for_now,
                         u_soc.u_cpu.DCache_inst.cpu_addr_r,
                         d_wb_pc);
                win_n <= win_n + 1;
            end
        end
    end

    /* ---------------- 观察 t2(x7) 的每一次写入 ---------------- */
    int rfw_n = 0;
    always @(posedge clk) begin
        if (!rst && rfw_n < 8 &&
            u_soc.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.wen &&
            u_soc.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.waddr == 5'd7) begin
            $display("[RFW] t2(x7) <= 0x%08h  @ t=%0t ns  (pc=0x%08h)",
                     u_soc.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.wdata, $time, d_wb_pc);
            rfw_n <= rfw_n + 1;
        end
    end

    /* ---------------- 寄存器堆快照：第一次 COL_PUSH 后打一次 ---------------- */
    logic rf_dumped = 1'b0;
    int   ri;
    always @(posedge clk) begin
        if (!rst && !rf_dumped && (xfer > 0)) begin
            rf_dumped = 1'b1;
            $display("[RF] 第一次 COL_PUSH 之后的寄存器堆快照：");
            for (ri = 1; ri < 32; ri = ri + 1) begin
                $display("   x%0d(t%0d/s%0d) = 0x%08h = %0d",
                         ri, (ri >= 5 && ri <= 7) ? ri - 5 : ((ri >= 28 && ri <= 31) ? ri - 23 : 9),
                         (ri >= 8 && ri <= 9) ? ri - 8 : ((ri >= 18 && ri <= 27) ? ri - 16 : 9),
                         u_soc.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[ri],
                         u_soc.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[ri]);
            end
        end
    end

    /* ---------------- 总线级观测：0x1000_0094 / 0x1000_0090 的读回值 ---------------- */
    int bus_n = 0;
    always @(posedge clk) begin
        if (!rst && bus_n < 30 &&
            (u_soc.perip_addr == 32'h1000_0094 || u_soc.perip_addr == 32'h1000_0090)) begin
            $display("[BUS %0d] t=%0t addr=0x%08h idx=%0d prdata=0x%08h | rd_req=%b unc=%b busy=%b hold=%b resp=%b cpu_rdata=0x%08h mmio=0x%08h lvl=%0d",
                     bus_n, $time, u_soc.perip_addr, u_soc.bus_mmio_idx, u_soc.perip_rdata,
                     u_soc.u_cpu.DCache_inst.cache_rd_req, u_soc.u_cpu.DCache_inst.uncacheable,
                     u_soc.u_cpu.DCache_inst.unc_busy, u_soc.u_cpu.DCache_inst.hold,
                     u_soc.u_cpu.DCache_inst.resp_for_now, u_soc.u_cpu.DCache_inst.cpu_rdata,
                     u_soc.mmio_rdata, adc_level);
            bus_n <= bus_n + 1;
        end
    end

    /* ---------------- 指令级跟踪（只在第一帧附近开一小段） ----------------
     * 目的：看清 CPU 到底从 ADC_LVL / ADC_ST 读回了什么。
     * 只打 pc + 写回值 + 当时的 ext_idx，120 条足够覆盖一轮列循环的开头。 */
    logic        trace_on = 1'b0;
    int          trace_n  = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (!trace_on && d_have_inst && d_wb_pc == 32'h0000_02d0) begin
                trace_on <= 1'b1;
                $display("[TRACE] 抓到第一条 'lw ADC_LVL'（pc=0x2d0），从这里逐条打印");
            end
            if (trace_on && d_have_inst && trace_n < 90) begin
                $display("[TR %0d] t=%0t pc=0x%08h wb=0x%08h ext_idx=%0d ext_rdata=0x%08h lvl=%0d",
                         trace_n, $time, d_wb_pc, d_wb_value, ext_idx, ext_rdata, adc_level);
                trace_n <= trace_n + 1;
            end
        end
    end

    /* ---------------- 主流程 ---------------- */
    int k;
    int n_fail;
    longint unsigned pops0, eff0, cnt0, xfer0;

    task automatic wait_frame();
        @(posedge clk);
        while (frm_ph != 20'd0) @(posedge clk);
    endtask

    initial begin
        $display("======== TB_RECORDER（真 RTL + 真镜像 + 假 DRP）========");
        $display("  IROM=project_src/boot_rec.hex  DRAM=project_src/boot_rec_dram.hex");
        $display("  帧周期桩=%0d 拍（%0d us）  观察 %0d 帧", FRAME_CLK, FRAME_CLK/50, NFRAME);
        $display("  ADC 轮询 200 kHz（真参数），FIFO 深 1024");
        $display("======================================================");

        repeat (200) @(posedge clk);
        rst_n = 1'b1;

        // ★ 不要用 adc_en 当"程序起来了"的标志：rec_mmio 复位后 adc_en_r 默认就是 1
        //   （这是故意的：不打软件也能从 JTAG 看样本）。真正的标志是**第一次 COL_PUSH**
        //   —— 那说明程序已经打完横幅、进到主循环了。横幅约 121 字节 @115200 ≈ 10.5 ms，
        //   本来就必须等它，否则会误判成"程序卡在 putc_"。
        fork
            begin
                wait (xfer > 0);
                $display("[INFO] 第一次 COL_PUSH @ t=%0t ns（主循环已进入）", $time);
            end
            begin
                #(64'd20_000_000);                          // 20 ms 还没推第一列 → 报错
                $display("[ERROR] 20 ms 内没有发生任何 COL_PUSH：程序没进主循环");
                $finish;
            end
        join_any
        disable fork;

        pops0 = 0; eff0 = 0; cnt0 = 0; xfer0 = 0;
        n_fail = 0;
        for (k = 0; k < NFRAME; k = k + 1) begin
            wait_frame();
            $display("[FRAME %0d] t=%0t ns  level=%0d  cnt=%0d(+%0d)  pop=%0d eff=%0d  xfer=%0d(+%0d) col=%0d bank=%b pc=0x%08h",
                     k, $time, adc_level, adc_cnt, adc_cnt - cnt0,
                     pops, pops_eff, xfer, xfer - xfer0, col_col, disp_bank, d_wb_pc);
            $display("         整帧列 range = %0d .. %0d  (自动量程正常时应接近 0 .. 1023)", frm_ymin, frm_ymax);

            /* ---------------- 判据（每帧都查） ----------------
             * 桩帧 = FRAME_CLK 拍 = 2 ms；200 kHz 采样 → 每帧到达 400 个样本。
             *   D1 每帧 COL_PUSH 必须正好 800（列循环跑满、一列不少）
             *   D2 第 0 帧 pop ≥ 1000（一次把 FIFO 里积压的排空）
             *   D3 之后每帧 pop ∈ [300,500]（≈400，跟得上采样率）
             *   D4 每帧 adc_cnt 增量 == pop 增量（排空真的落到 FIFO 上）
             *   D5 第 1 帧起 frm_ymin..frm_ymax 展宽 ≥ 400 行（自动量程生效）
             *   D6 col_col 必须在 0..799 之间（没跑飞）
             * 这 6 条正好钉住本工程踩过的两个真 bug：
             *   · ADC_CTL 的 pop 顺手清 en → D2/D3 立刻掉到 ~0
             *   · DCache 不可缓存读错位 → avail 读到 0/1 → D2/D3 也掉到 ~0 */
            begin : chk
                int dp, dc, dxx, spread;
                dp  = pops - pops0;
                dxx = xfer - xfer0;
                spread = frm_ymax - frm_ymin;

                if (dxx != 800) begin
                    n_fail++;
                    $display("  [FAIL D1] 第 %0d 帧 COL_PUSH=%0d（应为 800）", k, dxx);
                end
                if ((k == 0) && (dp < 1000)) begin
                    n_fail++;
                    $display("  [FAIL D2] 第 0 帧 pop=%0d（应 ≥1000：一次排空积压）", dp);
                end
                if ((k >= 1) && (dp < 300 || dp > 500)) begin
                    n_fail++;
                    $display("  [FAIL D3] 第 %0d 帧 pop=%0d（应 ≈400）", k, dp);
                end
                // D4 用**精确守恒式**而不是比增量：writes = pops_eff + level
                //   （增量会因为"帧边沿"和"排空时刻"不对齐而差几十个，那是采样窗口问题，
                //     不是 bug；而这条恒等式在任何时刻都必须严格成立）
                if (adc_cnt != (pops_eff + adc_level)) begin
                    n_fail++;
                    $display("  [FAIL D4] 第 %0d 帧 adc_cnt=%0d != pops_eff(%0d)+level(%0d)=%0d",
                             k, adc_cnt, pops_eff, adc_level, pops_eff + adc_level);
                end
                if ((k >= 1) && (spread < 400)) begin
                    n_fail++;
                    $display("  [FAIL D5] 第 %0d 帧列展宽只有 %0d 行（自动量程没生效？）", k, spread);
                end
                if (col_col > 10'd799) begin
                    n_fail++;
                    $display("  [FAIL D6] col_col=%0d 越界（程序跑飞？）", col_col);
                end
            end

            pops0 = pops;
            frm_ymin = 4095; frm_ymax = 0;
            cnt0  = adc_cnt;
            xfer0 = xfer;
        end

        $display("------------------------------------------------------");
        $display(" 合计 %0d 帧：pop 选通 %0d（%0.1f/帧），其中真的弹出 %0d（%0.1f/帧）",
                 NFRAME, pops, pops * 1.0 / NFRAME, pops_eff, pops_eff * 1.0 / NFRAME);
        $display(" COL_PUSH 合计 %0d（%0.1f/帧，满帧应是 800*%0d=%0d）",
                 xfer, xfer * 1.0 / NFRAME, NFRAME, 800 * NFRAME);
        $display(" FIFO level 范围 %0d .. %0d", lvl_min, lvl_max);
        $display(" 最终 adc_cnt=%0d  col_col=%0d  pc=0x%08h", adc_cnt, col_col, d_wb_pc);
        if (n_fail == 0)
            $display("[RECORDER] status=PASS (6 判据 x %0d 帧)", NFRAME);
        else
            $display("[RECORDER] status=FAIL (%0d 条不满足)", n_fail);
        $display("[TB_RECORDER] done");
        $finish;
    end

    initial begin
        #(64'd60_000_000);      // 60 ms 硬上限（横幅 ~10.5 ms + 若干帧）
        $display("[TB_RECORDER] WATCHDOG 超时退出  t=%0t ns", $time);
        $finish;
    end

endmodule
