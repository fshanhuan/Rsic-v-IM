# v12 状态快照（压缩上下文 · 2026-10-18 19:30）

> 用途：让下一次会话在**不重读整段历史**的情况下继续干活。
> 只写"现在是什么状态 / 什么已经验证过 / 什么绝对不能改回去 / 下一步"。

## 1. 一句话现状

BigBird RV32IM 软核（xc7z020clg484-1，50 MHz）在 EES-331 板上**跑通**：
串口引导灌程序（1 分钟级迭代）、console 收发、Zicntr 计数器、GPIO LED、定时器中断、
16 探针 ILA 可观测量；全量回归 **32/32 PASS**。

## 2. 交付物

| 项 | 位置 |
|---|---|
| bitstream | `v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.bit` |
| probes | 同目录 `board_top_gui_boot.ltx` |
| 构建 | `_diag/vivado_boot.ps1` → `build_project_boot.tcl`（报告 `*.boot.rpt`） |
| 回归 | `_diag/regress.ps1`（32 项） |
| 上板脚本 | `_diag/load_uart.ps1`、`read_uart.ps1`、`program_only.tcl`、`capture_ila.tcl`（需 `ILA_LTX`） |
| 文档 | `docs/ZICNTR_UART.md`（v12B）、`docs/CONSOLE_GPIO.md`（v12C + BUG-1）、`docs/优化_v11_进度.md`（轮次 1~7） |

## 3. 最后一次构建（含 BUG-1 修复）

```
build OK   WNS 0.734  WHS 0.009  TNS 0  THS 0   0 error / 0 critical warning
LUT 35690 (67.09%)  FF 22777 (21.41%)  BRAM 38.5 (27.5%)  DSP 4    Fmax ≈ 51.9 MHz
board_top_gui_boot.bit 4 045 694 B
```

## 4. 板级事实（改之前必看）

- 时钟：板载 100 MHz（M19）→ MMCM ×10/20 → **50 MHz**；`reset_sync` 异步置位同步释放。
- **J8 = PL_RS232**：J8-1 `RX` = **A16**（FPGA 收）、J8-2 `TX` = **A17**（FPGA 发）。
  宿主机串口 = **COM9**（Silicon Labs CP210x）。**COM13 是另一个 FTDI 模块，不是板子。**
- 引导：`IROM_BOOT=1`，帧 = `0x42 + 4B 字数 + N×4B(大端) + 4B 校验和`，IDLE 超时 5 s。
  **流程必须先起串口流、再编程**（编程=复位，窗口才打开）。
- GPIO：`led[6:0]` → LED1~LED7 = **U6 U5 V7 W7 W6 W5 U7**；LED0(V4) 仍是 `debug_dead` 心跳。
- XDC：`v9_board_boot.xdc`；`set_clock_uncertainty -hold 0.200` 是**必需的 hold 保护带**；
  所有输出脚都要 `set_false_path -to`（否则 `no_output_delay` 判据失败）。

## 5. MMIO 映射（`0x1000_00xx`，DCache 的 `UNCACHE_MASK` 自动走非缓存通路）

| 地址 | 方向 | 内容 |
|---|---|---|
| `+0x00` | WO | TXDATA（低 8 位；忙时丢弃） |
| `+0x04` | RO | TXSTAT bit0 = busy |
| `+0x08` | RO | RXDATA（**读即弹出**，空则 0） |
| `+0x0c` | RO | RXSTAT bit0 = 非空，bit1 = 溢出过（读清） |
| `+0x10` | RW | LED[6:0] |

★ 不变量：MMIO 写必须 `& ~mmio_sel` 门掉 DRAM 的 `wen`（否则写会覆盖 DRAM[0]）。
★ 不变量：RXDATA 的弹出必须**延迟一拍**（DCache 是"请求拍 + 下一拍采样"两拍契约）。

## 6. Zicntr

`mcycle`(0xB00) `minstret`(0xB02) `mcycleh`(0xB80) `minstreth`(0xB82) 64 位 RW；
只读影子 `cycle`(0xC00) `time`(0xC01) `instret`(0xC02) `cycleh/instreth`(0xC80/0xC82)；
`time` = mtime（500 kHz 墙钟），`timeh` 读 0。

- 写位 `csr_wen[14:11]`；★★ **别名必须映射到同一个 onehot 位**（否则前递漏，读到清零前的值）。
- `minstret` 使能 = `LSU.retire_wb = ready_next & ~lsu_freeze & valid_reg_pipe`
  （**不能**用 `WBU_valid`，冻结期它是多拍高）。

## 7. ILA 探针（16 个，宽度冻结，未重建 IP）

`0` wb_have_inst · `1` wb_pc · `2` wb_ena · `3` wb_reg · `4` wb_value ·
**`5` debug_status** · **`6` debug_mcycle** · `7/8` dcache hit/miss · `9/10/11` mcause/mepc/mtval ·
`12` trap_take · `13` dnpc_flag · `14` ready · `15` ifu_pc

`debug_status` 位：0 IFU_stall · 1 dcache_hold · 2 mdu_busy · 3 system_redirect ·
4 trap_seen(粘滞) · 5 dnpc_flag · 6 load_use_stall · 7 IDU_ready · 8 boot_busy · 9 boot_ok · 10 boot_err

## 8. 已上板验证的结论（可信基线）

1. 串口引导 + console：`uart_hello` 6 s 收到 740 组 `Hi`（8.11 ms/轮，仿真 8.2 ms）。
2. **`mcycle` 每拍 +1**：ILA 2048 采样，逐拍差分 **2047/2047 全为 1**。
3. `debug_status` 在延时循环里只有一个取值 `0x280`（IDU_ready + boot_ok，**停顿位全 0**）；
   1024 次写回 / 2048 拍 ⇒ **板上 IPC = 1.00，零停顿**。
4. console 回显：宿主机敲 `Hi` → 板上原样回显；9 s 收到 ~900 个心跳点（tick 10 ms）。
5. BUG-1 修复后：带条件分支的 console 程序 8 s 收到 **405 字节 ≈ 400 个点**（20 ms/点）+ `OK` 回显。

## 9. 本轮修掉的 CPU bug（v12-BUG-1）

`Control.sv` 的 `bp_misp_det` 原来屏蔽了 `system_redirect`（= mret/ecall/fence.i/trap），
而前三个是 **IDU 译码标志 → 更年轻的指令**。后果：**更年轻的 mret 吞掉更老分支的误预测**，
错路径的 mret 被执行，紧跟分支的那条指令被静默跳过（不报错、不跑飞）。

修复：`~(intr_take | trap_redirect)`。dnpc 优先级链本来就对
（`intr_take > trap_redirect > bp_mispredict > system_redirect`）。

★ 新增不变量：`bp_misp_det` 的屏蔽项只能含"会造成同一拍 dnpc 冲突"的源；
"更年轻指令的重定向"是**优先级问题**，不是冲突。

★ 永久回归项：`tb_mini + brsel_a/b/c/h`（4 条）。

## 10. 明确"做不到 / 没做"的（别再重复问）

- **load-use 0 拍前递：本微架构不可能**。DCache 的 `cpu_en/cpu_addr` 取自 **M2**
  （`LSU.sv:199` 用 `Ex_result_addr_reg_pipe`），数据最早 M2 出现，而消费者最晚 M1 就得拿到。
  要少停 1 拍只能把 DCache 请求前移到 M1 = **重定时工程**。
  顺带：`LSU_Rdata`（M1 数据）与 M1 地址**错位**，接 `Control.MEM_Rdata` 却无读者。
- `time` 64 位、UART TX FIFO、`minstret` 排除陷入指令：**有意不做**。
- Linux：需要 S-mode + PMP + MMU，是另一条路线；M-only 对 RTOS 够用。

## 11. 下一步候选（按性价比）

1. **平台**：16 KB IROM / 64 KB DRAM 是 RTOS 硬天花板 → 接 PS DDR（AXI HP）或 MIG。
2. **C 工具链**：riscv-gcc + crt0 + linker script（不占板子，可先纯仿真跑通）。
3. **外设**：GPIO 输入、外部中断源、RXDATA FIFO 加深。
4. **微架构**：DCache 请求前移（换 1 拍 load-use）、RAS 推测压栈、
   提频 100 MHz（需先降 hold 保护带 0.200→0.150 + EX 级重平衡）。
5. 板上跑 `bench_call/mem/div` 拿三条 IPC 基线（现在有 `mcycle` 了）。

## 12. 踩坑清单（照做能省几小时）

- **XDC 不是通用 Tcl**：不支持 `foreach/if/puts/proc/source`；只支持约束 + `set/get_*/list/expr`。
- **`.ps1` 必须纯 ASCII**：PS 5.1 按 GBK 解码 BOM-less 文件，中文注释会吞掉下一行。
- **`capture_ila.tcl` 必须设 `$env:ILA_LTX`** 指向 boot 版 ltx；用错**不报错**，
  只是 probe 名字张冠李戴。
- **`regress.ps1` 的 `Run-Vvp` 判定正则**要能匹配新测试台的 `[XXX-SELFCHECK]` 标签，
  否则 vvp 正常退出 = `PASS(exit)`，**FAIL 会被报成 PASS**。
- **IROM 与 DRAM 是两套地址空间**：`lw` 读不到 IROM；字符串要启动时写进 DRAM。
- TB 里的**激励一律在 negedge 驱动**，每个 `while` 都要带 guard；串口激励直接位翻转最稳。
- 文档/RTL/TB：UTF-8 **无 BOM**、LF、无 U+FFFD；不要用 PS 的 `Get-Content/Set-Content` 处理。
