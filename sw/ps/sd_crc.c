/* =============================================================================
 * sw/ps/sd_crc.c -- SD 命令帧 CRC7 与数据块 CRC16
 * -----------------------------------------------------------------------------
 * 两个实现都只依赖 xil_types.h，能被 ARM 裸机和 PC 测试共用；
 * 已知答案见 sd_crc.h 头注释，测试在 tools/ps/host/fat32_host_test.c 的 t_crc()。
 *
 * 注意逐字节写成 `volatile` 读：Cortex-A9 上 gcc -O2 可能把相邻的字节访问合并成
 * 字访问，而这几个函数经常被传奇数地址（比如 5 字节命令帧的栈上数组）。见方案 §39.4。
 * ============================================================================= */
#include "sd_crc.h"

u8 sd_crc7(const u8 *d, u32 n)
{
    const volatile u8 *p = d;
    u8 crc = 0U;
    u32 i;
    int b;

    for (i = 0; i < n; i++) {
        u8 v = p[i];

        for (b = 7; b >= 0; b--) {
            u8 in  = (u8)((v >> b) & 1U);
            u8 msb = (u8)((crc >> 6) & 1U);

            crc = (u8)((crc << 1) & 0x7FU);
            if ((msb ^ in) != 0U) {
                crc ^= 0x09U;          /* x^7 + x^3 + 1 */
            }
        }
    }
    return (u8)(crc & 0x7FU);
}

u16 sd_crc16(const u8 *d, u32 n)
{
    const volatile u8 *p = d;
    u16 crc = 0U;
    u32 i;
    int b;

    for (i = 0; i < n; i++) {
        crc ^= (u16)((u16)p[i] << 8);
        for (b = 0; b < 8; b++) {
            if ((crc & 0x8000U) != 0U) {
                crc = (u16)((crc << 1) ^ 0x1021U);
            } else {
                crc = (u16)(crc << 1);
            }
        }
    }
    return crc;
}
