/* =============================================================================
 * sw/soc_map.h — SoC 地址映射（**自动生成，不要手改**）
 * -----------------------------------------------------------------------------
 * 来源：rtl/soc_map.sv
 * 生成：python tools/gen_soc_map.py
 * 校验：python tools/gen_soc_map.py --check  （_diag/regress.ps1 会跑）
 * ============================================================================= */
#ifndef SOC_MAP_H
#define SOC_MAP_H

/* ---- CODE ---- */
#define SOC_CODE_BASE            0  /* 取指口 */
#define SOC_CODE_BYTES           0x00010000u  /* 64 KB */
/* ---- CODEWIN ---- */
#define SOC_CODEWIN_BASE         0x00020000u
#define SOC_CODEWIN_BYTES        0x00010000u  /* 64 KB */
/* ---- DRAM ---- */
#define SOC_DRAM_BASE            0
#define SOC_DRAM_BYTES           0x00020000u  /* 128 KB */
#define SOC_DRAM_WORDS           32768
/* ---- IMEM ---- */
#define SOC_IMEM_WORDS           16384
/* ---- IRQ ---- */
#define SOC_IRQ_PS               4  /* PS 发来的事件（AXI 控制寄存器 bit1，电平） */
#define SOC_IRQ_SW               3  /* 软件自触发（写 0x1000_002C） */
#define SOC_IRQ_TIMER            2  /* 定时器（A3 接 CLINT） */
#define SOC_IRQ_UART_OVF         1  /* RX 溢出（电平） */
#define SOC_IRQ_UART_RX          0  /* RX FIFO 非空（电平） */
/* ---- MMIO ---- */
#define SOC_MMIO_BASE            0x10000000u
#define SOC_MMIO_BYTES           32768  /* 32 KB */
#define SOC_MMIO_IDX_ADC_CH      39  /* 0x9C RW  {ch1_en, ch1[6:0], ch0[6:0]} */
#define SOC_MMIO_IDX_ADC_CNT     40  /* 0xA0 RO  累计样本数（32 位，会回卷） */
#define SOC_MMIO_IDX_ADC_CTL     38  /* 0x98 RW  bit0 en（启动轮询）bit1 clr_ovf */
#define SOC_MMIO_IDX_ADC_DATA    35  /* 0x8C RO  {16'b0, adc[15:0]}（读 = 弹出一个样本） */
#define SOC_MMIO_IDX_ADC_LAST    41  /* 0xA4 RO  {16'b0, adc_last[15:0]} 最新一次转换（FIFO 满了也能看到当前值） */
#define SOC_MMIO_IDX_ADC_LVL     37  /* 0x94 RO  FIFO 里现成的样本数 */
#define SOC_MMIO_IDX_ADC_ST      36  /* 0x90 RO  bit0 full bit1 overflow bit2 有数据 */
#define SOC_MMIO_IDX_BOOTREQ     5  /* 0x14 WO  写 1 → 重新引导 */
#define SOC_MMIO_IDX_COL_PUSH    32  /* 0x80 WO  {2'b0, max[9:0], min[9:0], col[9:0]} */
#define SOC_MMIO_IDX_CTL         7  /* 0x1C RW  控制（见上：无效/irq_ps/alive） */
#define SOC_MMIO_IDX_DAC         34  /* 0x88 WO  {24'b0, dac[7:0]} → DAC0832 直通输出 */
#define SOC_MMIO_IDX_DISP_CTL    42  /* 0xA8 WO  写 1 = 提交一帧（下一次帧同步才翻 bank，防撕裂） */
#define SOC_MMIO_IDX_DISP_ST     33  /* 0x84 RO  bit0 = 当前该写哪一块 bank */
#define SOC_MMIO_IDX_I2C_A_CLR   25  /* 0x64 */
#define SOC_MMIO_IDX_I2C_A_CTRL  21  /* 0x54   音频总线（ADAU1761），同上 */
#define SOC_MMIO_IDX_I2C_A_RX    23  /* 0x5C */
#define SOC_MMIO_IDX_I2C_A_ST    24  /* 0x60 */
#define SOC_MMIO_IDX_I2C_A_TX    22  /* 0x58 */
#define SOC_MMIO_IDX_I2C_H_CLR   20  /* 0x50 WO  写 1 清 done */
#define SOC_MMIO_IDX_I2C_H_CTRL  16  /* 0x40 WO  bit0 START bit1 BYTE bit2 STOP bit3 R/W bit4 NACK */
#define SOC_MMIO_IDX_I2C_H_RX    18  /* 0x48 RO  最近读到的字节 */
#define SOC_MMIO_IDX_I2C_H_ST    19  /* 0x4C RO  bit0 busy bit1 done bit2 ack bit3 SCL bit4 SDA */
#define SOC_MMIO_IDX_I2C_H_TX    17  /* 0x44 WO  待发字节 */
#define SOC_MMIO_IDX_IRQEN       9  /* 0x24 RW  使能位图 */
#define SOC_MMIO_IDX_IRQID       10  /* 0x28 RO  最高优先级的待处理源号（0 = 无） */
#define SOC_MMIO_IDX_IRQPEND     8  /* 0x20 RW  读=待处理位图；写 1s = claim（清位） */
#define SOC_MMIO_IDX_IRQSW       11  /* 0x2C WO  写 1 → 触发软件中断源（src[3]，自测用） */
#define SOC_MMIO_IDX_LED         4  /* 0x10 RW  低 7 位驱动 LED */
#define SOC_MMIO_IDX_LINE_HEALTH 31  /* 0x7C RO  {aud_scl,aud_sda,hdmi_scl,hdmi_sda} 各 2 位 */
#define SOC_MMIO_IDX_MEAS_CNT    50  /* 0xC8 RO  已完成窗口数 */
#define SOC_MMIO_IDX_MEAS_MAX    48  /* 0xC0 RO  窗内最大值 */
#define SOC_MMIO_IDX_MEAS_MEAN   49  /* 0xC4 RO  窗内均值（sum>>10） */
#define SOC_MMIO_IDX_MEAS_MIN    47  /* 0xBC RO  窗内最小值（1024 样本窗口） */
#define SOC_MMIO_IDX_MTIME       12  /* 0x30 RW  mtime 低 32 位 */
#define SOC_MMIO_IDX_MTIMECMP    14  /* 0x38 RW  mtimecmp 低 32 位 */
#define SOC_MMIO_IDX_MTIMECMPH   15  /* 0x3C RO  恒 0（写忽略） */
#define SOC_MMIO_IDX_MTIMEH      13  /* 0x34 RO  恒 0（本设计 mtime 只有 32 位） */
#define SOC_MMIO_IDX_PRB_A_FOUND 28  /* 0x70 RO  音频扫描位图 */
#define SOC_MMIO_IDX_PRB_A_ID    29  /* 0x74 RO */
#define SOC_MMIO_IDX_PRB_H_FOUND 26  /* 0x68 RO  HDMI 扫描位图 [15:0] */
#define SOC_MMIO_IDX_PRB_H_ID    27  /* 0x6C RO  {1'b0, addr[6:0], id00, idf5, idf6} */
#define SOC_MMIO_IDX_PRB_ST      30  /* 0x78 RO  bit0 hdmi_done bit1 aud_done bit2 h_busy bit3 a_busy */
#define SOC_MMIO_IDX_RXDATA      2  /* 0x08 RO  队头字节（不弹） */
#define SOC_MMIO_IDX_RXPOP       6  /* 0x18 WO  写 1 → 弹出队头 */
#define SOC_MMIO_IDX_RXSTAT      3  /* 0x0C RO  bit0 = FIFO 非空, bit1 = 溢出过 */
#define SOC_MMIO_IDX_TEXT_PUT    51  /* 0xCC WO  {line[0], col[4:0], ch[4:0]} 写一个字符单元（S6 文本层） */
#define SOC_MMIO_IDX_TRIG_CNT    46  /* 0xB8 RO  累计触发次数 */
#define SOC_MMIO_IDX_TRIG_CTL    44  /* 0xB0 RW  bit0 en bit1 clear bit3:2 mode(0=上升1=下降2=任意3=电平) */
#define SOC_MMIO_IDX_TRIG_ST     45  /* 0xB4 RO  bit0 fired bit1 above */
#define SOC_MMIO_IDX_TRIG_TH     43  /* 0xAC RW  触发阈值（12 位，左对齐或右对齐由软件决定） */
#define SOC_MMIO_IDX_TXDATA      0  /* 0x00 WO  写 → 串口发送 */
#define SOC_MMIO_IDX_TXSTAT      1  /* 0x04 RO  bit0 = 发送器忙 */

#endif /* SOC_MAP_H */
