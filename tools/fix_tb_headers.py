#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix_tb_headers.py — 一次性修复：把 6 个 testbench 的头部注释块整段重写。

背景（必须记下来，别再犯）：
    2026-11-11 用 PowerShell 把 sim/*.sv 里的 `u_board.g_irom_rom.irom_inst`
    批量替换成 `u_board.irom_inst` 时，用的是
        Get-Content -Raw  (PS 5.1 默认按 ANSI/OEM 936 解码 UTF-8 文件)
        [IO.File]::WriteAllText(..., UTF8)
    于是每个中文字符被 GBK 解码成 1.5 个字符，**第三个字节（含换行）被换成 U+FFFD**，
    写回去就变成"注释被吃字 + 多行合并"。代码没坏，注释坏了。

    这个脚本不试图猜那些丢掉的字节（猜不准），而是**重写头部注释块**：
    头部是信息最密、损坏最重的地方。正文里的行内注释只丢了行尾一两个字，
    已经人工过了一遍。

用法：python tools/fix_tb_headers.py   （幂等：只替换 `timescale 之后到 module 之前的整段）
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HDR = {}

HDR["tb_bus.sv"] = """/* =============================================================================
 * tb_bus.sv — A1 总线化的板级冒烟测试（不需要 C 工具链）
 * -----------------------------------------------------------------------------
 * 载入 sim/bus_smoke.hex（由 sim/gen_bus_smoke.py 生成），检查四件事：
 *
 *   ① DRAM 写/读        → u_board.g_dram_single.dram_inst.mem_ram[0x4000] == 0xCAFE_0123
 *   ② 代码窗口读指令字   → 程序自己比较（读不到就跳 fail）
 *   ③ 代码窗口写         → u_board.irom_inst.mem[0x100] == 0xBEEF_0456
 *   ④ MMIO              → led == 7'h2A、UART 收到 "OK"
 *
 * ★ 为什么第 ② 条必须由程序自己比：读 mux 的回选是**纯译码**（hit_*），
 *   数据在请求的下一拍才有效 —— 如果用 sel_*（含 ren）门控，读回会变成 0。
 *   这个错误只有"真的读一次再比"才能抓出来。
 * ★ 为什么第 ③ 条直接查 BRAM 数组：DCache 是写直达，写回后缓存里也有这份数据，
 *   用 `lw` 读回来会命中缓存，**测不出总线写通路**。直接看数组才是真判据。
 * ★ 层次路径：sync_mem 的数组在**模块作用域**（mem_rom / mem_ram）；sync_mem_dp
 *   （IROM）的数组叫 `mem`，实例 irom_inst 已提到 generate 外（双核协同时改的）。
 *
 * 判据输出：[BUS-SMOKE] PASS / FAIL（regress 脚本靠这行判断）
 * ============================================================================= */"""

HDR["tb_mem.sv"] = """/* =============================================================================
 * tb_mem.sv — 存储器模块级波形台（IROM / DRAM 的端口级检查）
 * -----------------------------------------------------------------------------
 * 和板级 TB 的区别：这里直接看 **BRAM 实例的端口**，不经过 CPU/总线。
 * 用途：
 *   1. 抓"读写使能/字节掩码/地址索引"这一层的时序（WaveDrom 图就是从这来的）；
 *   2. 覆盖 `sync_mem` / `sync_mem_dp` 的读延迟契约（ren 那拍给地址，rdata 下一拍有效）。
 *
 * ★ 为什么用 wire 把端口引出来：WaveDrom 图要求"全部输入输出都在模块边界上"，
 *   层次化引用（u_board.irom_inst.xxx）不能直接画图，所以这里一根根接出来。
 * ★ 本台子例化时 IROM_BOOT=0，IROM 实例现在在 board_top 顶层（不在 generate 里）。
 * ============================================================================= */"""

HDR["tb_console.sv"] = """/* =============================================================================
 * sim/tb_console.sv — v12（C）console 收发 + 定时器中断 + GPIO 端到端测试
 * -----------------------------------------------------------------------------
 * 被测通路：uart_rx -> 8 深 FIFO -> MMIO 0x1000_0008/0x1000_000C -> 软件轮询
 *          -> 命令分发 -> TXDATA 0x1000_0000 -> uart_tx
 *
 * 程序：sim/console_demo_sim.hex（由 sim/gen_console_demo.py 生成）
 *   tick = 2000 * 2us = 4ms（比板上的 10ms 短，仿真才跑得完）
 *
 * 判据：
 *   C1 上电横幅 == "BigBird v12\\r\\n"（3 字节起，顺序与内容都要对）
 *   C2 发 'A' 回显 'A'（RX FIFO -> 主循环 -> TXDATA 全链路）
 *   C3 连发 "OK\\r"（3 字节）全部回显
 *   C4 定时器中断在跑：led != 0，且回显期间它还在变（中断不与主循环互锁）
 *   C5 至少收到 2 个 '.'（每 4 个 tick 一个点）
 * ============================================================================= */"""

HDR["tb_board_top_uart.sv"] = """/* =============================================================================
 * sim/tb_board_top_uart.sv — v12（B）UART MMIO 端到端测试（板级）
 * -----------------------------------------------------------------------------
 * 层次：
 *   tb_uart_tx.sv        发送器本身对不对（回环）
 *   tb_board_top_uart    TXDATA/TXSTAT 经 MMIO 写、经真实 uart_tx 发出去
 *   tb_sys (+kind=zicntr) CSR/计数器对不对
 *
 * 判据（对应 sim/gen_uart_mmio_prog.py 的程序）：
 *   U1 串口先收到 'H'(0x48)，再收到 'i'(0x69) —— MMIO 写 + busy 轮询都对
 *   U2 x5 == 0xCAFE0000：MMIO 写没有踩坏 DRAM
 *      （board_top 的 dram.wen 必须被 ~mmio_uart_sel 门掉；漏门就是"打一个字，
 *       栈里的变量莫名变了"这种最恶心的一类 bug）
 *   U3 x8 == 0x1234：普通 DRAM 读写没被 MMIO 干扰
 *
 * ★ BIT_TICKS(50MHz,115200) = 434，与真板完全一致；
 *   uart_rx 的 CLK_FREQ 必须与 board_top 的 uart_tx 相同，否则每个字节都收错。
 * ★ IROM 实例已提到 generate 外，路径是 u_board.irom_inst（不再是 g_irom_rom.*）。
 * ============================================================================= */"""

HDR["tb_monitor.sv"] = """/* =============================================================================
 * sim/tb_monitor.sv — 串口 shell 全链路（monitor 命令解析 + 回显）
 * -----------------------------------------------------------------------------
 * 为什么单独一个测试台：monitor 的**输出**在 tb_cm 里已经验证过（横幅/帮助/提示符），
 *   但它还依赖一条完全不同的通路 —— 串口**输入**：
 *     uart_rx -> 8 深 FIFO -> MMIO 0x1000_0008/0x1000_000C -> 软件轮询（或中断）
 *   -> 命令分发 -> TXDATA 0x1000_0000 -> uart_tx
 *
 * 判据（M1..M9，逐条打 PASS/FAIL）：
 *   M1 上电横幅出现
 *   M2 `l 3f` 有回显        -> RX FIFO + 轮询 + 十六进制解析 + 外设写
 *   M3 `p 10000` 有回显     -> peek 命令 + 地址/数据格式
 *   M4 代码窗口读（d 24000）-> IROM 第二口
 *   M5 多参数命令（含空格）
 *   M6 校验和 `k 20000` 与主机侧 djb2 一致
 *   M7 断点命令 bk/bl/bd
 *   M8 连续灌 100 字节不丢
 *   M9 收尾时 debug_status 无 X（P0-1 的 X 溯源就靠这一条）
 *
 * 用法：
 *   vvp sim/build/tb_monitor.vvp +prog=sw/build/monitor_irom.hex +dram=sw/build/monitor_dram.hex
 * ============================================================================= */"""

HDR["tb_runapp.sv"] = """/* =============================================================================
 * sim/tb_runapp.sv — P0-2：`run <name>` 仿真端到端（容器加载 + 执行 + 返回）
 * -----------------------------------------------------------------------------
 * 它验证的不是某条命令，而是**整条 P1 链路**：
 *   文件系统里的一个容器（32 B 头 + 代码 + 数据 + 校验和）
 *   -> `run` 解析 -> 代码写进 IROM 窗口 0x2_4000 -> 数据写进 DRAM 0xA000
 *   -> fence.i -> 跳转执行 -> 返回 shell
 *
 * 办法（sw/mkfs.py）：把文件系统（超级块 + 目录 + 位图 + 数据块）直接烤成 DRAM 镜像，
 *   仿真开始时用 `+fs=` 一把装进 DRAM 0。于是：
 *     +prog=monitor_irom.hex  -> shell 本体
 *     +fs=tb_fs.hex           -> 预置的 ramdisk（里面有 hello_app 这个容器）
 *     +dram=monitor_dram.hex  -> shell 的 .rodata
 *
 * 判据：
 *   A1 "run hello_app" 的回显里出现 `code 472B + data 36B`（容器头被正确解析）
 *   A2 应用真的跑了：回显 "HELLO-APP" 与 "acc=15"
 *   A3 应用返回后 shell 还在（提示符再次出现，没有跑飞/复位）
 *   A4 跑完 `df` 的可用块数没有掉（`run` 不占文件系统）
 *   A5 收尾 debug_status 无 X
 *
 * 用法：
 *   python3 sw/mkfs.py --file hello_app=sw/build/hello_app.app --out sw/build/tb_fs.hex
 *   vvp sim/build/tb_runapp.vvp +prog=... +dram=... +fs=...
 * ============================================================================= */"""


def main():
    for name, hdr in HDR.items():
        path = os.path.join(ROOT, "sim", name)
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        m = re.search(r"^module\s", text, re.M)
        if not m:
            print("!! %s: 找不到 module 行" % name)
            continue
        body = text[m.start():]
        out = "`timescale 1ns / 1ps\n\n" + hdr + "\n" + body
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
        print("rewrote header: %s (%d bytes)" % (name, len(out)))


if __name__ == "__main__":
    main()
