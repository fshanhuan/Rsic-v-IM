/* =============================================================================
 * sw/ps/sd_wr.c -- SD 模式 1-bit 的块读写（CMD17 / CMD24）
 * -----------------------------------------------------------------------------
 * 只依赖 sd_bus 里的回调，不关心底层是 GPIO 位翻转还是内存假卡。
 *
 * 协议细节（SD 物理层规范）：
 *   CMD17(READ_SINGLE_BLOCK) : 响应 R1 之后，卡发 0xFE 起始令牌 + 512 字节 + CRC16
 *   CMD24(WRITE_BLOCK)       : 响应 R1 之后，主机发 0xFE + 512 字节 + CRC16，
 *                              卡回一个数据响应令牌，然后把 DAT0 拉低表示"忙"
 *   数据响应令牌低 5 位：0101=接受, 1011=CRC 错, 1101=写错
 *
 * 返回码见 sd_wr.h；所有失败路径都有独立的负数，测试里逐个注入验证。
 * ============================================================================= */
#include "sd_wr.h"
#include "sd_crc.h"
#include "xil_printf.h"

#define BLK 512U

/* 读的时候要不要校验 CRC16。SD 模式（非 SPI）卡的 CRC 一定是有效的，
 * 校验能抓出采样错误；万一某张卡不给有效 CRC，把它改成 0 即可。 */
#define SDW_VERIFY_READ_CRC 1

/* R1 里的错误位：bit31..19 是各类错误，bit16 = CRC 错，bit15 = 写保护违例。
 * 早先用 0xFFF90000，漏了 bit19 以下的一位，测试注入 0x00200000(bit21) 验证。 */
#define SDW_R1_ERR_MASK 0xFFF98000U

/* XMODEM CRC16（SD 数据块用的就是它）在 sw/ps/sd_crc.c —— 那里有已知答案测试
 * （XMODEM("123456789") 必须等于 0x31C3），见 tools/ps/host/fat32_host_test.c。 */

static void bus_dir(const sd_bus *b, int host_out)
{
    if (b->dir != 0) {
        b->dir(b->ctx, host_out);
    }
}

int sd_read_block(const sd_bus *b, u32 lba, u8 *buf)
{
    u32 r;
    u32 i;
    u32 n;
    u16 c;
    u16 got;

    b->cmd(b->ctx, 17U, lba);
    if (b->resp48(b->ctx, &r) != 0) {
        return SDW_ENORESP;
    }
    if ((r & SDW_R1_ERR_MASK) != 0U) {
        return SDW_ER1;                  /* R1 里报了错 */
    }

    bus_dir(b, 0);                       /* 下面由卡驱动 DAT0 */

    /* 等起始令牌 0xFE（卡可能先发若干 0xFF） */
    for (i = 0; i < 65536U; i++) {
        if (b->rx_d0(b->ctx) == 0xFEU) {
            break;
        }
    }
    if (i >= 65536U) {
        return SDW_ENOTOKEN;
    }

    for (n = 0; n < BLK; n++) {
        buf[n] = b->rx_d0(b->ctx);
    }
    {   /* 注意：两个 rx_d0 必须显式分步取，否则 C 不保证求值顺序 */
        u8 hi = b->rx_d0(b->ctx);
        u8 lo = b->rx_d0(b->ctx);

        got = (u16)(((u16)hi << 8) | (u16)lo);
    }

#if SDW_VERIFY_READ_CRC
    c = sd_crc16(buf, BLK);
    if (c != got) {
        xil_printf("  sdw: rd lba=%u crc got=0x%04x exp=0x%04x\n", lba, got, c);
        return SDW_EDCRC;
    }
#else
    (void)c;
    (void)got;
#endif
    return SDW_OK;
}

int sd_write_block(const sd_bus *b, u32 lba, const u8 *buf)
{
    u32 r;
    u32 i;
    u32 n;
    u16 c;

    b->cmd(b->ctx, 24U, lba);
    if (b->resp48(b->ctx, &r) != 0) {
        return SDW_ENORESP;
    }
    if ((r & SDW_R1_ERR_MASK) != 0U) {
        return SDW_ER1;
    }

    bus_dir(b, 1);                       /* 主机驱动 DAT0 发数据和 CRC */
    b->tx_d0(b->ctx, 0xFEU);
    for (n = 0; n < BLK; n++) {
        b->tx_d0(b->ctx, buf[n]);
    }
    c = sd_crc16(buf, BLK);
    b->tx_d0(b->ctx, (u8)(c >> 8));
    b->tx_d0(b->ctx, (u8)c);

    bus_dir(b, 0);                       /* 交还数据线，卡才能回令牌 */

    /* 数据响应令牌 */
    for (i = 0; i < 64U; i++) {
        u8 t = b->rx_d0(b->ctx);

        if ((t & 0x1FU) == 0x05U) {
            /* 接受：等卡释放忙（DAT0 回高） */
            u32 k = 0U;

            while ((b->rx_bit_d0(b->ctx) == 0U) && (k < 2000000U)) {
                k++;
            }
            if (k >= 2000000U) {
                return SDW_EBUSY;        /* 卡一直忙：写没完成，不能报成功 */
            }
            return SDW_OK;
        }
        if ((t & 0x1FU) == 0x0BU) {
            return SDW_ECRC;             /* 卡说我们 CRC 错 */
        }
        if ((t & 0x1FU) == 0x0DU) {
            return SDW_EWRITE;           /* 卡说写错 */
        }
    }
    return SDW_ENODR;
}

/* ---------------------------------------------------------------
 * fat32_io 适配：ctx 直接就是 sd_bus*，这样 fat32_io 的 read/write 回调
 * 不用再包一层结构体。
 * --------------------------------------------------------------- */
int sd_fat_read(void *ctx, u32 lba, u8 *buf)
{
    return sd_read_block((const sd_bus *)ctx, lba, buf);
}

int sd_fat_write(void *ctx, u32 lba, u8 *buf)
{
    return sd_write_block((const sd_bus *)ctx, lba, buf);
}
