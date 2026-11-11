# IROM 两段式布局：`0x0000` 主镜像 + `0x4000` 程序区

> 汇报用代码清单。所有代码均为仓库原文（`sw/`、`rtl/`、`board/`），不是伪代码。
> 环境：BigBird RV32IM+Zicsr+Zicntr，50 MHz，IROM 64 KB / 16384 words，哈佛结构（取指口与数据口地址独立）。

---

## 0　一张表看完

| 区间（**取指口**地址） | 大小 | 放什么 | 由谁决定 |
|---|---|---|---|
| `0x0000` ~ `_etext` | ≈13.8 KB | **主镜像** `.text`（crt0 + shell 全部代码） | `sw/coremark_port/link.ld:20` 与 `:36` |
| `_etext` ~ `0x4000` | 空隙 | 4 KB 对齐余量 | `sw/monitor.c:62` 取整 |
| `0x4000` ~ `0xFFFF` | **48 KB** | **可加载程序区** `.text` | `sw/app/link_app.ld:19` |
| `0x2_0000` ~ `0x2_FFFF`（**数据口**） | 64 KB 窗口 | 同一块 IROM 的第二读/写口 | `board/board_top.sv:152` |

> 两段共用同一块 64 KB BRAM：低段由**引导器**在复位期间灌入，高段由 **shell 在运行期**通过数据窗口灌入。

---

## 1　第一段：主镜像链接脚本（全文）

`sw/coremark_port/link.ld`

```ld
/* =============================================================================
 * sw/coremark_port/link.ld -- CoreMark 的内存布局
 * -----------------------------------------------------------------------------
 *   irom : 0x0000_0000 .. 0x0000_FFFF  (64 KB)  只放 .text（取指口）
 *   dram : 0x0001_0000 .. 0x0001_FFFF  (64 KB)  .rodata/.data/.bss + 栈（数据口）
 *          ★ 板级 DRAM 实际有 128 KB（0x0_0000~0x1_FFFF），但 0x0_0000~0x0_FFFF
 *            故意留空给 IROM 的同地址空洞，所以数据能用的只有上半 64 KB。
 *
 * ★ 为什么 .rodata 也在 dram：本核 lw/lb 只能访问数据口，读不到 IROM。
 *   C 语言的字符串常量、const 表都必须放在能被 lw 读到的地方。
 * ★ 为什么 dram 不从 0 开始：irom 也从 0 开始译码，数值重叠会让同一地址在
 *   取指口/数据口指到不同物理存储（程序能跑，但调试时极易看错）。
 *   留出 64 KB 空洞是最省心的做法。
 * ============================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    irom (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    dram (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}

_stack_top = ORIGIN(dram) + LENGTH(dram);

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
        . = ALIGN(4);
        /* ★ v16：monitor 的 `load`/`run` 用它算"自己的代码区到哪儿结束"，
         *   再往上取 4KB 对齐才是可以安全 load 应用的下界。
         *   硬编码 0x3000 踩过坑：monitor 加了 load/run 两条命令后 text 涨到
         *   13 836 B（> 0x3000），load 会覆盖 shell 自己。 */
        _etext = .;
    } > irom

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > dram

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > dram

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.*) *(COMMON)
        *(.sbss .sbss.*)
        . = ALIGN(4);
        __bss_end = .;
    } > dram

    __global_pointer$ = ADDR(.data) + 0x800;

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
```

**三个关键点**

1. `ORIGIN = 0x00000000` —— 这就是"主镜像从 0 开始"的唯一来源，配合 `rtl/IFU.sv:214` 复位 PC = 0。
2. `_etext = .` —— 链接器自动填的符号，`SECTIONS` 内 `.text` 结束的位置。
3. `_stack_top = ORIGIN(dram) + LENGTH(dram)` = `0x2_0000` —— 就是 DRAM 顶，`crt0.S` 拿它初始化 `sp`。

---

## 2　第二段：程序区链接脚本（全文）

`sw/app/link_app.ld`

```ld
/* =============================================================================
 * sw/app/link_app.ld -- "从 shell 加载并运行" 的 C 应用内存布局
 * -----------------------------------------------------------------------------
 * 与 sw/coremark_port/link.ld 的区别只有两处：
 *   1. .text 从 **0x4000** 开始（0x0~0x2FFF 是 shell 自己，见 IROM_APP_MIN）；
 *   2. 没有 crt0（.text.init 不需要）：入口就是 C 的 main，由 shell 用 jalr 调用，
 *      sp 沿用 shell 的栈 —— 应用返回就回到 shell。
 *
 * ★ 为什么 .rodata 仍必须放 DRAM：本核 lw 走数据口，地址 0x3000 会被译到 **DRAM**
 *   （不是 IROM 窗口 0x2_xxxx），所以字符串常量、const 表都必须落在 DRAM 段，
 *   运行时由 `D 10000` 灌进去。放 IROM 的只有**取指**读的那些字节。
 * ★ 栈：不在这里开（用 shell 的）。
 * ============================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(main)

MEMORY
{
    irom (rx)  : ORIGIN = 0x00004000, LENGTH = 48K
    dram (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text .text.*)
        . = ALIGN(4);
        _etext = .;
    } > irom

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > dram

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > dram

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > dram

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
```

**与第一段的四个差别**

| 项 | 主镜像 | 程序区 |
|---|---|---|
| `.text` 起点 | `0x0000` | `0x4000` |
| 大小上限 | 64 KB | 48 KB |
| 入口 | `ENTRY(_start)` + crt0，自己设 `gp`/`sp` | `ENTRY(main)`，**没有 crt0**，沿用 shell 的 `sp` |
| `.rodata` | DRAM | DRAM（一样，因为 `lw` 到不了 IROM） |

> ⚠️ 该文件第 5 行注释仍写着"0x0~0x2FFF 是 shell 自己"，是 v16 早期的旧口径；**以第 19 行的 `ORIGIN = 0x00004000` 为准**。

---

## 3　两段的边界是怎么算出来的

### 3.1 链接器把 `_etext` 导出

见上面 `link.ld` 第 36 行：

```ld
        . = ALIGN(4);
        _etext = .;
    } > irom
```

### 3.2 shell 把它向上取整到 4 KB

`sw/monitor.c:54-62`

```c
/* IROM 数据窗口基址（与 board_top 的 irom_win_sel 一致） */
#define IROM_WIN   0x00020000u
#define DRAM_BASE  0x00010000u

/* ★ v16：shell 自己代码区的结束地址（link.ld 的 `_etext`）。向上取 4KB 对齐之后，
 *   才是可以安全 `load` 应用的下界 —— 硬编码 0x3000 踩过坑：加了 load/run 两条
 *   命令之后 text 涨到 13 836 B（> 0x3000），load 会覆盖 shell 自己。 */
extern char _etext[];
#define IROM_APP_MIN ((uint32_t)(((uint32_t)_etext + 0xFFFu) & ~0xFFFu))
```

`13 836 B = 0x3610`，`+0xFFF` 后掩掉低 12 位 → **`0x4000`**，正好等于 `link_app.ld` 的 `ORIGIN`。

> 这就是"两段"的接缝：**边界不是常量，是链接器算的**；改 shell 代码不会让程序区错位，只会让接缝上移。

---

## 4　shell 怎么把程序写进去（`L` 命令）

`sw/monitor.c:463-529`（节选实现＋原文注释）

```c
/* ---------------------------------------------------------------- load / run
 * ★ v16：`load` 把 ASCII 十六进制行写进 **IROM 数据窗口**（0x2_0000 + addr），
 *   `run` 再跳到**取指地址**（= 同一个字地址，因为窗口 0x2_xxxx 与取指 0xxxx 是
 *   同一块 IROM）。也就是说：软件第一次能"写自己的代码区、然后执行它"。
 *   两个命令必须成对用，且**不能覆盖 monitor 自己**（monitor 在 IROM 低 11KB，
 *   从 0x3000（= 窗口 0x2_3000）以上才安全）。
 *
 *   `load` 的协议（字符流，行尾 CR/LF 均认）：
 *     每行 8 个十六进制数字（一个 32 位字），写一个到 addr、addr += 4；
 *     收到单独一行 "."（或空行）结束；写满 4KB 也结束。
 *   为什么用 ASCII 而不是二进制：`_diag/mon_cmd.ps1` 只能发文本，ASCII 还能人手敲。
 */
#define LOAD_MAX_WORDS 1024u    /* 4KB：够一个演示程序，也不至于刷屏太久 */

static void c_load(int argc, char **argv)
{
    uint32_t base, n = 0, got, v;
    char *p;
    int c, i;

    if (argc < 2) { puts_("usage: L <irom_addr>\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &base)) { puts_("usage: L <irom_addr>\n"); return; }
    if ((base & 3u) != 0u) { puts_(" irom addr must be word-aligned\n"); return; }
    if (base < IROM_APP_MIN) {                       /* ← 两段的守卫 */
        puts_(" refuse: below shell text end; use >= 0x"); puthex8(IROM_APP_MIN); putc_('\n');
        return;
    }
    /* ★ 提示必须**短**：RX FIFO 只有 8 深，宿主（脚本）在提示还没打完时就会开始
     *   灌字节；长提示会把 FIFO 灌满并丢掉行尾的 CR —— 实测就是"两行粘成 16 个
     *   十六进制数字"然后报错。所以只回一行 14 字符，而且下面的解析**不依赖换行**。 */
    puts_("hex8, '.'=end\n");

    /* 解析：连续十六进制数字流，每 8 位 = 一个字；CR/LF/空格一律忽略；
     * '.' 结束。这样即使宿主把两行粘在一起、或者丢了 CR，也能正确切分。 */
    got = 0;
    v = 0;
    for (;;) {
        c = getc_to(2000000u);              /* 4 s @500kHz：一路灌下来不会等这么久 */
        if (c < 0) { puts_("\n timeout\n"); break; }
        if (c == '.') { puts_("\n done\n"); break; }
        i = hexval(c);
        if (i < 0) continue;                /* CR/LF/空格/杂字符：跳过，不打断 */
        v = (v << 4) | (uint32_t)i;
        got++;
        if (got == 8u) {
            *(volatile uint32_t *)(IROM_WIN + base + n * 4u) = v;
            n++;
            got = 0;
            v = 0;
            putc_('.');                     /* 每写一个字回一个点，宿主可以数 */
            if (n >= LOAD_MAX_WORDS) { puts_("\n limit\n"); break; }
        }
    }
    if (got != 0u)
        puts_(" (odd digit count ignored)\n");
    puts_(" loaded "); putdec_(n * 4u); puts_(" bytes @irom 0x"); puthex8(base);
    puts_("  (run 0x"); puthex8(base); puts_(")\n");
    /* ★ fence.i：写完代码区后必须让取指端的队列失效，否则 `r` 可能取到旧字。
     *   本核没有 I-Cache，但 IFU 有 4 项取指队列 —— 对"刚写、从没取过"的区域本来
     *   也安全，插上它是为了让"覆盖一段已经执行过的代码"（热补丁）也正确。 */
    __asm volatile(".word 0x0000100f" ::: "memory");   /* fence.i */
}
```

**一句话**：`L 4000` 实际执行的是 `sw (0x2_0000 + 0x4000) = 字`；而取指口的 `0x4000` 与数据口的 `0x2_4000` 指向**同一个字**，所以写进去就等于改了代码。

---

## 5　shell 怎么跳过去（`r` 命令）

`sw/monitor.c:581-613`

```c
static void c_run(int argc, char **argv)
{
    uint32_t a;
    char *p;
    void (*fn)(void);

    if (argc < 2) { puts_("usage: r <irom_word_addr>   (e.g. r 3000)\n"); return; }
    p = argv[1];
    if (!parse_num(&p, &a)) { puts_("usage: r <irom_word_addr>\n"); return; }
    if ((a & 3u) != 0u) { puts_(" irom addr must be word-aligned\n"); return; }
    if (a < IROM_APP_MIN) {
        puts_(" refuse: below shell text end; use >= 0x"); puthex8(IROM_APP_MIN); putc_('\n');
        return;
    }
    /* 取指地址与窗口地址是同一块 IROM 的同一个字 ⇒ 直接把 a 当函数指针。
     * ★ fence.i：让取指看到刚写进来的那几行（本核无 I-Cache，但取指队列是 4 项，
     *   刚写完就跳过去时要保证队列里不是旧字）。 */
    puts_(" jump to irom 0x"); puthex8(a); puts_(", running...\n");
    __asm volatile(".word 0x0000100f" ::: "memory");   /* fence.i */
    /* ★ 等发送器**真的空**再跳：putc_ 只在写之前等 busy，最后一个 '\n' 还在移位寄存器里
     *   （115200 下 87 us）。应用第一件事往往就是往 TXDATA 写字符，uart_tx 忙时**丢弃**，
     *   实测就是"应用跑了、但它的第一个字符不见了"。 */
    while (UART_TXSTAT & 1u)
        ;
    fn = (void (*)(void))a;
    fn();                                   /* 返回时继续（应用自己决定是否返回） */
    puts_(" returned to shell\n");
}
```

这是整件事最要紧的一句：**`0x4000` 这个地址在取指口和窗口口是同一个字**，所以 `void (*fn)(void) = (void *)0x4000` 就能直接把程序跑起来——不需要搬代码、不需要重定位、不需要 MMU。

---

## 6　硬件侧：数据窗口是怎么接出来的

### 6.1 译码（一行）

`board/board_top.sv:150-152`

```verilog
    logic [31:0] irom_d_rdata;      // IROM 第二读口（数据侧）返回
    logic        irom_win_sel;      // 本次数据访问落在 IROM 窗口
    assign irom_win_sel = (perip_addr[31:16] == 16'h0002);
```

### 6.2 IROM 第二端口（读 + 写）

`board/board_top.sv:335-355`（`IROM_BOOT=1` 引导版）

```verilog
            sync_mem_dp #(
                .WORDS     (IROM_WORDS),
                .INIT_FILE (IROM_INIT)
            ) irom_inst (
                .clk     (sys_clk),
                .reset   (cpu_rst),
                // ---- 端口 A：取指（只读，引导期间 CPU 被按住 → ren=0）----
                .a_addr  (irom_addr),
                .a_ren   (boot_busy ? 1'b0 : irom_en),
                .a_rdata (irom_data),
                // ---- 端口 B：CPU 数据读/写（窗口 0x2_0000）/ 引导器写（'B' 帧）----
                //   ★ 二者互斥：boot_busy=1 时 CPU 在复位，不可能来读/写。
                //   ★ v16：CPU 的 store 也走这一路（写代码区），见上面 2a 段。
                .b_addr  (boot_busy ? (boot_addr << 2) : perip_addr),
                .b_ren   (boot_busy ? 1'b0 : (perip_en & irom_win_sel)),
                .b_rdata (irom_d_rdata),
                .b_wen   (boot_busy ? (boot_we & ~boot_mem_sel)
                                    : (perip_wen & irom_win_sel)),
                .b_wdata (boot_busy ? boot_wdata : perip_wdata),
                .b_mask  (boot_busy ? 2'b11 : perip_mask)
            );
```

`IROM_BOOT=0`（纯 `$readmemh` 固化）分支同理，见 `board_top.sv:371-390`，窗口照样可写，这样仿真里也能测 `load/run`。

### 6.3 读数据三路 mux

`board/board_top.sv:546-559`

```verilog
    always_comb begin
        if (mmio_sel) begin
            case (mmio_idx)
                3'd1:    perip_rdata = {31'b0, uart_busy};
                3'd2:    perip_rdata = {24'b0, rx_fifo[rx_rp]};
                3'd3:    perip_rdata = {30'b0, rx_ovf, rx_avail};
                default: perip_rdata = 32'b0;          // idx0(TXDATA)/idx4(LED) 读回 0
            endcase
        end else if (irom_win_sel) begin
            perip_rdata = irom_d_rdata;                // IROM 第二读口（只读）
        end else begin
            perip_rdata = dram_rdata;
        end
    end
```

### 6.4 ★ 不变量：写窗口时 DRAM 必须被挡住

`board/board_top.sv:582-583`

```verilog
        .wen   (boot_busy ? (boot_we & boot_mem_sel)
                          : (perip_wen & ~mmio_sel & ~irom_win_sel)),
```

少了 `~irom_win_sel`，一次 `sw 0x2_0040` 会**同时**改掉 IROM 与 DRAM 的第 `0x40` 个字——这是这块设计里最容易写错的一行。

---

## 7　构建侧：让应用落在 `0x4000`

`sw/build_app.sh:25-26, 47-51`

```bash
APP_BASE=0x4000
SPLIT=$((0x10000 - 0x4000))          # 0xC000

...
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/${NAME}.bin" \
    --split $((SPLIT)) \
    --irom "${OUT}/${NAME}_irom.hex" --dram "${OUT}/${NAME}_dram.hex" \
    --trim \
    --irom-words 12288 --dram-words 16384
```

`--split 0xC000` 的口径是：`.bin` 里前 `0x4000` 字节位置的偏移对齐到 `0x10000`，于是 `.text` 落在 IROM、`.rodata/.data` 落在 DRAM `0x1_0000` 起。产物直接喂给 shell：

```text
L 4000   →  应用 _irom.hex
D 10000  →  应用 _dram.hex
r 4000   →  APP_ENTRY
```

> ⚠️ `build_app.sh` 第 8、13 行的注释还写着 `0x3000`/`--split 0xD000`，是 v16 早期的旧口径，**以第 25–26 行为准**。

---

## 8　汇报可以照着念的五句话

1. 这块 IROM 只有 64 KB，物理上是一块双口 BRAM；**取指走 A 口，数据走 B 口**，两个口地址空间独立。
2. 低段 `0x0000` 起是**主镜像**（crt0 + shell，约 13.8 KB），由复位后的引导器整块灌入，做完就跳 `0x0` 执行——因为 `IFU` 的复位 PC 硬连为 0。
3. 高段 `0x4000` 起 **48 KB** 是**程序区**，编译期留空，运行期由 shell 用数据窗口 `0x2_xxxx` 写进去。
4. 接缝 `IROM_APP_MIN` **不是常量**，而是链接器符号 `_etext` 向上 4 KB 对齐——所以改 shell 代码不会让程序区错位，只会让接缝上移。
5. 因为有这条通路，**换程序不用重新综合比特流**：串口发 `L` / `D` / `r` 三条命令就完成"装载—跳转—返回"。

---

## 附　相关文件索引

| 文件 | 内容 |
|---|---|
| `sw/coremark_port/link.ld` | 主镜像布局（0x0 起 64 KB） |
| `sw/app/link_app.ld` | 程序区布局（0x4000 起 48 KB） |
| `sw/monitor.c:54-62` | `IROM_WIN` / `DRAM_BASE` / `IROM_APP_MIN` |
| `sw/monitor.c:477-529` | `L` 命令（写代码区） |
| `sw/monitor.c:537-579` | `D` 命令（灌 `.rodata/.data`，不许写 `0x2_xxxx`） |
| `sw/monitor.c:581-613` | `r` 命令（跳转执行，返回后打印 `returned to shell`） |
| `sw/coremark_port/crt0.S` | `_start`：设 `gp`、`sp=C 0000`、清 `.bss`、`call main` |
| `sw/build_app.sh` | `APP_BASE=0x4000`、`--split 0xC000` |
| `board/board_top.sv:152` | `irom_win_sel` 译码 |
| `board/board_top.sv:335-390` | IROM 第二端口（引导器写 / CPU 读写） |
| `board/board_top.sv:582-583` | DRAM 写使能被窗口挡住（不变量） |
| `rtl/IFU.sv:214-215` | 复位 PC = `0x0` |
