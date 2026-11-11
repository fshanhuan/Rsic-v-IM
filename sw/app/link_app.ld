/* =============================================================================
 * sw/app/link_app.ld -- "从 shell 加载并运行" 的 C 应用内存布局（P1-1）
 * -----------------------------------------------------------------------------
 * 本核是哈佛双口：**取指口**和**数据口**是两套物理存储，地址空间可以重叠。
 *   · 代码 .text  -> IROM 取指地址 0x0000_6000 起（0x0000_0000~0x5FFF 是 shell）
 *   · 数据 .rodata/.data/.bss -> **DRAM** 0x0000_A000 起
 * 所以同一串数字 0x8000 在取指端指的是 IROM，在数据端指的是 DRAM —— 互不干扰。
 *
 * 板级 DRAM 一共 128 KB（0x0_0000~0x1_FFFF），这里把它切成三段（见 sw/monitor.c
 * 的 FS 注释，两边必须一致）：
 *   0x0_0000 ~ 0x0_9FFF   文件系统 40 KB（160 块 × 256 B）
 *   0x0_A000 ~ 0x0_FFFF   应用数据区 24 KB（本脚本 20 KB + 4 KB 栈）
 *   0x1_0000 ~ 0x1_FFFF   shell 自己的 .rodata/.data/.bss/栈
 *
 * ★ 为什么应用不能把自己的变量放 0x1_0000：那是 shell 的 .data，写进去等于破坏
 *   shell 的命令表/历史行，`run` 返回后 shell 就废了（这就是 P1-1 曾经失败的
 *   第二个原因）。
 * ★ 栈为什么单独给 4 KB（0xF000~0xFFFF 顶）：应用递归/局部缓冲再深也不会踩到
 *   shell 的栈 —— 两个程序的 sp 从此互不相干。
 * ============================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    irom (rx)  : ORIGIN = 0x00006000, LENGTH = 40K
    dram (rwx) : ORIGIN = 0x0000A000, LENGTH = 20K
}

/* 给应用的私有栈：4 KB，向下生长 */
__app_stack_top = 0x0000F000;

SECTIONS
{
    .text : {
        KEEP(*(.text.start))        /* 入口桩必须在基址：容器头只记 0x6000 */
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

    __global_pointer$ = ADDR(.data) + 0x800;

    /* 数据 + .bss 不许越过 0xF000（栈底）——越了链接期就报错，别等上板 */
    ASSERT(ADDR(.bss) + SIZEOF(.bss) <= 0x0000F000, "app .data/.bss overflow 0xF000")

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
