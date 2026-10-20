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
