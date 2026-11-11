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
#define SOC_MMIO_IDX_BOOTREQ     5  /* 0x14 WO  写 1 → 重新引导 */
#define SOC_MMIO_IDX_CTL         7  /* 0x1C RW  控制（见上：无效/irq_ps/alive） */
#define SOC_MMIO_IDX_IRQEN       9  /* 0x24 RW  使能位图 */
#define SOC_MMIO_IDX_IRQID       10  /* 0x28 RO  最高优先级的待处理源号（0 = 无） */
#define SOC_MMIO_IDX_IRQPEND     8  /* 0x20 RW  读=待处理位图；写 1s = claim（清位） */
#define SOC_MMIO_IDX_IRQSW       11  /* 0x2C WO  写 1 → 触发软件中断源（src[3]，自测用） */
#define SOC_MMIO_IDX_LED         4  /* 0x10 RW  低 7 位驱动 LED */
#define SOC_MMIO_IDX_MTIME       12  /* 0x30 RW  mtime 低 32 位 */
#define SOC_MMIO_IDX_MTIMECMP    14  /* 0x38 RW  mtimecmp 低 32 位 */
#define SOC_MMIO_IDX_MTIMECMPH   15  /* 0x3C RO  恒 0（写忽略） */
#define SOC_MMIO_IDX_MTIMEH      13  /* 0x34 RO  恒 0（本设计 mtime 只有 32 位） */
#define SOC_MMIO_IDX_RXDATA      2  /* 0x08 RO  队头字节（不弹） */
#define SOC_MMIO_IDX_RXPOP       6  /* 0x18 WO  写 1 → 弹出队头 */
#define SOC_MMIO_IDX_RXSTAT      3  /* 0x0C RO  bit0 = FIFO 非空, bit1 = 溢出过 */
#define SOC_MMIO_IDX_TXDATA      0  /* 0x00 WO  写 → 串口发送 */
#define SOC_MMIO_IDX_TXSTAT      1  /* 0x04 RO  bit0 = 发送器忙 */

#endif /* SOC_MAP_H */
