# Vivado / ILA 文档索引（本目录）

> 本目录是 `E:\FPGA\v9_vivado_ila\` 的 **Vivado / ILA 专属文档**。
> 工程入口与快速上手请看上层的 **[`../../README.md`](../../README.md)**。

## 这份文档讲什么

v9 上板工程的 ILA 调试方案：调试信号**一个都不引到引脚**，全部由片内 ILA
通过 JTAG 抓取，顶层只剩 **3 个引脚**。

| 项 | 值 |
| --- | --- |
| 器件 | `xc7z020clg484-1`（依元素科技 **EES-331** 教学板） |
| 工程文件 | `../../v9_ila/v9_ila.xpr`（双击打开，Design Runs 全流程可见） |
| 顶层 | `board_top_gui`（`../../board_top_gui.sv`） |
| 被测设计 | `board_top_ila`（`../../board/board_top_ila.sv`）+ ILA IP `u_ila_0` |
| CPU 时钟 | **50MHz**（板载 100MHz 经 MMCM 分频） |
| 状态 | 综合 + 实现 + **bitstream 全部成功**，DRC 0 Error / 0 Critical Warning；**已上板抓过 ILA**，抓出并修复了一个真实 bug（v9 B9） |
| Vivado | `2025.2`（`D:\vivado\2025.2\Vivado\bin\vivado.bat`） |

> ⚠️ **工程模式 vs 非工程模式**
> 早期脚本用 `synth_design` / `route_design` 在内存里跑完流程，报告和 bit 都有，
> 但结果**不进工程 run** → 打开工程后 Design Runs 全灰、点不动（"打开是黑的"）。
> 本版已改为全程工程模式：ILA 是标准 IP 例化，`synth_1` / `impl_1` 都是真实 run。
> 排查细节见 [`工程打开是黑的_排查与正确用法.md`](工程打开是黑的_排查与正确用法.md)。

## 引脚（全部来自 EES-331 用户手册的"FPGA IO 约束"列）

| 端口 | 引脚 | 说明 |
| --- | --- | --- |
| `sys_clk` | **M19** | PL 时钟 `FPGA_CLK0` = 100MHz |
| `btn_rst_n` | **L18** | PL 按键 S1 / `FPGA_RESET`，4.7K 上拉、按下为低 |
| `debug_dead` | **V4** | 调试量"或"输出（心跳灯），接板载 LED0 |

⚠️ 手册里 `S5` 之类是**原理图位号**，不是引脚名；写成 `PACKAGE_PIN S5` 只会给一条
CRITICAL WARNING（不中止流程），很容易带着坏约束一路跑到实现。

## 本目录文档

| 文档 | 讲什么 |
| --- | --- |
| [`ecall重定向故障_根因与修复.md`](ecall重定向故障_根因与修复.md) | ★ **v9 B9**：板上 ILA 抓出的 `ecall` 重定向失败 —— 逐拍证据、仿真复现、根因（`dnpc_flag & ready`）、修复、新增回归断言。**"为什么 35/35 全过还有 bug"看这篇** |
| [`ila_使用说明.md`](ila_使用说明.md) | **实测主报告**：引脚表、**16 根探针**分配、Hardware Manager 触发姿势、时序/资源实测、11 条踩坑 |
| [`上板验证判据.md`](上板验证判据.md) | **上板时怎么判定"正常工作"** ★：LED 心跳灯判读、`prog.hex` 14 条指令的预期写回值表、**五个**单点决定性检查（**§7.1 是 `ecall` 重定向判据**）、症状 → 根因速查 |
| [`工程打开是黑的_排查与正确用法.md`](工程打开是黑的_排查与正确用法.md) | 为什么 GUI 里 Design Runs 是灰的、工程模式与非工程模式不能混用、三个版本沿革 |
| [`vivado_50mhz_实测.md`](vivado_50mhz_实测.md) | 早期「调试信号引到引脚」方案（顶层 `board_top_vivado`）的实测记录，对照用 |
| [`../../syn/上板改造说明.md`](../../syn/上板改造说明.md) | 上板障碍清单 P0~P5、改造前后对照、6 个 RTL 缺陷的根因 |
| [`交付说明.md`](交付说明.md) | 上板改造的交付清单与「本机没能做的部分」 |
| `改动diff_接管前快照_vs_上板改造后.txt` | 全部 RTL 改动的逐行对照（**注意：这是 B9 之前的快照**） |

> 这份 README 的前身（描述 GitHub 仓库里 `v9/vivado_project/` 的版本）已随仓库更新，
> 仓库版见 `https://github.com/fshanhuan/Rsic-v-IM/blob/main/v9/vivado_project/README.md`。

## 工程怎么跑（命令见上层 README）

- `../../build_project_ila.tcl` —— 一条命令重建整个工程（建工程 + ILA IP + 综合 + 实现 + bitstream）
- `../../verify_project.tcl` —— 自检：run 状态 / IP 配置 / 已实现设计能否打开 / 时序 / 探针连通性
- 烧板：`Program Device` 选 `../../v9_ila/v9_ila.runs/impl_1/board_top_gui.bit`，
  探针文件是同目录的 `board_top_gui.ltx`

## 顶层层次（GUI 里 Sources 窗口展开的样子）

```
board_top_gui (board_top_gui.sv)          ← 顶层
├─ u_board_top_ila (board_top_ila.sv)     ← MMCM 100→50MHz + CPU + 存储器
│   └─ u_board_top (board_top.sv)
│       └─ u_cpu (rtl/myCPU.sv)
└─ u_ila_0 (u_ila_0.xci)                  ← ILA，标准 IP
```
