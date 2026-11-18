/* =============================================================================
 * sw/ps/sd_bit.c -- 诊断程序：用 MIO 位翻转识别 SD 卡并读 LBA0
 * -----------------------------------------------------------------------------
 * 硬件层在 sd_bit_bus.c（MIO 复用、时钟、命令/响应、sd_bus 适配），
 * 块读在 sd_wr.c（CMD17 + 令牌 + CRC）。这个文件只负责"跑一遍、打日志、判定"。
 *
 * 为什么重要：块读走的是 sd_wr.c 的**同一个函数**，和内存假卡测试
 * (sd_wr_test.c) 用的完全一样 —— 所以假卡测试通过之后，这里唯一的未知
 * 就只剩"位翻转时序在真卡上对不对"，协议逻辑不必再查。
 * ============================================================================= */
#include "sd_bit.h"
#include "sd_wr.h"
#include "xil_printf.h"
#include "sleep.h"

static void dump_hex(const u8 *p, u32 n)
{
    u32 i;

    for (i = 0U; i < n; i++) {
        if ((i % 16U) == 0U) { xil_printf("\n  %04x:", i); }
        xil_printf(" %02x", (u32)p[i]);
    }
    xil_printf("\n");
}

int main(void)
{
    u32 rca = 0U;
    u8 *buf = (u8 *)0x00020000U;      /* link_ps_sd.ld 里预留的 16 KB 缓冲 */
    int rc;
    int ok = 0;

    port_log_reset();

    if (sd_bit_init() != 0) {
        xil_printf("RESULT FAIL_gpio_selftest (MIO 复用没配对)\n");
        goto idle;
    }

    xil_printf("\n=== SD Mode (1-bit, bit-banged over MIO) ===\n");
    xil_printf("half=%u (~%u kHz)\n", sd_bit_half(), 1000000U / (sd_bit_half() * 10U + 1U));

    sd_bit_powerup();
    rc = sd_bit_card_init(&rca);
    if (rc != 0) {
        xil_printf("RESULT FAIL_card_init step=%d waitbits=0x%08x\n",
                   -rc, sd_bit_waitbits());
        goto idle;
    }

    xil_printf("[8] card ready (RCA=0x%04x), reading LBA0 through sd_read_block()\n", rca);
    rc = sd_read_block(sd_bit_bus(), 0U, buf);
    if (rc != 0) {
        xil_printf("[8] sd_read_block rc=%d\n", rc);
        xil_printf("RESULT FAIL_read rc=%d\n", rc);
        goto idle;
    }

    xil_printf("[8] read 512 bytes ok\n");
    dump_hex(buf, 64U);

    if ((buf[510] == 0x55U) && (buf[511] == 0xAAU)) {
        xil_printf("    MBR 0x55AA -> OK\n");
        ok = 1;
    } else if ((buf[82] == 'F') && (buf[83] == 'A') && (buf[84] == 'T')) {
        xil_printf("    superfloppy FAT -> OK\n");
        ok = 1;
    }
    xil_printf(ok ? "RESULT PASS\n" : "RESULT FAIL_no_fs_signature\n");

idle:
    xil_printf("=== done ===\n");
    for (;;) {
        usleep(500000UL);
    }
    return 0;
}
