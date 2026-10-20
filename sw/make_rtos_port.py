#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/make_rtos_port.py -- 从 vendor 的 FreeRTOS 端口生成"CSR 定时器版"

为什么需要打补丁：FreeRTOS 的 RISC-V 端口假设定时器是 SiFive CLINT 的**内存映射**
寄存器（mtime/mtimecmp 在 0x0200_0000 附近，64 位）。本核没有 CLINT，只有两条 CSR：
    mtime    (0x7C0, 只读, 32 位, 500 kHz)
    mtimecmp (0x7D0, 可写, 32 位)
所以只改两处，其余（陷阵入口、上下文切换、临界区）全部沿用 stock 端口：

  1. port.c 的 vPortSetupTimerInterrupt()  → 用 csrr/csrw 装第一次比较值 + 开 MTIE
  2. portASM.S 的 portUPDATE_MTIMER_COMPARE_REGISTER
                                        → 改成 "mtimecmp = mtime + 周期"（32 位、
                                          回绕安全），不再走 64 位 uint64 累加器

生成物落在 sw/freertos_port/，vendor 目录保持原样（升级内核时重跑本脚本即可）。

用法：
    python3 sw/make_rtos_port.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "sw" / "freertos" / "port"
DST = ROOT / "sw" / "freertos_port"

# ---------------------------------------------------------------- port.c 补丁
# 替换 "有 MMIO mtime 时" 的整段（含 #if / #endif），换成 CSR 实现。
SETUP_RE = re.compile(
    r"#if \( configMTIME_BASE_ADDRESS != 0 \).*?"
    r"#endif /\* \( configMTIME_BASE_ADDRESS != 0 \)"
    r".*?\*/\n",
    re.DOTALL,
)

SETUP_NEW = r"""/* ---- 本核：mtime/mtimecmp 是 CSR，不是 CLINT MMIO ----
 * ★ CSR 号只能用**数字**：GNU as 不认识 `mtime`/`mtimecmp` 这两个名字（标准里
 *   它们不是 CSR，而是 CLINT 的 MMIO）。本核自定义在 0x7C0 / 0x7C1
 *   （rtl/CSR.sv:54-56）。
 * 一 tick = configMTIME_TICKS_PER_TICK 个 mtime 计数（5000 @100Hz / 500kHz）。
 * 32 位 mtime 会在 8589 s 回绕，而 "now + 周期" 的写法对回绕天然安全。 */
void vPortSetupTimerInterrupt( void )
{
    uint32_t ulNow;

    __asm volatile ( "csrr %0, 0x7c0" : "=r" ( ulNow ) );        /* mtime    */
    ulNow += ( uint32_t ) configMTIME_TICKS_PER_TICK;
    __asm volatile ( "csrw 0x7c1, %0" ::"r" ( ulNow ) );         /* mtimecmp */

    /* 打开机器定时器中断（mie.MTIE = bit7）；mstatus.MIE 由端口在启动第一个任务时开 */
    __asm volatile ( "csrs mie, %0" ::"r" ( 0x80 ) );
}
"""

# ------------------------------------------------------------- portASM.S 补丁
MACRO_RE = re.compile(
    r"\.macro portUPDATE_MTIMER_COMPARE_REGISTER.*?\.endm\n",
    re.DOTALL,
)

MACRO_NEW = r""".macro portUPDATE_MTIMER_COMPARE_REGISTER
    /* ---- 本核：mtimecmp = mtime + 周期 ----
     * 原来是"读 pullMachineTimerCompareRegister 指针再存 64 位 ullNextTime"，
     * 那需要 CLINT 的 MMIO。这里换成两条 CSR 指令（0x7C0 = mtime，0x7C1 = mtimecmp，
     * CSR 号必须用数字：GNU as 不认识这两个名字）：
     *   csrr a2, 0x7c0                读当前时间
     *   lw   t0, 周期                 周期来自 uxTimerIncrementsForOneTick
     *   add  a2, a2, t0
     *   csrw 0x7c1, a2                写比较值（写新值即清中断）
     * 注意 a2/t0 在陷入入口已经保存过，可以随便用。 */
    csrr a2, 0x7c0
    lw   t0, uxTimerIncrementsForOneTick
    add  a2, a2, t0
    csrw 0x7c1, a2
.endm
"""


def patch_tick_increments() -> int:
    """把 uxTimerIncrementsForOneTick 改成"mtime 单位"，而不是 CPU 拍数。

    ★ 这是个很容易漏的坑：端口里这个常量原来是
        ( configCPU_CLOCK_HZ / configTICK_RATE_HZ )
      在 CLINT 平台成立（mtime 与 CPU 同频）；但本核的 mtime 是 **500 kHz**
      （50MHz 100 分频，rtl/CSR.sv），一个 1 ms tick = 500 个 mtime 计数，
      写成 50000 会让 tick 周期变成 100 ms —— 表现为"任务只跑一次就再也不动了"。
    """
    src = SRC / "port.c"
    text = src.read_text(encoding="utf-8")
    old = ("const size_t uxTimerIncrementsForOneTick = ( size_t ) "
           "( ( configCPU_CLOCK_HZ ) / ( configTICK_RATE_HZ ) );")
    new = ("/* ★ 本核补丁：周期必须按 **mtime 频率** 算（见 FreeRTOSConfig.h 里的说明），\n"
           " *   不是 CPU 主频。写成 CPU_CLK/TICK 会让 tick 慢 100 倍。 */\n"
           "const size_t uxTimerIncrementsForOneTick "
           "= ( size_t ) ( configMTIME_TICKS_PER_TICK );")
    if old not in text:
        print("!! port.c: 没找到 uxTimerIncrementsForOneTick 的原定义", file=sys.stderr)
        return 1
    # 注意：上面 patch_c() 已经写过一次文件，这里要读**已生成**的那份
    dst = DST / "port.c"
    text = dst.read_text(encoding="utf-8")
    if old not in text:
        print("!! port.c(生成版): 没找到 uxTimerIncrementsForOneTick", file=sys.stderr)
        return 1
    dst.write_text(text.replace(old, new), encoding="utf-8", newline="\n")
    print("   port.c    patched (tick -> mtime ticks)")
    return 0


def patch_c() -> int:
    src = SRC / "port.c"
    text = src.read_text(encoding="utf-8")
    new, n = SETUP_RE.subn(SETUP_NEW, text)
    if n != 1:
        print(f"!! port.c: 没找到唯一的 vPortSetupTimerInterrupt 段（匹配 {n} 次）",
              file=sys.stderr)
        return 1
    (DST / "port.c").write_text(new, encoding="utf-8", newline="\n")
    print(f"   port.c    patched (setup -> CSR)")
    return 0


def patch_asm() -> int:
    src = SRC / "portASM.S"
    text = src.read_text(encoding="utf-8")
    new, n = MACRO_RE.subn(MACRO_NEW, text)
    if n != 1:
        print(f"!! portASM.S: 没找到唯一的 portUPDATE_MTIMER_COMPARE_REGISTER（匹配 {n} 次）",
              file=sys.stderr)
        return 1
    (DST / "portASM.S").write_text(new, encoding="utf-8", newline="\n")
    print(f"   portASM.S patched (macro -> CSR)")
    return 0


def copy_rest() -> int:
    for name in ("portmacro.h", "portContext.h"):
        text = (SRC / name).read_text(encoding="utf-8")
        (DST / name).write_text(text, encoding="utf-8", newline="\n")
        print(f"   {name} copied")
    return 0


def main() -> int:
    DST.mkdir(parents=True, exist_ok=True)
    rc = patch_c()
    rc |= patch_tick_increments()
    rc |= patch_asm()
    rc |= copy_rest()
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
