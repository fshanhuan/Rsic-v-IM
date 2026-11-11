`timescale 1ns / 1ps

/* =============================================================================
 * board/ps_ctrl.sv -- AXI 侧的"控制平面"寄存器（双核协同 第 1/2/3 步共用）
 * -----------------------------------------------------------------------------
 * 为什么需要这个模块：
 *   #6/#7 让 PS 能读写 RISC-V 的 128 KB DRAM，但**没有控制面** —— PS 只能往内存里
 *   灌数据，无法告诉 CPU"准备好了"、也无法把 CPU 按在复位里等自己灌完。
 *   128 KB DRAM 只占 BD 窗口（256 KB）的**一半**，地址 0x2_0000..0x3_FFFF 是空的，
 *   正好拿来放控制寄存器，**不动 DRAM 的译码**（`addr[17]==0` 才是 DRAM）。
 *
 * 寄存器（PS 视角，基址 = BD 里给的 0x4000_0000）：
 *   0x4002_0000  CTRL   RW
 *                 bit0 = HOLD      1 = 把 CPU 按在复位里（**复位值 1**，见下）
 *                 bit1 = PS_IRQ    电平，经 PLIC 源 4 打断 CPU
 *                 bit2 = CLR_ALIVE 写 1 → 清 STATUS.alive（PS 重新开始一次装载时用）
 *   0x4002_0004  STATUS RO
 *                 [31:16] = MAGIC 0xB155（确认窗口在位/没被 DRAM 回卷吃掉的探针）
 *                 [7] = PS_IRQ 回读   [6] = ALIVE（CPU 的 stub 报过到）
 *                 [5] = plic_irq      [4] = boot_busy
 *                 [3] = cpu_rst_eff   [2] = irq_ps（CPU 敲 PS 的电平）
 *                 [0] = HOLD 回读
 *   0x4002_0008  SCRATCH RW  32 位便条（PS 自用/调试）
 *
 * ★ 为什么 HOLD 复位值是 1（而不是 0）：
 *   如果默认 0，FPGA 配置完 CPU 立刻从 IROM 的 stage-0 stub 跑，而此刻 DRAM 里的
 *   镜像还是空的 → stub 会把 IMEM 前 20 KB 抄成 0，**包括复位向量 word0**
 *   （stub 的 `jal` 在那儿）。之后再按复位也回不去了：word0 已经是非法指令。
 *   默认按住 CPU 就没有这个窗口：PS 灌完 → 写 HOLD=0 → CPU 从干净的镜像启动。
 *   代价：AXIL_EN=1 的板子**必须有主机来放行**（仿真里由 TB 写一下）。
 *
 * ★ 握手（与 board/axil_slave.sv 的简单总线契约一致）：
 *   s_req 保持到 s_gnt；本模块**当拍**给 s_gnt（组合），下一拍给 s_rvalid 单拍脉冲。
 *   写：授权当拍落盘。
 * ============================================================================= */
module ps_ctrl (
    input  logic        clk,
    input  logic        aresetn,

    // ---- 来自 board/axil_slave.sv 的简单总线侧（地址是 BD 窗口内的本地偏移）----
    input  logic [31:0] s_addr,
    input  logic        s_req,
    input  logic        s_we,
    input  logic [31:0] s_wdata,
    output logic        s_gnt,
    output logic        s_rvalid,
    output logic [31:0] s_rdata,

    // ---- 观测/控制（同一时钟域，50 MHz）----
    input  logic        cpu_rst_eff,
    input  logic        boot_busy,
    input  logic        plic_irq,
    input  logic        irq_ps,        // CPU → PS，来自 MMIO 0x1000_001C bit1
    input  logic        cpu_alive,     // stage-0 stub 写 MMIO 0x1000_001C bit2 置位
    output logic        hold,          // → cpu_rst_eff
    output logic        ps_irq,        // → PLIC 源 SOC_IRQ_PS
    output logic        alive_clr,     // 一拍脉冲：PS 要求清"CPU 已到岗"标志
    output logic        irq_ps_clr     // 一拍脉冲：PS 收下 CPU 的中断后清 irq_ps
);

    localparam logic [15:0] MAGIC = 16'hB155;

    /* 控制窗口：BD 窗口内 0x2_0000 以上（DRAM 只用 0x0_0000..0x1_FFFF）。
     * 用 addr[17] 一位译码就够，且与 soc_map 的"128 KB DRAM"严格互补。 */
    logic ctrl_sel;
    assign ctrl_sel = s_addr[17];

    logic [1:0] ridx;
    assign ridx = s_addr[4:2];

    /* ---------------- 寄存器 ---------------- */
    logic        hold_r, ps_irq_r;
    logic [31:0] scratch_r;

    logic        wr;
    assign wr = s_req & s_we & ctrl_sel;

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            hold_r    <= 1'b1;          // ★ 默认按住 CPU，见头部说明
            ps_irq_r  <= 1'b0;
            scratch_r <= 32'h0;
        end else if (wr) begin
            case (ridx)
                // CTRL：bit0 HOLD / bit1 PS_IRQ / bit2 CLR_ALIVE
                2'd0: begin
                    hold_r   <= s_wdata[0];
                    ps_irq_r <= s_wdata[1];
                    // bit2 是对 STATUS.alive 的清零（alive 的**置位**在 CPU 侧）
                end
                2'd2: scratch_r <= s_wdata;
                default: ;                       // STATUS 只读；写忽略
            endcase
        end
    end

    assign hold   = hold_r;
    assign ps_irq = ps_irq_r;

    assign alive_clr = wr & (ridx == 2'd0) & s_wdata[2];

    /* ★ 双向中断的"握手"：irq_ps 是**电平**（GIC 的 SPI 就是电平敏感）。
     *   如果 PS 不能清它，GIC 会一直保持挂起 → 中断风暴。
     *   所以 PS 的 ISR 做完事之后写 CTRL.bit3=1 → 本模块给一拍脉冲 →
     *   board_top 把 irq_ps_r 清 0 → 线拉低 → GIC 自然退出。
     *   （CPU 侧只会把它**置 1**，从不自己清 —— 生产者/消费者分工明确。） */
    assign irq_ps_clr = wr & (ridx == 2'd0) & s_wdata[3];

    /* ---------------- 读通道：授权下一拍给 rvalid ---------------- */
    logic [31:0] rdata_r;
    logic        rvalid_r;

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            rdata_r  <= 32'h0;
            rvalid_r <= 1'b0;
        end else begin
            rvalid_r <= s_req & ~s_we & ctrl_sel;
            if (s_req & ~s_we & ctrl_sel) begin
                case (ridx)
                    2'd0: rdata_r <= {31'b0, hold_r};
                    2'd1: rdata_r <= {MAGIC, 8'h00,
                                      ps_irq_r,              // [7]
                                      cpu_alive,             // [6]
                                      plic_irq,              // [5]
                                      boot_busy,             // [4]
                                      cpu_rst_eff,           // [3]
                                      irq_ps,                // [2]
                                      1'b0,                  // [1]
                                      hold_r};               // [0]
                    2'd2: rdata_r <= scratch_r;
                    default: rdata_r <= 32'h0;
                endcase
            end
        end
    end

    assign s_rvalid = rvalid_r;
    assign s_rdata  = rdata_r;
    assign s_gnt    = s_req & ctrl_sel;   // 当拍授权（写当拍落盘 / 读下一拍回数据）

endmodule
