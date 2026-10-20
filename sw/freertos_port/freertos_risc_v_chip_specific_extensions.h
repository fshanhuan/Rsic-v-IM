/* =============================================================================
 * freertos_risc_v_chip_specific_extensions.h -- 本核的 RISC-V 端口芯片扩展
 * -----------------------------------------------------------------------------
 * FreeRTOS 的 RISC-V 端口把"这颗芯片有什么"抽到这个头里。我们需要的只有三条：
 *   portasmHAS_MTIME         1 → 有机器定时器（我们的 mtime/mtimecmp CSR），
 *                               trap handler 会走 test_if_mtimer 分支。
 *   portasmHAS_SIFIVE_CLINT  0 → 不是 SiFive CLINT 的 MMIO 布局。
 *   portasmADDITIONAL_CONTEXT_SIZE 0 → 除 32 个通用寄存器 + mstatus/mepc 之外
 *                               没有额外的"芯片私有寄存器"要压栈。
 * ============================================================================= */
#ifndef FREERTOS_RISCV_CHIP_SPECIFIC_EXTENSIONS_H
#define FREERTOS_RISCV_CHIP_SPECIFIC_EXTENSIONS_H

#define portasmHAS_MTIME                     1
#define portasmHAS_SIFIVE_CLINT              0
#define portasmADDITIONAL_CONTEXT_SIZE       0

/* ★ 这两个宏是 portASM.S 里直接当"伪指令"展开的（不是 C 宏！），
 *   必须定义成空的汇编宏，否则汇编器会报 unrecognized opcode。
 *   用 __ASSEMBLER__ 包住：这个头只被 portASM.S include，但万一哪天被 .c 带上
 *   也不会把 .macro 当 C 代码编译。 */
#if defined( __ASSEMBLER__ )
    .macro portasmSAVE_ADDITIONAL_REGISTERS
    /* 没有芯片私有寄存器要保存 */
    .endm

    .macro portasmRESTORE_ADDITIONAL_REGISTERS
    /* 没有芯片私有寄存器要恢复 */
    .endm
#endif

#endif /* FREERTOS_RISCV_CHIP_SPECIFIC_EXTENSIONS_H */
