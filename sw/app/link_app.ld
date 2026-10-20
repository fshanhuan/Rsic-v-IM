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
