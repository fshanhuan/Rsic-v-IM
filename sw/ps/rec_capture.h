/* =============================================================================
 * sw/ps/rec_capture.h -- 记录仪 FIFO 的"取样本"逻辑（**板子和 PC 共用同一份**）
 * -----------------------------------------------------------------------------
 * 为什么把这段抽出来：
 *   2026-11-20 00:30 在这段里查出两个真 bug（而且只有在"有卡"时才会跑到）：
 *     1) idx35(0x8C) 读**只是窥视队头**，弹出必须写 idx38(0x98) 的 bit2；
 *        原来的代码只读不弹 → 1024 个样本全是同一个队头值。
 *     2) XADC 结果是**左对齐 16 位**，12 位码在 [15:4]；原来的 `& 0x0FFF`
 *        取成了低 12 位。
 *   这两个 bug 能活几个月，是因为这段代码在 PC 上从来跑不到（主机测试只测
 *   fat32/sd_wr，不测 MMIO 取样本）。抽到 header 里以后：
 *     · 板上：sd_fat_sd.c 用真实的 Xil_In32/Xil_Out32 调它
 *     · PC 上：tools/ps/host/rec_capture_test.c 用假的 rec_mmio 模型调它
 *   —— 同一份代码，两边都跑，协议错了 PC 上立刻红。
 *
 * 寄存器（PS 侧 0x4001_0000 + 偏移，见 board/rec_mmio.sv）：
 *   0x8C  读 = FIFO 队头（**只窥视**，不弹）
 *   0x90  bit2 写 1 = 弹出一个；bit0 = en（bit2=1 时 bit0 被忽略）
 *   0x94  bit2 = 有数据可读
 *   0xA0  累计样本数（用来证明"取的时候数据在动"）
 *
 * 用法见 sd_fat_sd.c 与 host/rec_capture_test.c。
 * ============================================================================= */
#ifndef REC_CAPTURE_H
#define REC_CAPTURE_H

#define REC_OFF_DATA  0x8CU
#define REC_OFF_ST    0x94U
#define REC_OFF_CTL   0x98U
#define REC_OFF_CNT   0xA0U

#define REC_ST_LEVEL_MASK 0x4U    /* bit2: FIFO 里有数据 */
#define REC_CTL_EN        0x1U    /* bit0: 启动轮询 */
#define REC_CTL_POP       0x4U    /* bit2: 弹出一个（与 en 同拍写时 en 被忽略） */

#define REC_GUARD         200000U /* 等"有数据"的上限，超时即认为取完了 */

typedef struct {
    unsigned int (*rd)(unsigned int addr);
    void         (*wr)(unsigned int addr, unsigned int val);
    /* 写是 posted 的：不等它落地就再窥视会又读到同一个队头。
     * 板上给 dsb；PC 上给 NULL（顺序执行，不需要）。 */
    void         (*barrier)(void);
} rec_io_ops;

/* 取最多 max 个样本；返回实际拿到的个数，c0/c1 是前后两次 adc_cnt。 */
static inline unsigned int rec_capture(const rec_io_ops *io, unsigned int base,
                                       unsigned short *out, unsigned int max,
                                       unsigned int *c0, unsigned int *c1)
{
    unsigned int n = 0U;
    unsigned int guard;

    *c0 = io->rd(base + REC_OFF_CNT);
    io->wr(base + REC_OFF_CTL, REC_CTL_EN);

    while (n < max) {
        guard = 0U;
        while (((io->rd(base + REC_OFF_ST) & REC_ST_LEVEL_MASK) == 0U) && (guard < REC_GUARD)) {
            guard++;
        }
        if (guard >= REC_GUARD) {
            break;                          /* FIFO 空了：正常结束 */
        }
        /* 左对齐 16 位 -> 12 位码 */
        out[n] = (unsigned short)((io->rd(base + REC_OFF_DATA) >> 4) & 0x0FFFU);
        io->wr(base + REC_OFF_CTL, REC_CTL_POP);
        if (io->barrier) { io->barrier(); }
        n++;
    }

    *c1 = io->rd(base + REC_OFF_CNT);
    return n;
}

#endif /* REC_CAPTURE_H */
