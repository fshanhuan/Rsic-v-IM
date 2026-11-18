/* =============================================================================
 * sw/ps/link_ps_sd.ld -- SD 卡程序的链接脚本（PS/Cortex-A9，裸机，跑在 OCM）
 * -----------------------------------------------------------------------------
 * 与 link_ps.ld 的区别，三处，都很关键：
 *   1) 代码/数据/栈只占**前 128 KB**（0x0 ~ 0x1FFFF）。Zynq 低端 OCM 实际有
 *      192 KB（0x0~0x2FFFF），多出来的 64 KB 留给下面两块。
 *   2) 0x2_0000 起 16 KB 是 **SD 数据缓冲**（ADMA2 要物理连续、512 对齐）。
 *   3) 0x2_4000 起是**内存日誌**（长度 + 文本），0x2_FFFC 是进度标记。
 *      ★ 为什么要日誌：PS UART1 的波特率在这块板上对不上（见记录仪方案 §SD），
 *      所以程序把 xil_printf 的内容同时写进这块内存，JTAG 直接读出来就是文本，
 *      不依赖任何串口。日志和标记都**不能**落在 .bss 里 —— 早期版本把标记写在
 *      0x2F00，正好压在 .bss 的 XSdPs 实例上，把驱动状态踩坏了（排查了半天）。
 * ============================================================================= */
OUTPUT_ARCH(arm)
ENTRY(_start)

MEMORY
{
    ocm (rwx) : ORIGIN = 0x00000000, LENGTH = 128K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
        . = ALIGN(4);
    } > ocm

    .rodata : { *(.rodata .rodata.*) . = ALIGN(4); } > ocm
    .data   : { *(.data .data.*)     . = ALIGN(4); } > ocm

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > ocm

    /* 栈：16 KB，向下增长，_stack_top = 栈区顶端 */
    .stack (NOLOAD) : {
        . = ALIGN(8);
        _stack_bottom = .;
        . = . + 16K;
        _stack_top = .;
    } > ocm

    /DISCARD/ : { *(.comment) *(.note*) *(.ARM.attributes) *(.eh_frame*) }
}

/* 0x2_0000 : SD 数据缓冲，16 KB（= 32 个 512 字节扇区） */
_sd_buf_base = 0x00020000;
_sd_buf_size = 0x00004000;

/* 0x2_4000 : 内存日誌（长度 + 文本），到 0x2_FFFB */
_log_len_addr = 0x00024000;
_log_buf_addr = 0x00024004;
_log_buf_size = 0x0000BFF4;

/* 0x2_FFFC : 进度标记（一个 32 位字） */
_prog_mark_addr = 0x0002FFFC;
