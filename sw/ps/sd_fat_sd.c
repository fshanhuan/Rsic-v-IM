/* =============================================================================
 * sw/ps/sd_fat_sd.c -- 真卡记录：从记录仪 FIFO 取样本 -> CSV -> 写进 SD 卡
 * -----------------------------------------------------------------------------
 * 这是 S5 的"真产品路径"。它只做三件硬件相关的事：
 *   1) 抓样本（记录仪 MMIO）；
 *   2) 位翻转识别 SD 卡，拿到 sd_bus；
 *   3) 调 sd_record_to_card() —— 那段"CSV/格式化/写/回读逐字节比对"的纯逻辑
 *      被抽到 sw/ps/sd_record.c，**同一份代码在 PC 上也会跑**
 *      （tools/ps/host 里用 64 MB 假卡跑，所以它不是"只编译过"）。
 *
 * 样本来源：记录仪 MMIO（PS 侧 0x4001_0000，见 tools/ps/arm_drain.tcl 头注释）
 *   0x4001_008C  读一次 = 弹出一个 16 位样本（idx35）
 *   0x4001_0090  bit0 full / bit1 ovf / bit2 有数据（idx36）
 *   0x4001_0098  bit0 en / bit1 clr_ovf（idx38）
 *   0x4001_00A0  累计 ADC 样本数 adc_cnt（idx40），用来证明"抓的时候数据在动"
 * 注意：这组地址要求 PL 烧的是带记录仪 MMIO 的位流（如 board_top_ps_rec_S5.bit）。
 *       如果 PL 没配对，读 MMIO 会触发 AXI 解码错误 -> 数据中止，异常处理器会打印
 *       "*** CPU FAULT type=3 DFSR=... DFAR=0x40010090 ***"，而不是假装采到了数据。
 *
 * ★ 会**清空卡上原有文件系统**（整卷格式化）。只能在测试卡上用。
 * ============================================================================= */
#include "sd_bit.h"
#include "sd_wr.h"
#include "sd_record.h"
#include "rec_capture.h"
#include "fat32.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define REC_MMIO     0x40010000U
#define REC_DATA     (REC_MMIO + 0x8CU)
#define REC_ST       (REC_MMIO + 0x90U)
#define REC_CTL      (REC_MMIO + 0x98U)
#define REC_CNT      (REC_MMIO + 0xA0U)

#define CSV_BUF      0x00020000U      /* link_ps_sd.ld 预留的 16 KB */
#define CSV_CAP      0x00004000U
#define NSAMP_MAX    1024U

/* 识别完成后把时钟提快（识别阶段必须 100~400 kHz）。300 = ~100 kHz，40 约 5~8 倍。 */
#define SD_HALF_FAST 40U

static u16 samp[NSAMP_MAX] __attribute__((aligned(4)));
static u8  blk[512] __attribute__((aligned(4)));

/* 取样本的实现搬到 sw/ps/rec_capture.h 了 —— 因为那段逻辑有两个真 bug（见那里的说明），
 * 而它在板子上**只有插了卡才会跑到**。抽出来以后 PC 上也能跑同一份代码：
 *   tools/ps/host/rec_capture_test.c 会用假的 rec_mmio 模型调它。
 * 这里只做"接到真实 MMIO"的适配。 */
static unsigned int f_rd(unsigned int a)             { return Xil_In32(a); }
static void         f_wr(unsigned int a, unsigned int v) { Xil_Out32(a, v); }
static void         f_bar(void)                      { __asm__ volatile ("dsb sy" ::: "memory"); }

static const rec_io_ops rec_ops_real = { f_rd, f_wr, f_bar };

static u32 capture(u32 max, u32 *cnt_before, u32 *cnt_after)
{
    return rec_capture(&rec_ops_real, REC_MMIO, samp, max, cnt_before, cnt_after);
}

int main(void)
{
    u32 rca = 0U;
    u32 n;
    u32 c0, c1;
    int rc;
    static fat32_geo g;
    static sd_record_stat st;
    u8 *csv = (u8 *)CSV_BUF;

    port_log_reset();

    if (sd_bit_init() != 0) {
        xil_printf("RESULT FAIL_gpio_selftest\n");
        goto idle;
    }
    xil_printf("\n=== record -> CSV -> SD card (real card) ===\n");

    /* --- 1. 抓样本（和卡无关，先确认"数据在动"） --- */
#ifdef SD_SYNTH_SAMPLES
    /* 编 sd_fat_sd_syn 时走这条：不读记录仪 MMIO。
     * 为什么需要：PL 没烧记录仪位流时，读 0x4001_00xx 会数据中止，于是
     * "验卡"这件事会被"PL 状态"拖住。这个变体把两个变量分开：先用假样本
     * 证明卡能写（同样的 0x800+7i 公式，PC 侧测试用的也是它）。 */
    for (c0 = 0U; c0 < NSAMP_MAX; c0++) {
        samp[c0] = (u16)((0x800U + 7U * c0) & 0xFFFU);
    }
    n = NSAMP_MAX;
    xil_printf("[1] synthetic samples: %u (built with SD_SYNTH_SAMPLES)\n", n);
    c0 = 0U;
    c1 = 0U;
#else
    n = capture(NSAMP_MAX, &c0, &c1);
    xil_printf("[1] captured %u samples, adc_cnt %u -> %u (delta %u)\n",
               n, c0, c1, c1 - c0);
#endif
    if (n < 16U) {
        xil_printf("[1] too few samples: PL 没跑记录仪位流，或 FIFO 本来就没数据\n");
        xil_printf("RESULT FAIL_no_samples\n");
        goto idle;
    }

    /* --- 2. 卡 --- */
    sd_bit_powerup();
    rc = sd_bit_card_init(&rca);
    if (rc != 0) {
        xil_printf("[2] card init failed step=%d waitbits=0x%08x\n", -rc, sd_bit_waitbits());
        xil_printf("RESULT FAIL_no_card\n");
        goto idle;
    }
    xil_printf("[2] card ready, RCA=0x%04x; clock half %u -> %u\n",
               rca, sd_bit_half(), SD_HALF_FAST);

    if (sd_read_block(sd_bit_bus(), 0U, blk) != SDW_OK) {
        xil_printf("[3] cannot read LBA0\n");
        xil_printf("RESULT FAIL_read0\n");
        goto idle;
    }
    xil_printf("[3] LBA0 read ok: %02x %02x %02x %02x ... %02x %02x\n",
               (u32)blk[0], (u32)blk[1], (u32)blk[2], (u32)blk[3],
               (u32)blk[510], (u32)blk[511]);

    /* 提频：识别阶段用的 100 kHz 太慢，格式化要写一千多个块。
     * 但位翻转能跑多快事先不知道，所以由 sd_bit_speed_probe() 试一次：
     * 高速读不出来就自动退回慢速（那只是慢，不是错）。 */
    rc = sd_bit_speed_probe(SD_HALF_FAST, blk);
    xil_printf("[3b] speed probe -> %d, half now %u\n", rc, sd_bit_half());
    if (rc < 0) {
        xil_printf("RESULT FAIL_speed (高速低速都读不出 LBA0)\n");
        goto idle;
    }

    /* --- 3. CSV -> 格式化 -> 写 -> 回读逐字节比对 --- */
    fat32_geo_default(&g);                 /* 64 MB 卷 / 512 B 簇 */
    rc = sd_record_to_card(sd_bit_bus(), &g, samp, n, csv, CSV_CAP, blk, &st);
    xil_printf("[4] sd_record_to_card rc=%d\n", rc);
    if (rc != 0) {
        xil_printf("RESULT FAIL_record rc=%d\n", rc);
        goto idle;
    }

    xil_printf("[5] card file: %u bytes, djb2 card=0x%08x csv=0x%08x, diff=%u\n",
               st.csv_bytes, st.djb2_card, st.djb2_csv, st.bytes_diff);
    xil_printf("[6] first_clus=%u clusters=%u compared=%u\n",
               st.first_clus, st.clusters, st.bytes_compared);
    xil_printf("RESULT PASS\n");

idle:
    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
