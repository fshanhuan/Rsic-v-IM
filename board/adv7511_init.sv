`timescale 1ns / 1ps

/* =============================================================================
 * adv7511_init.sv — 上电自动配置 ADV7511（记录仪项目 S1a 的下半段）
 * -----------------------------------------------------------------------------
 * 为什么放在硬件里，而不是做成软件：
 *   ADV7511 必须在有 HPD（显示器接上）之后才能配置。而"什么时候插显示器"是
 *   不可预知的 —— 如果配置靠软件，用户每次插拔显示器都得重新灌一次程序。
 *   放进硬件以后：只要总线上出现 ADV7511，状态机就自动重试配置，插上即亮。
 *
 * 状态机（每个表项 = 一次 I2C 写）：
 *   IDLE → START → ADDR(0x72 写) → REG → VAL → STOP → 下一项
 *   地址字节 NACK → 认为"器件还没上电/没接"→ 等 RETRY 时间后整表重来
 *   配置成功后 done=1，不再重试（要重配就重新打 start）
 *
 * ★ 表内容说明与风险（如实记录）：
 *   0x98/0x9A/0x9C/0x9D/0xA2/0xA3/0xAF 是 ADI 手册要求必写的寄存器，风险低；
 *   0x15/0x16/0x17/0x18 是**视频格式**配置（输入 16 位 YCbCr 4:2:2、
 *   输出 RGB 4:4:4），这几个值是按 ADI 参考代码给的，**必须上板用显示器确认**：
 *   如果屏幕亮了但颜色不对/没有图，就改这几个值（软件侧 i2ctool 也能改）。
 *   0x41=0x10 是"退出掉电"，放在最后。
 * ============================================================================= */
module adv7511_init #(
    parameter int CLK_HZ   = 50_000_000,
    parameter int SCL_HZ   = 100_000,
    parameter int RETRY_CY = 10_000_000,   // 重试间隔 200 ms @50MHz
    parameter logic [6:0] I2C_ADDR = 7'h39 // ADV7511 7 位地址（8 位写地址 0x72）
) (
    input  logic clk,
    input  logic rst,

    input  logic start,          // 单拍：开始/重新开始配置

    /* ---- I2C（开漏，与 i2c_probe / i2c_mmio 相或）---- */
    output logic scl_oe,
    output logic sda_oe,
    input  logic sda_i,

    /* ---- 状态（给 MMIO / VIO 看）---- */
    output logic        busy,
    output logic        done,      // 配置完成
    output logic        no_dev,    // 最近一轮没有得到 ACK
    output logic [ 4:0] cur_idx,   // 正在写第几项
    output logic [ 7:0] last_reg,
    output logic [ 7:0] last_val,
    output logic [15:0] ack_err    // 累计 NACK 次数
);

    /* ------------------------------ 表 ------------------------------
     * ★★ 2026-11-21 22:0x 重写：原来的 14 项里 0x16=0x30 与 0x15=0x01 **自相矛盾**
     *   （0x15 说输入是 YCbCr 4:2:2，0x16[1:0]=00 却说是 RGB 4:4:4），而且缺了
     *   几项上 HDMI 输出必需的配置。新表逐条对照 Linux 主线驱动
     *   drivers/media/i2c/adv7511-v4l2.c（adv7511_setup / adv7511_set_fmt）：
     *
     *   0x15[7:4] = 输入格式  0x0=RGB444  0x1=YCbCr422(16 位)   ← 我们只要 0x1
     *   0x16[7:2] = 输出/位宽 0xB8=UYVY(16 位 4:2:2) 0xBC=YUYV
     *   0x17[2:1] = 4:2:2→4:4:4 插值（0x06 = 一阶插值 + 16:9）
     *   0x18[7]   = CSC 使能（输入 YCbCr、输出 RGB 时必须为 1）
     *   0xBA[6:5] = 输入时钟沿（0x60 = 上升沿采样）
     *   0x55/0x44/0x56 = 输出 RGB444 + AVI InfoFrame（很多 sink 靠它判格式）
     *   0xD6[7:6] = 0xC0：**禁止 HPD 变化复位寄存器**（我们板上 HPD 是接实的）
     * ---------------------------------------------------------------------- */
    localparam int NTBL = 20;

    function automatic logic [15:0] tbl(input logic [4:0] i);   // {reg, val}
        case (i)
            5'd0:  tbl = {8'h41, 8'h00};   // 0x41[6]=0 -> 退出掉电（HPD 必须为高）
            5'd1:  tbl = {8'h98, 8'h03};   // 下面 7 个是手册 Table 14“必须写”的固定寄存器
            5'd2:  tbl = {8'h9A, 8'hE0};   // 9A[7:5]=111
            5'd3:  tbl = {8'h9C, 8'h30};
            5'd4:  tbl = {8'h9D, 8'h61};   // 9D[1:0]=01
            5'd5:  tbl = {8'hA2, 8'hA4};
            5'd6:  tbl = {8'hA3, 8'hA4};
            5'd7:  tbl = {8'hE0, 8'hD0};   // 原来漏了
            5'd8:  tbl = {8'hF9, 8'h00};   // 原来漏了
            5'd9:  tbl = {8'hD6, 8'hC0};   // 禁止 HPD 复位寄存器（Linux 驱动同样处理）
            /* ---- 输入：YCbCr 4:2:2、16 位、style 2、分离同步 ---- */
            5'd10: tbl = {8'h15, 8'h01};   // 0x15[3:0]=1
            5'd11: tbl = {8'h16, 8'h34};   // [7]=0 输出4:4:4  [5:4]=11 8bit  [3:2]=01 style2
            5'd12: tbl = {8'h17, 8'h00};   // 4:3
            /* ---- 输出：4:4:4 + CSC + HDMI 模式 + GC ---- */
            5'd13: tbl = {8'h18, 8'h80};   // CSC 使能，缩放 00
            5'd14: tbl = {8'hAF, 8'h02};   // 0xAF[1]=1 -> HDMI 模式（原 0x00 是 DVI）
            5'd15: tbl = {8'h40, 8'h80};   // 0x40[7]=1 使能 General Control
            5'd16: tbl = {8'h4C, 8'h04};   // GC 颜色深度 24 bit/pixel
            5'd17: tbl = {8'h3B, 8'h00};   // 不做像素重复
            5'd18: tbl = {8'hBA, 8'h60};   // 输入时钟上升沿采样
            5'd19: tbl = {8'h41, 8'h00};   // 最后再确认一次退出掉电
            default: tbl = 16'h0000;
        endcase
    endfunction


    /* --------------------------- i2c_master --------------------------- */
    logic        m_start, m_byte, m_stop;
    logic        m_rw, m_nack;
    logic [ 7:0] m_tx, m_rx;
    logic        m_ack, m_done;

    /* ★★ 2026-11-20 21:1x 总线恢复（§52.15 的修法）
     * -------------------------------------------------------------------------
     * 现象：不管冷上电多少次，ADV7511 一直不应答；但在**手工**做一次
     *   "9 个 SCL 时钟 + STOP" 之后，`init_done` 立刻变成 1（整套 14 个寄存器
     *   都写进去了，`ack_err` 不再增长）。两次独立复现：
     *     · 21:05  把 SCL/SDA 强制拉低再放开（放开瞬间 = 合法 STOP）之后
     *     · 21:1x  显式打 9 拍时钟 + STOP 之后
     * 说明从机被"半截字节"卡住、在等 STOP —— 只有恢复时序能把它放出来。
     *
     * 修法：进入（以及每次重试之前）先跑一段恢复时序：
     *   9 个 SCL 时钟（SDA 释放）→ SCL 低时拉低 SDA → SCL 高 → 释放 SDA（= STOP）
     * 这段时间**绕过 i2c_master**，直接驱动 oe（下面 assign 相或）。
     * ------------------------------------------------------------------------- */
    logic m_scl_oe, m_sda_oe;       // master 的
    logic r_scl_oe, r_sda_oe;       // 恢复时序的
    logic rec_active;               // 1 = 恢复期间，两根线完全由恢复时序接管
    // ★ 必须"二选一"而不是"相或"：i2c_master 在字节/STOP 结束后会一直拉着 SCL 低，
    //   相或的话恢复时序想把 SCL 抬高会被按回去 → STOP 和 9 个时钟根本没上总线。
    assign scl_oe = m_scl_oe | r_scl_oe;   // ★ 与主控并行（手工实验就是这样）
    assign sda_oe = m_sda_oe | r_sda_oe;

    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) u_master (
        .clk        (clk),
        .rst        (rst),
        .start_req  (m_start),
        .byte_req   (m_byte),
        .stop_req   (m_stop),
        .byte_rw    (m_rw),
        .read_nack  (m_nack),
        .byte_tx    (m_tx),
        .byte_rx    (m_rx),
        .ack_rx     (m_ack),
        .busy       (),
        .done       (m_done),
        .scl_oe     (m_scl_oe),
        .sda_oe     (m_sda_oe),
        .sda_i      (sda_i)
    );

    /* ------------------------------ 步骤 ------------------------------ */
    typedef enum logic [3:0] {
        S_IDLE, S_START, S_ADDR, S_REG, S_VAL, S_STOP, S_NEXT, S_WAIT, S_RECOVER
    } st_t;

    st_t         st;
    logic        waiting;
    logic [ 4:0] idx;
    logic [ 7:0] cur_reg, cur_val;
    logic [ 7:0] nack_byte;            // 最近 NACK 的字节（调试）
    logic        abort_done;            // S_WAIT 里那句 STOP 有没有发完（§52.9）
    logic [31:0] wait_cnt;

    /* 恢复时序：半周期拍数 + 相位 + 剩余时钟数 */
    localparam int HOLD_CYC  = CLK_HZ / 10;      // 100 ms：实测阈值
    // ★ 释放之后必须给总线一段"空闲高"的时间：手工恢复之所以有效，是因为恢复完
    //   之后主控还要等完 200 ms 的重试间隔才发 START；第一版 RTL 把 hold 设成 250 ms
    //   （> 200 ms 重试间隔）又紧接着 START，等于总线一直被按着，片子反而没机会应答。
    localparam int GAP_CYC   = CLK_HZ / 50;      // 20 ms：手工实验里每一步之间的间隔
    localparam int SLOW_HALF = CLK_HZ / 500;     // 2 ms 半周期 = 250 Hz 慢时钟（实测有效）
    logic [23:0] rec_cnt;
    logic [ 2:0] rec_ph;
    logic [ 3:0] rec_clk;

    /* ★ 函数调用不能直接取位段（tbl(idx)[15:8] 是语法错），必须先落到一条线上；
     *   而且必须写在 idx 声明**之后**（xvlog 不允许先用后声明）。
     *   同一个坑在 hdmi_timing 的 color_of() 上踩过一次。 */
    wire [15:0] tbl_cur = tbl(idx);

    always_ff @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            waiting    <= 1'b0;
            abort_done <= 1'b0;
            idx        <= 5'd0;
            cur_reg    <= 8'h00;
            cur_val    <= 8'h00;
            nack_byte  <= 8'h00;
            wait_cnt   <= 32'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
            no_dev     <= 1'b1;
            cur_idx    <= 5'd0;
            last_reg   <= 8'h00;
            last_val   <= 8'h00;
            ack_err    <= 16'd0;
            m_start    <= 1'b0;
            m_byte     <= 1'b0;
            m_stop     <= 1'b0;
            m_rw       <= 1'b0;
            m_nack     <= 1'b0;
            m_tx       <= 8'h00;
            r_scl_oe   <= 1'b0;
            r_sda_oe   <= 1'b0;
            rec_active <= 1'b0;
            rec_cnt    <= 24'd0;
            rec_ph     <= 3'd0;
            rec_clk    <= 4'd9;
        end else begin
            /* 请求都是单拍 */
            m_start <= 1'b0;
            m_byte  <= 1'b0;
            m_stop  <= 1'b0;

            case (st)
                S_IDLE: begin
                    busy    <= 1'b0;
                    waiting <= 1'b0;
                    if (start) begin
                        idx      <= 5'd0;
                        busy     <= 1'b1;
                        done     <= 1'b0;
                        no_dev   <= 1'b1;
                        ack_err  <= 16'd0;
                        wait_cnt <= 32'd0;
                        abort_done <= 1'b0;
                        /* 先做总线恢复（§52.15），再开始写表 */
                        rec_ph   <= 3'd0;
                        rec_clk  <= 4'd9;
                        rec_cnt  <= 24'd0;
                        rec_active <= 1'b0;
                        /* 2026-11-21 20:5x：RTL 恢复从来没成功过，先跳过它，
                         * 让 ILA 能抓到一次真实的地址字节（判断 ACK 真假）。 */
                        st       <= S_START;
                    end
                end

                /* ================= 总线恢复：9 拍 SCL + 一个 STOP =================
                 * 相位：
                 *   0  SCL 低（SDA 释放）   1  SCL 高（SDA 释放）—— 重复 rec_clk 次
                 *   2  SCL 低，同时拉低 SDA
                 *   3  SCL 高（SDA 仍低）
                 *   4  释放 SDA（SDA 上升 + SCL 高）= 合法 STOP
                 *   5  收尾，进 S_START
                 * ------------------------------------------------------------------ */
                S_RECOVER: begin
                    /* 实测得出的两个时间尺度（§52.15）：
                     *   · 把两根线**按住 50 ms** 以上 —— 这一步才是把 ADV7511 的
                     *     I2C 从"半截字节"里放出来的关键；
                     *   · STOP 之后的时钟要**慢**（2 ms 半周期），100 kHz 的快速时钟没用。
                     */
                    busy <= 1'b1;
                    if (rec_cnt != 24'd0) begin
                        rec_cnt <= rec_cnt - 24'd1;
                    end else begin
                        case (rec_ph)
                            3'd0: begin                    // 两根都按住（hold）
                                r_scl_oe <= 1'b1;
                                r_sda_oe <= 1'b1;
                                rec_cnt  <= HOLD_CYC[23:0];
                                rec_ph   <= 3'd1;
                            end
                            3'd1: begin                    // 放开 SCL（高），SDA 仍低
                                r_scl_oe <= 1'b0;
                                rec_cnt  <= GAP_CYC[23:0];    // 20 ms（手工实验的间隔）
                                rec_ph   <= 3'd2;
                            end
                            3'd2: begin                    // 放开 SDA = STOP
                                r_sda_oe <= 1'b0;
                                rec_cnt  <= GAP_CYC[23:0];    // 20 ms
                                rec_ph   <= 3'd3;
                            end
                            3'd3: begin                    // 慢时钟：SCL 低
                                r_scl_oe <= 1'b1;
                                rec_cnt  <= SLOW_HALF[23:0];
                                rec_ph   <= 3'd4;
                            end
                            3'd4: begin                    // 慢时钟：SCL 高
                                r_scl_oe <= 1'b0;
                                rec_cnt  <= SLOW_HALF[23:0];
                                if (rec_clk == 4'd0) rec_ph <= 3'd5;
                                else begin rec_clk <= rec_clk - 4'd1; rec_ph <= 3'd3; end
                            end
                            3'd5: begin
                                /* 恢复动作做完 → **不要**马上 START：
                                 * 先把两线释放，空 50 ms 让总线回到空闲高。 */
                                r_scl_oe <= 1'b0;
                                r_sda_oe <= 1'b0;
                                rec_cnt  <= GAP_CYC[23:0];
                                rec_ph   <= 3'd6;
                            end
                            3'd6: begin
                                /* 空闲够了：交还总线，开始写表 */
                                r_scl_oe   <= 1'b0;
                                r_sda_oe   <= 1'b0;
                                waiting    <= 1'b0;
                                rec_active <= 1'b0;
                                st         <= S_START;
                            end
                            default: begin
                                r_scl_oe   <= 1'b0;
                                r_sda_oe   <= 1'b0;
                                waiting    <= 1'b0;
                                rec_active <= 1'b0;
                                st         <= S_START;
                            end
                        endcase
                    end
                end

                S_START: begin
                    /* ★ 必须**等 START 真的做完**再发地址字节。
                     *   第一版在发完 m_start 就直接 st<=S_ADDR，于是 S_ADDR 抓到的
                     *   m_done 其实是 START 的那一拍，而 m_ack 还是复位值 0 ——
                     *   结果每次都判成"地址 NACK"，整表一项都写不进去。
                     *   TB 里表现为 ack_err=1、nwr=0、SCL 只动了一下就停住。 */
                    if (!waiting) begin
                        m_start <= 1'b1;
                        waiting <= 1'b1;
                        /* 顺便把表项取出来，后面直接用 */
                        cur_reg <= tbl_cur[15:8];
                        cur_val <= tbl_cur[7:0];
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        st      <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    if (!waiting) begin
                        m_byte  <= 1'b1;
                        m_rw    <= 1'b0;
                        m_tx    <= {I2C_ADDR, 1'b0};
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        if (!m_ack) begin
                            /* 器件不在（还没上电 / 没接显示器）→ 整表重来 */
                            no_dev  <= 1'b1;
                            nack_byte <= {I2C_ADDR, 1'b0};
                            ack_err <= ack_err + 16'd1;
                            st      <= S_WAIT;
                        end else begin
                            st <= S_REG;
                        end
                    end
                end

                S_REG: begin
                    if (!waiting) begin
                        m_byte  <= 1'b1;
                        m_rw    <= 1'b0;
                        m_tx    <= cur_reg;
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        if (!m_ack) begin
                            nack_byte <= cur_reg;
                            ack_err   <= ack_err + 16'd1;
                            st        <= S_WAIT;
                        end else begin
                            st <= S_VAL;
                        end
                    end
                end

                S_VAL: begin
                    if (!waiting) begin
                        m_byte  <= 1'b1;
                        m_rw    <= 1'b0;
                        m_tx    <= cur_val;
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        /* 写数据字节的 ACK 也检查，但即便 NACK 也继续（不少器件对
                         * 某些只读寄存器会 NACK，不该因此整表失败） */
                        if (!m_ack) begin
                            nack_byte <= cur_val;
                            ack_err   <= ack_err + 16'd1;
                        end else begin
                            no_dev  <= 1'b0;
                            last_reg <= cur_reg;
                            last_val <= cur_val;
                        end
                        st <= S_STOP;
                    end
                end

                S_STOP: begin
                    if (!waiting) begin
                        m_stop  <= 1'b1;
                        waiting <= 1'b1;
                    end else if (m_done) begin
                        waiting <= 1'b0;
                        st      <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    cur_idx <= idx;
                    if (idx == (NTBL - 1)) begin
                        /* 整表写完 */
                        done <= 1'b1;
                        busy <= 1'b0;
                        st   <= S_IDLE;
                    end else begin
                        idx <= idx + 5'd1;
                        st  <= S_START;
                    end
                end

                S_WAIT: begin
                    /* ★★ 2026-11-20 02:20 修：等重试之前**必须先发一个 STOP**。
                     * -----------------------------------------------------------------
                     * 原来的流程是"地址 NACK → 直接进 S_WAIT 等 200 ms → 再来一次 START"。
                     * 问题在于：字节结束时按 i2c_master 的约定总线停在 **SCL 低、SDA 释放**，
                     * 而 NACK 过的从机会**卡在那个字节中间、一直拉低 SDA** —— 于是 200 ms
                     * 里 SCL 被主机按着、SDA 被从机按着，**总线死锁**；下一轮 START 也
                     * 建立不起来，永远 NACK。
                     *
                     * 硬件实测（新增 21 ms 占空比计数，§52.9）：
                     *   SCL = 0/1048576、SDA = 0/1048576  —— 两根线在整个窗口里**都没高过**。
                     *   SCL 低可以由"等待期主机不放线"解释，**SDA 也为 0 只能是从机在按**。
                     *
                     * 修法：进 S_WAIT 后先发 STOP（合法的总线释放），等它 done，再开始计时。
                     * 这是 I2C 的标准恢复动作，对"从机中途复位""器件后插上"都有效。
                     * ----------------------------------------------------------------- */
                    busy <= 1'b0;
                    if (!abort_done) begin
                        if (!waiting) begin
                            m_stop  <= 1'b1;
                            waiting <= 1'b1;
                        end else if (m_done) begin
                            waiting    <= 1'b0;
                            abort_done <= 1'b1;
                        end
                    end else if (wait_cnt >= RETRY_CY[31:0]) begin
                        wait_cnt   <= 32'd0;
                        abort_done <= 1'b0;
                        idx        <= 5'd0;
                        busy       <= 1'b1;
                        /* 重试之前也先做一次总线恢复（从机可能又被卡住）*/
                        rec_ph     <= 3'd0;
                        rec_clk    <= 4'd9;
                        rec_cnt    <= 24'd0;
                        rec_active <= 1'b0;
                        st         <= S_START;   /* 同上：重试时也不跑恢复 */
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
