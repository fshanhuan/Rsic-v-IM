# Rsic-v-IM —— v9：RV32IM 处理器 + FPGA 上板工程

> **工具链：Vivado 2025.2 / 目标板：依元素 EES-331 / 器件：`xc7z020clg484-1`**
>
> 本仓库 = v9 上板工作的完整工程。**核心 RTL 只有一份，在 `rtl/`**；
> 板级件在 `board/`、流水乘除的编译版是 `rtl/MDU_pipelined.sv`；
> Vivado 综合的和 `sim/run_iverilog.bat` 跑的是**同一份文件**，不会出现副本不同步。
>
> 2026-10 起，**本目录本身就是仓库根目录**。此前它只是 `E:\share doc\v9`
> 的工作副本，每次构建前会从"仓库正本"覆盖 RTL —— 那套两棵树同步机制已经退休，
> 详见 §4.1 末尾。

**当前状态：已上板跑通并抓过波形；板上 ILA 抓出并已修复一个真实功能 bug（v9 B9）。**

| 指标 | 实测值（**v9 B9 重建后**） |
| --- | --- |
| CPU 时钟 | **50MHz**（板载 100MHz 经 MMCM 分频） |
| WNS / WHS | **+4.890 ns / +0.021 ns**，建立时间失败端点 **0**（`All user specified timing constraints are met.`） |
| Fmax | **≈ 63 MHz** 以上（50MHz 余量约 26%，B9 后 WNS 从 4.162 升到 4.890） |
| DRC（后布线） | **0 Error、0 Critical Warning** |
| 资源 | LUT 13012 (24.5%)、FF 14776 (13.9%)、Block RAM Tile 38.5 (27.5%)、DSP48E1 12、**Bonded IOB 3**、BUFGCTRL 2 |
| 调试手段 | 片内 **ILA**（`ila` IP 6.2，**16 探针**、深度 2048），顶层只 3 个引脚 |
| iverilog 回归 | 7 程序全过（`prog` 36/36）+ `tb_dcache_unit` PASS |
| 板上结论 | 程序逐拍执行**完全正确**（`mul`=35、存/取往返=12、`beq` 不跳、`jal` 跳过 `0x2C`）；`ecall` 重定向**已修并在板上确认**：PC 每 ~43 拍绕回 `mtvec`，`mepc` 恒 `0x34`，`icache_miss_cnt` 冻结在 15 |

> ★ **v9 B9（2026-10-15）**：上板 ILA 抓到 `ecall` 之后 PC 从不回到 `mtvec(=0)`，
> 而是一路顺序爬行、每绕 IROM 一圈又执行一次 `ecall`（`mepc` 每次 `+0x4000`）。
> 根因是 `rtl/IFU.sv` 用 `dnpc_flag & ready` 门控真实重定向，而 `ecall`/`mret`/`fence.i`
> 的 `dnpc_flag` **只有一拍宽**，撞上 `ready=0` 就**永久丢失**。已改成 `else if (dnpc_flag)`。
> 完整定位过程（含逐拍证据、仿真复现、新增回归断言）：[`docs/vivado/ecall重定向故障_根因与修复.md`](docs/vivado/ecall重定向故障_根因与修复.md)。

---

## 1. 五分钟上手

> ⚠️ **Vivado 工程 `v9_ila/` 不在仓库里**（约 115 MB 的生成物，已在 `.gitignore` 里）。
> 仓库只带**生成它的脚本**，所以第一次使用要从第 ② 步开始，之后 ① 才有工程可开。

```powershell
$VIVADO = 'D:\vivado\2025.2\Vivado\bin\vivado.bat'
$REPO   = 'E:\FPGA\v9_vivado_ila'      # ← 换成你自己的克隆路径

# ② 一条命令重建整个工程（建工程 + ILA IP + 综合 + 实现 + bitstream），约 20~40 分钟
& $VIVADO -mode batch -notrace -source "$REPO/build_project_ila.tcl"

# ③ 自检：run 状态 / IP 配置 / 已实现设计能否打开 / 时序数字 / ILA 探针是否连着真信号
& $VIVADO -mode batch -notrace -source "$REPO/verify_project.tcl"

# ① 打开工程（GUI 里 Design Runs 都是真实的 100%）
start "$REPO/v9_ila/v9_ila.xpr"
```

> ⚠️ **脚本里目前写的是绝对路径**（`E:/FPGA/v9_vivado_ila`）。
> 换机器/换克隆目录时，要改 `build_project_ila.tcl`、`verify_project.tcl`、
> `dump_ila_*.tcl` 顶部的 `WORK` / `PROJ` / `DCP` 变量（见 §8）。

`build_project_ila.tcl` 顶部两个开关：

| 开关 | 值 | 作用 |
| --- | --- | --- |
| `DO_SYNTH` | `1` | 删掉工程重建 + 重跑综合（干净，默认） |
| | `0` | 保留已有工程和 `synth_1`，只重跑实现（省一次综合） |
| `DO_IMPL` | `0` | **只跑到综合**（约 5 分钟）——改 RTL 后先这样验证，别动辄等 30 分钟 |

> 改 RTL 后想确认"能不能综合过"，先把 `DO_IMPL` 设 0 跑一遍。

## 2. 烧板与抓波形

1. `Open Hardware Manager` → `Open Target` → `Auto Connect`
   （EES-331 用板载 USB3.0 下载器；找不到就按手册把 SW8 拨成板载下载器模式）；
2. `Program Device`，选
   `v9_ila.runs\impl_1\board_top_gui.bit`；
   探针文件是同目录的 **`board_top_gui.ltx`**，一般自动带上，没带上就手工选；
3. 出现 `hw_ila_1` → `Run trigger`。

常用触发姿势（等某条 PC、等 `trap_take`、核对 Cache 计数）见
[`docs/vivado/ila_使用说明.md`](docs/vivado/ila_使用说明.md) 第 4 节。

**烧完之后怎么判"正常"**（LED 心跳灯、每条指令的预期值、坏了怎么查）见
[`docs/vivado/上板验证判据.md`](docs/vivado/上板验证判据.md)。

### 不用点 GUI：脚本抓波形

上板结论是靠**独立 batch Vivado 会话**连 `hw_server` 自动抓 ILA 得到的：

| 脚本 | 作用 |
| --- | --- |
| `dump_ila_csv.tcl` | 抓一组通用触发，导 `ila_from_hw.csv` |
| `dump_ila_prog.tcl` | 抓"跑程序"那一组，导 `ila_prog.csv` |
| `dump_ila_b9.tcl` | B9 专项：抓 PC 重定向前后，导 `ila_b9_pc0.csv` / `ila_b9_redir.csv` |
| `analyze_ila_csv.py` / `analyze_ila_b9.py` | 把 CSV 逐拍解析成可读结论 |

> 这几个脚本产出的 `.csv` / `.analysis.txt` / `.log` **属于本地实测产物，不入库**
> （见 §3 末尾的"不在仓库里的东西"）。

## 3. 目录

```
<仓库根 = 本目录>\
├─ README.md                     ← 你在这里（**先读这个**）
├─ build_project_ila.tcl         ★★ 一条命令重建 Vivado 工程（工程模式）
├─ verify_project.tcl            ★  工程自检（run / IP / 网表 / 时序 / 探针连通性）
├─ dump_ila_csv.tcl              ★  连 hw_server 抓 ILA 并导 CSV（不需要点 GUI）
├─ dump_ila_prog.tcl             ★  同上，"跑程序"那一组
├─ dump_ila_b9.tcl               ★  同上，B9 专项（PC 重定向）
├─ analyze_ila_csv.py            ★  CSV 逐拍分析
├─ analyze_ila_b9.py             ★  B9 专项分析
├─ v9_board_ila.xdc              100MHz 主时钟 + 复位 + 3 个引脚（M19 / L18 / V4）
├─ prog.hex                      IROM 初值（= sim/prog.hex）
│
├─ rtl\                          ★★ 21 个 CPU RTL —— **全部在这里**
│   │  myCPU / IFU / IDU / EXU / LSU / WBU / ICache / DCache / Branch_Predictor /
│   │  CSR / Control / Data_hazard / ALU / Reg / Reg_Stack / RegisterFile /
│   │  add / sext / para.sv
│   ├─ MDU_pipelined.sv          时序化乘除（EXU 里 MDU_i0 就是它）★ 在编译的那一份
│   └─ MDU.sv                    旧的组合版，**不参与构建**，只作对照
│
├─ board\                        板级件：board_top.sv / board_top_ila.sv /
│                                sync_mem.sv / reset_sync.sv + 测试台
│                                ★ 含 Xilinx 原语，**不能**并进 rtl\（Verilator 会编不过）
├─ experimental\                 MDU_pipelined.sv 的历史副本（只留档，不参与编译）+ MDU_tb.sv
├─ sim\                          iverilog 回归（7 程序 + 测试台 + 运行脚本）
├─ syn\                          约束与实测报告：v9.xdc / v9.sdc / timing_sweep.tcl /
│                                修复史_全量.md / 上板改造说明.md
├─ figures\                      架构图与上板后时序图（SVG/PNG，被产品说明文档引用）
├─ msim\                         ModelSim 第二仿真器验证日志
├─ teach\                        教学波形包（独立副本，**有意**与主线脱钩）
├─ wave\                         仿真 VCD（模块阅读文档里引用的可视证据）
├─ reports\                      访存子系统与 MDU 分析
├─ docs\                         ★ 全部文档
│   ├─ 模块阅读文档.md              **权威主文档**：逐模块 I/O、关键信号、改造清单
│   ├─ README.md                   文档索引与阅读顺序
│   ├─ 产品说明_v9_客户版.md        产品说明（含待办清单）
│   ├─ vivado\                    ★ Vivado / ILA 专属文档（见第 4 节）
│   └─ ...
└─ tools\                        工具：acceptance_report.py / check_*.py / wsl\（官方差分）
```

### 不在仓库里的东西

以下都是**本机生成物或一次性实验脚手架**，已在 `.gitignore` 里，**不要提交**：

| 路径 | 是什么 | 怎么得到 |
| --- | --- | --- |
| `v9_ila/` | Vivado 工程与全部 run 产物（约 115 MB）：`.xpr` / `.runs/` / `.srcs/` / `.cache/` | 跑 `build_project_ila.tcl` |
| `project_src/` | 工程临时目录（`board_top_gui.sv` / `prog.hex` / `*.rpt` 报告） | 同上，脚本自动生成 |
| `sim/build/` | iverilog 中间产物（`.vvp`） | 跑 `sim/run_iverilog.*` |
| `*.log` / `*.jou` / `*.backup.*` | Vivado 会话日志与备份 | 每次跑 Vivado |
| `ila_*.csv` / `*.analysis.txt` / `*.check.txt` | 板上 ILA 抓取结果与逐拍分析 | 跑 `dump_ila_*.tcl` + `analyze_ila_*.py` |
| `_deprecated/` | 早期的非工程模式 / 内存插桩方案脚本，**跑不通**，仅作历史记录 | 本地保留 |
| `_diag/` `_fw/` `_comment_iter/` `_ila_crops/` | 一次性实验台与注释迭代中间文件 | 本地保留 |

> ⚠️ 因此 `docs/` 里有一部分分析文档会引用到 `project_src/*.rpt`、`_diag/*.sv`、
> `_fw/*.md` 这类**只存在于作者本机**的路径 —— 那是当时的原始证据出处，
> 保留原样以便追溯；它们不在仓库里。

## 4. 文档索引

按"先结论、再模块、最后细节"排序：

| 文档 | 讲什么 |
| --- | --- |
| [`docs/待修复清单_cdp-tests第三轮.md`](docs/待修复清单_cdp-tests第三轮.md) | ★ **官方差分（`cdp-tests`）发现并已修复的 H1/H2/H3**：现象、根因、分步实测（0/39 → 32/39 → 39/39）、以及"47 条"这个数字为什么对不上 |
| [`tools/wsl/README.md`](tools/wsl/README.md) | **在 WSL 里跑官方差分**：无 sudo 装 Verilator 5.020、克隆上游套件、一键跑 39 条；含脚本清单与两个必踩的坑 |
| [`syn/修复史_全量.md`](syn/修复史_全量.md) | ★ **注释迭代的归档**（220 KB / 138 个主题）：RTL 里被压缩掉的故障战史、实测现象、方案沿革**逐字原文**。RTL 注释里的 `见 syn/修复史_全量.md §XXX-n` 就指向这里 |
| [`docs/vivado/ecall重定向故障_根因与修复.md`](docs/vivado/ecall重定向故障_根因与修复.md) | ★ **v9 B9**：板上 ILA 抓出的 `ecall` 重定向失败 —— 逐拍证据、仿真复现、根因（`dnpc_flag & ready`）、修复与新增回归断言。**想知道"为什么 35/35 全过还有 bug"就读这篇** |
| [`docs/vivado/ila_使用说明.md`](docs/vivado/ila_使用说明.md) | **Vivado 实测主报告**：EES-331 引脚表、**16 根 ILA 探针**、Hardware Manager 触发姿势、时序/资源、11 条实测踩坑 |
| [`docs/vivado/上板验证判据.md`](docs/vivado/上板验证判据.md) | ★ **上板时怎么判定"正常工作"**：LED 心跳灯判读、`prog.hex` 14 条指令的预期写回值表、**五个**单点决定性检查、症状 → 根因速查、§7.1 `ecall` 重定向判据 |
| [`docs/vivado/工程打开是黑的_排查与正确用法.md`](docs/vivado/工程打开是黑的_排查与正确用法.md) | 工程模式 vs 非工程模式：为什么 GUI 里 Design Runs 是灰的 |
| [`docs/vivado/vivado_50mhz_实测.md`](docs/vivado/vivado_50mhz_实测.md) | 早期「调试信号引到引脚」方案（顶层 `board_top_vivado`）的实测记录，对照用 |
| [`syn/上板改造说明.md`](syn/上板改造说明.md) | 上板障碍清单 P0~P5、改造前后对照、6 个 RTL 缺陷的根因 |
| [`docs/模块阅读文档.md`](docs/模块阅读文档.md) | **权威主文档**：逐模块 I/O、关键信号作用、上板改造三个必知机制、指令走查 |
| [`docs/vivado/README.md`](docs/vivado/README.md) | 本目录（Vivado / ILA 文档）的索引与工程入口说明 |
| [`docs/vivado/交付说明.md`](docs/vivado/交付说明.md) | 上板改造的交付清单与「本机没能做的部分」 |
| [`docs/vivado/改动diff_接管前快照_vs_上板改造后.txt`](docs/vivado/改动diff_接管前快照_vs_上板改造后.txt) | 全部 RTL 改动的逐行对照 |
| [`docs/产品说明_v9_客户版.md`](docs/产品说明_v9_客户版.md) | 面向使用者的产品说明（含 §7 P0 待办清单） |
| [`reports/mem_mdu_analysis.md`](reports/mem_mdu_analysis.md) | 访存子系统与 MDU 的专项分析 |

> 文档有冲突时，以 [`docs/模块阅读文档.md`](docs/模块阅读文档.md) 为准。

## 4.1 注释规范与迭代工具（2026-10 注释迭代）

**权威风格定义**：[`tools/COMMENT_STYLE.md`](tools/COMMENT_STYLE.md)（含每个文件的注释行数预算表 §7.1）。

**三类注释，处理方式不同**：

| 类 | 内容 | 处理 |
| --- | --- | --- |
| **A 接口契约 / 设计不变量** | "同步 BRAM 是请求/响应两拍交替"、"PC 只在结果属于当前 PC 时才推进"、"重定向不看 `inst_valid` 也不看 `ready`" | **保留并显式化**为 `★ 不变量：` + `原因：`（1~3 行机制）+ 锚点。**优先级高于预算**，压不下就超预算 |
| **B 故障战史** | "v9 修复（B4）：原来…实测 x1 涨到 2491…" | **压缩**成 2~5 行结论，**原文逐字搬进** `syn/修复史_全量.md` |
| **C 缺失 / 不好读** | 位选掩码、优先级、握手时序、魔数 | **补充**，判据只有一条：**"不看注释就会写错"** |

**铁律**：注释迭代**只许改注释**，不许动任何代码 token；不许删知识、只许搬。

**工具**（都在 `tools/`，每个都自证过）：

| 工具 | 作用 |
| --- | --- |
| `strip_sv_comments.py` + `selftest_strip.py` | SystemVerilog 注释剥离器（正确处理字符串里的 `//`）+ **11 个用例**证明它能识别代码/字符串改动 |
| `check_all.py --stats` | 25 个文件批量做"剥离注释后代码等价"判定 + 注释行数统计 |
| `check_extract_coverage.py` | 核对"删掉的注释有没有搬进归档"（4-gram 覆盖率，阈值**实测标定**：中度改写 46%、重度改写 20% → 取 35%） |
| `check_encoding.py` + `selftest_encoding.py` | 检测**中文注释变乱码**（本仓库栽过两次；乱码只影响注释，剥离器看不见） |
| `check_anchors.py` | 交叉引用完整性：`§锚点` 能不能落地 + 注释里的**文件路径**存不存在 |
| `assemble_fix_history.py` | 把 `_comment_iter/extract/*.md` 汇编成 [`syn/修复史_全量.md`](syn/修复史_全量.md)（两树同时写、核对字节一致） |
| `check_ila_board.py` | 板上 ILA 抓取结果的自检器（`ila_*.check.txt` 由它生成） |
| `regress_canonical.py` | 在隔离目录跑 iverilog 7/7（带前置闸门：有文件不是 `CODE-IDENTICAL` 就拒绝跑） |
| `acceptance_report.py` | **一条命令出验收总表**：代码等价 / 注释预算 / 知识覆盖率 / 编码 / 锚点 |

```powershell
# 注释迭代的验收（一次跑全）
python tools\acceptance_report.py
```

> ⚠️ **不要用 PowerShell 的 `Get-Content` / `Set-Content` 读写这些文件**：PS 5.1 默认按 ANSI(936)
> 读，中文注释会变乱码、换行还可能被吃掉，结果是**真代码被吸进 `//` 注释里**（本次迭代真实踩到过：
> `Data_hazard Data_hazard_inst (` 被粘到上一行注释末尾 → `invalid module item`）。
> 用编辑器/agent 的文件工具，或 Python 显式 UTF-8。

**本次迭代结果**（2026-10-15 定稿）：注释行数 **1654 → 1312（−20.7%）**；
`★ 不变量 / 接口契约` 标记 **0 → 129**（把原来"藏在长段落里"的约束显式化成可检索的条目）；
25 个文件的故障战史全部归档到 [`syn/修复史_全量.md`](syn/修复史_全量.md)（**228 KB / 144 个主题**，
原文逐字保留，知识覆盖率 **100%**）；
**25/25 文件 `CODE-IDENTICAL`**（"剥离全部注释 + 归一化空白后逐字符相同" —— 机械证明只改了注释）；
iverilog **7/7 回归全过**；编译诊断（`sorry`/`error` 计数）改动前后**逐项一致**。

**迭代的副产品**：过程中发现 3 处"注释与代码不符 / 代码有坏味道"（均按"只标注、不动代码"处理）：
`rtl/LSU.sv` 的 addr 拼接清的是 bit[17:16]（扩地址空间时是别名隐患）、
`rtl/IDU.sv` 的 `imm` 第 6 档是死分支（本意 `R_opcode` 写成 `S_opcode`，无行为影响）、
`rtl/EXU.sv` 一条优先级顺序写反的过期注释（已按 Control 的实际实现改正）。

> **⚠️ 2026-10 之后：`check_all.py` 会报 3 个文件 `CODE-CHANGED`，这是预期的，不代表写坏了。**
> H1/H2/H3 三项真实缺陷修复**有意**改动了 `rtl/EXU.sv`（新增 `up_stall`）、`rtl/myCPU.sv`（接线）、
> `rtl/DCache.sv`（读窗口整字 mask）—— 见 §4.2。其余 **22 个文件仍是 `CODE-IDENTICAL`**。
> 跑整机回归请用 `python tools/regress_canonical.py --skip-gate` ——
> `--skip-gate` 就是为"RTL 被有意修改"这种情况加的（它会在开始前明确打印这一点）。

> **📌 两棵树同步机制已退休**：上面 `sync_trees.py` / `check_all.py` 里"仓库正本 ↔ 工作目录"
> 的双树比对，源于 2026-10 之前 `E:\share doc\v9`（正本）与 `E:\FPGA\v9_vivado_ila`（工作副本）
> 并存的那段时期。现在**本仓库就是唯一一份源码**，双树比对退化成"自己跟自己比"（恒等）。
> `sync_trees.py` 保留仅作历史参考；`build_project_ila.tcl` 里从外部正本覆盖
> `rtl/` 与 `board/` 的那段同步代码也已**加上存在性判断**（外部正本不存在时自动跳过），
> 仓库可独立使用。

## 4.2 官方差分（`cdp-tests`）修复：H1 / H2 / H3

**背景**：v9 此前**从没跑过**上游 [`BigBird-CPU-Lab`](https://github.com/hongpengWu/BigBird-CPU-Lab)
的官方差分套件 `cdp-tests`；`syn/修复进度_C系列.md` 里的「103/103」「239/239」都是 v9 **自带**
`sim/` 测试台的数字。本轮把官方套件真正跑起来，三个缺陷全部修掉并验证通过。

| 编号 | 缺陷 | 后果 | 改动 | 归档 |
| --- | --- | --- | --- | --- |
| **H3** | `experimental/MDU_pipelined.sv` 不在工程顶层 | 官方 Makefile 用 `$(wildcard $(CPU_DIR)/*.sv)` 只通配顶层 → **功能全对也编译不过** | 顶层新增一份**逐字相同**的副本（文件头有同步警示） | §MDU-4 |
| **H1** | 前端 hold 时 EXU 重复接收同一条指令（EXU 的 `ready_last` 不含 `IFU_stall`，而 IDU 的 ready 含） | **算错结果**：官方差分第一条 `addi` 就 desync；`jal` 用例里一条 `addi` 被执行两次 | `rtl/EXU.sv` 新增 `up_stall` 端口并并进**四处**接收门控；`rtl/myCPU.sv` 接 `.up_stall(IFU_stall)` | §EXU-11 |
| **H2** | 读窗口按字节 mask 上报，被课程 SoC「二次抽取」 | `lb/lbu/lh/lhu/lw/sb/sh` 7 条读成 0（应为 `0xfffffff0` 之类） | `rtl/DCache.sv` 读窗口改 `2'b10`（整字），写口仍用真实 mask | §DCACHE-6 |

**分步实测**（WSL2 + Verilator 5.020 + 官方 `cdp-tests`，当前套件 39 条）：

| 配置 | 结果 |
| --- | --- |
| 修复前 | **0 / 39** |
| 只修 H3 + H1 | **32 / 39** —— 失败集恰好 `lb lbu lh lhu lw sb sh`（= H2 的预测） |
| H3 + H1 + H2（最终） | **39 / 39 PASS** ✅ |

同批其它验证：

| 验证 | 结果 |
| --- | --- |
| iverilog 整机回归（7 程序） | **7 / 7 PASS** |
| `sim/tb_dcache_unit.sv`（DCache 模块级） | **PASS** —— H2 改的正是 DCache 的 mask，必测 |
| Vivado 2025.2 全流程重建（synth + impl + bitstream） | **0 errors / 0 critical warnings**；`WNS = 3.445 ns`、`WHS = 0.032 ns`、失败建立路径 **0** ⇒ 50 MHz（周期 20 ns）下时序闭合；bitstream `4045689` 字节 |
| 两棵树一致性（当时） | 25/25 文件一致；`EXU` / `DCache` / `myCPU` / `MDU_pipelined`（两份）逐字一致 |

> **时序对照**：改动前 `WNS = 4.890 ns` → 之后 `WNS = 3.445 ns`（**−1.445 ns**）。
> 这是 H1 把 `up_stall` 引入"接收"组合路径的预期代价，但仍**远大于 0**
> （50 MHz 周期 20 ns，留给布局布线的余量充足）。`WHS` 基本不变（0.021 → 0.032 ns）。
> 之后 v9 B9 的 `IFU` 修复又把 WNS 拉回 **+4.890 ns**（见开头指标表）。

**对已上板硬件的影响**：H1/H2 都改了 RTL，**必须重新综合烧板**。
其中 H2 对板级**无功能影响** —— `board/sync_mem.sv` 的读口是 `if (ren) rdata <= mem_ram[word_addr];`，
**完全不看 mask**（已逐行核对）；H2 只是为了兼容课程 SoC 与官方差分。

**怎么在本机复现这套验证**（不需要 sudo、不需要预装 verilator）：

```bash
# 1) 取 verilator 5.020 的 .deb 并解包到 ~/opt（无需 root）
wsl -d Ubuntu -e bash /mnt/e/FPGA/v9_vivado_ila/tools/wsl/get_verilator.sh
wsl -d Ubuntu -e bash /mnt/e/FPGA/v9_vivado_ila/tools/wsl/fix_vroot.sh   # 补 verilator_bin 软链
# 2) 克隆上游官方套件（浅克隆）
wsl -d Ubuntu -e bash /mnt/e/FPGA/v9_vivado_ila/tools/wsl/get_suite.sh
# 3) RTL → 无空格路径 → 建工程并跑全部用例
wsl -d Ubuntu -e bash /mnt/e/FPGA/v9_vivado_ila/tools/wsl/run_canonical.sh mylabel
```

> 为什么要拷到 `~/work`：`share doc` 含空格，Verilator 的 `obj_dir` 在含空格路径下建不起来。

## 5. 硬件事实（EES-331，取自用户手册的"FPGA IO 约束"列）

| 项 | 值 | 出处 |
| --- | --- | --- |
| 器件 | `xc7z020clg484-1` | 手册 §3 |
| **PL 时钟 `FPGA_CLK0`** | **100MHz，引脚 M19** | 手册 §5 |
| PL 按键 S1 / `FPGA_RESET` | **引脚 L18**，4.7K 上拉、**按下为低** | 手册 §21 |
| PL LED0~7 | V4 U6 U5 V7 W7 W6 W5 U7 | 手册 §20 |
| PL 拨码 SW0~7 | AB6 Y4 AA4 R6 T6 T4 U4 V5 | 手册 §19 |
| PL Bank 电压 | 全部 3.3V → `LVCMOS33` | 手册 §2 |

> 厂商手册 PDF **不随仓库分发**（未指定许可证），引脚信息已整理进
> [`docs/vivado/ila_使用说明.md`](docs/vivado/ila_使用说明.md) 与 `v9_board_ila.xdc`。

**两条硬约束：**

1. **板子给 100MHz，但本设计 Fmax ≈ 63MHz，100MHz 跑不了。**
   所以必须用 `MMCME2_BASE` 分频：VCO = 100MHz × 10 = 1000MHz，
   CLKOUT0 = 1000 / 20 = **50MHz**。以后要提频只改
   `CLKFBOUT_MULT_F` / `CLKOUT0_DIVIDE_F`，不用换晶振。
2. **`S5` 不是引脚号，是原理图位号。** 手册里按键画的是 `S1`。
   写错只会给一条 `CRITICAL WARNING: [Common 17-69] ... 'S5' is not a valid site
   or package pin name`，**不中止流程** —— 不看日志就会带着坏约束一路跑到实现。

## 6. 四个已经踩过的坑（别再踩）

1. **`MMCME2_BASE` 的 `CLKFBIN` 必须接回 `CLKFBOUT`。**
   漏接只给一条很容易忽略的
   `WARNING: [Synth 8-7071] port 'CLKFBIN' of module 'MMCME2_BASE' is unconnected`，
   但内部反馈环断开 → `LOCKED` 恒 0 → `rst_n = btn_rst_n & mmcm_locked` 恒低 →
   **CPU 永远停在复位态**，上板表现为"什么动静都没有"。

2. **工程模式与非工程模式不能混用。**
   用 `create_project` 建了工程，却用 `synth_design` / `place_design` /
   `route_design` 在**内存里**跑完流程 → 磁盘上不会有 `.runs` / `.srcs`，
   GUI 里 Design Runs 全灰、点不动。
   只要用了 `create_project`，后面就必须用 `launch_runs` + `wait_on_run`；
   ILA 也要做成**标准 IP 例化**，而不是 `create_debug_core` 内存插桩。
   详见 [`docs/vivado/工程打开是黑的_排查与正确用法.md`](docs/vivado/工程打开是黑的_排查与正确用法.md)。

3. **不要用 `ready`（或 `inst_valid`）去门控"真实重定向"。**
   `ready` 的意思是"下游这一拍能不能**接收**一条新指令"，而重定向的语义是
   **命令下游丢弃**当前这条取指（`dnpc_flag` 同时就是 IDU 的 `flush`）。
   更麻烦的是 `ecall`/`mret`/`fence.i` 的 `dnpc_flag` **只有一拍宽**
   （IDU 在 `flush` 那一拍就把译码级灌成 NOP），所以这一拍被吃掉就**永久丢失** ——
   而 `Control` 里只有分支误预测建了"挂起重发"机制。
   实测后果：`ecall` 之后 PC 一路顺序爬行，板上看是"程序在跑、数据也对，就是控制流错了"。
   详见 [`docs/vivado/ecall重定向故障_根因与修复.md`](docs/vivado/ecall重定向故障_根因与修复.md)。

4. **仿真全过 ≠ 功能正确。** `ecall` 重定向这个 bug 活到上板，就是因为原来的测试台
   在 `ecall` 译码后再等 8 拍就 `$finish`，**从来没有人看过 `ecall` 之后的 PC**。
   现在 `tb_iverilog` 有 `ecall-redirect (pc -> mtvec)` 断言专门守这一条。
   教训：**判据必须覆盖"控制流去了哪"，不能只覆盖"数据算得对不对"。**

## 7. 待办（按优先级）

| # | 事项 | 说明 |
| --- | --- | --- |
| 1 | ~~上板跑程序~~ | ✅ **已完成**（2026-10-15）。用独立 batch Vivado 会话连 `hw_server` 抓 ILA、导 CSV 逐拍核对，**不需要点 GUI**。脚本：`dump_ila_csv.tcl` / `dump_ila_prog.tcl`，分析：`analyze_ila_csv.py` |
| 2 | ~~修 `CSR.mtval`（一行）~~ | ✅ **已完成（v9 B9）**：`rtl/CSR.sv` 补了 `assign mtval_out = mtval_reg;` |
| 3 | ~~修 `ecall` 重定向~~ | ✅ **已完成（v9 B9）**：`rtl/IFU.sv` 去掉重定向分支的 `& ready`；同批还修了 `fault_inst_in` 接在未声明信号上的问题 |
| 4 | ~~官方差分 H3 / H1 / H2~~ | ✅ **已完成并验证 39/39**（见 §4.2）：`rtl/EXU.sv` 新增 `up_stall` 接收门控、`rtl/DCache.sv` 读窗口整字 mask、工程顶层补 `rtl/MDU_pipelined.sv`。上游套件已克隆到 WSL `~/BigBird-CPU-Lab`，一行命令可复跑 |
| 4b | **异常体系（D1 / C4）—— 现在优先级最高** | **先纠正一个说法**：不是"同步异常检测不工作"，而是 `Control` 的 `TRAP_ENABLE` **默认 0、且 `rtl/myCPU.sv` 例化时没把它引出来** ⇒ 每个 build 都是关的。在临时副本里强行打开后实测：`trap events = 5/4/4`（陷阱**确实触发**）但 **`mcause`/`mepc`/`mtval` 恒为 0**、程序恢复反而失败、基线回归掉到 6/7（`prog_loop` 复现 B4 症状）。⇒ 文档 D1 那句"判定与 CSR 登记已验证正确（实测 `mcause=2`、`mepc=0x20`）"**复现不出来**。修法见 [`docs/产品说明_v9_客户版.md`](docs/产品说明_v9_客户版.md) §7 P0-1（登记挪到 WB 级、复用已调通的 `ecall` 通道） |
| 5 | **板上确认 B9 修复** | 重新烧录 + 抓 `probe15 == 0`（或 `probe1 == 0`）确认 `ecall` 后 PC 真的回到 `mtvec`。判据见 [`docs/vivado/上板验证判据.md`](docs/vivado/上板验证判据.md) §7.1 |
| 6 | **时序收敛 / 提频** | 当前 Fmax ≈ 63MHz，100MHz 收敛不了（存在 >10ns 组合通路，瓶颈在布线） |
| 7 | **上板外设** | LED / 4 位数码管 / UART 的引脚译码还没写（引脚表见 `docs/vivado/ila_使用说明.md` 第 1 节） |
| 8 | 板级件替换 | `board/sync_mem.sv` 是行为模型，上板建议换成 `xpm_memory_*`（注：Vivado 已经把 `$readmemh` 初值推断成 BRAM 了） |
| 9 | ~~提交并推送仓库~~ | ✅ **已完成**：本目录已成为仓库根目录，内容整体推送到 `main` |

## 8. 注意

- **核心 RTL 只有一份，在 `rtl/`**；板级件在 `board/`；
  流水乘除的编译版是 `rtl/MDU_pipelined.sv`，`experimental/` 那份只留档、不参与编译。
- ★ **`board/` 不能并进 `rtl/`**：`board_top*.sv` 例化了 Xilinx 原语
  （`MMCME2_BASE` / `IBUF` / `BUFG`），而官方 `cdp-tests` 用 Verilator 编译 `rtl/*.sv`
  —— 混在一起会直接编译不过。
- ★ **iverilog 必须带 `-I rtl`**：它只在**当前目录**与 `-I` 目录里找 `` `include ``，
  **不会**去源文件自己所在的目录找，而 `para.sv` 在 `rtl/` 下。
  `sim/` 下的 `run_iverilog.bat|sh`、`run_all.sh` 都已带上；自己手敲命令时别忘。
- ⚠️ **脚本里是绝对路径**：`build_project_ila.tcl` 顶部的 `WORK` / `PROJ`，
  `verify_project.tcl` 的 `PROJ`，`dump_ila_*.tcl` 的 `BIT` / `LTX` / `CSV`，
  默认都写死成 `E:/FPGA/v9_vivado_ila/...`。**换机器必须先改这几处**，
  否则 Vivado 会报"找不到文件"或把产物写到别的盘。
- `build_project_ila.tcl` 里有一段"从外部仓库正本 `E:\share doc\v9` 覆盖 `rtl/` 与 `board/`"
  的历史代码，**已加存在性判断**：外部正本不存在时自动跳过，仓库可独立使用。
- `_deprecated/`、`_diag/`、`_fw/`、`_comment_iter/`、`project_src/`、`v9_ila/` 都**不在仓库里**
  （见 §3"不在仓库里的东西"）。`_deprecated/` 里的脚本依赖已删除的目录，
  **现在跑不通**，只作为"当初为什么走错路"的记录保留。请一律用 `build_project_ila.tcl`。
- `v9_ila/`（约 115MB）和 `sim/build/` 都是生成物，不要提交、不要手工改；
  工程可以从 `build_project_ila.tcl` 完整重建。
- 改完 RTL 想快速探路：把 `build_project_ila.tcl` 顶部的 `DO_IMPL` 设 0 只跑到综合
  （省掉实现那十几分钟），确认综合是 **0 error / 0 critical warning** 再设回 1 跑完整流程。

## 9. 许可

本仓库**尚未指定开源许可证**（`LICENSE` 文件缺失）。在添加许可证之前，
默认版权归作者所有，他人**没有**复制、修改、再发布的法定许可
（虽然 GitHub 上仍可 Fork/开 PR，但那只是平台功能，不构成授权）。

如果打算长期多人协作，建议尽快补一个，例如：

- `MIT` —— 最宽松，最省事；
- `Apache-2.0` —— 宽松 + 显式专利授权，适合可能有商业使用的场景；
- `CERN-OHL-S-2.0` / `Solderpad-2.0` —— 硬件专用；
- 若是**课程作业/竞赛作品**，请先确认学校或赛事的作品归属规定再选。
