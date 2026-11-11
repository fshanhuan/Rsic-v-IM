/* =============================================================================
 * sw/ps/link_ps_irq.ld -- PS 侧裸机 + 异常向量表的链接脚本（第 3 步专用）
 * -----------------------------------------------------------------------------
 * 与 link_ps.ld 的区别：
 *   · `.vectors` 必须在 **0x0**（Cortex-A9 复位后 VBAR = 0，硬件就是从这里取
 *     复位向量和 IRQ 向量）；
 *   · 多给一个 IRQ 模式的栈（_irq_stack_top，放在 SVC 栈下面 1 KB）。
 *
 * 布局：0x0 向量表 → .text → .rodata/.data/.bss → 栈（从 256 KB 顶端向下）
 * ============================================================================= */
OUTPUT_ARCH(arm)
ENTRY(_start)

MEMORY
{
    ocm (rwx) : ORIGIN = 0x00000000, LENGTH = 128K   /* 低 OCM 只有 128 KB！ */
}

_stack_top     = ORIGIN(ocm) + LENGTH(ocm) - 16;
_irq_stack_top = ORIGIN(ocm) + LENGTH(ocm) - 1024;

SECTIONS
{
    .vectors 0x00000000 : {
        KEEP(*(.vectors))
        . = ALIGN(4);
    } > ocm

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
