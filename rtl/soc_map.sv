`ifndef SOC_MAP_SV
`define SOC_MAP_SV
/* =============================================================================
 * soc_map.sv — SoC 地址映射的**单一来源**（A4）
 * -----------------------------------------------------------------------------
 * 为什么要有这个文件：
 *   改造前，同一份地址映射散落在 **4 个地方**，每加一个外设都要人肉对齐：
 *     · board/board_top.sv      译码（mmio_sel / irom_win_sel）
 *     · board/board_top.sv      读数据 mux
 *     · board/board_top.sv      DRAM 写使能门控（防误写）
 *     · sw/monitor.c            软件侧宏（IROM_WIN / DRAM_BASE）
 *     · docs 下的 .md             文档里的表格
 *   A4 之后：**这里改一处**，RTL 与 C 头文件都从这张表来。
 *
 * 地址空间（数据口视角，哈佛：取指口另有一套）：
 *
 *   0x0000_0000 ┌──────────────────────────────┐
 *               │ DRAM 128 KB（32768 字）       │  .rodata/.data/.bss/栈
 *               │ ★ 0x0_0000–0x0_FFFF 是空洞   │  （留给 ramdisk / 文件系统）
 *   0x0002_0000 ├──────────────────────────────┤
 *               │ 代码窗口 64 KB（只读/可写）   │  = IMEM 的第二口，字地址直通
 *   0x0003_0000 ├──────────────────────────────┤
 *               │ （未映射，默认落到 DRAM）     │  STRICT=1 时回 bus_err
 *   0x1000_0000 ├──────────────────────────────┤
 *               │ MMIO 32 KB（addr[15]==0）     │  idx = addr[4:2]
 *   0x1000_8000 └──────────────────────────────┘
 *
 * 取指口（与数据口完全独立，这是哈佛结构）：
 *   0x0000_0000 – 0x0000_FFFF   IMEM 64 KB（16384 字）
 *
 * ★ 改这里的后果：RTL 译码、软件宏、文档表格要一起变。改完跑
 *   `_diag/regress.ps1` + `sim/tb_monitor.sv`（板级），两者都过才算改对。
 * =========================================================================== */

/* ------------------------------- 片选比较 ---------------------------------
 * 刻意用"掩码 + 常量"而不是 (addr >= BASE && addr < BASE+SIZE)：
 *   · 综合出来是同一套比较器，但掩码写法**不含加法器**，对 WNS 友好
 *     （本设计 WNS 只有 0.048 ns，地址比较在关键路径上）；
 *   · 展开成常量后 Vivado 能直接折成 LUT，不会被"范围比较"拖成进位链。
 * ------------------------------------------------------------------------- */
// 代码窗口：addr[31:16] == 0x0002
`define SOC_SEL_CODE(a)  (((a) & 32'hFFFF_0000) == 32'h0002_0000)
// MMIO：addr[31:16] == 0x1000 且 addr[15] == 0（0x1000_8000 以上不映射，留给未来）
`define SOC_SEL_MMIO(a)  (((a) & 32'hFFFF_8000) == 32'h1000_0000)
// DRAM：默认从设备（既不命中 MMIO 也不命中代码窗口）
`define SOC_SEL_DRAM(a)  (!`SOC_SEL_MMIO(a) && !`SOC_SEL_CODE(a))

/* ------------------------------- 基址常量 --------------------------------- */
`define SOC_DRAM_BASE      32'h0000_0000
`define SOC_DRAM_BYTES     32'h0002_0000    // 128 KB
`define SOC_CODEWIN_BASE   32'h0002_0000
`define SOC_CODEWIN_BYTES  32'h0001_0000    // 64 KB
`define SOC_MMIO_BASE      32'h1000_0000
`define SOC_MMIO_BYTES     32'h0000_8000    // 32 KB
`define SOC_CODE_BASE      32'h0000_0000    // 取指口
`define SOC_CODE_BYTES     32'h0001_0000    // 64 KB

/* ------------------------- 容量（与 board_top 参数一致） ------------------ */
`define SOC_IMEM_WORDS     16384
`define SOC_DRAM_WORDS     32768

/* --------------------------- MMIO 寄存器号 --------------------------------
 * ★ A2：索引从 3 位扩到 **4 位**（addr[5:2]），寄存器空间从 8 个变 16 个。
 *   原来 3 位时 0x1000_0020 会和 0x1000_0000 别名 —— 停机 magic 写 0x1000_00F0
 *   会撞上 LED（idx=4）就是这条缺陷的现场（见 docs/总线化_A1.md §6）。
 * ------------------------------------------------------------------------- */
`define SOC_MMIO_IDX_TXDATA   4'd0    // 0x00 WO  写 → 串口发送
`define SOC_MMIO_IDX_TXSTAT   4'd1    // 0x04 RO  bit0 = 发送器忙
`define SOC_MMIO_IDX_RXDATA   4'd2    // 0x08 RO  队头字节（不弹）
`define SOC_MMIO_IDX_RXSTAT   4'd3    // 0x0C RO  bit0 = FIFO 非空, bit1 = 溢出过
`define SOC_MMIO_IDX_LED      4'd4    // 0x10 RW  低 7 位驱动 LED
`define SOC_MMIO_IDX_BOOTREQ  4'd5    // 0x14 WO  写 1 → 重新引导
`define SOC_MMIO_IDX_RXPOP    4'd6    // 0x18 WO  写 1 → 弹出队头
/* ---- 双核协同（三步计划）----
 * 0x1C 是 4 位索引下**最后一个空位**（其余 16 个都占了；7 号从来没分配过）。
 * 为什么不再扩到 5 位：A2 已经因为"3→4 位时 0x20 与 0x00 别名"踩过一次，
 * 这里够用就不动索引宽度 —— 少一次全表回归的风险。
 *   bit0 WO 自清：写 1 → D-cache 全无效（PS 改了 DRAM 之后，CPU 必须先清）
 *   bit1 RW     ：irq_ps 电平，CPU 用它敲 ARM 的 GIC（经 IRQ_F2P）
 *   bit2 WO 自清：写 1 → 置"CPU 已到岗"标志（stage-0 stub 用它报平安，PS 侧可读）
 * 读回：bit1 = irq_ps 当前值，其余 0。 */
`define SOC_MMIO_IDX_CTL      4'd7    // 0x1C RW  控制（见上：无效/irq_ps/alive）
/* ---- A2：PLIC-lite（中断控制器）---- */
`define SOC_MMIO_IDX_IRQPEND  4'd8    // 0x20 RW  读=待处理位图；写 1s = claim（清位）
`define SOC_MMIO_IDX_IRQEN    4'd9    // 0x24 RW  使能位图
`define SOC_MMIO_IDX_IRQID    4'd10   // 0x28 RO  最高优先级的待处理源号（0 = 无）
`define SOC_MMIO_IDX_IRQSW    4'd11   // 0x2C WO  写 1 → 触发软件中断源（src[3]，自测用）
/* ---- A3：CLINT（定时器）---- */
`define SOC_MMIO_IDX_MTIME     4'd12   // 0x30 RW  mtime 低 32 位
`define SOC_MMIO_IDX_MTIMEH    4'd13   // 0x34 RO  恒 0（本设计 mtime 只有 32 位）
`define SOC_MMIO_IDX_MTIMECMP  4'd14   // 0x38 RW  mtimecmp 低 32 位
`define SOC_MMIO_IDX_MTIMECMPH 4'd15   // 0x3C RO  恒 0（写忽略）

/* --------------------- PLIC-lite 中断源编号（与 board_top 一致）----------- */
`define SOC_IRQ_UART_RX    0     // RX FIFO 非空（电平）
`define SOC_IRQ_UART_OVF   1     // RX 溢出（电平）
`define SOC_IRQ_TIMER      2     // 定时器（A3 接 CLINT）
`define SOC_IRQ_SW         3     // 软件自触发（写 0x1000_002C）
`define SOC_IRQ_PS         4     // PS 发来的事件（AXI 控制寄存器 bit1，电平）

`endif
