`timescale 1ns / 1ps

/* =============================================================================
 * xadc_sampler.sv — XADC 采样器（DRP 读 + 双通道交替 + FIFO）
 * -----------------------------------------------------------------------------
 * 板上 XADC 的两路模拟输入（EES-331 手册 §16，J5 排针）：
 *   J5-9/10  = ADC 辅助通道 11（AD11）→ FPGA 脚 A18 / A19 → DADDR = 0x1B
 *   J5-13/14 = ADC 辅助通道 6 （AD6 ）→ FPGA 脚 V13 / W13 → DADDR = 0x16
 *   量程 0–1 V，**超过 1.0 V 有损坏风险**（接信号源前必须分压并实测）。
 *
 * ★ 本模块**不写 XADC 配置寄存器**，理由很实在：
 *   XADC 的序列器配置（0x48/0x4A/0x4B 等）一旦写错，整颗 ADC 直接不转换，
 *   而上板之前无法验证 —— 那是最难查的一类错（"读回来的永远是 0"）。
 *   默认配置下 XADC 会连续扫描全部通道（片内温度/电压 + 辅助通道），
 *   读某个通道的 DRP 得到的永远是**该通道最近一次转换结果**。
 *   代价：每通道的有效新数据率 = 1 MSPS / 序列长度（约 17）≈ 59 kSPS。
 *   对数据记录仪（慢信号）完全够用；要更高再单独配置序列器。
 *
 * ★ POLL_HZ 决定的是**轮询**速率，不是转换速率：
 *   轮询快了只是重复读到同一个值，不会出错，只是浪费总线。
 *   这点必须写清楚 —— 否则软件里看到"相邻样本一模一样"会误判成 ADC 坏了。
 *
 * ★ 为什么 FIFO 放在 PL 而不是让 CPU 每次读 DRP：
 *   DRP 读有 DRDY 握手，CPU 逐次轮询会占满总线且抖动大；
 *   FIFO 让 CPU 按块取，采集节拍完全由硬件决定 —— 这正是"记录仪时基不抖"的来源。
 *
 * ★ 结构上有一条硬规矩：**一个寄存器只能在一个 always 块里被赋值**。
 *   第一版把 FIFO 写指针同时放在状态机和 FIFO 块里，两个 always 抢同一个 wp ——
 *   综合会报多驱动，仿真里表现为指针乱跳。现在状态机只产生"该写了"这个**条件**
 *   （do_wr 组合自 st），指针与计数全部交给下面的 FIFO 块。
 * ============================================================================= */
module xadc_sampler #(
    parameter int CLK_HZ  = 50_000_000,
    parameter int POLL_HZ = 200_000,
    parameter int FIFO_AW = 10          // 1024 深 × 16 位 = 2 KB
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        en,
    input  logic [6:0]  ch0,
    input  logic [6:0]  ch1,
    input  logic        ch1_en,

    /* ---- XADC DRP ---- */
    output logic [6:0]  daddr,
    output logic        den,
    output logic        dwe,
    output logic [15:0] di,
    input  logic [15:0] do_,
    input  logic        drdy,

    /* ---- FIFO 读出侧 ---- */
    input  logic        rd_en,
    input  logic        clr_ovf,
    output logic [15:0] rd_data,
    output logic [FIFO_AW:0] level,
    output logic        full,
    output logic        overflow,
    output logic [31:0] sample_cnt,

    /* ---- 最新一次转换结果（独立于 FIFO）----
     * ★ 为什么需要它：FIFO 一旦满了就不再写入，rd_data(=队头) 会**永远停在**
     *   第一次填满时的内容。调试阶段（软件还没跑、只能靠 JTAG 看）就完全看不到
     *   "现在输入是什么电压"。这一路每转换一次就更新，直接反映当前值。
     *   软件正常工作时仍然读写 FIFO，两者互不影响。 */
    output logic [15:0] last_data,

    /* 每拿到一次新转换结果给一拍（给 trigger_unit 用：触发判定必须踩在样本节拍上） */
    output logic        sample_stb
);

    localparam int PERIOD = (CLK_HZ / POLL_HZ < 2) ? 2 : (CLK_HZ / POLL_HZ);
    localparam logic [FIFO_AW:0] DEPTH = (1 << FIFO_AW);

    /* ------------------------------ 轮询节拍 ------------------------------ */
    logic [15:0] ph;
    logic        tick;

    always_ff @(posedge clk) begin
        if (rst) begin
            ph   <= 16'd0;
            tick <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (ph == (PERIOD - 1)) begin
                ph   <= 16'd0;
                tick <= en;
            end else begin
                ph <= ph + 16'd1;
            end
        end
    end

    /* ------------------------------ DRP 状态机 ------------------------------
     * IDLE → ISSUE（den 一拍）→ WAIT（等 drdy）→ CAP（数据已被 FIFO 块取走）
     * ---------------------------------------------------------------- */
    typedef enum logic [1:0] { S_IDLE, S_ISSUE, S_WAIT, S_CAP } st_t;
    st_t         st;
    logic        ch_sel;
    logic [15:0] rx;
    logic [ 7:0] wdog;

    assign dwe = 1'b0;
    assign di  = 16'h0000;

    /* 状态机只做"该不该写"这个决定，不碰指针 */
    wire cap_now = (st == S_CAP);            // 本拍刚拿到一次转换结果
    wire do_wr  = (st == S_CAP) && !full;
    wire wr_ovf = (st == S_CAP) &&  full;   // 想写但满了 —— 溢出就是这么丢的

    always_ff @(posedge clk) begin
        if (rst) begin
            st     <= S_IDLE;
            daddr  <= 7'h16;
            den    <= 1'b0;
            ch_sel <= 1'b0;
            rx     <= 16'd0;
            wdog   <= 8'd0;
        end else begin
            den <= 1'b0;

            case (st)
                S_IDLE: begin
                    wdog <= 8'd0;
                    if (tick) begin
                        daddr <= ch_sel ? ch1 : ch0;
                        den   <= 1'b1;
                        st    <= S_ISSUE;
                    end
                end

                S_ISSUE: st <= S_WAIT;

                S_WAIT: begin
                    if (drdy) begin
                        rx <= do_;
                        st <= S_CAP;
                    end else if (wdog == 8'hFF) begin
                        /* 看门狗：DRP 没回应也要往前走，不能把整条链路卡死。
                         * 256 拍 = 5.12 us @50MHz，远大于 DRP 的 2~3 拍延迟。 */
                        st <= S_IDLE;
                    end else begin
                        wdog <= wdog + 8'd1;
                    end
                end

                S_CAP: begin
                    ch_sel <= ch1_en ? ~ch_sel : 1'b0;
                    st     <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    /* ------------------------------ FIFO ------------------------------
     * 环形缓冲 + 显式计数。level 直接就是软件要的"现在能取多少样本"。
     * ---------------------------------------------------------------- */
    logic [15:0] mem [0:(1 << FIFO_AW) - 1];
    logic [FIFO_AW-1:0] wp, rp;
    logic [FIFO_AW:0]   cnt;

    logic do_rd;
    assign do_rd = rd_en && (cnt != '0);

    assign sample_stb = cap_now;
    assign full    = (cnt == DEPTH);
    assign level   = cnt;
    assign rd_data = mem[rp];

    always_ff @(posedge clk) begin
        if (rst) begin
            wp         <= '0;
            rp         <= '0;
            cnt        <= '0;
            overflow   <= 1'b0;
            sample_cnt <= 32'd0;
            last_data  <= 16'd0;
        end else begin
            if (cap_now) last_data <= rx;    // 最新值，与 FIFO 是否满无关

            if (do_wr) begin
                mem[wp]    <= rx;
                wp         <= wp + 1'b1;
                sample_cnt <= sample_cnt + 32'd1;
            end
            if (do_rd) rp <= rp + 1'b1;

            /* 计数：同拍读写各不改变总数 */
            case ({do_wr, do_rd})
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: ;
            endcase

            if (wr_ovf)                     overflow <= 1'b1;
            if (clr_ovf)                    overflow <= 1'b0;
        end
    end

endmodule
