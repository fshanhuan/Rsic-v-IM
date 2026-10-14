# v9 ILA 上板调试说明（EES-331 / xc7z020clg484-1）

> 这一版**不再把调试信号引到引脚**，改成片内 **ILA（Integrated Logic Analyzer）**
> 通过 JTAG 抓取。顶层只剩 3 个引脚，彻底绕开 EES-331 上 PL 引脚紧张的问题，
> 而且 4 个性能计数器可以保持**全 32 位**精度。
>
> **工程模式版（当前版本）**
> 工程位置：`E:\FPGA\v9_vivado_ila\v9_ila\v9_ila.xpr`（双击打开）
> 顶层：`project_src/board_top_gui.sv`
> ILA：标准 IP `u_ila_0`（`xilinx.com:ip:ila:6.2`）**例化在 RTL 里**
> 重建脚本：`E:\FPGA\v9_vivado_ila\build_project_ila.tcl`
>
> ⚠️ 早期两个版本（`v9_vivado` 引脚版 / `v9_ila_gui` 内存插桩版）都**已删除**，不要再用：
> 前者引脚截断到 8 位，后者**在 GUI 里 Design Runs 全灰**（磁盘上不产生 `.runs`/`.srcs`）。
> 原因与正确用法见 `工程打开是黑的_排查与正确用法.md`；
> 仓库里配套的旧脚本（`build_ila.tcl` / `impl_ila.tcl` / `build_gui_project.tcl` 等）
> 因依赖的 `reports\post_synth.dcp` 已删而**跑不通**，只作历史记录保留。
>
> **本版与早期版本最大的区别**：ILA 不再靠 `(* mark_debug *)` + `create_debug_core`
> 在内存里插入，而是**当普通 IP 例化**。这样 `synth_1` / `impl_1` 都是真实的
> 工程 run，GUI 里从综合到 bitstream 每一步都能双击查看、右键 Re-run。

---

## 1. 板卡侧事实（全部取自 EES-331 用户手册）

| 项 | 值 | 出处 |
| --- | --- | --- |
| 器件 | `xc7z020clg484-1` | §3 FPGA 资源概览 |
| **PL 时钟 `FPGA_CLK0`** | **100MHz，引脚 M19** | §5 系统时钟 |
| PS 时钟 `PS_CLK` | 33.333MHz，引脚 F7（本设计不用） | §5 系统时钟 |
| **PL 按键 `S1` / `FPGA_RESET`** | **引脚 L18**，4.7K 上拉、**按下为低** | §21 PL 按键电路 |
| PL LED0~LED7 | V4 U6 U5 V7 W7 W6 W5 U7 | §20 PL LED |
| PL 拨码 SW0~SW7 | AB6 Y4 AA4 R6 T6 T4 U4 V5 | §19 PL 拨码开关 |
| 4 位数码管 | 段选 LED0_CA..DP = R21 P20 P21 N15 P15 P17 P18 T16；位选 LED_BIT1..4 = M20 N19 N20 M21 | §20 |
| PL 侧 Bank 电压 | Bank0/13/33/34/35 **全部 3.3V** | §2 注意事项 |

### ⚠️ 两个必须注意的点

1. **板子给的是 100MHz，不是 50MHz。** 而本设计实测 Fmax ≈ 67.95MHz
   （见 `syn/vivado_50mhz_实测.md` §3），**100MHz 现在跑不了**。
   所以 `board_top_ila.sv` 里用 `MMCME2_BASE` 把 100MHz 分频成 **50MHz**：
   VCO = 100MHz × 10 = 1000MHz，CLKOUT0 = 1000 / 20 = 50MHz。
   以后要提频率，改 `CLKFBOUT_MULT_F` / `CLKOUT0_DIVIDE_F` 即可，不用换晶振。
2. **`S5` 不是引脚号。** 手册里按键画的是 `S1`，`S5` 那种是**原理图位号**。
   写成 `set_property PACKAGE_PIN S5 ...` 会报
   `CRITICAL WARNING: [Common 17-69] Command failed: 'S5' is not a valid site or package pin name.`
   而且它只是 CRITICAL WARNING，不会中止流程 —— 不看日志就会带着一个没生效的
   引脚约束一路跑到实现。**引脚一律以手册"FPGA IO 约束"列为准。**

---

## 2. ILA 抓了什么（13 根探针）

| 探针 | 信号 | 位宽 | 说明 |
| --- | --- | --- | --- |
| probe0 | `debug_wb_have_inst` | 1 | 写回事件有效 |
| probe1 | `debug_wb_pc` | 32 | 写回指令的 PC |
| probe2 | `debug_wb_ena` | 1 | 写回使能 |
| probe3 | `debug_wb_reg` | 5 | 写回目标寄存器号 |
| probe4 | `debug_wb_value` | 32 | 写回数据 |
| probe5 | `debug_icache_hit_cnt` | 32 | I-Cache 命中计数（**全宽，不再截 8 位**） |
| probe6 | `debug_icache_miss_cnt` | 32 | I-Cache 缺失计数 |
| probe7 | `debug_dcache_hit_cnt` | 32 | D-Cache 命中计数 |
| probe8 | `debug_dcache_miss_cnt` | 32 | D-Cache 缺失计数 |
| probe9 | `debug_mcause` | 32 | 异常原因（v9 修复 C4 的观察口，**原来悬空，现在终于能看到**） |
| probe10 | `debug_mepc` | 32 | 异常 PC |
| probe11 | `debug_mtval` | 32 | 异常附加值 ⚠️ **当前不可信**，见 §5 |
| probe12 | `debug_trap_take` | 1 | 陷入发生 |

采样时钟 = `sys_clk_50m`（MMCM 输出经 BUFG 的 50MHz），采样深度 **2048**。

> **探针是怎么"挂"上去的（本版做法）**：ILA 是**标准 IP 例化**。
> `build_project_ila.tcl` 里用 `create_ip` + `set_property CONFIG.C_PROBEn_WIDTH`
> 生成 IP，然后在顶层 `project_src/board_top_gui.sv` 里像普通模块一样例化：
>
> ```systemverilog
> u_ila_0 u_ila_0 (
>     .clk     (sys_clk_50m),          // 采样时钟 = CPU 时钟 = 50MHz
>     .probe0  (debug_wb_have_inst),
>     .probe1  (debug_wb_pc),
>     ...
>     .probe12 (debug_trap_take)
> );
> ```
>
> 信号来源：`board_top_ila.sv` 把 13 个调试量**引到输出端口**（原来只是内部线网），
> 顶层接过来同时送给 ILA 和 `debug_dead` 心跳。因为 ILA 的 probe 端口就是这些
> 信号的**真实负载**，综合不会再把它们优化掉。
>
> 早期那版用的是 `(* mark_debug = "true" *)` + `create_debug_core` 内存插桩，
> 结果正确但工程在 GUI 里没有 run（Design Runs 全灰），已弃用。

---

## 3. 怎么跑

### 3.1 推荐：直接开工程（GUI）

双击 **`E:\FPGA\v9_vivado_ila\v9_ila\v9_ila.xpr`**，然后按 GUI 里正常的
Vivado 流程走：`Run Synthesis` → `Open Synthesized Design` → `Run Implementation`
→ `Report Timing Summary` → `Generate Bitstream`。
Design Runs 里 `synth_1` / `impl_1` / `u_ila_0_synth_1` 都有真实状态，不是灰的。

### 3.2 命令行重建整个工程

```powershell
# 完整流程（建工程 + ILA IP + 综合 + 实现 + bitstream），约 20~40 分钟
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado_ila/build_project_ila.tcl' `
  -log    'E:/FPGA/v9_vivado_ila/build_project_ila.log'
```

脚本开头两个开关很好用：

| 开关 | 值 | 作用 |
| --- | --- | --- |
| `DO_SYNTH` | `1` | 删掉工程重建 + 重跑综合（干净，默认） |
| | `0` | **保留**已有工程和 `synth_1`，只重跑实现（省一次综合） |
| `DO_IMPL` | `1` | 一路跑到 bitstream（默认） |
| | `0` | 只到综合，用来快速验证 RTL 能不能过（约 5 分钟） |

> 改 RTL 后只想看"能不能综合过"，就把 `DO_IMPL` 设 0 先跑一遍，
> 别动辄等 30 分钟。这是本工程实测最省时间的一条经验。

### 3.3 产物

| 文件 | 说明 |
| --- | --- |
| `v9_ila\v9_ila.xpr` | **工程文件，双击打开** |
| `v9_ila\v9_ila.runs\synth_1\board_top_gui.dcp` | 综合 checkpoint（run 产物） |
| `v9_ila\v9_ila.runs\impl_1\board_top_gui.dcp` | 后布线 checkpoint（run 产物） |
| `v9_ila\v9_ila.runs\impl_1\board_top_gui.bit` | **含 ILA 的 bitstream**，Hardware Manager 用这个 |
| `v9_ila\v9_ila.runs\impl_1\board_top_gui.ltx` | **ILA 探针文件**，烧录时自动带上 |
| `project_src\*.rpt` | 时序 / 资源 / DRC / debug core 报告（脚本自动导出） |

> 注意 `.ltx` 是标准 IP 例化方案**天生就有**的产物。
> 早期内存插桩那版没有它，Hardware Manager 里常常要手工指探针文件。

### 3.4 已废弃的旧脚本

`build_ila.tcl` / `impl_ila.tcl` / `build_gui_project.tcl` 是非工程模式那一套，
只为复现历史问题保留，**不要再用**（理由见
`工程打开是黑的_排查与正确用法.md` §2）。

## 4. 在 Hardware Manager 里怎么抓

1. Vivado → **Open Hardware Manager** → **Open Target** → **Auto Connect**。
   （EES-331 用板载 USB3.0 下载器；若 Auto Connect 找不到，按手册 §6 把 SW8
   拨成"板载下载调试器"模式，并确认 JP6/JP7 的 USB 配置跳线。）
2. **Program Device**，选
   `v9_ila\v9_ila.runs\impl_1\board_top_gui.bit`。
   烧完 ILA 会自动出现在 Hardware 窗口的 `hw_ila_1` 下
   （没出现就点 **Refresh Device**）；探针文件是同目录的 `board_top_gui.ltx`，
   一般会自动带上，没带上就在 `Debug probes file` 里手工选它。
3. 打开 `hw_ila_1` 的波形窗口，点 **Run trigger for this ILA core**（或先设触发条件再 Run）。
4. 常用触发姿势：
   - **看一次完整运行**：`probe0 (have_inst)` 设 `R`（上升沿），立即触发，
     抓到的 2048 个采样点就是 2048 个 50MHz 时钟（约 **41µs**）的写回序列；
   - **等某条指令**：`probe1 (wb_pc)` 设 `== 0x00000034`（例如 prog.hex 里的 ecall 地址），
     配合 `probe0 == 1`，就能精确停在那一拍的上下文；
   - **看异常**：`probe12 (trap_take)` 设 `R`，抓到后看 `probe9 (mcause)` / `probe10 (mepc)`；
   - **核对 Cache 行为**：在波形里读 `probe5..probe8`，与仿真日志里的
     `ICache: hit=48 miss=16` / `DCache: hit=3 miss=1`（`sim/build/prog.log`）对照。
5. 别忘了 `0x00000013`（NOP）之类噪声：`have_inst=1` 但 `ena=0` 的拍很常见，
   想看"真正写入寄存器"的事件就把触发条件加上 `probe2 (ena) == 1`。

> 采样深度 2048 × 288 位 ≈ 590Kb，约占 16~20 个 RAMB36。
> 要抓更长的窗口就把 `build_project_ila.tcl` 里的 `ILA_DEPTH` 调大后重跑
> （4096 → 约 40 个 RAMB36；器件共 140 个，还有余量）。
> 也可以在 GUI 里双击 Sources 窗口的 `u_ila_0` IP 直接改。

---

## 5. 本次踩的坑（都是实测暴露的，改之前先看这里）

| # | 现象 | 根因 | 修法 |
| --- | --- | --- | --- |
| 0 | **打开工程后 Design Runs 全灰、点不动** | 用 `create_project` 建了工程，却用 `synth_design`/`route_design` 这些**非工程模式**命令在内存里跑完流程。磁盘上没有 `.runs`/`.srcs`，GUI 没有 run 可显示 | 全程改用 `launch_runs` + `wait_on_run`；ILA 改成标准 IP 例化。详见 `工程打开是黑的_排查与正确用法.md` |
| 1 | MMCM 不锁定，LOCKED 恒 0，CPU 永远停在复位态（上板表现为"完全没动静"） | `MMCME2_BASE` 的 **`CLKFBIN` 漏接**，内部反馈环断开。综合只给一条容易忽略的 `WARNING: [Synth 8-7071] port 'CLKFBIN' ... is unconnected` | `board_top_ila.sv` 里 `.CLKFBIN(clkfb)` 必须接上 `CLKFBOUT` |
| 2 | ILA 只能找到 3 个信号，其余 10 组 32 位全丢 | 顶层没有负载 → Vivado 把调试网络**优化掉**了。日志里只有一句 `WARNING: [Synth 8-4446] all outputs are unconnected for this instance and logic may be removed`。**光加 `mark_debug`/`keep` 不够** | ① 把全部调试量或（OR）到唯一输出 `debug_dead` 当心跳；② **更彻底的办法是本版采用的：让 ILA 的 probe 端口直接成为这些信号的真实负载**，综合就绝不会删 |
| 3 | `get_nets u_board_top/u_cpu/debug_wb_pc` 返回空，但网络明明存在 | 综合后总线被拆成**逐位网络**（`debug_wb_pc[0]`…`[31]`），总线名查不到 | 用折叠写法 `debug_wb_pc[*]`，一次返回 32 个位网络（这条只在早期内存插桩流程里才需要） |
| 4 | `set_property port_width [get_debug_ports u_ila_0/probe1]` 报 `No ChipScope debug ports matched` + `[Common 17-55] expects at least one object` | `create_debug_core` 只自动创建 **`clk` + `probe0`** 一个探针 | `probe1..N` 必须显式 `create_debug_port u_ila_0 probe` 再设位宽（早期流程的坑） |
| 5 | `implement_debug_core` 报 `ERROR: [IP_Flow 19-3458] ... ALL_PROBE_SAME_MU_CNT ... Value '1' is out of the range (2,16)` | 该参数默认值 1，但 IP 校验要求 2~16 | **本版同样要设**：`CONFIG.ALL_PROBE_SAME_MU_CNT = 2`（标准 IP 流程里写在 `create_ip` 的 `-dict` 里） |
| 6 | `PACKAGE_PIN S5` 报 `'S5' is not a valid site or package pin name`（只是 CRITICAL WARNING，不中止） | `S5` 是**原理图位号**，不是引脚名 | 用手册"FPGA IO 约束"列的真值：按键 = **L18** |
| 7 | `debug_mtval` 抓到的是常数/无效值 | v9 的 `CSR.mtval` 在 **RTL 层面就没有被写**：综合报 `mtval_reg_reg was removed` / `mtval_out does not have driver` | **属于 RTL 待修项**，不是 ILA 的问题。修 `CSR.sv` 的 mtval 写入逻辑后即可看到真值 |
| 8 | 顶层例化 `board_top_ila` 时报 13 个 `ERROR: [Synth 8-11365] named port connection 'debug_xxx' does not exist` | 原来那 13 个调试量只是 `board_top_ila` 内部的局部线网，**模块没有对应输出端口** | 给 `board_top_ila` 补上 13 个 `output`（内部线网改名与端口一致，逻辑零改动） |
| 9 | `read_verilog -include <dir>` 报 `'-include' is only supported when is_compile_unit_mode is enabled` | 该选项只在 compile-unit 模式下有效 | 改用 Tcl：`set_property include_dirs {...} [current_fileset]` |

## 6. 与仿真回归的关系

改了 `myCPU.sv` / `board_top.sv` / `board_top_ila.sv`（只加属性、只多引出端口，
**没有改逻辑**）后，`sim/` 的 iverilog 回归**全过**：

```
prog            35/35 PASS
prog_mul        34/34 PASS
prog_div        34/34 PASS
prog_load_lane  34/34 PASS
prog_load_use   34/34 PASS
prog_loop       34/34 PASS
prog_div_pair   34/34 PASS
```

`(* mark_debug *)` / `(* keep *)` 对 iverilog / ModelSim 是透明注释，不影响仿真。
测试台本来就直接例化 `myCPU`，不经过 `board_top_ila`，所以加端口也不影响它们。
复现：`sim\run_iverilog.bat <prog>`（iverilog 在 `D:\eda_tools\iverilog\bin`）。

---

## 7. 实测结果（工程模式 ILA 版）

环境：Vivado 2025.2 / `xc7z020clg484-1` / 顶层 `board_top_gui` / CPU 时钟 50MHz。
工程：`E:\FPGA\v9_vivado_ila\v9_ila\v9_ila.xpr`。

| 指标 | 值 |
| --- | --- |
| 状态 | 综合 + 实现 + **bitstream 全部成功**，`synth_1` / `impl_1` 均 100% |
| DRC | 后布线 **0 Error、0 Critical Warning**（只剩 DPOP/REQP/RTSTAT/ZPS7 类 Warning） |
| `dbg_hub` | `labtools_xsdbm_v3`，已插入，时钟 = `sys_clk_50m` |
| `u_ila_0` | `xilinx.com:ip:ila:6.2`，13 探针，深度 2048，采样时钟 50MHz |
| 顶层端口 | **3 个**（sys_clk / btn_rst_n / debug_dead） |
| 布线后单元数 | 32616 |
| bitstream | `v9_ila.runs\impl_1\board_top_gui.bit`（3.86 MB，文件头 `00 09 0F F0 …` 正确） |
| 探针文件 | `v9_ila.runs\impl_1\board_top_gui.ltx`（61 KB） |

### 7.1 时序（两个时钟域都满足）

| 时钟 | 频率 | WNS | WHS | 失败端点 |
| --- | --- | --- | --- | --- |
| `clk_sys_unbuf`（CPU 实际时钟，MMCM 输出） | 50MHz / 20ns | **+4.162 ns** | **+0.011 ns** | **0** / 27564 |
| `…SERIES7_BSCAN…/TCK`（JTAG 域，ILA 用） | 30.303MHz / 33ns | 满足 | 满足 | 0 |
| 整体（含跨时钟域） | — | **+4.162 ns** | **+0.011 ns** | **0** / 27564（保持 27548） |

`All user specified timing constraints are met`，**TNS = THS = TPWS = 0**。
按 CPU 时钟算 **Fmax ≈ 63.14MHz** —— 50MHz 下余量约 **26%**（4.162 / 20）。

> 三个时钟域：`sys_clk`（100MHz 输入，M19）、`clk_sys_unbuf`（50MHz，CPU 真时钟）、
> `clkfb`（100MHz，MMCM 反馈）、以及 JTAG 的 `TCK`（30.3MHz）。
> 报告里 JTAG 域 slack 很大（几十 ns），别拿它当设计的关键路径。

### 7.2 资源（后布线）

| 资源 | 本版（ILA IP 例化） | 无 ILA 版（引脚引出方案） | ILA 自身增量 |
| --- | --- | --- | --- |
| Slice LUTs | 12677 (23.83%) | 9842 (18.50%) | +2835 |
| Slice Registers | 14190 (13.34%) | 9333 (8.77%) | +4857 |
| Block RAM Tile (RAMB36/RAMB18) | 36.5 (26.07%) | 20 (14.29%) | **+16.5** |
| DSP48E1 | 12 (5.45%) | 12 (5.45%) | 0 |
| **Bonded IOB** | **3 (1.50%)** | 105 (52.50%) | **−102** |
| BUFGCTRL | 2 | 1 | +1（ILA/时钟） |

**这就是用 ILA 换来的核心收益**：引脚从 105 降到 **3**，
以后想加数码管 / UART / LED 都随便用；代价是 ~2.8K LUT、~4.9K FF、16.5 个 BRAM，
以及 Fmax 从 67.95MHz 降到 **63.14MHz**（因为 ILA 要采样那 288 位调试总线）。

> 若要更长的采样窗口：`ILA_DEPTH` 改 4096 → 大约再多 20 个 RAMB36
> （器件共 140 个，当前只用 36.5，余量充足）。

### 7.3 综合时值得留意的告警（都在容忍范围内）

| 告警 | 含义 | 处理 |
| --- | --- | --- |
| `[Synth 8-6014] Unused sequential element mtval_reg_reg was removed` + `[Synth 8-3848] Net mtval_out ... does not have driver` | `CSR.mtval` 死寄存器 | **RTL 待修项**，probe11 因此抓不到真值 |
| `[Synth 8-4767] Trying to implement RAM 'data_reg' in registers` | DCache 的 `data_reg` 无法推断成 BRAM，改用寄存器实现 | 功能正确；要省资源可以改 DCache 的写法，属优化项 |
| `[Synth 8-6841] Block RAM (dram_inst/g_ram.mem_ram_reg) ... ByteWide feature` | DRAM 的 BRAM 推断成功，只是没用字节写使能 | 无害（本次实测就是这条，BRAM 确实推断出来了） |
| `[Synth 8-7129] Port addr[31] ... is either unconnected or has no load` | 存储器高位地址没用到（IROM 4096 字 / DRAM 16384 字，地址位本就用不满） | 无害 |
| `[Timing 38-436] There are set_bus_skew constraint(s) in this design` | ILA IP 自带 `set_bus_skew` 约束 | 无害；想彻底确认可跑 `report_bus_skew` |
| `[Power 33-332] high-fanout reset nets being asserted for excessive periods` | 复位网络的估算活动度偏高，影响功耗估算精度 | 上板前复位是拉低的，属正常；功耗分析时才需要关注 |


