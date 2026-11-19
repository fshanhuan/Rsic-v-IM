`timescale 1ns / 1ps

/* =============================================================================
 * adc_sweep.sv — DAC↔ADC 传输曲线扫描器（硬件配对 + 过采样平均）
 * -----------------------------------------------------------------------------
 * 为什么需要它（S2 剩下的两个真实偏差，见 docs/记录仪_HDMI_方案.md §48.16）：
 *   1) "读数与码值不是同一个时刻的"。原来靠 JTAG 读两个 VIO 探针，斜坡 2 ms/码，
 *      两次读之间码值早就跑过去了 —— 于是只能证明"大致跟着变"，画不出传输曲线。
 *   2) 单次读的噪声 ±3 LSB，靠一次读数算斜率/线性度没有意义。
 *
 * 做法（全部在硬件里，不依赖 CPU、不依赖串口）：
 *   收到 start 之后，对 code = 0…255 逐个：
 *       ① 把码值打到 DAC（wr 一拍）
 *       ② 等 settle 个时基（默认 100 × 10 µs = 1 ms，让 DAC/运放/分压彻底稳定）
 *       ③ 累加 avg 个 ADC 新样本（默认 16 个，用 adc_stb 当节拍，绝不会重复计同一个）
 *       ④ 平均值写进 mem[code]
 *   256 个码跑完约 256 × (1 ms + 16×5 µs) ≈ 277 ms，一次扫描就得到一条**码值-读数
 *   严格配对**的曲线。配对之所以严格，是因为每次采样时码值是**静止**的 ——
 *   "同时性"这个要求在物理上被消掉了，而不是靠读得快来凑。
 *
 * ★ 为什么要 average 而不是单次：XADC 的 12 位结果噪声约 ±3 LSB，平均 16 次降到
 *   ±0.75 LSB，才能分辨"斜率差 2%"这个量级的真实偏差（LM324 带载下垂）。
 *
 * ★ drain：扫描期间把 ADC FIFO 一直弹出（rd_en 常 1）。否则 0.28 s × 200 kSa/s
 *   = 5.5 万个样本必然把 1024 深的 FIFO 灌满并置 overflow，之后软件读 FIFO 会拿到
 *   一堆陈旧数据，还会误以为"溢出"是故障。扫描只关心 adc_last，FIFO 顺手清空最干净。
 *
 * ★ 只用 16 位平均值的低 16 位存：XADC 结果寄存器是 12 位左对齐到 [15:4]，
 *   平均后仍是同一格式，软件按 v = code/4096 V 换算即可。
 * ============================================================================= */
module adc_sweep #(
    parameter int CLK_HZ  = 50_000_000,
    parameter int TICK_HZ = 100_000          // 时基 = 10 µs，settle 的单位
) (
    input  logic        clk,
    input  logic        rst,

    /* ---- 控制（电平输入，内部取上升沿，避免一直拉高时反复重跑）---- */
    input  logic        start_level,
    input  logic        abort_level,
    input  logic [15:0] settle,          // 单位 = 10 µs（默认 100 → 1 ms）
    input  logic [ 3:0] avg_log2,        // 平均次数 = 1<<avg_log2（默认 4 → 16 次）

    /* ---- 结果读出（组合读，256 × 16 位，推断为分布式 RAM）---- */
    input  logic [ 7:0] rd_ptr,
    output logic [15:0] rd_avg,
    output logic        rd_ok,           // 该条目真的被扫过了（否则读到的是未初始化值）

    /* ---- DAC 侧 ---- */
    output logic        busy,            // 1 = 本模块占用 DAC
    output logic [ 7:0] code,            // 当前正在测的码
    output logic        wr,              // 单拍：码值变了，把 code 打进 DAC

    /* ---- 状态 ---- */
    output logic        done,
    output logic [ 8:0] n_done,          // 已完成（已写入）的条目数 0…256

    /* ---- ADC 侧 ---- */
    input  logic [15:0] adc_last,
    input  logic        adc_stb,
    output logic        drain
);

    localparam int TICK = (CLK_HZ / TICK_HZ < 2) ? 2 : (CLK_HZ / TICK_HZ);

    /* ------------------------------ 时基 ------------------------------ */
    logic [15:0] tick_div;
    logic        tick;
    always_ff @(posedge clk) begin
        if (rst) begin
            tick_div <= 16'd0;
            tick     <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (tick_div == (TICK - 1)) begin
                tick_div <= 16'd0;
                tick     <= 1'b1;
            end else begin
                tick_div <= tick_div + 16'd1;
            end
        end
    end

    /* ------------------------------ 控制边沿 ------------------------------ */
    logic start_q, abort_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            start_q <= 1'b0;
            abort_q <= 1'b0;
        end else begin
            start_q <= start_level;
            abort_q <= abort_level;
        end
    end
    wire start_p = start_level & ~start_q;
    wire abort_p = abort_level & ~abort_q;

    /* ------------------------------ 平均参数 ------------------------------ */
    wire [3:0]  l2    = (avg_log2 > 4'd10) ? 4'd10 : avg_log2;
    wire [11:0] nsamp = 12'd1 << l2;
    wire [11:0] ns_m1 = nsamp - 12'd1;

    /* ------------------------------ 状态机 ------------------------------ */
    typedef enum logic [1:0] { S_IDLE, S_SETTLE, S_ACC, S_FIN } st_t;
    st_t         st;
    logic [15:0] st_cnt;      // settle 倒计时（单位：tick）
    logic [11:0] n_acc;       // 已累加样本数
    logic [27:0] sum;         // 累加和（16 位 × 最多 1024）
    logic [ 7:0] code_r;
    logic [ 8:0] n_done_r;
    logic        busy_r, done_r, wr_r;

    logic [15:0] mem [0:255];

    /* ★ 故意**不**给 mem 加 initial 清零块：一旦整块被 initial 写过，Vivado 就不再把它
     *   推断成分布式 RAM，而会变成 4096 个触发器 + 一个 256:1 大 mux —— 又大又慢。
     *   代价是"还没扫到的条目"读出来是未初始化值，所以必须配一根 rd_ok 让上层能判断；
     *   软件只要先看 n_done 就知道哪些条目有效。 */

    wire [27:0] sum_next = sum + {12'b0, adc_last};
    wire [27:0] avg_next = sum_next >> l2;

    always_ff @(posedge clk) begin
        if (rst) begin
            st       <= S_IDLE;
            st_cnt   <= 16'd0;
            n_acc    <= 12'd0;
            sum      <= 28'd0;
            code_r   <= 8'd0;
            n_done_r <= 9'd0;
            busy_r   <= 1'b0;
            done_r   <= 1'b0;
            wr_r     <= 1'b0;
        end else begin
            wr_r <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (start_p) begin
                        /* 从 0 开始，先把码值打出去 */
                        code_r   <= 8'd0;
                        wr_r     <= 1'b1;
                        st_cnt   <= settle;
                        n_done_r <= 9'd0;
                        done_r   <= 1'b0;
                        busy_r   <= 1'b1;
                        st       <= S_SETTLE;
                    end
                end

                S_SETTLE: begin
                    if (abort_p) begin
                        busy_r <= 1'b0;
                        st     <= S_IDLE;
                    end else if (st_cnt == 16'd0) begin
                        sum   <= 28'd0;
                        n_acc <= 12'd0;
                        st    <= S_ACC;
                    end else if (tick) begin
                        st_cnt <= st_cnt - 16'd1;
                    end
                end

                S_ACC: begin
                    if (abort_p) begin
                        busy_r <= 1'b0;
                        st     <= S_IDLE;
                    end else if (adc_stb) begin
                        sum   <= sum_next;
                        n_acc <= n_acc + 12'd1;
                        if (n_acc == ns_m1) begin
                            /* ★ 这里用 sum_next 而不是 sum：本拍的样本必须算进去 */
                            mem[code_r] <= avg_next[15:0];
                            n_done_r    <= {1'b0, code_r} + 9'd1;
                            sum         <= 28'd0;
                            n_acc       <= 12'd0;
                            if (code_r == 8'hFF) begin
                                done_r <= 1'b1;
                                busy_r <= 1'b0;
                                st     <= S_FIN;
                            end else begin
                                code_r <= code_r + 8'd1;
                                wr_r   <= 1'b1;
                                st_cnt <= settle;
                                st     <= S_SETTLE;
                            end
                        end
                    end
                end

                S_FIN: begin
                    /* 扫完保持 done 直到下一次 start；码值停在 0xFF */
                    if (start_p) begin
                        code_r   <= 8'd0;
                        wr_r     <= 1'b1;
                        st_cnt   <= settle;
                        n_done_r <= 9'd0;
                        done_r   <= 1'b0;
                        busy_r   <= 1'b1;
                        st       <= S_SETTLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    assign busy    = busy_r;
    assign done    = done_r;
    assign code    = code_r;
    assign wr      = wr_r;
    assign n_done  = n_done_r;
    assign rd_avg  = mem[rd_ptr];
    assign rd_ok   = ({1'b0, rd_ptr} < n_done_r);
    assign drain   = busy_r;      // 扫描期间把 FIFO 一直腾空

endmodule
