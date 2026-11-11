/* =============================================================================
 * sw/ps/link_ps.ld -- PS 侧（Cortex-A9）裸机程序的链接脚本：放在 OCM 里
 * -----------------------------------------------------------------------------
 * 为什么放 OCM（0x0000_0000，256 KB）而不是 DDR：本工程的 PS7 配置**没开 DDR**
 *   （没有 ZedBoard board file，配 DDR 要一长串 PCW_UIPARAM_DDR_* 参数，风险大且
 *   本验证不需要）。OCM 跑几百字节的程序绰绰有余。
 *
 * 入口 _start 放在 0x0000_0000：JTAG `dow` 之后调试器会把 PC 指到 ELF 入口，
 *   不需要 BootROM 的 vector table（我们不开异常）。
 * ============================================================================= */
OUTPUT_ARCH(arm)
ENTRY(_start)

MEMORY
{
    ocm (rwx) : ORIGIN = 0x00000000, LENGTH = 128K   /* 低 OCM 只有 128 KB！ */
}

_stack_top = ORIGIN(ocm) + LENGTH(ocm) - 16;

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

    /DISCARD/ : { *(.comment) *(.note*) *(.ARM.attributes) *(.eh_frame*) }
}
