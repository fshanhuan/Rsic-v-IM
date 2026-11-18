/* =============================================================================
 * sw/ps/sd_dump.c -- 真卡证据导出：只把"校验需要的几个扇区"读进 OCM，供 JTAG dump
 * -----------------------------------------------------------------------------
 * 为什么不能直接 dump 整张卡：卡有 64 MB，JTAG 一读一跳太慢；而验证 FAT32 布局
 * 只需要 7 个扇区：引导扇区、FSInfo、备份引导、FAT 第一扇区、根目录簇、以及
 * 文件的前两个数据簇。
 *
 * 缓冲区格式（与 tools/ps/fat32_verify_dump.py、tools/ps/host/ 的 C 测试一致）：
 *   +0      4 字节 'S','D','C','1'
 *   +4      u32 n
 *   +8      n 个 { u32 lba, u32 off }   off = 该扇区数据在缓冲区里的字节偏移
 *   +8+8n   扇区数据（每扇区 512 字节）
 *
 * 卡上的几何参数**不写死**：从引导扇区里读 reserved / nfats / sectors-per-FAT /
 * FSInfo 扇区 / 备份引导扇区号，再算出根目录与数据簇的 LBA。所以哪怕换几何
 * （小卷测试卡 / 64 MB 产品卷）这份程序都适用。
 *
 * 用法：
 *   $env:SD_ELF='sw/build/ps/sd_dump.elf'; xsdb _diag\ps_run_sd.tcl
 *   xsdb _diag\dump_sd_evidence.tcl          # -> sim/build/sd/sd_dump.bin (16 KB)
 *   python tools\ps\fat32_verify_dump.py sim/build/sd/sd_dump.bin
 * ============================================================================= */
#include "sd_bit.h"
#include "sd_wr.h"
#include "sd_record.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define EVID_BASE   0x00020000U      /* link_ps_sd.ld 预留的 16 KB 缓冲区 */
#define EVID_MAX    0x00004000U
#define MAX_ENT     SD_EVID_MAX

static u16 rd16(const u8 *p)
{
    const volatile u8 *q = p;

    return (u16)(q[0] | ((u16)q[1] << 8));
}

static u32 rd32(const u8 *p)
{
    const volatile u8 *q = p;

    return (u32)q[0] | ((u32)q[1] << 8) | ((u32)q[2] << 16) | ((u32)q[3] << 24);
}

static void put32(u8 *p, u32 v)
{
    volatile u8 *q = p;

    q[0] = (u8)v;
    q[1] = (u8)(v >> 8);
    q[2] = (u8)(v >> 16);
    q[3] = (u8)(v >> 24);
}

int main(void)
{
    u8 *ev = (u8 *)EVID_BASE;
    u8 s0[512] __attribute__((aligned(4)));
    u8 s1[512] __attribute__((aligned(4)));
    u32 lbas[MAX_ENT];
    u32 n = 0U;
    u32 i, off, data_off;
    u32 rca = 0U;
    static sd_evid_plan_t plan;
    int rc;

    port_log_reset();

    if (sd_bit_init() != 0) {
        xil_printf("RESULT FAIL_gpio_selftest\n");
        goto idle;
    }
    xil_printf("\n=== SD evidence dump (structure + all data sectors) ===\n");

    sd_bit_powerup();
    rc = sd_bit_card_init(&rca);
    if (rc != 0) {
        xil_printf("RESULT FAIL_card_init step=%d waitbits=0x%08x\n", -rc, sd_bit_waitbits());
        goto idle;
    }
    xil_printf("[1] card ready RCA=0x%04x\n", rca);

    if (sd_read_block(sd_bit_bus(), 0U, s0) != SDW_OK) {
        xil_printf("RESULT FAIL_read0\n");
        goto idle;
    }

    /* 选哪些扇区：交给 sd_evid_plan()（同一份逻辑在 PC 上也被测过）。
     * 先只要"结构扇区"（root=NULL），拿到 root_lba；读根目录；再算完整计划。 */
    rc = sd_evid_plan(s0, 0, &plan);
    if (rc != 0) {
        xil_printf("RESULT FAIL_bpb rc=%d (卷看起来不是 FAT32)\n", rc);
        goto idle;
    }
    xil_printf("[2] plan: total=%u rsv=%u fatsec=%u root_lba=%u\n",
               plan.total_sec, plan.reserved, plan.fat_sec, plan.root_lba);

    if (sd_read_block(sd_bit_bus(), plan.root_lba, s1) != SDW_OK) {
        xil_printf("RESULT FAIL_read_root\n");
        goto idle;
    }
    rc = sd_evid_plan(s0, s1, &plan);
    if (rc == -2) {
        xil_printf("RESULT FAIL_too_many (文件太大，%u 个扇区放不进 %u 的缓冲)\n",
                   plan.n, (u32)SD_EVID_MAX);
        goto idle;
    }
    if (rc != 0) {
        xil_printf("RESULT FAIL_plan rc=%d\n", rc);
        goto idle;
    }
    xil_printf("[2b] file first_clus=%u len=%u -> %u data sectors, %u total\n",
               plan.first_clus, plan.file_len, plan.data_secs, plan.n);

    for (i = 0U; i < plan.n; i++) {
        lbas[i] = plan.lba[i];
    }
    n = plan.n;

    ev[0] = 'S'; ev[1] = 'D'; ev[2] = 'C'; ev[3] = '1';
    put32(&ev[4], n);
    data_off = 8U + 8U * n;

    for (i = 0U; i < n; i++) {
        off = data_off + i * 512U;
        put32(&ev[8U + 8U * i], lbas[i]);
        put32(&ev[12U + 8U * i], off);
        rc = sd_read_block(sd_bit_bus(), lbas[i], &ev[off]);
        xil_printf("[3] lba %u -> off 0x%04x : %s\n", lbas[i], off, (rc == 0) ? "ok" : "FAIL");
        if (rc != 0) {
            xil_printf("RESULT FAIL_read (lba=%u rc=%d)\n", lbas[i], rc);
            goto idle;
        }
    }

    xil_printf("[4] evidence buffer at 0x%08x, %u sectors, %u bytes\n",
               (u32)EVID_BASE, n, data_off + n * 512U);
    xil_printf("[5] now run: xsdb _diag\\dump_sd_evidence.tcl\n");
    xil_printf("RESULT PASS\n");

idle:
    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
