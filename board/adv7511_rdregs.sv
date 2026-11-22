`timescale 1ns / 1ps

/* =============================================================================
 * adv7511_rdregs.sv —— 配置完成后，把 ADV7511 的 4 个关键寄存器读回来
 * -----------------------------------------------------------------------------
 * 为什么需要它：我们一直不知道芯片自己怎么看自己的状态。按官方 Programming Guide：
 *   0x41[6] = 1  -> 主掉电（TMDS 一定不输出；而且 0x00–0x93 会被复位）
 *   0x42[6]      -> HPD 引脚的实时状态
 *   0x15 / 0x16  -> 输入格式配置有没有真的写进去
 *
 * 做法：`go` 上升沿后，用 i2c_master 做 4 次"写寄存器号 + 重复 START + 读一字节"：
 *   START, {0x39,0}, reg, START, {0x39,1}, RD(nack), STOP
 * 结果锁在 d0..d3 里，由 VIO 读走。
 *
 * ★ 只读、不改任何配置；出错（NACK）就把 ok 清 0，对应字节保持 0。
 * ============================================================================= */
module adv7511_rdregs #(
    parameter int CLK_HZ   = 50_000_000,
    parameter int SCL_HZ   = 100_000,
    parameter logic [6:0] I2C_ADDR = 7'h39
) (
    input  logic clk,
    input  logic rst,
    input  logic go,                 // 上升沿触发一次读取

    output logic scl_oe,
    output logic sda_oe,
    input  logic sda_i,

    output logic [7:0] d0,           // 0x00 器件 ID
    output logic [7:0] d1,           // 0x41 电源
    output logic [7:0] d2,           // 0x42 HPD 状态
    output logic [7:0] d3,           // 0x16 输入格式（验证写入是否生效）
    output logic       busy,
    output logic       ok,           // 4 个都读成功
    /* ★ 对照实验：向一个**不存在的地址** 0x50 发一个字节。
     *   它必须是 NACK（ack_bogus=0）。如果它也"ACK"，说明我们的 ACK 检测
     *   有问题（或 SDA 被按住），那么所有"写成功"的结论都不成立。 */
    output logic       ack_bogus
);

    /* ----------------------------- i2c_master ----------------------------- */
    logic m_start, m_byte, m_stop, m_rw, m_nack;
    logic [7:0] m_tx, m_rx;
    logic m_ack, m_done;

    logic m_scl_oe, m_sda_oe;
    logic c_scl_oe, c_sda_oe, clr_active;
    assign scl_oe = clr_active ? c_scl_oe : m_scl_oe;
    assign sda_oe = clr_active ? c_sda_oe : m_sda_oe;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_master (
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
        .scl_oe    (m_scl_oe),
        .sda_oe    (m_sda_oe),
        .sda_i     (sda_i)
    );

    /* ------------------------------- 状态 -------------------------------- */
    typedef enum logic [3:0] {
        R_IDLE, C_RUN, B_START, B_ADDR, B_STOP, R_START1, R_ADDRW, R_REG, R_START2, R_ADDRR, R_DATA, R_STOP, R_NEXT, R_DONE
    } st_t;

    /* 总线清零（9 个 SCL 时钟 + STOP）：把被按住的从机放出来 */
    localparam int HALF = (CLK_HZ / SCL_HZ) / 2;
    localparam int HOLD = CLK_HZ / 20;              // 50 ms 按住
    logic [23:0] c_cnt;
    logic [2:0]  c_ph;
    logic [3:0]  c_clk;

    st_t  st;
    logic waiting;
    logic [1:0] idx;                 // 第几个寄存器
    logic [7:0] rsel;                // 当前寄存器号
    logic       go_q;

    function automatic logic [7:0] reg_of(input logic [1:0] k);
        case (k)
            2'd0: reg_of = 8'h00;
            2'd1: reg_of = 8'h41;
            2'd2: reg_of = 8'h42;
            default: reg_of = 8'h16;
        endcase
    endfunction
    wire [7:0] reg_cur = reg_of(idx);

    always_ff @(posedge clk) begin
        if (rst) begin
            st      <= R_IDLE;
            waiting <= 1'b0;
            idx     <= 2'd0;
            rsel    <= 8'h00;
            go_q    <= 1'b0;
            busy    <= 1'b0;
            ok      <= 1'b0;
            d0 <= 8'h00; d1 <= 8'h00; d2 <= 8'h00; d3 <= 8'h00;
            ack_bogus <= 1'b0;
            clr_active <= 1'b0; c_scl_oe <= 1'b0; c_sda_oe <= 1'b0;
            c_cnt <= 24'd0; c_ph <= 3'd0; c_clk <= 4'd9;
            m_start <= 1'b0; m_byte <= 1'b0; m_stop <= 1'b0;
            m_rw <= 1'b0; m_nack <= 1'b0; m_tx <= 8'h00;
        end else begin
            go_q    <= go;
            m_start <= 1'b0;
            m_byte  <= 1'b0;
            m_stop  <= 1'b0;

            case (st)
                R_IDLE: begin
                    busy <= 1'b0;
                    if (go & ~go_q) begin
                        idx     <= 2'd0;
                        ok      <= 1'b1;
                        busy    <= 1'b1;
                        waiting <= 1'b0;
                        ack_bogus <= 1'b0;
                        clr_active <= 1'b0; c_scl_oe <= 1'b0; c_sda_oe <= 1'b0;
                        c_cnt <= 24'd0; c_ph <= 3'd0; c_clk <= 4'd9;
                        st      <= B_START;   // 上电对照：**不做**恢复，测自然状态
                    end
                end

                /* ================= 总线清零：按住 50ms -> STOP -> 9 个慢时钟 =================
                 * 手工做过 5 次都有效（§52.15）。相位：
                 *   0 两根按住 50 ms   1 放开 SCL（SDA 低）   2 放开 SDA = STOP
                 *   3 SCL 低           4 SCL 高（重复 9 次）  5 收尾
                 * ------------------------------------------------------------------------ */
                C_RUN: begin
                    if (c_cnt != 24'd0) c_cnt <= c_cnt - 24'd1;
                    else case (c_ph)
                        3'd0: begin c_scl_oe <= 1'b1; c_sda_oe <= 1'b1; c_cnt <= HOLD[23:0]; c_ph <= 3'd1; end
                        3'd1: begin c_scl_oe <= 1'b0; c_cnt <= HALF[23:0];      c_ph <= 3'd2; end
                        3'd2: begin c_sda_oe <= 1'b0; c_cnt <= HALF[23:0];      c_ph <= 3'd3; end
                        3'd3: begin c_scl_oe <= 1'b1; c_cnt <= HALF[23:0];      c_ph <= 3'd4; end
                        3'd4: begin c_scl_oe <= 1'b0; c_cnt <= HALF[23:0];
                                    if (c_clk == 4'd0) c_ph <= 3'd5;
                                    else begin c_clk <= c_clk - 4'd1; c_ph <= 3'd3; end end
                        default: begin
                            c_scl_oe <= 1'b0; c_sda_oe <= 1'b0;
                            clr_active <= 1'b0;
                            st <= B_START;
                        end
                    endcase
                end

                /* ---- 对照：不存在的地址 0x50，必须 NACK ---- */
                B_START: if (!waiting) begin m_start <= 1'b1; waiting <= 1'b1; end
                         else if (m_done) begin waiting <= 1'b0; st <= B_ADDR; end

                B_ADDR: begin
                    if (!waiting) begin
                        m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= {7'h50, 1'b0};
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting   <= 1'b0;
                        ack_bogus <= m_ack;      // 期望 0
                        st        <= B_STOP;
                    end
                end

                B_STOP: begin
                    if (!waiting) begin m_stop <= 1'b1; waiting <= 1'b1; end
                    else if (m_done) begin waiting <= 1'b0; st <= R_START1; end
                end

                R_START1: if (!waiting) begin m_start <= 1'b1; waiting <= 1'b1; end
                          else if (m_done) begin waiting <= 1'b0; st <= R_ADDRW; end

                R_ADDRW: begin
                    if (!waiting) begin
                        m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= {I2C_ADDR, 1'b0};
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        if (!m_ack) begin ok <= 1'b0; st <= R_STOP; end
                        else st <= R_REG;
                    end
                end

                R_REG: begin
                    rsel <= reg_cur;
                    if (!waiting) begin
                        m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= reg_cur;
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        if (!m_ack) begin ok <= 1'b0; st <= R_STOP; end
                        else st <= R_START2;
                    end
                end

                R_START2: if (!waiting) begin m_start <= 1'b1; waiting <= 1'b1; end
                          else if (m_done) begin waiting <= 1'b0; st <= R_ADDRR; end

                R_ADDRR: begin
                    if (!waiting) begin
                        m_byte <= 1'b1; m_rw <= 1'b0; m_tx <= {I2C_ADDR, 1'b1};
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        if (!m_ack) begin ok <= 1'b0; st <= R_STOP; end
                        else st <= R_DATA;
                    end
                end

                R_DATA: begin
                    if (!waiting) begin
                        m_byte <= 1'b1; m_rw <= 1'b1; m_nack <= 1'b1;
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        case (idx)
                            2'd0: d0 <= m_rx;
                            2'd1: d1 <= m_rx;
                            2'd2: d2 <= m_rx;
                            default: d3 <= m_rx;
                        endcase
                        st <= R_STOP;
                    end
                end

                R_STOP: begin
                    if (!waiting) begin m_stop <= 1'b1; waiting <= 1'b1; end
                    else if (m_done) begin waiting <= 1'b0; st <= R_NEXT; end
                end

                R_NEXT: begin
                    if (idx == 2'd3) begin
                        busy <= 1'b0;
                        st   <= R_DONE;
                    end else begin
                        idx <= idx + 2'd1;
                        st  <= R_START1;
                    end
                end

                R_DONE: begin
                    /* 停在这里；保持 ok/busy 供 VIO 读 */
                    busy <= 1'b0;
                end

                default: st <= R_IDLE;
            endcase
        end
    end

endmodule
