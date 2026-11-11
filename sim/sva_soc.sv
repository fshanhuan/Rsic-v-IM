`timescale 1ns / 1ps

/* =============================================================================
 * sim/sva_soc.sv -- P0-5：SoC 级 SystemVerilog 断言（用 Vivado xsim 跑）
 * -----------------------------------------------------------------------------
 * 为什么单独一套：iverilog **不支持并发断言**（assert property），而立即断言又只在
 * 被调用时才检查。所以真 SVA 走 xsim（_diag/sva.ps1），激励直接复用 tb_irq
 * （irqtest：PLIC 软件源 → MEIP → 陷入 → mret，且跑真实的 MMIO/UART 通路）。
 *
 * 断言选的都是**设计里有明确不变量、且过去真的踩过坑**的东西：
 *   A1 总线方向互斥        —— 同一拍不可能既是读又是写（译码错就会同时选中两路）
 *   A2 译码地址字对齐      —— DCache 只发整字，字节/半字靠 cpu_mask；地址带低位
 *                             说明上游算错了（曾经的 "load 值整体偏一个 index"）
 *   A3 引导期间 CPU 必须停 —— IROM 只有一个口，loader 写的时候 CPU 不能取指
 *   A4 PLIC 输出与寄存器一致 —— plic_irq 必须恒等于 |(pending & enable)
 *   A5 复位后控制信号无 X  —— P0-1 的 RTL 版守卫：X 一旦进控制路径，仿真和真片
 *                             都会"时好时坏"，这里让它当场炸
 *   A6 写 MMIO 只能有一路   —— we_mmio 不得与 we_dram / we_code 同拍（曾经的
 *                             "sw 0x2_0040 同时改掉 DRAM 第 0x40 个字"）
 *
 * 用法（_diag/sva.ps1 全自动）：xvlog --sv ... ; xelab tb_irq -s sva ; xsim sva -runall
 * 判据：日志里没有 "Assertion" + "FAILED"，且脚本打印 SVA PASS。
 * ============================================================================= */

// ---------------------------------------------------------------- board_top 级
module sva_board (
    input logic        clk,
    input logic        rst,           // = cpu_rst_eff（引导期间也算复位）
    input logic        bus_re_dram,
    input logic        bus_re_code,
    input logic        bus_we_dram,
    input logic        bus_we_code,
    input logic        bus_we_mmio,
    input logic [31:0] perip_addr,
    input logic [7:0]  plic_pend,
    input logic [7:0]  plic_en,
    input logic        plic_irq,
    input logic        boot_busy
);

    // A1/A6：读、写、各路片选在**同一拍**最多只能有一个有效
    property p_onehot;
        @(posedge clk) disable iff (rst)
            $onehot0({bus_re_dram, bus_re_code, bus_we_dram, bus_we_code, bus_we_mmio});
    endproperty
    A1_bus_onehot: assert property (p_onehot)
        else $error("[SVA] A1 violated: multiple bus selects in one cycle");

    // A2：MCU 侧发到总线的地址必须是字对齐的
    property p_align;
        @(posedge clk) disable iff (rst)
            (bus_re_code || bus_we_code || bus_we_mmio) |-> (perip_addr[1:0] == 2'b00);
    endproperty
    A2_addr_aligned: assert property (p_align)
        else $error("[SVA] A2 violated: bus address not word aligned: %h", perip_addr);

    // A3：引导器忙 => CPU 必须被按住（否则 IROM 单口被两头抢）
    property p_boot;
        @(posedge clk) boot_busy |-> rst;
    endproperty
    A3_boot_holds_cpu: assert property (p_boot)
        else $error("[SVA] A3 violated: boot_busy=1 but cpu_rst_eff=0");

    // A4：PLIC 汇总输出必须恒等于 |(pending & enable)
    always_comb begin
        if (!rst && plic_irq !== (|(plic_pend & plic_en)))
            $error("[SVA] A4 violated: plic_irq=%b pend&en=%b", plic_irq, |(plic_pend & plic_en));
    end

    // A5：复位释放之后，控制类信号不许有 X
    property p_no_x;
        @(posedge clk) disable iff (rst)
            !$isunknown({bus_re_dram, bus_re_code, bus_we_dram, bus_we_code,
                         bus_we_mmio, plic_pend, plic_irq});
    endproperty
    A5_no_x_on_control: assert property (p_no_x)
        else $error("[SVA] A5 violated: X on control signals (bus/plic)");

endmodule

// ------------------------------------------------------------------- myCPU 级
module sva_cpu (
    input logic        clk,
    input logic        rst,
    input logic        dcache_hold,
    input logic [31:0] IFU_pc
);

    // C1：取指 PC 永远不许落进 MMIO 区（0x1000_0000 以上）。
    //     代码只可能在 IROM(0x0~0xFFFF) 或 DRAM(0x0~0x1FFFF)；PC 跑到 MMIO 说明
    //     跳转目标算错（比如把外设地址当函数指针）。这条**代替**了最初写的
    //     "dcache_hold 期间 PC 不许动" —— 那条是我理解错了：dcache_hold 只冻结
    //     LSU/WBU，IFU 照常推进，所以它在真实设计上会误报（第一次跑就抓到了自己）。
    property p_pc_not_mmio;
        @(posedge clk) disable iff (rst) (IFU_pc < 32'h1000_0000);
    endproperty
    C1_pc_not_in_mmio: assert property (p_pc_not_mmio)
        else $error("[SVA] C1 violated: IFU_pc in MMIO space: %h", IFU_pc);

    // C2：取指地址必须 4 字节对齐（本核无 C 扩展，Misaligned 由 trap 处理）
    property p_pc_align;
        @(posedge clk) disable iff (rst) (IFU_pc[1:0] == 2'b00);
    endproperty
    C2_pc_aligned: assert property (p_pc_align)
        else $error("[SVA] C2 violated: IFU_pc not 4-byte aligned: %h", IFU_pc);

endmodule

bind board_top sva_board u_sva_board (
    .clk           (sys_clk),
    .rst           (cpu_rst_eff),
    .bus_re_dram   (bus_re_dram),
    .bus_re_code   (bus_re_code),
    .bus_we_dram   (bus_we_dram),
    .bus_we_code   (bus_we_code),
    .bus_we_mmio   (bus_we_mmio),
    .perip_addr    (perip_addr),
    .plic_pend     (plic_pend),
    .plic_en       (plic_en),
    .plic_irq      (plic_irq),
    .boot_busy     (boot_busy)
);

bind myCPU sva_cpu u_sva_cpu (
    .clk        (cpu_clk),
    .rst        (cpu_rst),
    .dcache_hold(dcache_hold),
    .IFU_pc     (IFU_pc)
);
