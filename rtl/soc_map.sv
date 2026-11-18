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
 *               │ MMIO 32 KB（addr[15]==0）     │  idx = addr[7:2]
 *   0x1000_8000 └──────────────────────────────┘
 *
 *   ★ S0（记录仪项目）：MMIO 索引 4→6 位，index = addr[7:2]，寄存器空间 16 → 64 个。
 *     寄存器**必须落在 0x00 ~ 0xFC** 之内；0x100 及以上会回卷到 0x00（索引只有 6 位）。
 *     这一条是硬约束：将来若要更多寄存器，改成 addr[11:2] 之前先想清楚别名。
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
 * 索引宽度演进（每次都被"别名"咬过，记在这里防复发）：
 *   · 3 位（addr[4:2]）：8 个寄存器。0x1000_0020 与 0x1000_0000 别名，
 *     停机 magic 写 0x1000_00F0 会撞上 LED（idx=4）—— docs/总线化_A1.md §6。
 *   · 4 位（addr[5:2]）：16 个寄存器（A2）。
 *   · **6 位（addr[7:2]）：64 个寄存器（S0，记录仪项目）**。
 *     必须扩的理由很实在：4 位时 16 个位置已全部占满（0x00–0x3C），
 *     记录仪要加的 I2C / HDMI / XADC / 列缓冲一个都放不进去。
 *   ★ 硬约束：寄存器只能落在 0x00–0xFC；0x100 起会回卷到 0x00。
 *
 * ★ 兼容性（S0 改动**不动**既有行为）：
 *   0x00–0x3C 的 16 个寄存器编号、语义、读写时序全部不变，只是比较位宽变宽。
 *   唯一可观测的变化是 0x40–0xFF 不再回卷到 0x00–0x3C —— 老的"写 0x1000_00F0
 *   当停机 magic"因此**不再**误写 MTIME（本来就是个隐患，顺手消失了）。
 * ------------------------------------------------------------------------- */
`define SOC_MMIO_IDX_TXDATA   6'd0    // 0x00 WO  写 → 串口发送
`define SOC_MMIO_IDX_TXSTAT   6'd1    // 0x04 RO  bit0 = 发送器忙
`define SOC_MMIO_IDX_RXDATA   6'd2    // 0x08 RO  队头字节（不弹）
`define SOC_MMIO_IDX_RXSTAT   6'd3    // 0x0C RO  bit0 = FIFO 非空, bit1 = 溢出过
`define SOC_MMIO_IDX_LED      6'd4    // 0x10 RW  低 7 位驱动 LED
`define SOC_MMIO_IDX_BOOTREQ  6'd5    // 0x14 WO  写 1 → 重新引导
`define SOC_MMIO_IDX_RXPOP    6'd6    // 0x18 WO  写 1 → 弹出队头
/* ---- 双核协同（三步计划）----
 * 0x1C 在 4 位索引时代是最后一个空位；S0 扩到 6 位之后不再是，但编号保持不迁移
 * —— 已经烧进 PS 侧脚本和文档的地址不动，避免"文档与 RTL 对不上"这类回归。
 *   bit0 WO 自清：写 1 → D-cache 全无效（PS 改了 DRAM 之后，CPU 必须先清）
 *   bit1 RW     ：irq_ps 电平，CPU 用它敲 ARM 的 GIC（经 IRQ_F2P）
 *   bit2 WO 自清：写 1 → 置"CPU 已到岗"标志（stage-0 stub 用它报平安，PS 侧可读）
 * 读回：bit1 = irq_ps 当前值，其余 0。 */
`define SOC_MMIO_IDX_CTL      6'd7    // 0x1C RW  控制（见上：无效/irq_ps/alive）
/* ---- A2：PLIC-lite（中断控制器）---- */
`define SOC_MMIO_IDX_IRQPEND  6'd8    // 0x20 RW  读=待处理位图；写 1s = claim（清位）
`define SOC_MMIO_IDX_IRQEN    6'd9    // 0x24 RW  使能位图
`define SOC_MMIO_IDX_IRQID    6'd10   // 0x28 RO  最高优先级的待处理源号（0 = 无）
`define SOC_MMIO_IDX_IRQSW    6'd11   // 0x2C WO  写 1 → 触发软件中断源（src[3]，自测用）
/* ---- A3：CLINT（定时器）---- */
`define SOC_MMIO_IDX_MTIME     6'd12   // 0x30 RW  mtime 低 32 位
`define SOC_MMIO_IDX_MTIMEH    6'd13   // 0x34 RO  恒 0（本设计 mtime 只有 32 位）
`define SOC_MMIO_IDX_MTIMECMP  6'd14   // 0x38 RW  mtimecmp 低 32 位
`define SOC_MMIO_IDX_MTIMECMPH 6'd15   // 0x3C RO  恒 0（写忽略）

/* ---- 记录仪项目（S0 扩位之后才有的空间；只有 board_top_rec 打开 EXT_MMIO）----
 * 为什么这些寄存器不在 board_top 里：board_top 是全工程共用的 SoC，
 * 记录仪外设只属于那个项目，所以 board_top 只开一个通用转发口（EXT_MMIO=1 时
 * idx>=16 的访问转给 board/rec_mmio.sv），具体定义落在那里。
 * 这里列出来是为了让 C 头文件（tools/gen_soc_map.py 生成）也有同一套编号 ——
 * 软件写死裸地址是最容易在重构时出错的地方。
 * ------------------------------------------------------------------------- */
/* 两路 I2C 主控（每路 5 个寄存器，见 board/i2c_mmio.sv） */
`define SOC_MMIO_IDX_I2C_H_CTRL   6'd16   // 0x40 WO  bit0 START bit1 BYTE bit2 STOP bit3 R/W bit4 NACK
`define SOC_MMIO_IDX_I2C_H_TX     6'd17   // 0x44 WO  待发字节
`define SOC_MMIO_IDX_I2C_H_RX     6'd18   // 0x48 RO  最近读到的字节
`define SOC_MMIO_IDX_I2C_H_ST     6'd19   // 0x4C RO  bit0 busy bit1 done bit2 ack bit3 SCL bit4 SDA
`define SOC_MMIO_IDX_I2C_H_CLR    6'd20   // 0x50 WO  写 1 清 done
`define SOC_MMIO_IDX_I2C_A_CTRL   6'd21   // 0x54   音频总线（ADAU1761），同上
`define SOC_MMIO_IDX_I2C_A_TX     6'd22   // 0x58
`define SOC_MMIO_IDX_I2C_A_RX     6'd23   // 0x5C
`define SOC_MMIO_IDX_I2C_A_ST     6'd24   // 0x60
`define SOC_MMIO_IDX_I2C_A_CLR    6'd25   // 0x64
/* 上电自动探测的结果（只读） */
`define SOC_MMIO_IDX_PRB_H_FOUND  6'd26   // 0x68 RO  HDMI 扫描位图 [15:0]
`define SOC_MMIO_IDX_PRB_H_ID     6'd27   // 0x6C RO  {1'b0, addr[6:0], id00, idf5, idf6}
`define SOC_MMIO_IDX_PRB_A_FOUND  6'd28   // 0x70 RO  音频扫描位图
`define SOC_MMIO_IDX_PRB_A_ID     6'd29   // 0x74 RO
`define SOC_MMIO_IDX_PRB_ST       6'd30   // 0x78 RO  bit0 hdmi_done bit1 aud_done bit2 h_busy bit3 a_busy
`define SOC_MMIO_IDX_LINE_HEALTH  6'd31   // 0x7C RO  {aud_scl,aud_sda,hdmi_scl,hdmi_sda} 各 2 位
/* S3：列缓冲（一次写一列）*/
`define SOC_MMIO_IDX_COL_PUSH    6'd32   // 0x80 WO  {2'b0, max[9:0], min[9:0], col[9:0]}
`define SOC_MMIO_IDX_DISP_ST     6'd33   // 0x84 RO  bit0 = 当前该写哪一块 bank

/* ---- S2：DAC0832 + XADC（模拟自环）----
 * 自环接法：板上 DAC 输出（VREF=−3.98V 进反相运放 → 0~+3.98 V，码 0x00=0V）接到 XADC 的
 * AD11（A18/A19）或 AD6（V13/W13）。★ 手册明确：这两个脚**只支持 0~1 V**，
 * 所以必须先分压，或者把 DAC 码值限制在低压段，否则有过压损坏 XADC 的风险。
 * 12 位 ADC 码 ↔ 电压：V = code/4096 × 1.0 V（单极性，0~1 V 量程）。 */
`define SOC_MMIO_IDX_DAC         6'd34   // 0x88 WO  {24'b0, dac[7:0]} → DAC0832 直通输出
`define SOC_MMIO_IDX_ADC_DATA    6'd35   // 0x8C RO  {16'b0, adc[15:0]}（读 = 弹出一个样本）
`define SOC_MMIO_IDX_ADC_ST      6'd36   // 0x90 RO  bit0 full bit1 overflow bit2 有数据
`define SOC_MMIO_IDX_ADC_LVL     6'd37   // 0x94 RO  FIFO 里现成的样本数
`define SOC_MMIO_IDX_ADC_CTL     6'd38   // 0x98 RW  bit0 en（启动轮询）bit1 clr_ovf
`define SOC_MMIO_IDX_ADC_CH      6'd39   // 0x9C RW  {ch1_en, ch1[6:0], ch0[6:0]}
`define SOC_MMIO_IDX_ADC_CNT     6'd40   // 0xA0 RO  累计样本数（32 位，会回卷）
`define SOC_MMIO_IDX_ADC_LAST    6'd41   // 0xA4 RO  {16'b0, adc_last[15:0]} 最新一次转换（FIFO 满了也能看到当前值）
`define SOC_MMIO_IDX_DISP_CTL     6'd42   // 0xA8 WO  写 1 = 提交一帧（下一次帧同步才翻 bank，防撕裂）
`define SOC_MMIO_IDX_TRIG_TH      6'd43   // 0xAC RW  触发阈值（12 位，左对齐或右对齐由软件决定）
`define SOC_MMIO_IDX_TRIG_CTL     6'd44   // 0xB0 RW  bit0 en bit1 clear bit3:2 mode(0=上升1=下降2=任意3=电平)
`define SOC_MMIO_IDX_TRIG_ST      6'd45   // 0xB4 RO  bit0 fired bit1 above
`define SOC_MMIO_IDX_TRIG_CNT     6'd46   // 0xB8 RO  累计触发次数
`define SOC_MMIO_IDX_MEAS_MIN    6'd47   // 0xBC RO  窗内最小值（1024 样本窗口）
`define SOC_MMIO_IDX_MEAS_MAX    6'd48   // 0xC0 RO  窗内最大值
`define SOC_MMIO_IDX_MEAS_MEAN   6'd49   // 0xC4 RO  窗内均值（sum>>10）
`define SOC_MMIO_IDX_MEAS_CNT    6'd50   // 0xC8 RO  已完成窗口数
`define SOC_MMIO_IDX_TEXT_PUT    6'd51   // 0xCC WO  {line[0], col[4:0], ch[4:0]} 写一个字符单元（S6 文本层）

/* --------------------- PLIC-lite 中断源编号（与 board_top 一致）----------- */
`define SOC_IRQ_UART_RX    0     // RX FIFO 非空（电平）
`define SOC_IRQ_UART_OVF   1     // RX 溢出（电平）
`define SOC_IRQ_TIMER      2     // 定时器（A3 接 CLINT）
`define SOC_IRQ_SW         3     // 软件自触发（写 0x1000_002C）
`define SOC_IRQ_PS         4     // PS 发来的事件（AXI 控制寄存器 bit1，电平）

`endif
