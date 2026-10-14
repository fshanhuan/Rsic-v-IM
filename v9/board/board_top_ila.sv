`include "para.sv"
`timescale 1ns / 1ps

/* =============================================================================
 * board_top_ila.sv — v9 在 EES-331 板上的顶层（ILA 版，不引出任何调试引脚）
 * -----------------------------------------------------------------------------
 * 设计意图（与 board_top_vivado.sv 的取舍正好相反）：
 *   上一版为了"少占引脚"，把 4 个 32 位性能计数器截成 8 位引到引脚上。
 *   本版**一个调试信号都不引到引脚**：全部交给片内 ILA（Integrated Logic Analyzer）
 *   通过 JTAG 抓取。这样带来三个好处：
 *     1) 顶层只剩 3 个引脚，彻底摆脱 EES-331 上 DDR3/QSPI/以太网/USB 把 PL 引脚
 *        吃掉一大半的问题；
 *     2) 计数器可以保持**全 32 位**，不再有"8 位 256 次回绕"的精度损失；
 *     3) myCPU 里原来**悬空没人接**的 debug_mcause/debug_mepc/debug_mtval/
 *        debug_trap_take 四个异常现场口，现在终于能被观察到了。
 *   ILA 的抓取信号由 myCPU 调试端口上的 (* mark_debug = "true" *) 标记决定，
 *   在实现阶段由 build_ila.tcl 自动插入 —— 本文件里看不到 ILA 例化，这是
 *   Vivado 的标准调试流程（mark_debug → create_debug_core → implement_debug_core）。
 *
 * ★ 时钟（EES-331 用户手册 §5 系统时钟）：
 *     板载给 PL 的时钟 FPGA_CLK0 = **100MHz**（引脚 M19，有源晶振）。
 *   而本设计实测 Fmax 只有 ~67.95MHz（见 syn/vivado_50mhz_实测.md §3），
 *   **直接拿 100MHz 当时钟跑不了**。所以这里用 MMCME2_BASE 把 100MHz
 *   分频成 50MHz：VCO = 100MHz × 10 = 1000MHz，CLKOUT0 = 1000 / 20 = 50MHz。
 *   50MHz 是本次验证的目标频率；等内容收敛后再逐步提高（改 CLKFBOUT_MULT_F /
 *   CLKOUT0_DIVIDE_F 即可，不用换晶振）。
 *
 * ★ 引脚（均来自 EES-331 用户手册的"管脚约束表"，**不要用原理图位号**）：
 *   sys_clk    ← M19   §5 PL 时钟 FPGA_CLK0，100MHz
 *   btn_rst_n  ← L18   §21 PL 按键 S1，标号 FPGA_RESET，4.7K 上拉、按下为低
 *   debug_dead → 不用接
 *   注意：手册里按键画的是 S1，而 SW0~SW7 那 8 个**拨码开关**是 AB6/Y4/AA4/R6/
 *   T6/T4/U4/V5，两者不是一回事，别混。
 *   另：曾经误写成 PACKAGE_PIN S5 —— 'S5' 是**原理图位号**，Vivado 直接报
 *     CRITICAL WARNING: [Common 17-69] Command failed: 'S5' is not a valid site
 *     or package pin name.
 *   这类错误只有当约束真的被读进设计时才暴露，务必以手册的"FPGA IO 约束"列为准。
 *
 * ★ 复位极性（重要）：
 *   EES-331 的 PL 按键是**上拉 + 按下接地**，即按下为低，与 reset_sync 要的
 *   rst_n_async（低有效）**直接对得上**，不需要反相。
 *   （对比 ZedBoard 的 BTNC 是高有效，那个才需要反相。这块板不需要。）
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

    // ---------------------------------------------------------------------
    // 系统时钟引出（50MHz，MMCM 分频后经 BUFG）。
    //
    // 为什么加这个口（工程模式版加的，逻辑一点没改）：
    //   ILA 的采样时钟必须**和被观测信号同源同频**。CPU 跑在 MMCM 出来的
    //   50MHz 上，如果拿板载 100MHz 去采样，抓到的数据是异步跨时钟的，
    //   触发和波形都不可信。而这个时钟原来是模块内部的局部信号，外面取不到，
    //   所以专门开一个输出口给上层顶例化 ILA 用（见 project_src/board_top_gui.sv）。
    //   纯组合输出，不引入任何额外逻辑，也不影响非工程模式那条链路
    //   （build_ila.tcl 里 ILA 时钟取自综合网表里的 net sys_clk_50m，同名同源）。
    // ---------------------------------------------------------------------
    output logic sys_clk_50m,

    // ---------------------------------------------------------------------
    // 13 个调试观察口（工程模式版新增，只是把原来的内部线网引出来，逻辑零改动）。
    //
    // 为什么要引出来：
    //   这些量原来只在模块内部汇总成 debug_dead，外面取不到。工程模式的 ILA
    //   是**标准 IP 例化**在上层顶（project_src/board_top_gui.sv）里的，
    //   必须能从端口拿到这些信号，所以在这里开出来。
    //   宽度 / 顺序与 board_top.sv 完全一致，名字也一致，方便对照。
    //
    //   ★ 顺带说明为什么现在不怕综合把它们优化掉：
    //     本模块的 debug_dead 仍然把这些量或到一起（见文件末尾），
    //     而 ILA 的 probe 端口是它们的**真实负载**，所以综合一定保留。
    //     （早先那版只靠 keep 属性、顶层又没负载，13 组只剩 3 组。）
    //
    //   ★ probe11 / debug_mtval 目前抓不到有效值：v9 的 CSR.mtval 在 RTL
    //     层面从未被写。这是 RTL 待修项，见 ../syn/上板改造说明.md。
    // ---------------------------------------------------------------------
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

    // ---------------------------------------------------------------------
    // 唯一的一根"假"输出，不接任何东西（或接一个 LED 也行）。
    //
    // 为什么非要它 —— 这是本工程实测踩出来的一个关键坑：
    //   本设计对外**一个信息都不需要输出**（观察全靠 ILA）。但 Vivado 综合
    //   对"顶层没有负载"的调试信号会**直接优化掉**：实测第一版只加了
    //   (* mark_debug *)/(* keep *) 属性，综合后 13 组调试网络**只剩 3 组**
    //   （debug_wb_have_inst / debug_wb_ena / debug_trap_take，恰好是 1 位宽、
    //   且驱动侧没被连带删掉的那几个），其余 10 组 32 位的全部消失 →
    //   ILA 直接无信号可抓。日志里只有一句很不起眼的
    //     WARNING: [Synth 8-4446] all outputs are unconnected for this instance
    //     and logic may be removed
    //   所以必须给这些调试量一个**真实存在的负载**。
    //
    // 做法：把全部调试量或（OR）到一起送到这根引脚。这样：
    //   1) 每一位调试信号都在 output 的锥里，综合不敢删；
    //   2) 引脚占用仍然只有 1 根；
    //   3) 它自己也是一个有用的"心跳灯"：只要 CPU 在跑（PC/写回数据非 0），
    //      它就为高；CPU 被复位或彻底不动时为低。接一个 LED 就能一眼看出
    //      "板子到底跑没跑起来"，这是 ILA 之外最有用的一个信息。
    // 时序代价：约 16 级 LUT2 的或链，50MHz（20ns）下毫无压力。
    // ---------------------------------------------------------------------
    output logic debug_dead
);

    /* ---------------- 1) 100MHz 输入 → 50MHz 系统时钟（MMCM） ---------------- */
    logic clk_in_buf;      // 100MHz，经 IBUF 后
    logic clkfb;           // MMCM 反馈
    logic mmcm_locked;     // MMCM 锁定标志
    logic clk_sys_unbuf;   // 50MHz，MMCM 输出（未上全局时钟网络）
    logic rst_n;

    // 输入时钟缓冲
    IBUF clk_ibuf_inst (
        .I (sys_clk),
        .O (clk_in_buf)
    );

    // MMCM：100MHz → 50MHz
    //   VCO = 100MHz × CLKFBOUT_MULT_F(10) / DIVCLK_DIVIDE(1) = 1000MHz
    //   CLKOUT0 = VCO / CLKOUT0_DIVIDE_F(20) = 50MHz
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
        // v9 修复（实测踩到的坑）：CLKFBIN 必须接上 CLKFBOUT 的反馈！
        //   漏接的后果：综合只给一条很容易被忽略的告警
        //     WARNING: [Synth 8-7071] port 'CLKFBIN' of module 'MMCME2_BASE' is unconnected
        //   然后 MMCM 的**内部反馈环断开**，时钟根本不会锁定，LOCKED 恒 0 →
        //   下面 rst_n = btn_rst_n & mmcm_locked 恒为低 →
        //   CPU 永远停在复位态，上板现象是"什么动静都没有"。
        //   这是 MMCM 最经典的接线错误，务必保留这一行。
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
    // 为什么要把 mmcm_locked 并进来：MMCM 锁定前输出时钟是不稳的，
    //   这段时间 CPU 必须保持在复位态，否则会跑飞。
    assign rst_n = btn_rst_n & mmcm_locked;

    /* ---------------- 3) CPU + 同步存储器（沿用 board_top，逻辑未改） -------- */
    // board_top 的 13 个 debug_* 输出直接连到本模块的同名输出口（再往上层
    //   给 ILA 当 probe），同时汇总到 debug_dead 做心跳，两处都有负载。
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
        .debug_trap_take       (debug_trap_take)
    );

    /* ---------------- 4) 调试量汇总 → 唯一输出（心跳 + 防优化双保险） -------- */
    // 额外说明：debug_mtval 目前抓不到有效值 —— 综合报
    //   WARNING: [Synth 8-6014] Unused sequential element mtval_reg_reg was removed
    //   WARNING: [Synth 8-3848] Net mtval_out in module/entity CSR does not have driver
    //   即 v9 的 CSR.mtval 在 RTL 层面就没有被写（mtval 是个死寄存器，见
    //   ../syn/上板改造说明.md 的 C 系列修复记录）。这是 RTL 待修项，不是 ILA 的问题。
    assign debug_dead = |{debug_wb_have_inst, debug_wb_ena,
                          debug_wb_pc, debug_wb_reg, debug_wb_value,
                          debug_icache_hit_cnt, debug_icache_miss_cnt,
                          debug_dcache_hit_cnt, debug_dcache_miss_cnt,
                          debug_mcause, debug_mepc, debug_mtval,
                          debug_trap_take};

endmodule
