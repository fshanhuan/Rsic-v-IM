`timescale 1ns / 1ps

/* =============================================================================
 * i2c_master.sv — 极简 I2C 主机（字节级原语）
 * -----------------------------------------------------------------------------
 * 为什么自己写而不是用 Xilinx AXI IIC IP：
 *   · IP 要走 AXI/BD，而本设计的 PS 是**主**、PL 是**从**，加一个 AXI 主设备
 *     要开 S_AXI_HP 口、改 BD —— 为了读 3 个寄存器不值；
 *   · 自己写 150 行，iverilog 能直接仿真（IP 不能），迭代周期从 30 分钟降到 1 秒；
 *   · 后面 RISC-V 要按 MMIO 读写它，寄存器口比 AXI 事务口好用得多。
 *
 * ★ 接口是"一次一个操作"，不是"一次一个事务"：
 *     start_req / byte_req / stop_req 三个脉冲，各自在完成时给一个 done 脉冲。
 *   上层（i2c_probe / CPU）自己按协议拼 START → 字节 → 重复 START → 字节 → STOP。
 *   这样这一层不需要知道"寄存器地址""7 位还是 10 位地址"这些概念，
 *   ADV7511、ADAU1761、EEPROM 都能复用。
 *
 * ★ 开漏语义：输出是 scl_oe / sda_oe，**1 = 拉低**，0 = 释放（靠板上上拉电阻）。
 *   顶层用 IOBUF 把 sda_oe 变成真正的双向脚；本模块内部只处理"驱动/释放"。
 *   这个约定让仿真里不用建模三态。
 *
 * ★ 时序：每个 SCL 半周期 = HALF = CLK_HZ/(SCL_HZ*2) 个时钟。
 *   50 MHz / 100 kHz → HALF = 250。一个字节（8 数据 + 1 ACK）= 4500 拍 = 90 us。
 *
 * ★ 结束状态不变量（上层拼协议全靠这个）：
 *   · S_START_C 结束：SCL 低、SDA 低   → 可以直接接一个字节
 *   · 字节结束       ：SCL 低、SDA 释放 → 可以直接接 STOP 或重复 START
 *   · S_STOP_C 结束  ：SCL 高、SDA 高   → 总线空闲
 *
 * ★ 每个状态内 scl_oe/sda_oe 的物理含义必须与状态名一致：
 *     S_x_L 期间 SCL 恒为低；S_x_H 期间 SCL 恒为高。
 *   电平在**进入下一个状态的那一拍**才翻转（见每个 if(tick) 里的赋值），
 *   这样"数据在 SCL 低时改变"这条 I2C 铁律是被状态机结构保证的，
 *   而不是靠注释提醒 —— 上一版就是因为把翻转写在 L 态入口，变成了
 *   "SCL 还高就改数据"，被自己在评审里抓出来。
 *
 * ★ 已知取舍：没有时钟延展（slave 拉低 SCL）、没有总线仲裁、没有毛刺滤波。
 *   100 kHz 单主机场景下三者都不需要；要接多主机总线再补。
 * ============================================================================= */
module i2c_master #(
    parameter int CLK_HZ = 50_000_000,
    parameter int SCL_HZ = 100_000
) (
    input  logic       clk,
    input  logic       rst,          // 同步复位，高有效

    /* ---- 操作请求（各一个单拍脉冲，同一时刻只能给一个）---- */
    input  logic       start_req,    // START / 重复 START
    input  logic       byte_req,     // 传输 1 个字节（含其 ACK 位）
    input  logic       stop_req,     // STOP（只能在 SCL 低时发，即字节结束后）

    /* ---- 字节操作的参数 ---- */
    input  logic       byte_rw,      // 0 = 主机写（从机 ACK），1 = 主机读（主机 ACK/NACK）
    input  logic       read_nack,    // 读字节时回 NACK（最后一个字节用 1）
    input  logic [7:0] byte_tx,      // 写字节的数据

    /* ---- 结果 ---- */
    output logic [7:0] byte_rx,      // 读字节的数据
    output logic       ack_rx,       // 写字节时从机的响应：1 = ACK，0 = NACK
    output logic       busy,         // 一个操作正在进行
    output logic       done,         // 操作完成，单拍脉冲

    /* ---- 引脚（开漏，1 = 拉低）---- */
    output logic       scl_oe,
    output logic       sda_oe,
    input  logic       sda_i         // 经 IOBUF 回来的总线电平
);

    /* ------------------------------ 时序参数 ------------------------------ */
    localparam int HALF = CLK_HZ / (SCL_HZ * 2);

    typedef enum logic [3:0] {
        S_IDLE,
        S_START_A, S_START_B, S_START_C,
        S_WBIT_L,  S_WBIT_H,
        S_WACK_L,  S_WACK_H,
        S_RBIT_L,  S_RBIT_H,
        S_RACK_L,  S_RACK_H,
        S_STOP_A,  S_STOP_B,  S_STOP_C
    } state_t;

    state_t      st;
    logic [15:0] tcnt;
    logic [2:0]  biti;
    logic [7:0]  sh;
    logic        nack_r;

    wire tick = (tcnt == 16'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            st      <= S_IDLE;
            tcnt    <= 16'd0;
            biti    <= 3'd0;
            sh      <= 8'd0;
            nack_r  <= 1'b0;
            scl_oe  <= 1'b0;
            sda_oe  <= 1'b0;
            busy    <= 1'b0;
            done    <= 1'b0;
            ack_rx  <= 1'b0;
            byte_rx <= 8'd0;
        end else begin
            done <= 1'b0;
            if (tcnt != 16'd0) tcnt <= tcnt - 16'd1;

            case (st)
                /* ------------------------------ 空闲 ------------------------------
                 * ★ 绝对不能在 IDLE 里"释放" SCL/SDA。
                 *   一个操作结束后，引脚状态是上一个状态的**结果**，IDLE 必须原样保持：
                 *   START 之后是"SCL 低、SDA 低"，字节之后是"SCL 低、SDA 释放"，
                 *   STOP 之后才是"SCL 高、SDA 高"。
                 *   第一版在这里写了 scl_oe<=0/sda_oe<=0，结果 START 一结束 SCL 就被抬回
                 *   高电平、SDA 随后被释放 → 线上出现一个假的 STOP，从机直接回 IDLE。
                 *   仿真里表现为"扫描一个地址都不应答"，正是本文件开头说的那类坑。
                 *   复位值已经是"释放"，所以 IDLE 不需要再写这两根线。
                 * ----------------------------------------------------------------- */
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_req) begin
                        /* ★ 重复 START 的关键：必须先把 SCL 释放成高电平。
                         *   字节结束时我们处在"SCL 低、SDA 释放"，若直接拉低 SDA，
                         *   得到的是 SCL 低时的数据变化（非法），而不是起始条件。
                         *   S_START_A 先把两根线都释放 → S_START_B 在 SCL 高时拉低 SDA
                         *   → 这才是合法的 (重复) START。 */
                        busy   <= 1'b1;
                        scl_oe <= 1'b0;
                        sda_oe <= 1'b0;
                        tcnt   <= HALF - 1;
                        st     <= S_START_A;
                    end else if (byte_req) begin
                        busy   <= 1'b1;
                        biti   <= 3'd7;
                        sh     <= byte_tx;
                        nack_r <= read_nack;
                        tcnt   <= HALF - 1;
                        /* 写：进 L 态前就把第 7 位摆上（此时 SCL 低，合法）
                         * 读：L 态只是释放 SDA，不需要预置数据 */
                        if (byte_rw) begin
                            sda_oe <= 1'b0;
                            st     <= S_RBIT_L;
                        end else begin
                            sda_oe <= ~byte_tx[7];
                            st     <= S_WBIT_L;
                        end
                    end else if (stop_req) begin
                        busy   <= 1'b1;
                        sda_oe <= 1'b1;      // 先把 SDA 拉低（SCL 低时）
                        scl_oe <= 1'b1;
                        tcnt   <= HALF - 1;
                        st     <= S_STOP_A;
                    end
                end

                /* ------------------------------ START -----------------------------
                 * A：等一段（总线应为高/高）；结束时把 SDA 拉低 = 起始条件
                 * B：SCL 保持高；结束时把 SCL 拉低
                 * C：SCL 低、SDA 低 —— 可以开始传字节
                 * ----------------------------------------------------------------- */
                S_START_A: if (tick) begin sda_oe <= 1'b1; tcnt <= HALF - 1; st <= S_START_B; end
                S_START_B: if (tick) begin scl_oe <= 1'b1; tcnt <= HALF - 1; st <= S_START_C; end
                S_START_C: if (tick) begin done <= 1'b1; busy <= 1'b0; st <= S_IDLE; end

                /* ---------------------------- 写一个字节 ---------------------------
                 * 进入 WBIT_L 时 SDA 已经摆好（由上一个态的出口或 IDLE 完成），
                 * WBIT_L 只负责等 SCL 低的那半个周期；出口把 SCL 抬高。
                 * WBIT_H 让 SCL 保持高一整个半周期（从机采样），
                 * 出口的同一拍把 SCL 拉低**并**摆下一位 —— 两个动作同在 SCL 低，
                 * 满足"数据只在 SCL 低时变化"。
                 * ----------------------------------------------------------------- */
                S_WBIT_L: if (tick) begin scl_oe <= 1'b0; tcnt <= HALF - 1; st <= S_WBIT_H; end
                S_WBIT_H: if (tick) begin
                    scl_oe <= 1'b1;                       // SCL 低
                    if (biti == 3'd0) begin
                        sda_oe <= 1'b0;                   // 释放 SDA，让从机回 ACK
                        tcnt   <= HALF - 1;
                        st     <= S_WACK_L;
                    end else begin
                        biti   <= biti - 3'd1;
                        sda_oe <= ~sh[biti - 3'd1];       // 下一位，SCL 已低
                        tcnt   <= HALF - 1;
                        st     <= S_WBIT_L;
                    end
                end

                /* 第 9 拍：从机拉低 = ACK。在 SCL 高电平的末尾（tick 那拍）采样。 */
                S_WACK_L: if (tick) begin scl_oe <= 1'b0; tcnt <= HALF - 1; st <= S_WACK_H; end
                S_WACK_H: if (tick) begin
                    scl_oe <= 1'b1;                       // SCL 低 = 字节结束
                    ack_rx <= ~sda_i;
                    done   <= 1'b1;
                    busy   <= 1'b0;
                    st     <= S_IDLE;
                end

                /* ---------------------------- 读一个字节 --------------------------- */
                S_RBIT_L: if (tick) begin scl_oe <= 1'b0; tcnt <= HALF - 1; st <= S_RBIT_H; end
                S_RBIT_H: if (tick) begin
                    sh[biti] <= sda_i;                    // SCL 高电平末尾采样
                    scl_oe   <= 1'b1;
                    if (biti == 3'd0) begin
                        tcnt <= HALF - 1;
                        st   <= S_RACK_L;
                    end else begin
                        biti <= biti - 3'd1;
                        tcnt <= HALF - 1;
                        st   <= S_RBIT_L;
                    end
                end

                /* 第 9 拍：主机回 ACK(0) 或 NACK(1) */
                S_RACK_L: if (tick) begin sda_oe <= nack_r; tcnt <= HALF - 1; st <= S_RACK_H; end
                S_RACK_H: if (tick) begin
                    scl_oe  <= 1'b1;                      // SCL 低
                    sda_oe  <= 1'b0;                      // 释放总线
                    byte_rx <= sh;
                    done    <= 1'b1;
                    busy    <= 1'b0;
                    st      <= S_IDLE;
                end

                /* ------------------------------ STOP -----------------------------
                 * 进入时 SCL 低、SDA 已被拉低（见 IDLE 的 stop 分支）。
                 * A 段保持；B 段抬 SCL；C 段释放 SDA → SCL 高时 SDA 上升 = 停止条件。
                 * ----------------------------------------------------------------- */
                S_STOP_A: if (tick) begin scl_oe <= 1'b0; tcnt <= HALF - 1; st <= S_STOP_B; end
                S_STOP_B: if (tick) begin sda_oe <= 1'b0; tcnt <= HALF - 1; st <= S_STOP_C; end
                S_STOP_C: if (tick) begin scl_oe <= 1'b0; done <= 1'b1; busy <= 1'b0; st <= S_IDLE; end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
