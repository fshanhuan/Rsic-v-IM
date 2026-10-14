# v9 ILA 版 Vivado 工程（EES-331 / 50MHz）—— 工程模式版

本目录是 **v9 的 ILA 调试方案**工程：调试信号**一个都不引到引脚**，
全部由片内 ILA 通过 JTAG 抓取。顶层只剩 **3 个引脚**。

- 器件：`xc7z020clg484-1`（依元素科技 **EES-331** 教学板）
- **工程文件：`v9_ila\v9_ila.xpr`（双击打开即可，Design Runs 全流程可见）**
- 顶层：`board_top_gui`（`project_src\board_top_gui.sv`）
  内部例化 `board_top_ila`（`src\board_top_ila.sv`）+ ILA IP `u_ila_0`
- CPU 时钟：**50MHz**（由板载 100MHz 经 MMCM 分频）
- 状态：综合 + 实现 + **bitstream 全部成功**，DRC 0 Error / 0 Critical Warning
- Vivado：`2025.2`（`D:\vivado\2025.2\Vivado\bin\vivado.bat`）

> ⚠️ **工程模式 vs 非工程模式**
> 早期脚本用 `synth_design` / `route_design` 在内存里跑完流程，报告和 bit 都有，
> 但结果**不进工程 run** → 打开工程后 Design Runs 全灰、点不动（"打开是黑的"）。
> **本版已改为全程工程模式**：ILA 是标准 IP 例化，`synth_1` / `impl_1` 都是真实 run。
> 原因与排查方法见 [`../syn/工程打开是黑的_排查与正确用法.md`](../syn/工程打开是黑的_排查与正确用法.md)。

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
├─ v9_ila\                        ★ 工程目录
│   ├─ v9_ila.xpr                   ★★ 打开这个
│   └─ v9_ila.runs\
│       ├─ synth_1\                 board_top_gui.dcp（综合产物）
│       ├─ impl_1\                  ★ board_top_gui.bit / .ltx（烧板用这两个）
│       │                           board_top_gui_routed.dcp + 全套 rpt
│       └─ u_ila_0_synth_1\         ILA IP 的 OOC 综合
├─ project_src\                   ★ 工程模式专用源
│   ├─ board_top_gui.sv             顶层：board_top_ila + u_ila_0
│   ├─ prog.hex                     IROM 初值（= sim/prog.hex）
│   ├─ u_ila_0.veo.template         ILA 例化模板（对照端口名用）
│   └─ *.rpt                        脚本导出的时序/资源/DRC/debug core 报告
├─ build_project_ila.tcl          ★★ 一条命令重建工程（工程模式）
├─ verify_project.tcl             验证工程能否正常展开（run/IP/网表/时序）
├─ src\                           RTL 副本（board_top_ila.sv 从 E:\share doc\v9 同步）
├─ v9_board_ila.xdc               100MHz 主时钟 + 复位 + 3 个引脚
├─ v9_ila_gui\                    ⚠️ 旧的空壳工程（无 .runs/.srcs），保留供对比
├─ gui_build\ / reports\          旧非工程模式的产物（dcp/bit/rpt），历史保留
└─ 旧脚本：build_ila.tcl / impl_ila.tcl / build_gui_project.tcl（已废弃）
```

## 3. 怎么跑

### 3.1 推荐：直接开工程

双击 **`E:\FPGA\v9_vivado_ila\v9_ila\v9_ila.xpr`**，然后按 GUI 常识操作：
`Run Synthesis` → `Open Synthesized Design` → `Run Implementation` →
`Report Timing Summary` → `Generate Bitstream`。
Design Runs 里 `synth_1`（100%）、`impl_1`（write_bitstream Complete! 100%）、
`u_ila_0_synth_1`（100%）都有真实状态。

### 3.2 命令行重建

```powershell
# 一条命令重建整个工程（建工程 + ILA IP + 综合 + 实现 + bitstream）
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado_ila/build_project_ila.tcl' `
  -log    'E:/FPGA/v9_vivado_ila/build_project_ila.log'
```

脚本开头两个开关：

| 开关 | 值 | 作用 |
| --- | --- | --- |
| `DO_SYNTH` | `1` | 删掉工程重建 + 重跑综合（干净，默认） |
| | `0` | 保留已有工程和 `synth_1`，只重跑实现（省一次综合） |
| `DO_IMPL` | `1` | 一路跑到 bitstream（默认） |
| | `0` | 只到综合，快速验证 RTL（约 5 分钟） |

### 3.3 验证工程是否"能展开"

```powershell
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado_ila/verify_project.tcl'
```

它会把 run 状态、IP 配置、已实现设计能否打开、时序数字、探针是否连着真信号
全部打一遍。本次实测输出（节选）：

```
synth_1         status=synth_design Complete!      progress=100%
impl_1          status=write_bitstream Complete!   progress=100%
u_ila_0  ->  xilinx.com:ip:ila:6.2   probes=13  depth=2048
cells = 32616        top ports = 3 (btn_rst_n debug_dead sys_clk)
debug cores = dbg_hub u_ila_0
WNS = 4.162 ns   WHS = 0.011 ns   50MHz WNS = 4.162 ns -> Fmax = 63.14 MHz
probe1 : 97 net(s)   probe11 : 32 net(s)   probe12 : 1 net(s)
```

**在 GUI 里能做的事**（不用任何额外脚本）：

| 想做什么 | 怎么做 |
| --- | --- |
| 看层次结构 | Sources → `board_top_gui` 展开，能看到 `u_board_top_ila` / `u_ila_0` |
| 看已综合的设计 | Flow Navigator → Synthesis → **Open Synthesized Design** |
| 看已实现的设计（布局/布线） | Flow Navigator → Implementation → **Open Implemented Design** |
| 看时序 / 资源 | 同上，或打开 `v9_ila.runs\impl_1\board_top_gui_timing_summary_routed.rpt` |
| 确认 ILA 在不在 | Hardware 或 Tcl `get_debug_cores`（应有 `dbg_hub` + `u_ila_0`） |
| 改 ILA 深度/位宽 | 双击 Sources 里的 `u_ila_0`，改完 Generate Output Products 重跑 |
| 上板抓波形 | Open Hardware Manager → Auto Connect → Program Device |
| 从 GUI 重跑流程 | Design Runs → 选 run → 右键 Reset/Run |

## 4. 上板抓波形

1. Hardware Manager → Open Target → **Auto Connect**；
2. **Program Device** 选
   `E:\FPGA\v9_vivado_ila\v9_ila\v9_ila.runs\impl_1\board_top_gui.bit`；
   探针文件是同目录的 **`board_top_gui.ltx`**，一般自动带上，
   没带上就在 `Debug probes file` 里手工选它；
3. 出现 `hw_ila_1` → **Run trigger**。

详细触发姿势（等某条 PC、等 `trap_take`、核对 cache 计数）见
[`ila_使用说明.md`](ila_使用说明.md) §4。

## 5. 实测数据摘要（工程模式 ILA 版）

| 指标 | 值 |
| --- | --- |
| WNS（CPU 50MHz 域 `clk_sys_unbuf`） | **+4.162 ns**，0 失败端点 / 27564 |
| WHS | +0.011 ns，0 失败端点 / 27548 |
| Fmax（估算） | **63.14 MHz**（50MHz 余量 ≈ 26%） |
| JTAG 域（TCK 30.303MHz） | 满足，0 失败端点 |
| 资源 | LUT 12677 (23.8%)、FF 14190 (13.3%)、RAMB36 36.5 (26.1%)、DSP 12、**IOB 3** |
| bitstream | `v9_ila.runs\impl_1\board_top_gui.bit`（3.86 MB） |
| 探针文件 | `v9_ila.runs\impl_1\board_top_gui.ltx`（61 KB） |
| iverilog 回归 | 7 个程序 全 PASS（35/34/34/34/34/34/34） |

> ⚠️ 已知 RTL 待修项：`CSR.mtval` 在 RTL 层面没有被写，所以 ILA 的 `probe11`
> 抓到的是无效值（综合报 `mtval_reg_reg was removed` / `mtval_out does not have driver`）。
> 这是 v9 的 RTL 缺陷，不是 ILA 配置问题。

## 6. 三个版本的沿革（避免再走回头路）

| 版本 | 工程目录 | 顶层 | ILA 方式 | 结果 |
| --- | --- | --- | --- | --- |
| 第 1 版 | `E:\FPGA\v9_vivado`（已删） | `board_top_vivado` | 无，调试信号引到 105 个引脚 | 能用，但计数器截断到 8 位 |
| 第 2 版 | `v9_ila_gui`（空壳，保留对比） | `board_top_ila` | `mark_debug` + 内存 `create_debug_core` | 结果对，但 GUI 全灰 |
| **第 3 版（当前）** | **`v9_ila`** | **`board_top_gui`** | **标准 IP 例化** | **run 真实存在，GUI 全流程可见** |
