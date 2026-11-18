/* =============================================================================
 * sw/app/recorder.c -- 记录仪主循环（S3：列摘要 -> 上屏）
 * -----------------------------------------------------------------------------
 * 硬件分工（这是本项目的核心设计决定）：
 *   · XADC 在硬件里以 200 kHz 连续采样，样本进 1024 深 FIFO；
 *   · CPU **只做列摘要**：每帧 800 列，每列取 SAMPLES_PER_COL 个样本，
 *     算 min/max，用一次 MMIO 写（0x80 COL_PUSH）把整列推到显示子系统；
 *   · 显示子系统（scope_display）用双 bank ping-pong，CPU 写一块、屏幕扫另一块。
 *
 * 为什么不让 CPU 直接搬每个样本上屏：
 *   800 列 x 20 bit 的列缓冲在 FPGA 里是 2 KB；若让 CPU 逐样本写，每帧要写
 *   3333 次 MMIO（约 0.7 ms，能忍），但**软件要参与每一个样本**，一旦被中断
 *   打断就丢数据。列摘要把软件参与次数降到 800 次/帧，而且硬件 FIFO 兜住了
 *   抖动。
 *
 * 时序预算（50 MHz）：
 *   一帧 16.58 ms；800 列 x 4 样本 = 3200 样本 @200 kHz = 16.0 ms —— 刚好
 *   跟得上，CPU 还有余量。若把 SAMPLES_PER_COL 调到 8，采样率就得降到 100 kHz
 *   或帧率降到 30 Hz，否则 FIFO 会溢出。
 *
 * ★ ADC 原始值左对齐：12 位结果在 raw[15:4]（见 adctest.c 的说明）。
 * ★ 写列要用 DISP_ST 报出来的 bank，否则会和扫描撞在同一块上产生撕裂。
 * ============================================================================= */
#define UART_TXDATA (*(volatile unsigned int *)0x10000000u)
#define UART_TXSTAT (*(volatile unsigned int *)0x10000004u)

#define MMIO(i)     (*(volatile unsigned int *)(0x10000000u + 4u * (unsigned int)(i)))

#define R_ADC_DATA  MMIO(35)   /* 0x8C RO  队头（窥视） */
#define R_ADC_ST    MMIO(36)   /* 0x90 RO  bit0 full bit1 ovf bit2 有数据 */
#define R_ADC_LVL   MMIO(37)   /* 0x94 RO  FIFO 深度 */
#define R_ADC_CTL   MMIO(38)   /* 0x98 RW  bit0 en bit1 clr_ovf bit2 pop */
#define R_ADC_LAST  MMIO(41)   /* 0xA4 RO  最新样本（诊断用） */
#define R_COL_PUSH  MMIO(32)   /* 0x80 WO  {2'b0, max[9:0], min[9:0], col[9:0]} */
#define R_DISP_ST   MMIO(33)   /* 0x84 RO  bit0 = 该写哪块 bank */
#define R_DISP_CTL  MMIO(42)   /* 0xA8 WO  写 1 = 提交一帧（下次帧同步才翻 bank） */
#define R_TEXT_PUT  MMIO(51)   /* 0xCC WO  {line[0], col[4:0], ch[4:0]} 写一个字符单元 */

/* 字模索引（见 board/font5x7.sv 末尾的索引表） */
#define G_SPC  0u
#define G_0    1u
#define G_9   10u
#define G_DOT 11u
#define G_MIN 12u
#define G_V   14u
#define G_P   15u
#define G_M   16u
#define G_I   17u
#define G_N   18u
#define G_A   19u
#define G_X   20u
#define G_E   21u

/* S6 测量寄存器 */
#define R_MEAS_MIN   MMIO(47)
#define R_MEAS_MAX   MMIO(48)
#define R_MEAS_MEAN  MMIO(49)
#define R_MEAS_CNT   MMIO(50)

#define NCOLS        800u
#define SAMP_PER_COL   4u

extern char __bss_start[], __bss_end[];

static void putc_(char c)
{
    while (UART_TXSTAT & 1u)
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
}

/* =============================================================================
 * rd_mmio -- 同一个 MMIO 地址**连读两次**，取第二次的值
 * -----------------------------------------------------------------------------
 * 为什么必须这样（2026-11-17 用 sim/tb_recorder.sv 逐拍定位出来的核心缺陷）：
 *   本核的 DCache 在"不可缓存读"上有一拍错位：连续读**两个不同**的 MMIO 寄存器时，
 *   第一次读到的是**上一条地址**的数据。仿真证据（docs/记录仪_HDMI_方案.md §25）：
 *     · 总线侧  prdata = 0x00000400（正确，1024）
 *     · DCache 放行那拍 cpu_rdata = 0x00000400（正确）
 *     · 但 `lw t2,0x94` 写回 t2 的却是 0x0/0x1 —— 正好是前一个寄存器 0x84 的 bank 值
 *   后果：软件算 avail=0/1 → 每列取 0 个样本 → 一帧一个样本都不弹，屏幕只有平线。
 *
 *   为什么 monitor 一直没暴露：它全是 `while (!(RXSTAT & 1));` 这种**同地址轮询**，
 *   相邻两次读地址相同，错位也读到同一个寄存器的值，所以"看起来一直是对的"。
 *
 * 这个函数就是把"同地址连读"这个已知正确的用法显式化：
 *   第一次读是"空读"（只为把那一条地址送进总线），第二次读才是真实值。
 *   本文件里用到的 MMIO 读口（33/35/36/37/41/47..50）全部**只读、无副作用**，
 *   多读一次不会改变任何硬件状态。
 *
 * ★ 这是**绕过**，不是根治。根治要改 rtl/DCache.sv 的不可缓存响应时序，
 *   改完必须用 54 项全量回归 + tb_monitor + tb_recorder 三边同时验证。
 * ========================================================================== */
static unsigned int rd_mmio(volatile unsigned int *p)
{
#ifdef REC_SINGLE_READ
    /* ★ 只在"验证 RTL 是否已经修好"时编进这个分支：单读一次。
     *   如果核心的不可缓存读时序是好的，单读就应该拿到正确值；
     *   sim/tb_recorder.sv 用 -DSINGLE_IMG 指向这份镜像来判定 RTL 修复是否有效。 */
    return *p;
#else
    (void)*p;      /* 空读：只为把地址送进总线 */
    return *p;     /* 实读：此时总线给的就是这个地址的数据 */
#endif
}

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static void put_dec(unsigned int v)
{
    char buf[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i) putc_(buf[--i]);
}

static void put_hex16(unsigned int v)
{
    static const char hx[] = "0123456789ABCDEF";
    for (int sh = 12; sh >= 0; sh -= 4)
        putc_(hx[(v >> sh) & 0xF]);
}

/* ============================ S6 文本面板 ============================
 * 面板 2 行 x 32 列，字符格 8x8，左上角在屏幕 (16,16)。
 * 这里只写"行 0 = VPP，行 1 = 均值"，单位伏，保留 3 位小数（0.000 ~ 1.000 V）。
 *
 * ★ 为什么软件不自己算小数：XADC 12 位原始值左对齐在 raw[15:4]，
 *   mV = code12 * 1000 / 4096。这里用 64 位乘避免溢出，再逐位拆成字符。
 * ========================================================================= */
static void panel_put(int line, int col, unsigned int ch)
{
    R_TEXT_PUT = ((unsigned int)(line & 1) << 10)
               | ((unsigned int)(col & 0x1F) << 5)
               | (ch & 0x1Fu);
}

static void panel_clear_line(int line)
{
    for (int c = 0; c < 32; c++) panel_put(line, c, G_SPC);
}

/* 写 "标签 0.mmm" 这样的一个数（值以 mV 计，0~1000） */
static void panel_num(int line, int col, unsigned int mv)
{
    mv = mv % 1000u;                       /* 0.000 ~ 0.999 V */
    panel_put(line, col + 0, G_0 + (mv / 100u));        /* 整数位（0） */
    panel_put(line, col + 1, G_DOT);
    panel_put(line, col + 2, G_0 + ((mv / 10u) % 10u));
    panel_put(line, col + 3, G_0 + (mv % 10u));
}
/* 12 位 ADC（左对齐在 raw[15:4]）→ 10 位显示坐标（固定量程，保留对比用） */
static unsigned int adc_y(unsigned int raw)
{
    return ((raw >> 4) & 0xFFFu) >> 2;
}

/* =============================================================================
 * 自动量程（vertical auto-range）
 * -----------------------------------------------------------------------------
 * 为什么要它：显示的纵轴有 1024 行，而 AD11 量程是 0~1 V（12 位 → 4096 码）。
 *   固定量程下，一个 100 mV 的信号只占屏幕 10% 的高度，几乎看不出形状；
 *   而记录仪最常测的就是小幅信号（温度传感器噪声只有 20 个码 = 2% 屏高）。
 *
 * 做法：用硬件测量窗（meas_unit）给出的 min/max 当"当前信号范围"，每 8 帧更新一次
 *   （≈7.5 Hz，肉眼看不出跳变），把 [lo, lo+span] 线性映射到 0~1023：
 *       y = (code - lo) * 1023 / span
 *   再留 12.5% 的上下余量、并且给 span 一个下限（8 个码），避免：
 *     · 信号恒定时 span=0 → 除零；
 *     · 纯噪声被放大成满屏雪花。
 *
 * ★ 面板上的 VPP/MEAN 仍然是**真实物理量**（mV），自动量程只改显示坐标，
 *   不改任何测量值 —— 这一点很重要：不能为了好看去动测量。
 * ========================================================================== */
static unsigned int y_lo   = 0;        /* 窗口下界（12 位码） */
static unsigned int y_span = 1024;     /* 窗口宽度（≥ 8） */

static void autorange_update(unsigned int c_lo, unsigned int c_hi)
{
    unsigned int span = (c_hi > c_lo) ? (c_hi - c_lo) : 0u;
    unsigned int pad;
    if (span < 8u) {                    /* 恒定/极小幅信号：给个固定小窗，居中显示 */
        span = 8u;
        c_lo = (c_lo > 4u) ? (c_lo - 4u) : 0u;
    } else {
        pad  = span / 8u;               /* 上下各留 12.5% */
        c_lo = (c_lo > pad) ? (c_lo - pad) : 0u;
        span = span + 2u * pad;
        if (span > 4096u) span = 4096u;
    }
    y_lo   = c_lo;
    y_span = span;
}

static unsigned int map_y(unsigned int raw)
{
    unsigned int code = (raw >> 4) & 0xFFFu;
    unsigned int d;
    if (code <= y_lo)            return 0u;
    d = code - y_lo;
    if (d >= y_span)             return 1023u;
    return (d * 1023u) / y_span;        /* y_span ≥ 8，不会除零 */
}

int main(void)
{
    for (char *p = __bss_start; p < __bss_end; p++)
        *p = 0;

    puts_("\r\n== recorder (S3: ADC -> column summary -> display) ==\r\n");
    puts_("cols=");   put_dec(NCOLS);
    puts_(" samp/col="); put_dec(SAMP_PER_COL);
    puts_("  expect "); put_dec(NCOLS * SAMP_PER_COL);
    puts_(" samples/frame @200kHz = ");
    put_dec((NCOLS * SAMP_PER_COL) / 200u); puts_(" ms\r\n");

    /* 确保采样器在跑（复位默认就是 1，这里显式写一次） */
    R_ADC_CTL = 1u;
    panel_clear_line(0);
    panel_clear_line(1);

    unsigned int frames = 0, ovf_seen = 0, tears = 0, empty_frames = 0;
    unsigned int lvl_min = 0xFFFF, lvl_max = 0;
    unsigned int last_c = 0, last_min = 1023, last_max = 0;

    for (;;) {
        unsigned int bank0 = rd_mmio(&R_DISP_ST) & 1u;
        unsigned int avail = rd_mmio(&R_ADC_LVL) & 0x7FFu;

        /* ★ 为什么"按可用量分配"而不是固定每列 4 个：
         *   显示一帧 = 663168 pixclk / 40 MHz = 16.579 ms（60.32 Hz）
         *   而 800x4 = 3200 个样本 @200 kHz 只要 16.000 ms（62.5 Hz）
         *   两者差 3.6% —— 每帧 FIFO 净增约 116 个样本，1024 深的 FIFO
         *   大约 9 帧就满、然后开始丢数据。实测这条必须先算清楚再写代码。
         *   改成：每帧把"当前可用的样本"全部取走，按列平均分配（余数给前几列）。
         *   生产多少就消费多少，软件自动跟住采样率，不会累积溢出。
         *   上限 800*8 是为了防止 FIFO 长期积压后一次抢太多、把一帧拖太久。 */
        if (avail > NCOLS * 8u) avail = NCOLS * 8u;

        unsigned int per = avail / NCOLS;          /* 每列基础样本数（可能为 0） */
        unsigned int rem = avail % NCOLS;          /* 余数：前 rem 列多取 1 个 */

        for (unsigned int col = 0; col < NCOLS; col++) {
            unsigned int mn = 1023u, mx = 0u;
            unsigned int want = per + (col < rem ? 1u : 0u);

            for (unsigned int k = 0; k < want; k++) {
                if (!(rd_mmio(&R_ADC_ST) & 4u))
                    break;                          /* 已经取空，不再空转 */
                unsigned int y = map_y(rd_mmio(&R_ADC_DATA));
                /* ★ 写 5 = en(bit0) + pop(bit2)，不是 4。
                 *   老 RTL 里 ADC_CTL 的 bit0 是"电平写入"，只写 4 会把 en 清掉
                 *   → 采样本永久停住（2026-11-17 上板实测踩到：adc_cnt 停在 1024）。
                 *   新 RTL 已经改成"bit2 不动 en"，写 5 在新旧两版上都安全。 */
                R_ADC_CTL = 5u;                     /* en + pop */
                if (y < mn) mn = y;
                if (y > mx) mx = y;
            }

            if (mn > mx) {                          /* 这一列没取到样本：沿用新值 */
                unsigned int y = map_y(rd_mmio(&R_ADC_LAST) & 0xFFFFu);
                mn = y; mx = y;
            }

            R_COL_PUSH = (mx << 20) | (mn << 10) | col;

            last_c = col; last_min = mn; last_max = mx;

            /* 写列过程中 bank 变了 → 说明提交/翻转没锁上，计一次撕裂 */
            if ((rd_mmio(&R_DISP_ST) & 1u) != bank0) tears++;
        }

        /* ★ 800 列写完了：提交，让显示子系统在**下一次帧同步**才换 bank。
         *   这样"写"和"翻"的节奏锁在一起，不会写到一半被翻走。 */
        R_DISP_CTL = 1u;

        /* ★ 2026-11-17 上板后补的一步：**等 bank 真的翻过去**再进下一轮。
         *   不加这一步会怎样（实测）：主循环只受 MMIO 延迟限制，约 2500 次/秒；
         *   而显示是 60 Hz，于是 98% 的提交都被后来的覆盖掉，屏幕上永远是"最后一个
         *   0.4 ms 里的数据"，而且每次只取到约 80 个真实样本（其余列用 ADC_LAST 顶替）。
         *   加上等待后主循环 = 一帧一次（16.58 ms）：
         *     每帧拿到 FIFO 里的 1024 个样本 → 800 列各 1 个，前 224 列各 2 个，
         *     列列都是真实采样值，没有一个 ADC_LAST 顶替。
         *   带宽账（如实说明）：200 kHz × 16.58 ms ≈ 3316 个样本/帧，FIFO 只有 1024 深，
         *   所以每帧约 2/3 的样本被硬件丢弃（ovf 会每帧置位）。这是 FIFO 深度决定的，
         *   不是软件丢的；要一个不丢就改采样率（xadc_sampler 的轮询分频）或加深 FIFO。 */
        {
            unsigned int guard = 0;
            while ((rd_mmio(&R_DISP_ST) & 1u) == bank0) {
                if (++guard > 20000u)
                    break;                 /* 显示没在跑也别死等，最多约 1.6 ms */
            }
        }

        /* ---------------- S6 文本面板：每 8 帧刷一次（够用，省 MMIO 带宽）---------------- */
        if ((frames & 7u) == 0u) {
            unsigned int c_mx = (rd_mmio(&R_MEAS_MAX)  >> 4) & 0xFFFu;
            unsigned int c_mn = (rd_mmio(&R_MEAS_MIN)  >> 4) & 0xFFFu;
            unsigned int c_me = (rd_mmio(&R_MEAS_MEAN) >> 4) & 0xFFFu;

            /* 自动量程：用同一个窗口的 min/max 当纵轴范围（每 8 帧更新 ≈7.5 Hz） */
            autorange_update(c_mn, c_mx);

            /* 12 位码 → mV（0~1000）：用 64 位乘避免溢出 */
            unsigned int mv_vpp  = (unsigned int)(((unsigned long long)(c_mx - c_mn) * 1000ull) / 4096ull);
            unsigned int mv_mean = (unsigned int)(((unsigned long long)c_me * 1000ull) / 4096ull);

            /* 行 0： "VPP 0.mmm" */
            panel_put(0, 0, G_V); panel_put(0, 1, G_P);
            panel_put(0, 2, G_P); panel_put(0, 3, G_SPC);
            panel_num(0, 4, mv_vpp);

            /* 行 1： "MEAN 0.mmm" */
            panel_put(1, 0, G_M); panel_put(1, 1, G_E);
            panel_put(1, 2, G_A); panel_put(1, 3, G_N);
            panel_put(1, 4, G_SPC);
            panel_num(1, 5, mv_mean);
        }

        {
            unsigned int st = rd_mmio(&R_ADC_ST);
            unsigned int lv = rd_mmio(&R_ADC_LVL) & 0x7FFu;
            if (st & 2u) { ovf_seen++; R_ADC_CTL = 3u; }   /* en + clr_ovf（理由同上） */
            if (lv < lvl_min) lvl_min = lv;
            if (lv > lvl_max) lvl_max = lv;

            /* 先一直没数据就报错退出，别静默地画一屏"假波形" */
            if (avail == 0u) {
                if (++empty_frames > 200u) goto no_data;
            } else {
                empty_frames = 0u;
            }
        }
        frames++;

        if ((frames % 60u) == 0u) {
            puts_("frames=");  put_dec(frames);
            puts_(" ovf=");    put_dec(ovf_seen);
            puts_(" tear=");   put_dec(tears);
            puts_(" lvl=");    put_dec(lvl_min); putc_('-'); put_dec(lvl_max);
            puts_(" col");     put_dec(last_c);
            puts_("=");        put_dec(last_min); putc_('-'); put_dec(last_max);
            puts_(" adc=");    put_hex16(rd_mmio(&R_ADC_LAST) & 0xFFFFu);
            puts_("\r\n");
        }
    }
no_data:
    /* 采样器没给数据：报清楚状态再退出，不要静默死循环 */
    puts_("\r\n[ERROR] no ADC data. st=0x");
    put_hex16(rd_mmio(&R_ADC_ST) & 0xFFFFu);
    puts_(" lvl=");  put_dec(rd_mmio(&R_ADC_LVL) & 0x7FFu);
    puts_(" last=0x"); put_hex16(rd_mmio(&R_ADC_LAST) & 0xFFFFu);
    puts_("\r\n  检查：ADC_CTL.bit0 是否为 1、XADC 的 DCLK/RESET、INIT_41/42\r\n");
    return 1;
}
