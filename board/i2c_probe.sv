`timescale 1ns / 1ps

/* =============================================================================
 * i2c_probe.sv — 上电自检：扫描 I2C 总线 + 读 ADV7511 的 ID 寄存器
 * -----------------------------------------------------------------------------
 * 这个模块**不接 CPU 总线**，上电后自己跑一遍，把结果留在寄存器里给 ILA 看。
 * 目的只有一个：在写 2000 行 HDMI 时序代码之前，先用半天回答一个问题 ——
 *   "ADV7511 到底在不在总线上、I2C 地址是 0x72 还是 0x7A？"
 *
 * 为什么先扫描再做读：
 *   · 手册没给 I2C 地址。ADV7511 的地址由 ADDR 脚接法决定，两种都很常见。
 *   · 扫描 0x70~0x7F 只要几毫秒，比"猜一个地址、读不到、怀疑人生"便宜得多。
 *
 * 探测序列：
 *   对每个候选地址：START → 地址+W → 看 ACK → STOP
 *   然后对**最低的应答地址**读三个寄存器：
 *     START → 地址+W → 寄存器号 → (重复)START → 地址+R → 读字节(NACK) → STOP
 *
 * 期望值（ADI ADV7511 数据手册：0xF5/0xF6 是固定 ID 字节，ASCII 'A'/'D'）：
 *   0xF5 = 0x41 ('A')，0xF6 = 0x44 ('D')，0x00 = 版本（常见 0x13）
 * ★ 0xF5/0xF6 读到 'A''D' 是**不可伪造**的证据：别的芯片不会在那里放这两个字节。
 *   只看 0x00 有风险 —— 好几个 ADI 器件在 0x00 都返回 0x13 附近的值。
 *
 * ★ 结构约定：P_IDLE / P_PICK / P_DONE 是**控制态**（不请求、不等 done），
 *   其余是**等待态**（发一个请求，等 m_done）。上一版把 P_PICK 混进请求分支里，
 *   结果是 case 的 default 又给 waiting 置 1，和 PICK 块抢同一个寄存器 ——
 *   这次改成"控制态用 else if 提前截断"，结构上不可能再撞。
 *
 * 接口：start_pulse 拉高一次 → 跑完整轮 → done_pulse 一拍；结果保持到下次。
 * ============================================================================= */
module i2c_probe #(
    parameter int CLK_HZ = 50_000_000,
    parameter int SCL_HZ = 100_000,
    // 扫描基址：连续扫描 SCAN_BASE | {0..15} 这 16 个**7 位**地址。
    //
    // ★★ 这里踩过一次真坑（2026-11-16 上板才暴露）：
    //    模块发地址用的是 m_tx <= {scan_addr, 1'b0} —— 即 SCAN_BASE 是**7 位地址**，
    //    不是"8 位写地址"。第一版给 HDMI 写的是 7'h70，线上真正发出的是 0xE0，
    //    等于在扫 7 位 0x70~0x7F（SMBus 保留 / 10 位地址区），当然一个 ACK 都收不到。
    //    而 ADV7511 的 7 位地址是 0x39（8 位写地址 0x72），落在 0x38~0x3F 这一档。
    //    结论：HDMI 与音频都用 7'h38 —— 两个器件恰好都在这 8 个地址里
    //    （ADV7511 = 0x39，ADAU1761 = 0x38~0x3B）。
    parameter logic [6:0] SCAN_BASE = 7'h38
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start_pulse,   // 单拍：开始一轮探测
    output logic        done_pulse,    // 单拍：一轮结束

    /* ---- 结果（实时镜像 found_r，探测结束后保持不变）---- */
    output logic [15:0] found,         // bit n = 地址 (0x70+n) 应答了
    output logic        any_found,
    output logic [6:0]  addr_lo,       // 应答地址里最小的那个
    output logic [7:0]  id00,          // 寄存器 0x00
    output logic [7:0]  idf5,          // 寄存器 0xF5（应是 'A'）
    output logic [7:0]  idf6,          // 寄存器 0xF6（应是 'D'）
    output logic [2:0]  rd_ok,         // 每个寄存器的读事务是否走完
    output logic        busy,          // 一轮正在跑

    /* ---- 引脚（开漏，1 = 拉低）---- */
    output logic        scl_oe,
    output logic        sda_oe,
    input  logic        sda_i
);

    /* ------------------------------ i2c_master ------------------------------ */
    logic       m_start, m_byte, m_stop;
    logic       m_rw, m_nack;
    logic [7:0] m_tx, m_rx;
    logic       m_ack, m_done;

    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) u_master (
        .clk       (clk),
        .rst       (rst),
        .start_req (m_start),
        .byte_req  (m_byte),
        .stop_req  (m_stop),
        .byte_rw   (m_rw),
        .read_nack (m_nack),
        .byte_tx   (m_tx),
        .byte_rx   (m_rx),
        .ack_rx    (m_ack),
        .busy      (),
        .done      (m_done),
        .scl_oe    (scl_oe),
        .sda_oe    (sda_oe),
        .sda_i     (sda_i)
    );

    /* ------------------------------ 步骤编码 ------------------------------ */
    localparam logic [3:0]
        P_IDLE       = 4'd0,
        P_SCAN_START = 4'd1,
        P_SCAN_ADDR  = 4'd2,
        P_SCAN_STOP  = 4'd3,
        P_PICK       = 4'd4,
        P_RD_START   = 4'd5,
        P_RD_ADDR    = 4'd6,
        P_RD_REG     = 4'd7,
        P_RD_RSTART  = 4'd8,
        P_RD_RADDR   = 4'd9,
        P_RD_DATA    = 4'd10,
        P_RD_STOP    = 4'd11,
        P_DONE       = 4'd12;

    logic [3:0]  step;
    logic        waiting;      // 已发出请求，正在等 m_done
    logic [3:0]  scan_idx;     // 0..15 → 地址 0x70+scan_idx
    logic [1:0]  ridx;         // 0..2 → 0x00 / 0xF5 / 0xF6
    logic [15:0] found_r;
    logic [16:0] stuck_cnt;    // 超时保护

    // ★ 用加法、不用按位或：SCAN_BASE 不一定是 16 的整数倍。
    //   OR 的写法在 SCAN_BASE=0x38 时会把 0x39 扫两遍（0x38|1 和 0x38|9 都是 0x39），
    //   found 位图里出现"幽灵应答"（实测 found=0x0202），排查起来极费时间。
    //   加法则严格保证 bit n ↔ SCAN_BASE+n，和 lowest_addr() 的语义一致。
    wire [6:0] scan_addr = SCAN_BASE + {3'd0, scan_idx};

    function automatic logic [7:0] regsel(input logic [1:0] k);
        case (k)
            2'd0:    regsel = 8'h00;
            2'd1:    regsel = 8'hF5;
            default: regsel = 8'hF6;
            /* 2026-11-21 试过改成 0x41/0x42 想读回 ADV7511 的 Power-Down 位，
             * 但重扫根本找不到 0x39（f_h=0x0000），读不到东西 —— 已改回原值。
             * 详见《方案》§52.16。 */
        endcase
    endfunction

    /* 位图里最低的置位位置（无置位时返回 0x70，由 any_found 兜底） */
    function automatic logic [6:0] lowest_addr(input logic [15:0] f);
        integer i;
        begin
            lowest_addr = SCAN_BASE;
            for (i = 15; i >= 0; i = i - 1)
                if (f[i]) lowest_addr = SCAN_BASE + i[6:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            step       <= P_IDLE;
            waiting    <= 1'b0;
            scan_idx   <= 4'd0;
            ridx       <= 2'd0;
            found_r    <= 16'd0;
            found      <= 16'd0;
            any_found  <= 1'b0;
            addr_lo    <= 7'd0;
            id00       <= 8'd0;
            idf5       <= 8'd0;
            idf6       <= 8'd0;
            rd_ok      <= 3'd0;
            done_pulse <= 1'b0;
            busy       <= 1'b0;
            stuck_cnt  <= 17'd0;
            m_start    <= 1'b0;
            m_byte     <= 1'b0;
            m_stop     <= 1'b0;
            m_rw       <= 1'b0;
            m_nack     <= 1'b0;
            m_tx       <= 8'd0;
        end else begin
            /* 请求都是单拍；found 实时镜像状态，ILA 能看到扫描进度 */
            m_start    <= 1'b0;
            m_byte     <= 1'b0;
            m_stop     <= 1'b0;
            done_pulse <= 1'b0;
            found      <= found_r;

            if (step == P_IDLE) begin
                /* ---------------- 控制态：等外部启动 ---------------- */
                busy      <= 1'b0;
                waiting   <= 1'b0;
                stuck_cnt <= 17'd0;
                if (start_pulse) begin
                    found_r   <= 16'd0;
                    scan_idx  <= 4'd0;
                    ridx      <= 2'd0;
                    any_found <= 1'b0;
                    rd_ok     <= 3'd0;
                    busy      <= 1'b1;
                    step      <= P_SCAN_START;
                end
            end else if (step == P_PICK) begin
                /* ---------------- 控制态：从位图里挑地址 ---------------- */
                if (found_r == 16'd0) begin
                    any_found <= 1'b0;
                    step      <= P_DONE;
                end else begin
                    any_found <= 1'b1;
                    addr_lo   <= lowest_addr(found_r);
                    ridx      <= 2'd0;
                    step      <= P_RD_START;
                end
            end else if (step == P_DONE) begin
                /* ---------------- 控制态：收尾 ---------------- */
                busy       <= 1'b0;
                done_pulse <= 1'b1;
                step       <= P_IDLE;
            end else begin
                /* ---------------- 等待态：发请求 / 等 m_done ---------------- */
                if (!waiting) begin
                    case (step)
                        P_SCAN_START: begin m_start <= 1'b1; waiting <= 1'b1; end
                        P_SCAN_ADDR: begin
                            m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= {scan_addr, 1'b0};
                            waiting <= 1'b1;
                        end
                        P_SCAN_STOP: begin m_stop <= 1'b1; waiting <= 1'b1; end
                        P_RD_START:  begin m_start <= 1'b1; waiting <= 1'b1; end
                        P_RD_ADDR:   begin
                            m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= {addr_lo, 1'b0};
                            waiting <= 1'b1;
                        end
                        P_RD_REG:    begin
                            m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= regsel(ridx);
                            waiting <= 1'b1;
                        end
                        P_RD_RSTART: begin m_start <= 1'b1; waiting <= 1'b1; end
                        P_RD_RADDR:  begin
                            m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= {addr_lo, 1'b1};
                            waiting <= 1'b1;
                        end
                        P_RD_DATA:   begin
                            m_byte <= 1'b1; m_rw <= 1'b1; m_nack <= 1'b1;
                            waiting <= 1'b1;
                        end
                        P_RD_STOP:   begin m_stop <= 1'b1; waiting <= 1'b1; end
                        default:     step <= P_DONE;
                    endcase
                    stuck_cnt <= 17'd0;
                end else begin
                    /* 超时：100 kHz 下一个字节只要 4500 拍，给到 131k 拍还没完就是卡住了 */
                    stuck_cnt <= stuck_cnt + 17'd1;
                    if (stuck_cnt == 17'h1FFFF) begin
                        step    <= P_DONE;
                        waiting <= 1'b0;
                    end else if (m_done) begin
                        waiting   <= 1'b0;
                        stuck_cnt <= 17'd0;
                        case (step)
                            P_SCAN_START: step <= P_SCAN_ADDR;
                            P_SCAN_ADDR: begin
                                if (m_ack) found_r[scan_idx] <= 1'b1;
                                step <= P_SCAN_STOP;
                            end
                            P_SCAN_STOP: begin
                                if (scan_idx == 4'd15) step <= P_PICK;
                                else begin scan_idx <= scan_idx + 4'd1; step <= P_SCAN_START; end
                            end
                            P_RD_START:  step <= P_RD_ADDR;
                            P_RD_ADDR:   step <= P_RD_REG;
                            P_RD_REG:    step <= P_RD_RSTART;
                            P_RD_RSTART: step <= P_RD_RADDR;
                            P_RD_RADDR:  step <= m_ack ? P_RD_DATA : P_RD_STOP;
                            P_RD_DATA: begin
                                rd_ok[ridx] <= 1'b1;
                                case (ridx)
                                    2'd0:    id00 <= m_rx;
                                    2'd1:    idf5 <= m_rx;
                                    default: idf6 <= m_rx;
                                endcase
                                step <= P_RD_STOP;
                            end
                            P_RD_STOP: begin
                                if (ridx == 2'd2) step <= P_DONE;
                                else begin ridx <= ridx + 2'd1; step <= P_RD_START; end
                            end
                            default: step <= P_DONE;
                        endcase
                    end
                end
            end
        end
    end

endmodule
