# v9 ILA 版 Vivado 工程（EES-331 / 50MHz）

本目录是 **v9 的 ILA 调试方案**工程：调试信号**一个都不引到引脚**，
全部由片内 ILA 通过 JTAG 抓取。顶层只剩 **3 个引脚**。

- 器件：`xc7z020clg484-1`（依元素科技 **EES-331** 教学板）
- 顶层：`board_top_ila`（`board/board_top_ila.sv`）
- CPU 时钟：**50MHz**（由板载 100MHz 经 MMCM 分频）
- 状态：综合 + ILA 插入 + 实现 + **bitstream 全部成功**，DRC 0 Error / 0 Critical Warning
- Vivado：`2025.2`（`D:\vivado\2025.2\Vivado\bin\vivado.bat`）

> 另一个工程 `E:\FPGA\v9_vivado` 是**引脚引出**方案（顶层 `board_top_vivado`，
> 105 个端口、不出 bit）。两版的取舍见 `ila_使用说明.md` §7.2。

---

## 1. 引脚（全部来自 EES-331 用户手册的"FPGA IO 约束"列）

| 端口 | 引脚 | 说明 |
| --- | --- | --- |
| `sys_clk` | **M19** | PL 时钟 `FPGA_CLK0` = 100MHz |
| `btn_rst_n` | **L18** | PL 按键 S1 / `FPGA_RESET`，4.7K 上拉、按下为低 |
| `debug_dead` | **V4** | 调试量"或"输出（心跳灯），接板载 LED0 |

⚠️ 手册里 `S5` 之类是**原理图位号**，不是引脚名；写成 `PACKAGE_PIN S5` 只会给一条
CRITICAL WARNING（不中止流程），很容易带着坏约束一路跑到实现。

## 2. 目录

```
E:\FPGA\v9_vivado_ila\
├─ src\                  RTL（从 E:\share doc\v9 拷来 + board_top_ila.sv，不含 testbench/旧 MDU.sv）
├─ prog.hex              IROM 初值（= sim/prog.hex）
├─ v9_board_ila.xdc      100MHz 主时钟 + 复位 + 3 个引脚
├─ build_ila.tcl         全流程：建工程 → 综合 → 网络核对 → ILA → 实现 → bit
├─ impl_ila.tcl          只重做「ILA + 实现 + bit」（复用 reports/post_synth.dcp，省 4 分钟）
├─ query_nets.tcl        查综合后网表里的真实网络名（调试 ILA 连不上时用）
├─ probe_props.tcl       列 debug core 的可设属性（查 ALL_PROBE_SAME_MU_CNT 等）
├─ reports\
│   ├─ v9_ila.bit        ★ 含 ILA 的 bitstream，Hardware Manager 烧这个
│   ├─ post_synth.dcp / post_route.dcp
│   └─ timing_post_route.rpt / util_post_route.rpt / drc.rpt / debug_core.rpt
├─ ila_使用说明.md        ★ 引脚表、13 根探针、Hardware Manager 用法、7 个实测坑
└─ vivado_50mhz_实测.md   引脚引出方案的实测记录（对照用）
```

## 3. 怎么跑

> ⚠️ **想用 GUI 看设计，请用 `build_gui_project.tcl`。**
> 早期几个脚本是**非工程模式**（`synth_design`/`place_design`/`route_design`），
> 报告和 bit 都有，但结果**不进工程 run**，GUI 里 Design Runs 是空的、
> 双击打不出网表 —— 就是"打开是黑的"。详见
> [`工程打开是黑的_排查与正确用法.md`](../syn/工程打开是黑的_排查与正确用法.md)。

```powershell
# ★ 推荐：产出 GUI 里能正常查看的工程（内存实现 + 结果登记进工程）
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado_ila/build_gui_project.tcl' `
  -log 'E:/FPGA/v9_vivado_ila/gui_build.log' -journal 'E:/FPGA/v9_vivado_ila/gui_build.jou'
# 然后打开：E:\FPGA\v9_vivado_ila\v9_ila_gui\v9_ila_gui.xpr
#   （脚本里 REBUILD_IMPL=0 时会复用 gui_build\ 里已有的 dcp/bit，只重建工程，约 1 分钟；
#     要重新实现就把它改成 1。）

# 非工程模式全流程（不产 GUI 可看结果，约 12 分钟）
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado_ila/build_ila.tcl' `
  -log 'E:/FPGA/v9_vivado_ila/build_ila.log' -journal 'E:/FPGA/v9_vivado_ila/build_ila.jou'

# 只重做 ILA + 实现 + bit（复用 reports/post_synth.dcp，约 6 分钟）
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado_ila/impl_ila.tcl' `
  -log 'E:/FPGA/v9_vivado_ila/impl.log' -journal 'E:/FPGA/v9_vivado_ila/impl.jou'
```

**在 GUI 里能做的事**（`v9_ila_gui.xpr`，32 个登记文件）：

| 想做什么 | 怎么做 |
| --- | --- |
| 看已实现的设计（布局/布线/原理图） | Sources 里双击 `gui_build/post_route_ila.dcp` |
| 看时序 / 资源 | 打开 `gui_build/timing_post_route.rpt`、`util_post_route.rpt` |
| 确认 ILA 在不在 | 打开 `gui_build/debug_core.rpt`（应有 `dbg_hub` + `u_ila_0`，implemented / inserted） |
| 上板抓波形 | Open Hardware Manager → Auto Connect → Program Device 选 `gui_build/v9_ila.bit` |
| 从 GUI 重新综合 | Design Runs → `synth_1` 右键 Run Synthesis |

## 4. 上板抓波形

Hardware Manager → Open Target → Auto Connect → Program Device 选 `reports/v9_ila.bit`
→ `hw_ila_1` 点 Run trigger。详细触发姿势（等某条 PC、等 trap_take、核对 cache 计数）
见 `ila_使用说明.md` §4。

## 5. 实测数据摘要

| 指标 | 值 |
| --- | --- |
| WNS（CPU 50MHz 域 `clk_sys_unbuf`） | **+3.697 ns**，0 失败端点 |
| WHS | +0.023 ns |
| Fmax（估算） | **61.34 MHz** |
| JTAG 域（TCK 30MHz） | WNS +25.716 ns |
| 资源 | LUT 12677 (23.8%)、FF 14190 (13.3%)、RAMB36 36.5 (26.1%)、DSP 12、**IOB 3** |
| bitstream | `reports/v9_ila.bit`（4.05 MB） |
| iverilog 回归 | 7 个程序 全 PASS（35/34/34/34/34/34/34） |

> ⚠️ 已知 RTL 待修项：`CSR.mtval` 在 RTL 层面没有被写，所以 ILA 的 `probe11`
> 抓到的是无效值（综合报 `mtval_reg_reg was removed` / `mtval_out does not have driver`）。
> 这是 v9 的 RTL 缺陷，不是 ILA 配置问题。
