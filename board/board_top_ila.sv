`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * board_top_ila.sv — EES-331 上的“被观测设计”顶层（MMCM 100→50MHz + CPU + 存储器）
 * -----------------------------------------------------------------------------
 * 本文件**不含 ILA**，只把 CPU/存储器与调试量引到端口：工程模式顶层 board_top_gui.sv
 *   拿 sys_clk_50m 当采样时钟、拿 debug_* 当 ILA 的 probe。一个调试信号都不引到引脚
 *   （观察全靠片内 ILA 经 JTAG 抓），顶层只剩 3 个引脚，摆脱了 EES-331 上 DDR3/QSPI/
 *   以太网/USB 吃掉大半 PL 引脚的问题；计数器也因此保持**全 32 位**（上一版
 *   board_top_vivado.sv 把 4 个计数器截成 8 位引到引脚上）。沿革：§BOARDILA-1。
 *
 * ★ 时钟（EES-331 用户手册 §5 系统时钟）：板载 FPGA_CLK0 = **100MHz**（引脚 M19，有源
 *   晶振），而本设计实测 Fmax 只有 ~67.95MHz（syn/vivado_50mhz_实测.md §3），直接拿
 *   100MHz 跑不了，故用 MMCME2_BASE 分频：VCO = 100MHz × CLKFBOUT_MULT_F(10) /
 *   DIVCLK_DIVIDE(1) = **1000MHz**；CLKOUT0 = VCO / CLKOUT0_DIVIDE_F(20) = **50MHz**。
 *   50MHz 是本次验证目标；以后提频只改这两个参数，不换晶振。
 *
 * ★ 引脚（取手册“管脚约束表”，**不要用原理图位号**）：sys_clk ← M19（PL 时钟 100MHz）·
 *   btn_rst_n ← L18（§21 PL 按键 S1，标号 FPGA_RESET，4.7K 上拉、按下为低）· debug_dead →
 *   不用接（或接 LED 当心跳）。别混：SW0~SW7 那 8 个拨码开关是 AB6/Y4/AA4/R6/T6/T4/U4/V5。
 *   历史的坑：按键曾误写成 PACKAGE_PIN S5（'S5' 是原理图位号、不是引脚名），约束真被读进
 *   设计时才报 CRITICAL WARNING [Common 17-69]，原文见 §BOARDILA-2。
 *
 * ★ 复位极性：EES-331 的 PL 按键是上拉 + 按下接地（按下为低），与 reset_sync 要的
 *   rst_n_async（低有效）**直接对得上**，不需要反相（ZedBoard 的 BTNC 才需要反相）。
 * ============================================================================= */
module board_top_ila #(
    // IROM 字数（4096 字 = 16KB）
    parameter IROM_WORDS = 4096,
    // DRAM 字数（16384 字 = 64KB）
    parameter DRAM_WORDS = 16384,
    // 程序镜像（hex 文本，$readmemh 载入 IROM；Vivado 会把它变成 BRAM 初值）
    parameter IROM_INIT  = "prog.hex"
) (
    // 板载 100MHz 时钟（M19 / FPGA_CLK0）
    input  logic sys_clk,
    // 板载按键复位，低有效（L18 / FPGA_RESET，上拉，按下为低）
    input  logic btn_rst_n,

    // 系统时钟引出（50MHz，MMCM 分频后经 BUFG）。
    // ★ 不变量：这个口是给上层 ILA 当 sample clock 的 —— ILA 采样时钟必须与被观测信号
    //   **同源同频**（CPU 跑在 50MHz 上，拿 100MHz 采样到的是异步数据，波形不可信）。
    //   它原来是模块内部的局部信号、外面取不到，故开输出口；纯组合，无额外逻辑。
    output logic sys_clk_50m,

    // 13 个调试观察口（只是把原来的内部线网引出来，逻辑零改动）：这些量原来只在模块内
    //   汇总成 debug_dead，外面取不到；工程模式的 ILA 是**标准 IP 例化**在上层顶里的，
    //   必须能从端口拿到。宽度 / 顺序与 board_top.sv 一致（probe 编号见 board_top_gui.sv）。
    // ★ 不变量：debug_dead 仍然把它们或到一起，ILA 的 probe 是**真实负载**，故一定保留
    //   （早先那版只靠 keep、顶层又没负载，13 组只剩 3 组 —— §BOARDILA-3）。
    output logic        debug_wb_have_inst,
    output logic [31:0] debug_wb_pc,
    output logic        debug_wb_ena,
    output logic [ 4:0] debug_wb_reg,
    output logic [31:0] debug_wb_value,

    output logic [31:0] debug_icache_hit_cnt,
    output logic [31:0] debug_icache_miss_cnt,
    output logic [31:0] debug_dcache_hit_cnt,
    output logic [31:0] debug_dcache_miss_cnt,

    output logic [31:0] debug_mcause,
    output logic [31:0] debug_mepc,
    output logic [31:0] debug_mtval,
    output logic        debug_trap_take,

    // v9 新增（B9）：重定向诊断三根线（工程模式版因此加到 16 个探针）。上板 ILA 抓到
    //   "ecall 之后 PC 从不回到 mtvec"，只看 debug_wb_pc 分不清是①Control 没发出重定向
    //   请求，还是②请求被 IFU 的 `dnpc_flag & ready` 门控吃掉（ready=0 那一拍）；仿真里靠
    //   这三根定位，真凶是②（见 IFU.sv 的 B9）。引到顶层是为了让同样的判定在真实硬件上
    //   也能做：
    //     debug_dnpc_flag = dnpc_flag(1b) · debug_ready = IDU_ready(1b) · debug_ifu_pc = IFU PC(32b)
    //   三根同样并进 debug_dead，保证有真实负载、不会被综合优化掉。
    output logic        debug_dnpc_flag,
    output logic        debug_ready,
    output logic [31:0] debug_ifu_pc,

    // 唯一的一根"假"输出，不接任何东西（或接一个 LED 当心跳灯）。
    // ★ 不变量：debug_dead **必须存在**，且必须把全部调试量或（OR）进来。
    //   原因：本设计对外**一个信息都不需要输出**（观察全靠 ILA），而 Vivado 综合对"顶层
    //   没有负载"的调试信号会**直接优化掉** —— 实测只加 (* mark_debug *)/(* keep *) 属性
    //   时，13 组调试网络**只剩 3 组**（恰好是 1 位宽、驱动侧没被连带删掉的那几个），其余
    //   10 组 32 位的全部消失，ILA 直接无信号可抓。全部或到这一根引脚后，每一位都在
    //   output 的锥里，综合不敢删，引脚也仍然只占 1 根；它顺带是"心跳灯"（CPU 在跑就为高）。
    //   日志原文（Synth 8-4446）：syn/修复史_全量.md §BOARDILA-3
    output logic debug_dead
);

    /* ---------------- 1) 100MHz 输入 → 50MHz 系统时钟（MMCM） ---------------- */
    logic clk_in_buf;      // 100MHz，经 IBUF 后
    logic clkfb;           // MMCM 反馈
    logic mmcm_locked;     // MMCM 锁定标志
    logic clk_sys_unbuf;   // 50MHz，MMCM 输出（未上全局时钟网络）
    logic rst_n;

    // 输入时钟缓冲（IBUF：把 M19 的时钟引进 FPGA 内部时钟网络）
    IBUF clk_ibuf_inst (
        .I (sys_clk),
        .O (clk_in_buf)
    );

    // MMCM：100MHz → 50MHz（VCO = 100×10 = 1000MHz，CLKOUT0 = VCO/20 = 50MHz；见文件头）
    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (10.000),
        .CLKFBOUT_PHASE     (0.000),
        .CLKIN1_PERIOD      (10.000),   // 输入 100MHz = 10ns
        .CLKOUT0_DIVIDE_F   (20.000),   // 输出 50MHz = 20ns
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .DIVCLK_DIVIDE      (1),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) mmcm_inst (
        .CLKOUT0  (clk_sys_unbuf),
        .CLKOUT0B (),
        .CLKOUT1  (),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .LOCKED   (mmcm_locked),
        .CLKIN1   (clk_in_buf),
        // ★ 不变量：CLKFBIN 必须接回 CLKFBOUT（clkfb）—— MMCM 的内部反馈环靠它闭合，
        //   这是实测踩到的接线坑。漏接的后果：综合只给一句很容易被忽略的告警（Synth 8-7071
        //   port 'CLKFBIN' ... is unconnected），反馈环断开、时钟根本不锁定，LOCKED 恒 0 →
        //   下面的 rst_n 恒为低 → CPU 永远停在复位态，上板现象是"什么动静都没有"。
        //   告警原文：syn/修复史_全量.md §BOARDILA-4
        .CLKFBIN  (clkfb),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    // MMCM 输出必须经 BUFG 上全局时钟网络，否则 Vivado 会报时钟不在 BUFG 上
    BUFG clk_bufg_inst (
        .I (clk_sys_unbuf),
        .O (sys_clk_50m)
    );

    /* ---------------- 2) 复位：按键 + MMCM 未锁定都算复位 ---------------- */
    // ★ 不变量：rst_n = btn_rst_n & mmcm_locked —— 必须把 mmcm_locked 并进来。
    //   原因：MMCM 锁定前输出时钟不稳，这段时间 CPU 必须保持在复位态，否则会跑飞。
    //   也正因为这一条，上面 CLKFBIN 一旦漏接就表现为"整机毫无动静"。
    assign rst_n = btn_rst_n & mmcm_locked;

    /* ---------------- 3) CPU + 同步存储器（沿用 board_top，逻辑未改） -------- */
    // board_top 的 13 个 debug_* 输出直连本模块的同名输出口（再往上层给 ILA 当 probe），
    //   同时汇总到 debug_dead 做心跳 —— 两处都有真实负载。
    board_top #(
        .IROM_WORDS (IROM_WORDS),
        .DRAM_WORDS (DRAM_WORDS),
        .IROM_INIT  (IROM_INIT)
    ) u_board_top (
        .sys_clk               (sys_clk_50m),
        .btn_rst_n             (rst_n),

        .debug_wb_have_inst    (debug_wb_have_inst),
        .debug_wb_pc           (debug_wb_pc),
        .debug_wb_ena          (debug_wb_ena),
        .debug_wb_reg          (debug_wb_reg),
        .debug_wb_value        (debug_wb_value),

        .debug_icache_hit_cnt  (debug_icache_hit_cnt),
        .debug_icache_miss_cnt (debug_icache_miss_cnt),
        .debug_dcache_hit_cnt  (debug_dcache_hit_cnt),
        .debug_dcache_miss_cnt (debug_dcache_miss_cnt),

        .debug_mcause          (debug_mcause),
        .debug_mepc            (debug_mepc),
        .debug_mtval           (debug_mtval),
        .debug_trap_take       (debug_trap_take),

        // v9 + ILA（B9）：重定向诊断三根线
        .debug_dnpc_flag       (debug_dnpc_flag),
        .debug_ready           (debug_ready),
        .debug_ifu_pc          (debug_ifu_pc)
    );

    /* ---------------- 4) 调试量汇总 → 唯一输出（心跳 + 防优化双保险） -------- */
    // 注：早期这里（probe11 / debug_mtval）恒 0，是 CSR.mtval 漏驱动所致；现已在 CSR.sv
    //   补上 `assign mtval_out = mtval_reg;`，抓到的是真实值。历史见 syn/修复史_全量.md §BOARDILA-5
    assign debug_dead = |{debug_wb_have_inst, debug_wb_ena,
                          debug_wb_pc, debug_wb_reg, debug_wb_value,
                          debug_icache_hit_cnt, debug_icache_miss_cnt,
                          debug_dcache_hit_cnt, debug_dcache_miss_cnt,
                          debug_mcause, debug_mepc, debug_mtval,
                          debug_trap_take,
                          // v9 新增（B9）：重定向诊断三根线也并进心跳 OR，
                          //   保证它们都有真实负载（否则综合会把没负载的网删掉）
                          debug_dnpc_flag, debug_ready, debug_ifu_pc};

endmodule
