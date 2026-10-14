# v9 Vivado 实测报告（xc7z020clg484-1 / 50MHz）

> 本文记录 **BigBird v9 第一次在真实 Vivado 工具链下**跑完
> 「综合 → 实现 → 时序」的实测数据。
> 此前 `syn/上板改造说明.md` §2 的 8218 LUT / 5589 FF 是 Yosys 的**厂商无关规模估算**，
> 与本文的真实数字不是一回事，别混用。
>
> **本文是"引脚引出"方案的记录**（顶层 `board_top_vivado`）。
> 后来改用 ILA 方案（顶层 `board_top_ila`，调试信号一个都不出引脚），
> 那一版的数据在 [`ila_使用说明.md`](ila_使用说明.md) §7。
> 两版的对比：ILA 版引脚 105 → **3**，代价是 Fmax 67.95 → **61.34MHz**。

| 项 | 值 |
| --- | --- |
| 工具 | Vivado v2025.2 (win64) Build 6299465 |
| 器件 | `xc7z020clg484-1`（**EES-331 教学板**，Zynq-7000，只用 PL 不用 PS） |
| 顶层 | `board_top_vivado`（`board/board_top.sv` 的省引脚外壳） |
| 时钟约束 | `create_clock -period 20.000` = **50MHz** |
| 流程 | `synth_design` → `opt_design` → `place_design` → `phys_opt_design` → `route_design` |
| 工程位置 | `E:\FPGA\v9_vivado\`（工程文件 `v9_board\v9_board.xpr`） |
| 出 bitstream | **否**（引脚未约束，见 §5） |

---

## 1. 结论先看

1. **综合通过，实现通过，时序全部满足，0 条失败端点。**
   - 后布线 `WNS(setup) = +5.283 ns`、`WHS(hold) = +0.045 ns`、`WPWS = +8.750 ns`。
   - 50MHz 周期 20ns，实际最长数据通路 **14.717 ns**（含时钟偏斜/不确定性），
     即 **估算 Fmax ≈ 67.95 MHz**，50MHz 下有约 26% 余量。
2. **资源远不是瓶颈**：LUT 18.5%、FF 8.8%、BRAM 14.3%、DSP 5.5%。
   50MHz 下真正的瓶颈是**布线延时**，不是逻辑规模 —— 见 §3 的最差路径。
3. **引脚是瓶颈**：`board_top` 原始端口需要 **201** 个引脚，比 `clg484` 全部可用 IO（200）
   还多 1 个，第一次实现直接 `place_design failed`。已用 `board_top_vivado` 收到 105 个。
4. **100MHz 目前收敛不了**：存在 >10ns 的组合通路（实测一条 14.574ns 的数据路径延时里
   有 13.870ns 是纯布线）。

---

## 2. 踩到并修掉的 3 个真问题

### 问题 1：顶层端口 201 个 > 器件可用 200 个，实现阶段直接失败

第一次跑实现，`place_design` 报：

```
ERROR: [Place 30-58] IO placement is infeasible.
Number of unplaced IO Ports (201) is greater than number of available pins (200).
ERROR: [Place 30-99] Placer failed with error: 'IO Clock Placer failed'
place_design failed
```

根因是**端口位宽**，不是逻辑：

| 端口 | 位宽 |
| --- | --- |
| `sys_clk` / `btn_rst_n` | 1 + 1 |
| `debug_wb_have_inst` / `debug_wb_ena` | 1 + 1 |
| `debug_wb_reg` | 5 |
| `debug_wb_pc` / `debug_wb_value` | 32 + 32 |
| `debug_*_hit_cnt` / `debug_*_miss_cnt`（4 个） | 4 × 32 = 128 |
| **合计** | **201** |

**修法**：新增 `board/board_top_vivado.sv` —— `debug_wb_*` 五个关键信号保持全宽，
4 个性能计数器各截到**低 8 位**，顶层端口 201 → **105**。
之所以用「新增外壳」而不是改 `board_top`：`board_top.sv` 是 `sim/` 回归和
`board/tb_board_top.sv` 的现行顶层，动它会牵连已通过的 103/103 回归。

> 代价：8 位计数器 256 次事件后回绕，不能算精确命中率。
> 要全 32 位得换更大封装，或改成 UART / ILA 输出。

### 问题 2：复位树把真正的关键路径盖住了（时序报告会骗人）

第一次实现「成功」后，`WNS = 2.191ns`，最差路径的 startpoint 清一色是：

```
u_board_top/reset_sync_inst/sync_ff2_reg/C
  → u_board_top/u_cpu/IDU_Inst0/Reg_Stack_inst0/Reg_inst/rf_reg[..][..]/R
```

也就是说：**排在最前面的根本不是 CPU 数据通路，而是复位同步器的扇出** ——
`reset_sync` 的输出扇出到整个寄存器堆（`Reg_Stack` 里 32×32 个 `rf_reg`），
这条「复位树延时」把所有真实数据路径挤到了报告后面。
仅靠 `set_false_path -from [get_ports btn_rst_n]` 是**切断不了**它的，
因为被分析的是同步器**输出寄存器**的扇出。

**修法**：在 `v9_board.xdc` 里补一条

```tcl
set_false_path -from [get_cells -hier -filter {NAME =~ *reset_sync_inst/sync_ff2_reg*}]
```

这在语义上是对的（`reset_sync` 本就是「异步置位、同步释放」，复位网络不承担
数据通路的时序要求），不是为了好看。**重新做实现后**：

| | 首轮（未修） | 修正后 |
| --- | --- | --- |
| WNS | 2.191 ns | **5.283 ns** |
| 被分析的路径端点 | 27051 | 18133 |
| 最差路径性质 | 复位树扇出 | DCache 数据通路 |

> 教训：拿到 `WNS` 一定要看**最差路径的 startpoint/endpoint**，
> 否则会把复位树/高扇出网络当成性能上限，白白得出「只能跑 56MHz」的错误结论。

### 问题 3：BRAM 没能用上字节写使能（非阻塞，但要知情）

综合对 64KB 的 DRAM 报了：

```
WARNING: [Synth 8-6841] Block RAM (dram_inst/g_ram.mem_ram_reg) originally specified as a
Byte Wide Write Enable RAM cannot take advantage of ByteWide feature and is implemented with
single write enable per RAM ... (address width (14) is more than optimal threshold of 12 ...)
```

**BRAM 推断是成功的**（最终 RAMB36E1 = 20 个，见 §4），只是 `sb`/`sh` 的字节写
没法用 BRAM 原生的 byte-write-enable，改成了单写使能实现，会多花一点逻辑与时序。
对 50MHz 无影响；将来要收紧频率或做 DMA 时可以按提示加
`(* ram_decomp = power *)` 或把 DRAM 拆成 4 个字节宽 BRAM。

---

## 3. 时序实测

### 3.1 汇总

| 指标 | 综合后 | 实现后（最终） |
| --- | --- | --- |
| WNS (setup) | +7.284 ns | **+5.283 ns** |
| TNS | 0.000 ns | 0.000 ns |
| TNS 失败端点 | 0 | 0 |
| WHS (hold) | 0.000 ns | **+0.045 ns** |
| THS | 0.000 ns | 0.000 ns |
| WPWS (脉宽) | +8.750 ns | +8.750 ns |
| 约束状态 | All user specified timing constraints are met | All user specified timing constraints are met |

由 `WNS` 反推：**实际最长数据路径 = 20 − 5.283 = 14.717 ns → Fmax ≈ 67.95 MHz**。

### 3.2 最差路径（实现后）

```
Slack (MET) : 5.283ns
  Source:      u_board_top/u_cpu/DCache_inst/store2_index_reg[1]/C
  Destination: u_board_top/u_cpu/DCache_inst/data_reg[43][13]/D
  Path Type:   Setup (Max at Slow Process Corner), Requirement 20.000ns
  Data Path Delay: 14.574ns  (logic 0.704ns (4.83%)  route 13.870ns (95.17%))
  Logic Levels: 2  (LUT6=2)
```

**这条路径值得单独说**：只有 2 级 LUT6、逻辑延时 0.704ns，却有 **13.870ns 是布线**。

- 说明 50MHz 的瓶颈**不是组合逻辑深度**，而是**布局布线**：
  很可能是 DCache 的 64 行 tag/data 阵列与 CPU 各流水级寄存器之间的物理距离/扇出导致。
- 因此「改 RTL 让它更快」在 50MHz 下几乎没有收益；要提高频率应该动
  **存储阵列的实现方式**（BRAM 化的 tag 表、加输出流水级）或加布局约束。

最差 hold 路径在 `ICache_inst`（`align_tag_r_reg[22]` → `tag_reg_0_63_22_22`），
余量 +0.045ns，同样来自 cache 阵列。它**不是**复位路径，说明问题 2 的约束没有误伤数据通路。

### 3.3 频率阶梯（基于实测推算）

| 目标 | 周期 | 周期余量 | 判断 |
| --- | --- | --- | --- |
| **50MHz** | 20.000 ns | +5.283 ns | ✅ 已实现并收敛 |
| 60MHz | 16.667 ns | +1.950 ns | ⚠️ 需要重跑实现确认（未实测） |
| 65MHz | 15.385 ns | +0.668 ns | ⚠️ 临界，未实测 |
| 67.95MHz | 14.717 ns | 0.000 ns | 理论极限 |
| 100MHz | 10.000 ns | −4.717 ns | ❌ 当前结构收敛不了 |

---

## 4. 资源占用（后布线）

| 资源 | 用量 | 可用 | 占比 |
| --- | --- | --- | --- |
| Slice LUTs | 9842 | 53200 | 18.50% |
| ├ LUT as Logic | 9742 | 53200 | 18.31% |
| └ LUT as Memory（分布式 RAM） | 100 | 17400 | 0.57% |
| Slice Registers (FF) | 9333 | 106400 | 8.77% |
| Slice | 4778 | 13300 | 35.92% |
| Block RAM Tile | 20 | 140 | 14.29% |
| └ RAMB36E1 | 20 | 140 | 14.29% |
| DSP48E1 | 12 | 220 | 5.45% |
| Bonded IOB | 105 | 200 | 52.50% |
| BUFGCTRL | 1 | 32 | 3.13% |

几点解读：

- **DSP48E1 = 12** 与 Yosys 的估算**完全一致**（3 个 32×32 乘法器，每个占 4 个 DSP），
  说明 `MDU_pipelined` 的乘法确实落到了硬件乘法器上。
- **BRAM = 20 个 RAMB36**：IROM 16KB = 4 个 RAMB36，DRAM 64KB = 16 个 RAMB36，
  正好对上，`sync_mem.sv` 的 `$readmemh` 初值被正确推断成 BRAM 初值
  （即 P3「程序载入」这条真的通了）。
- **FF 9333 vs Yosys 估算 5589**：真实工具把移位寄存器/大数组展开成了更多触发器，
  这类差异是正常的，也是「估算不能替代实测」的原因。
- **LUT 9842 vs Yosys 估算 8218**：同量级，同样偏高，原因同上。

---

## 5. 出 bitstream 前必须补的（当前 DRC 状态）

`report_drc` 当前有 **0 条 Error、2 类必须处理的告警**：

| DRC | 内容 |
| --- | --- |
| `NSTD-1` | 105 个端口全部用默认 `IOSTANDARD`，**不指定就不能生成 bitstream** |
| `UCIO-1` | 105 个端口全部没有 `LOC` 约束，同上 |
| `PREG` | 提示 12 个 DSP 的 P 输出未流水（性能建议，非阻塞） |

也就是说：**「实现能过」不等于「能出 bit」**。要落到板上还需要：

1. **引脚约束**：填 `v9_board.xdc` 末尾 TODO 段的 `PACKAGE_PIN` + `IOSTANDARD`。
2. **时钟来源**：本工程按 50MHz 约束，ZedBoard 板载是 **100MHz**（引脚 Y9），
   要么加 MMCM 分频，要么把 `create_clock` 改回 10ns 并做 100MHz 时序收敛
   （按 §3.3 目前做不到，得先解决布线瓶颈）。
3. **复位极性**：ZedBoard 的 `BTNC` 是**高有效**，`btn_rst_n` 是**低有效**，
   直连会「上电即复位、按下才跑」，必须反相。
4. **按键消抖（~10ms）**：`board_top` 只做了「异步置位、同步释放」。
5. **7 段数码管扫描 + 段选译码**（1kHz 左右）；本板没有 8 位数码管，需外接或改用 LED。
6. **引脚预算再确认**：即使收窄到 105 个端口，`clg484` 的 200 个 IO 在真实 ZedBoard 上
   已被 DDR3 / QSPI / 以太网 / USB 占掉一大批，**留给扩展口的只有几十根**。
   全宽显示 `debug_wb_pc[31:0]` + `debug_wb_value[31:0]` 很可能仍然放不下。
   建议上板时进一步收敛观察手段：
   - 只显示 PC 低 16 位 + 写回寄存器号 + `have_inst`；
   - 或者用 **UART（115200-8-N-1）** 把写回信息打成文本（v9 原计划的做法）；
   - 或者用 **ILA（Integrated Logic Analyzer）**，不占引脚，靠 JTAG 看波形。
     `board_top` 已把 `debug_wb_*` 引到端口，挂 ILA 是几行 Tcl 的事。

---

## 6. 怎么复现

```powershell
# 完整流程（建工程 + 综合 + 实现 + 报告），约 8 分钟
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado/build_v9.tcl' `
  -log 'E:/FPGA/v9_vivado/build.log' -journal 'E:/FPGA/v9_vivado/build.jou'

# 只重跑实现（改 xdc 后用，约 4 分钟；脚本内会显式 read_xdc）
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source 'E:/FPGA/v9_vivado/rerun_impl.tcl' `
  -log 'E:/FPGA/v9_vivado/rerun.log' -journal 'E:/FPGA/v9_vivado/rerun.jou'
```

报告文件在 `E:\FPGA\v9_vivado\reports\`：

| 文件 | 内容 |
| --- | --- |
| `timing_post_route.rpt` | 最终时序汇总 + 最差路径全文 |
| `timing_worst_paths.rpt` | 最差路径清单 |
| `util_post_route.rpt` | 后布线资源占用 |
| `drc.rpt` | DRC 结果 |
| `post_synth.dcp` / `post_route.dcp` | checkpoint（可直接 `open_checkpoint` 用 Tcl 查任意信号） |

---

## 7. 与文档其它部分的口径

- `syn/v9.xdc` 与 `syn/v9.sdc` 已同步改为 **20ns = 50MHz**，与本次实测口径一致。
- `sim/tb_iverilog.sv` 的仿真时钟仍是 **10ns = 100MHz**：仿真不受约束文件影响，
  且 103/103 的回归结果是在这个周期下取得的，**不要为了对齐而改它**。
- 「50MHz 能跑」是**时序**结论；**功能**结论来自 `sim/` 的 iverilog 回归
  （`prog` 35/35、`prog_mul` 34/34、`prog_div` 34/34，加 `+no_wbu_force +raw_rf`
  同样全过）。两者合起来才叫「50MHz 下功能与时序都对」——**尚未做板级实测**。
