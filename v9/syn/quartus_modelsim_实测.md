# v9 用 Quartus / ModelSim 实测记录（本机：Quartus II 13.0.1 + ModelSim SE-64 10.5）

> 本文件记录「拿本机的 Quartus II 13.0 与 ModelSim 10.5se 去综合/仿真这颗 v9 CPU」
> 的过程、结论、以及**因此发现并修掉的 2 个真实 RTL 缺陷**。
> 逐步复现命令见文末 §5。

## 0. 一句话结论

| 项 | 结果 |
| --- | --- |
| ModelSim 功能仿真 | **全部通过**：7 程序 × {正常,严格} = 14 项 + D-Cache 单元测试 + board_top 上板路径测试台 = **16/16** |
| Quartus II 13.0 综合 | **可用**，但必须先加一行 `VERILOG_INPUT_VERSION SYSTEMVERILOG_2005`（否则 10170 语法错满屏），见 §2 |
| 修掉的真实缺陷 | **2 个**：`board_top` 的 5 处层次化引用（综合直接失败）、`sync_mem` 初始化循环越 Quartus 上限，见 §3 |
| CPU 核心资源（Cyclone IV E） | **18,815 LE / 8,995 寄存器 / 24 个 9 位乘法器** |
| 整机资源（含 64KB DRAM） | **19,175 LE / 9,268 寄存器 / 68 个 M9K / 530,688 存储位 / 201 引脚** |
| 能否装进 EP4CE6E22C8（征途板） | **不能**：逻辑 306 %、存储 192 %、引脚 218 %，见 §4 |
| 换到 EP4CE30 呢 | 逻辑 67 %、引脚 61 % 都够，**只有 M9K 差 2 块（68/66）** → 瓶颈是 64KB DRAM，见 §4.3 |
| 减存储变体（DRAM 16KB）| **fit 成功**：16,935 LE / 20 M9K / 75 引脚，见 §4.4 |
| 实测 Fmax | **78.2 MHz**（85 °C 慢速模型），100 MHz 下 setup slack −2.787 ns；**建议先按 50 MHz 上板**，见 §4.5 |
| 报告里的「103/103 全过」 | 与本次 ModelSim 结果一致，**可复现** |

## 1. 本机工具版本

| 工具 | 路径 | 版本 |
| --- | --- | --- |
| ModelSim | `E:\FPGA\ModelSim_10.5se\win64` | SE-64 10.5，2016.02（**SE 版**，无 PE 的行数限制，可以编译整颗 CPU） |
| Quartus II | `E:\FPGA\QuartusII_13.0\quartus\bin64` | 13.0.1 Build 232 SP1（32/64 位都有） |
| iverilog | `D:\eda_tools\iverilog\bin` | 12.0（另有一条回归线，见 `sim/README_iverilog.md`） |

ModelSim 版本确认：

```
# Model Technology ModelSim SE-64 vsim 10.5 Simulator 2016.02 Feb 13 2016
```

**注意**：如果手上是 ModelSim-Altera Starter（PE）版，整颗 CPU 会因为
「10000 行可执行代码」限制而**编不过**，必须用 SE 版或 Questa。

## 2. Quartus II 13.0 关键发现：SV 开关

Quartus II 13.0 默认按 **Verilog-2001** 解析，整套 SV 写法全部报错：

```
Error (10170): Verilog HDL syntax error at IFU.sv(55) near text "@";  expecting ".", or "("
Error (10170): Verilog HDL syntax error at ICache.sv(138) near text "@"; ...
Error (10170): Verilog HDL syntax error at RegisterFile.sv(26) near text "@"; ...
Error (10149): error at CSR.sv(116): identifier "mstatus_reg" is already declared ...
Error (10759): object update_taken declared in a list of port declarations cannot be redeclared
```

一开始的表现很容易被误判成「Q13.0 不支持 SystemVerilog」。**其实它支持**，
只是要在工程设置里显式声明输入版本。在 `.qsf` 里加**一行**即可：

```tcl
set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005
```

加上之后：

```
Info: Quartus II 64-Bit Analysis & Synthesis was successful. 0 errors, 16 warnings
```

> 教训：**先查工具开关，再下「工具不支持」的结论**。
> 这一行是本工程能否用 Quartus 综合的分水岭。

综合里另外几条值得注意的警告（都不影响功能，但说明代码有冗余）：

| 警告 | 位置 | 含义 |
| --- | --- | --- |
| `Warning (10335): Unrecognized synthesis attribute "max_fanout"` | `LSU.sv(84,85,105)` | `max_fanout` 是 Vivado 属性，Quartus 不认（要用 `set_instance_assignment -name MAX_FANOUT` 或在代码里换写法） |
| `Warning (10036): object "bp_redir_taken" assigned a value but never read` | `Control.sv(148)` | **死信号**：`bp_redir_taken` 算了但没人用（`dnpc` 用的是 `bp_redir_target`）。功能无误，但说明分支预测重定向那段代码有历史残留 |
| 同上：`mtval_reg` / `div_signed_r` / `store2_addr` / `store2_tag` | `CSR.sv(175)` `MDU_pipelined.sv(99)` `DCache.sv(193,197)` | 同类死信号 |
| `Warning (10230): truncated value with size 2 to match size of target (1)` | `DCache.sv(129)` | `~cpu_wen_r` 里 2 位截成 1 位，写法规避一下更干净 |
| `Warning (276020): Inferred RAM node ... Pass-through logic has been added` | `ICache`/`DCache` 的 tag/data 阵列 | 缓存阵列被推断成 RAM，但为了匹配「写后同拍可读」的老行为插了旁路逻辑 → **会额外消耗 LE，建议改成标准同步读写法**（先写后读的同一拍不该被读到） |

## 3. 因此发现并修掉的 2 个真实 RTL 缺陷

### 3.1 缺陷 B8：`board_top` 有 5 处层次化引用 → 综合直接失败

`board/board_top.sv` 里用了 5 个 **myCPU 根本不存在**的端口：

```systemverilog
assign irom_en  = u_cpu.icache_mem_en;        // ← myCPU 没有这个端口
assign debug_icache_hit_cnt  = u_cpu.icache_hit_cnt;   // ← 也没有
assign debug_icache_miss_cnt = u_cpu.icache_miss_cnt;  // ← 也没有
assign debug_dcache_hit_cnt  = u_cpu.dcache_hit_cnt;   // ← 也没有
assign debug_dcache_miss_cnt = u_cpu.dcache_miss_cnt;  // ← 也没有
```

这 5 个信号在 `myCPU.sv` 里都是**内部** `logic` 声明，不是端口。
`iverilog` / `ModelSim` 对层次化引用很宽容（这也是为什么
`board/tb_board_top.sv` 一直是 PASS 的），但真实综合工具会直接拒绝：

```
Error (10207): Verilog HDL error at board_top.sv(116):
               can't resolve reference to object "icache_mem_en"
Error (12153): Can't elaborate top-level user hierarchy
Error: Quartus II 64-Bit Analysis & Synthesis was unsuccessful. 2 errors, 7 warnings
```

**后果**：`board_top` 这条上板路径**综合都过不了**，fit / 时序 / 上板全部无从谈起。
这与 `myCPU.sv` 里 `perip_ren` 那次修复（注释里写的「层次化引用不可移植」）
是**完全同一类问题，只是当时只补了数据侧、漏了取指侧和 4 个计数器**。

**修法**（最小改动，不动任何控制逻辑）：

| 文件 | 改动 |
| --- | --- |
| `myCPU.sv` | 新增 5 个 output 端口：`irom_en`（= 原 `icache_mem_en`）与 4 个 `debug_*_hit/miss_cnt`，并各写一行 `assign` |
| `board/board_top.sv` | 例化时按名连接这 5 个端口，删掉 5 行层次化 `assign` |
| `quartus/build/syn_core_only.sv` | 测量外壳同步补上端口 |

验证：重新全量编译运行后

```
prog / prog_mul / prog_div / prog_load_lane / prog_load_use / prog_loop / prog_div_pair
  × {normal, strict}                        → 14/14 PASS（239 项检查）
board/tb_board_top（上板路径，含 sync_mem + reset_sync） → [BOARD-SELFCHECK] status=PASS (33/33)
```

> 一句话给设计者的建议：**永远不要让可综合的顶层去层次化引用子模块内部信号。**
> 仿真器宽容不等于工具链宽容。若确实需要观察内部信号，就在端口上引出来
> （本来也只需要 `output`，综合代价为零）。

### 3.2 缺陷 B9：`sync_mem` 的初始化循环越 Quartus 上限

```systemverilog
initial begin
    for (j = 0; j < WORDS; j = j + 1) mem_ram[j] = 32'h0000_0000;   // WORDS = 16384
    ...
```

Quartus 对 `initial`/`for` 的循环次数有**硬上限 5000**（而且不是 QSF 设置项）：

```
Error (10106): Verilog HDL Loop error at sync_mem.sv(94):
               loop must terminate within 5000 iterations
Error (12152): Can't elaborate user hierarchy "sync_mem:dram_inst"
```

IROM（4096 次）刚好踩在线上过，DRAM（16384 次）直接爆。

**修法**：把「被清零的字数」上限设成 4096（真实的 BRAM 上电内容是 undefined，
这段清零只是给 4 态仿真一个确定初值；仿真用的初值本来由测试台
`$readmemh` 与 DRAM 清零负责，所以**回归结果不变**）：

```systemverilog
localparam INIT_WORDS = (WORDS < 4096) ? WORDS : 4096;
...
for (j = 0; j < INIT_WORDS; j = j + 1) mem_ram[j] = 32'h0000_0000;
```

## 4. 资源与「能不能装进这块板」

### 4.1 实测：CPU 核心（`syn_core_only`，不含 IROM/DRAM）

Cyclone IV E `EP4CE6E22C8`，Quartus II 13.0.1 Analysis & Synthesis：

| 资源 | 用量 | EP4CE6 容量 | 占比 |
| --- | --- | --- | --- |
| Total logic elements | **18,815** | 6,272 | **300 %** |
| — combinational functions | 13,983 | — | — |
| — dedicated logic registers | **8,995** | 6,272 | **143 %** |
| Embedded Multiplier 9-bit elements | **24** | 30（15 个 18×18 块 ×2） | 80 % |
| Total memory bits | 6,400 | 276,480 | 2 % |

（这个数还不含 IROM/DRAM：那两块在 `board_top` 里。）

### 4.2 存储器账（`board/board_top.sv`）

Quartus 综合出来的实际数字（板级工程，`board_top` 为顶层）：

| 资源 | 用量 | EP4CE6 容量 | 占比 |
| --- | --- | --- | --- |
| **Total logic elements** | **19,175** | 6,272 | **306 %** |
| **Total registers** | **9,268** | 6,684 | **139 %** |
| **Total memory bits** | **530,688**（≈518 Kb） | 276,480 | **192 %** |
| **M9K 块** | **68** | 30 | **227 %** |
| **Total pins** | **201** | 92（可用 I/O） | **218 %** |

Fitter 的直接结论（同一份报告里的报错原文）：

```
Error (170048): Selected device has 66 RAM location(s) of type M9K.
                However, the current design needs more than 66 to successfully fit
Error (169282): There are 199 IO output pads in the design,
                but only 85 IO output pad locations available on the device.
Error (171000): Can't fit design in device
```

存储器的构成与占比（≈518 Kb 里的大头）：

| 块 | 大小 | 说明 |
| --- | --- | --- |
| DRAM `sync_mem` 16384 字 × 32b | **64 KB = 512 Kb** | 占了全部存储的 **99 %**，是压垮 M9K 的唯一大头 |
| IROM `sync_mem` 4096 字 × 32b | 16 KB = 128 Kb | 被推断成 RAM（不是 ROM），也要占 M9K |
| ICache 64 行 ×(32b data + 24b tag + 1b valid) | ~456 B ≈ 3.6 Kb | `Warning 276020` 推断成 RAM |
| DCache 64 行 × 同上 | ~456 B ≈ 3.6 Kb | 同上 |

> 注意：EP4CE30（66 个 M9K）也**装不下**，报的是同一句
> `needs more than 66 to successfully fit` —— 也就是说**只要 DRAM 还是 64 KB，
> 换到 CE30 都不够**。DRAM 尺寸是这里唯一的关键杠杆。

### 4.3 结论与可选方向

**结论**：`EP4CE6E22C8`（征途板）**装不下这颗 v9**，而且是四重超标：
逻辑 306 %、寄存器 139 %、存储 192 %、引脚 218 %。
即便把引脚喂给大封装、把芯片换到 EP4CE30，仍然卡在 DRAM 的 64 KB 上。

| 方案 | 具体做法 | 代价 |
| --- | --- | --- |
| **A. 缩存储器（性价比最高）** | DRAM 16384 字 → **1024 字（4 KB）**；IROM 4096 → 1024 字；ICache/DCache 64 行 → **16 行**；BPU 表 64 项 → 16 项。预计 M9K 从 68 降到 ~10、存储 bits 从 518 Kb 降到 ~40 Kb，**先让「存储」这一项达标** | 地址空间变小，教学程序要改链接地址 |
| **B. 再加缩逻辑** | 上面 A 做完还有 306 % 的逻辑超标：去掉 DCache（-1 套 tag/data + 控制）、BPU 表缩到 16 项、`Reg_Stack` 的 CSR 只留 mepc/mcause/mstatus/mtvec | 功能缩水，Cache/预测的示范价值下降 |
| **C. 换大芯片 + 减 DRAM** | `EP4CE22`(22,320 LE) 或 `EP4CE30`(28,848 LE) + DRAM 缩到 4~8 KB | 换板，但能保住全部功能 |
| **D. DRAM 外挂** | IROM/DRAM 走 SDRAM 或 SPI-Flash，FPGA 内只留 cache 与寄存器堆 | 要写存储控制器，工作量最大 |

一条经验线：**这颗 CPU 的逻辑规模（19 K LE）本身就决定了它不属于 EP4CE6/CE10 这一档**，
想原样上板至少要 CE22/CE30 级别的器件；CE6 上只能上「砍过的教学子集」。

### 4.4 减存储变体：fit 成功 + 第一个真实 Fmax 数字

为了确认「瓶颈只在存储器、不在流水线」，做了一个**不改任何 CPU 逻辑**的测量变体
（`quartus/build/board_top_small.sv`）：DRAM 16384 → 4096 字、IROM 4096 → 2048 字，
并把 4 个 32 位计数器压成 2 个 1 位「miss 发生过」标志（窄接口写法）。
在 `EP4CE30F23C6` 上：

| 资源 | 用量 | 容量 | 占比 |
| --- | --- | --- | --- |
| Total logic elements | **16,935** | 28,848 | 59 % |
| Total registers | 9,201 | 30,421 | 30 % |
| Total pins | **75** | 329 | 23 % |
| Total memory bits | 137,472 | 608,256 | 23 % |
| M9K | **20** | 66 | 30 % |

```
Info: Quartus II 64-Bit Fitter was successful. 0 errors, 13 warnings
```

**→ 结论成立**：逻辑与引脚都只剩六成占用，
原版 fit 失败完全是 64 KB DRAM 把 M9K 吃满（68/66）造成的。

### 4.5 时序（本机第一次拿到真实 ns 级数字）

约束 `syn/v9.sdc` 是 **10 ns = 100 MHz**。在同一颗拟合好的变体上跑 TimeQuest：

```
Critical Warning (332148): Timing requirements not met
Info (332146): Worst-case setup slack is -2.787      ← 100 MHz 下不收敛
Info (332146): Worst-case hold  slack is  0.283      ← 保持余量够
; Slow 1200mV 85C Model Fmax Summary
; Fmax     ; Restricted Fmax ; Clock Name
; 78.2 MHz ; 78.2 MHz        ; sys_clk
```

**关键路径**（85 °C 慢速模型，slack −2.787 ns，数据延迟 12.717 ns）：

```
From : myCPU:u_cpu|EXU:EXU_Inst0|alu_opcode_reg[0]
To   : myCPU:u_cpu|EXU:EXU_Inst0|jump_flag_reg / branch_flag_reg /
       pred_target_reg[..] / pred_index_reg[0]
```

也就是说最长的一跳是：

```
EXU.alu_opcode_reg
  → ALU（分支比较）
  → Control（branch_taken / bp_misp_det / bp_misp_pend / EXU_inst_clear /
             bp_hold_exu / dnpc_flag…）
  → EXU 的控制寄存器（jump/branch/pred_*）
```

**这与设计文档里的判断一致**：真正的瓶颈不在 MDU（那已经被流水化压下去了），
而在 **EXU ↔ Control 之间那一大坨组合控制逻辑**（分支判定 + 预测校验 +
挂起标志 + flush 生成），它被塞进了一个时钟周期里。

**频率建议**：

| 目标 | 余量 | 说明 |
| --- | --- | --- |
| **50 MHz（20 ns）** | 6.5 ns 正余量 | **上板先用这个**，几乎肯定能跑 |
| 78 MHz | 0 | 85 °C 慢速模型的实测上限 |
| 100 MHz | −2.787 ns | 当前 RTL 达不到，要改结构 |

想把 100 MHz 做出来，方向是**把 Control 里的 `bp_misp_det/bp_misp_pend/EXU_inst_clear`
这条长链打断**（例如把分支判定从 `Control` 挪回 `EXU` 内部、把 flush 生成再打一拍），
而不是继续动 MDU。这一条留给后续改造。

### 4.6 引脚 218 % 是设计问题，不是芯片问题

`Total pins = 201 / 92`。真正的原因是把 4 个 **32 位**计数器（`debug_icache_hit_cnt`
等）直接引成了顶层输出 —— 光它们就占了 128 个脚。
所以 §3.1 那个「把内部信号引到端口」的修复，从**综合正确性**看是必须的，
从**上板经济性**看是浪费的。合理做法二选一：

- **换窄接口**：一个 8 位观察总线 + 一个 3 位 `sel`，板上用数码管/逻辑分析仪轮询（推荐）；
  §4.4 的变体就是这么做的（2 个脚代替 128 个脚，75/329 = 23 %）；
- **只留 1 位指示**：每个计数器只引「是否发生过 miss」的 1 位锁存（4 个脚），
  波形要细节就在仿真里看。



## 5. 逐步复现命令

### 5.1 ModelSim 全量回归（推荐先跑这个）

```bat
cd /d "E:\share doc\v9"
sim\run_msim.bat
```

等价于：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\run_msim.ps1
```

细节与 5 个踩坑记录见 [`../sim/README_msim.md`](../sim/README_msim.md)。

### 5.2 单独跑 board_top（上板路径）

```bat
cd /d "E:\share doc\v9"
vlib work
vlog -sv -suppress 7061 -work work +incdir+. +incdir+experimental ^
     myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv RegisterFile.sv ^
     CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv LSU.sv DCache.sv WBU.sv ^
     Data_hazard.sv Control.sv add.sv sext.sv Reg.sv ^
     board/sync_mem.sv board/reset_sync.sv board/board_top.sv board/tb_board_top.sv
copy sim\prog.hex board\prog.hex
vsim -c -suppress 7061 -L work work.tb_board_top -do "run -all; quit -f"
```

期望输出：`[BOARD-SELFCHECK] status=PASS (33/33)`、`dram[0x1000] = 12 [PASS]`。

### 5.3 Quartus：核心资源（不需要存储器，跑得最快）

```bat
cd /d "E:\share doc\v9\quartus\build"
E:\FPGA\QuartusII_13.0\quartus\bin64\quartus_map.exe v9_core --read_settings_files=on
:: 结果：output_files_core\v9_core.map.rpt 的 Analysis & Synthesis Resource Usage
```

### 5.4 Quartus：整板 map + fit + 时序

```bat
cd /d "E:\share doc\v9\quartus\build"
copy ..\..\sim\prog.hex prog.hex
E:\FPGA\QuartusII_13.0\quartus\bin64\quartus_map.exe v9_board --read_settings_files=on
E:\FPGA\QuartusII_13.0\quartus\bin64\quartus_fit.exe v9_board --read_settings_files=on
E:\FPGA\QuartusII_13.0\quartus\bin64\quartus_sta.exe v9_board
```

> `quartus_sta` 需要 fit 先成功；在 EP4CE6 上 fit 会因为 §4 的资源原因失败，
> 所以本机拿不到真实 Fmax。要 Fmax 请按 §4.3 换芯片或砍功能后重跑。

### 5.5 两个工程文件里的关键设置

`quartus/build/v9_core.qsf` / `v9_board.qsf` 都包含：

```tcl
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE6E22C8
set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005   ;# ← 关键
set_global_assignment -name SDC_FILE "E:/share doc/v9/syn/v9.sdc"      ;# 10ns 主时钟
```

SDC 里主时钟是 `create_clock -name sys_clk -period 10.000 [get_ports {sys_clk}]`
（100 MHz）。上板建议先按 50 MHz（20 ns）跑通，再逐步收紧。
