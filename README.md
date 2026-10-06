# Rsic-v-IM

[![CI](https://github.com/fshanhuan/Rsic-v-IM/actions/workflows/ci.yml/badge.svg)](https://github.com/fshanhuan/Rsic-v-IM/actions/workflows/ci.yml)

用 SystemVerilog 写的一颗 **RV32IM** 处理器教学核，带 **I/D-Cache**、**机器模式中断/异常**
与 **gshare 分支预测**，并已完成一轮**面向 FPGA 上板的可综合化改造**（同步存储握手、
时序化 MDU、复位同步释放、板级顶层）。

- 当前版本：**v9**（源码在 [`v9/`](./v9)）。上板改造后又做了**一轮独立验证 + 缺陷修复**
  （见 [验证报告_独立复核.md](./验证报告_独立复核.md)）：官方回归从 7 项扩到 **15 项**，
  单轮 **239/239 项检查全过**（严格模式同样全过），板级顶层自检 **33/33 PASS**。
- 精度定位：**能跑、能综合、波形可读、文档齐全**的教学核；不是工业级 IP，
  真实时序收敛与板级实测尚未完成（见 [已知限制](#已知限制--roadmap)）。

---

## 快速开始（3 分钟）

```bash
git clone https://github.com/fshanhuan/Rsic-v-IM.git
cd Rsic-v-IM/v9

# Linux / macOS / WSL —— 全量回归：6 项整机 + 1 项 D-Cache 单元测试
sudo apt-get install -y iverilog        # 只需 iverilog，不需要 verilator/make
bash sim/run_all.sh
```

```bat
:: Windows —— 一条命令 = 编译 + 仿真 + 出波形（路径在 sim\run_iverilog.bat 顶部可改）
cd Rsic-v-IM\v9
sim\run_iverilog.bat                :: prog      35/35 PASS
sim\run_iverilog.bat prog_mul       :: prog_mul  34/34 PASS
sim\run_iverilog.bat prog_div       :: prog_div  34/34 PASS
:: v9 第二轮修复补的回归（专测字节/半字偏移、load 取数、后向分支、背靠背除法）
sim\run_iverilog.bat prog_load_lane :: prog_load_lane 34/34 PASS
sim\run_iverilog.bat prog_load_use  :: prog_load_use  34/34 PASS
sim\run_iverilog.bat prog_loop      :: prog_loop      34/34 PASS
sim\run_iverilog.bat prog_div_pair  :: prog_div_pair  34/34 PASS
sim\run_iverilog.bat prog wave      :: 跑完直接开 GTKWave
```

期望输出（最后一行）：

```
[SELFCHECK] PASS: prog  35/35 checks
```

跑完想看图，把 VCD 渲染成时序图（自包含脚本，只用 python3）：

```bash
cd v9
python sim/vcd2svg.py wave/tb_iverilog_prog.vcd figures/v9_postboard_prog.svg
```

现成的三张图在 [`v9/figures/`](./v9/figures)（前递、load-use 暂停、分支/跳转、`ecall`、
连续 `mul`、连续 `div`）。

---

## 目录

```
Rsic-v-IM/
├── README.md                     ← 你在这里
├── CONTRIBUTING.md               ← 协作约定（分支、提交、PR、评审）
├── .github/workflows/ci.yml      ← push/PR 自动跑 iverilog 回归 + 编译门禁
└── v9/                           ← v9：RV32IM + Cache + 中断 + 分支预测（已做上板改造）
    ├── README.md                 ← ★ 工程总览 / 验证命令 / 波形（**先读这个**）
    ├── myCPU.sv                  ← 顶层（5 级流水，物理 8 级）
    ├── IFU / IDU / EXU / LSU / WBU.sv      ← 取指 / 译码 / 执行 / 访存 / 写回
    ├── ICache / DCache.sv                  ← 直接映射 I-Cache、写直达 D-Cache（同步握手）
    ├── Branch_Predictor.sv                 ← gshare + BTB
    ├── CSR.sv / MDU.sv                     ← 机器模式 CSR / 原版组合 MDU（保留对照）
    ├── Control.sv / Data_hazard.sv         ← 控制与冒险处理（前递 / 暂停 / 冲刷 / 重定向）
    ├── ALU / Reg / Reg_Stack / RegisterFile / add / sext / para.sv
    ├── board/       ← 上板件：sync_mem（一拍读延迟 BRAM 模型）/ reset_sync / board_top + 测试台
    ├── experimental/← MDU_pipelined.sv（**上板用**乘除单元，已接入 EXU）+ 独立测试台
    ├── sim/         ← 自包含 iverilog 回归测试台 + 三个程序 + 运行脚本 + 波形工具
    ├── syn/         ← 综合/时序：synth_core.ys、v9.xdc、v9.sdc、timing_sweep.tcl、报告
    ├── docs/        ← ★ 模块阅读文档（逐模块 I/O、关键信号、改造清单）
    ├── figures/     ← 上板改造后重新生成的时序图（SVG）
    └── wave/        ← 上板改造后的 VCD（文档里引用的可视证据）
```

---

## 能力与状态

| 能力 | 实现 | 状态 |
| --- | --- | --- |
| RV32I 基础整数指令 | 5 级流水（物理 8 级：ID 拆 2 拍、MEM 拆 3 拍） | ✅ 回归通过 |
| RV32M 乘除法（8 条） | `experimental/MDU_pipelined.sv`：乘法 1 拍、除法 32 拍迭代 | ✅ 模块级向量 + 整机回归（含**背靠背 div/rem**、除零与 `INT_MIN/-1` 边界） |
| I-Cache / D-Cache | 直接映射；同步存储握手（请求/响应两拍 + `hold` 停拍重试） | ✅ 整机 + D-Cache 单元测试 |
| 中断 / 异常 | 机器模式 CSR（`mie/mip/mtime/mtimecmp/...`）、MSIP + MTIP、精确陷入 / `mret` | ✅ 回归通过 |
| 分支预测 | gshare（6 位 GHR ⊕ PC 低位 → 64 项 2 位计数器）+ 64 项 BTB | ✅ 回归通过 |
| 数据前递 / load-use 暂停 | `Data_hazard`：4 个前递点（含 MEM 三级对齐） | ✅ 回归通过 |
| 上板件 | `board/`：复位同步释放、同步 BRAM 模型、板级顶层 + 测试台 | ✅ 板级自检 33/33 PASS（CI 里真正运行） |
| 真实综合/实现（Fmax、LUT/FF/BRAM 实数） | `syn/`（有脚本与约束模板） | ⚠️ 未做（缺 Vivado/yosys 环境） |
| 47 条全指令表 difftest（`cdp-tests`） | 需 verilator + make | ⚠️ 未做（有 103 项替代回归） |
| 板级实测（比特流、引脚译码） | — | ⚠️ 未做 |

上板改造修掉了 **6 个真实 RTL 缺陷**（load 后紧邻指令前递拿到地址、重定向连环触发、
`ecall` 永不产生异常、写回被 `valid` 掐掉、`WBU.stall` 悬空、x0 初值为 `x`）；
随后一轮**独立验证**（自建 RV32IM 参考模型 + 差分测试 + 在自带测试台上交叉复现）
又发现并修掉了 **7 个缺陷**，根因与逐行对照见
[`v9/syn/上板改造说明.md`](./v9/syn/上板改造说明.md)、
[`v9/改动diff_接管前快照_vs_上板改造后.txt`](./v9/改动diff_接管前快照_vs_上板改造后.txt)
与 [`验证报告_独立复核.md`](./验证报告_独立复核.md)。第二轮修掉的 7 个：

| # | 症状 | 根因（修复文件） |
| --- | --- | --- |
| 1 | `lb/lh/lbu/lhu` 永远读**偏移 0** 的那一（半）字节 | `LSU.sv` / `WBU.sv` 按 `funct3` 抽取却没用地址低 2 位选道 |
| 2 | 前一条不是访存指令时 load 取到陈旧值/0；真实 BRAM 上变 `x` | `DCache.sv` 读握手 off-by-one：`hold` 在发读那一拍就撤销 |
| 3 | `sw` 的数据来自紧邻的 load 时，写进去的是旧值 | `Data_hazard.sv` 的 MEM/pipe 命中没检查 `valid`，挡住了 MEM2 前递 |
| 4 | 后向分支循环只跑 2 圈就掉出 / 失控 | `Control.sv` 用 `~mem_stall` 把误预测判定**丢弃**；`IFU.sv` 投机拨 PC 与接收条件不一致 |
| 5 | 背靠背 `div/rem` 结果与 rd **错位一条指令** | `EXU.sv` 的 MDU 在回到 IDLE 那一拍用旧操作码重复发射 |
| 6 | `jal x4,T` 后紧跟读 x4 的指令拿到**跳转目标**而不是 link | `Control.sv` 的 EXU 级前递用 `Ex_result` 而非 `rd_value` |
| 7 | 补发重定向那一拍，错路径指令已经进了 EX 并被提交 | `Control.sv` + `EXU.sv`：挂起期间必须挡住新指令接收 |

同时修掉了 3 处**验证基础设施**缺陷（它们让上面这些问题一直没被发现）：回归测试台的
DRAM 读口没有读使能（与真实 BRAM 语义不符，掩盖了第 2 条）、D-Cache 单元测试没有
`$fatal`（**永远不可能失败**）、CI 只编译板级测试台却从不运行它。

---

## 验证

| 层次 | 命令 | 结果 |
| --- | --- | --- |
| 整机回归（7 程序 × 正常/严格模式） | `cd v9 && bash sim/run_all.sh` | **15 项全过，单轮 239/239 检查**，严格模式同样全过 |
| D-Cache 单元测试 | 见 `run_all.sh` 最后一项 | miss→fill、二次命中、**写直达落盘**、MMIO 不缓存、外设副作用 —— 全 PASS，且失败会真正把回归打红（有 `$fatal`） |
| 板级顶层自检 | `v9/board/tb_board_top.sv`（命令见文件头注释） | **PASS 33/33**（CI 里会真正运行） |
| 回归波形（可直接看） | `v9/sim/run_iverilog.bat prog wave` | VCD 在 `v9/wave/` |
| 独立差分验证（额外夹具） | `bash .verify/difftest/run.sh 40` | 20 个定向 + 40 个随机程序与参考模型**逐寄存器/逐内存字一致** |

`run_all.sh` 的「严格模式」= `+no_wbu_force +raw_rf`，即**关掉测试台的所有兜底**
（不用 `force` 顶 `WBU.stall`、不做寄存器堆上电清零），直接跑修好的 RTL。
这是防止「靠测试台掩盖 RTL 缺陷」的关键一道检查，CI 里每次都跑。

CI 配置见 [`.github/workflows/ci.yml`](./.github/workflows/ci.yml)：push/PR 时自动
安装 iverilog、跑全量回归、并对整机与板级顶层各做一次编译门禁。

---

## 协作（多人开发）

仓库已配置好协作所需的基础设施，新人 **3 步**上手：

```bash
git clone git@github.com:fshanhuan/Rsic-v-IM.git
cd Rsic-v-IM
git checkout -b feat/your-topic          # 永远别直接推 main
# ...改代码 → bash v9/sim/run_all.sh 必须全过...
git commit -m "feat(icache): ..."
git push -u origin feat/your-topic       # 然后开 Pull Request
```

约定摘要（完整版见 [`CONTRIBUTING.md`](./CONTRIBUTING.md)）：

- **`main` 只接受 PR**，不直接 push；建议开启分支保护（见下）。
- **每个 PR 必须让 `bash v9/sim/run_all.sh` 全过**（CI 会替你跑）。
- **改 RTL 必须同时更新对应文档**（`v9/docs/模块阅读文档.md` 的 I/O 表与关键信号），
  否则下一个人读代码会踩坑。
- **命名风格不要动**：模块名、信号名、`_next`/`_last` 后缀、`valid`/`ready` 语义保持原样；
  新增端口/信号请带中文注释说明用途。
- **分支名**：`feat/…`、`fix/…`、`docs/…`、`chore/…`、`refactor/…`。
- **提交信息**：Conventional Commits（`type(scope): 摘要`），正文写「为什么」和「验证方式」。

### 邀请协作者（仓库所有者操作）

1. **加人**：`Settings → Collaborators → Add people`，输入对方 GitHub 用户名，
   选 `Write`（能推分支/开 PR）或 `Maintain`。
2. **保护 main**（强烈建议）：`Settings → Branches → Add branch protection rule`，
   pattern 填 `main`，勾选：
   - ✅ Require a pull request before merging（建议 Required approvals = 1）
   - ✅ Require status checks to pass → 选 `iverilog 回归 (v9)` 与 `编译门禁 (iverilog -g2012)`
   - ✅ Require branches to be up to date before merging
   - ⛔ Do not allow bypassing the above settings
3. **讨论区**：`Settings → Features` 里打开 `Issues`（已开）与 `Discussions`，
   用来分工、认领任务、记录设计与踩坑。
4. **不加协作者也能协作**：仓库是 public，任何人可以 `Fork → 改 → Pull Request`。

---

## 文档索引

按「先读结论、再读模块、最后读实现细节」排序：

| 文档 | 讲什么 |
| --- | --- |
| [`v9/README.md`](./v9/README.md) | **工程总览**：做了什么、结构、验证命令、波形/时序图 |
| [`v9/docs/模块阅读文档.md`](./v9/docs/模块阅读文档.md) | **主文档**：逐模块 I/O、关键信号作用、模块间联系、上板改造三个必知机制、指令走查、一页速查 |
| [`v9/docs/README.md`](./v9/docs/README.md) | 文档索引与推荐阅读顺序、命名约定 |
| [`v9/syn/上板改造说明.md`](./v9/syn/上板改造说明.md) | 上板障碍清单（P0~P5）、改造前后对照、6 个 RTL 缺陷的根因 |
| [`v9/syn/synth_report.md`](./v9/syn/synth_report.md) | Yosys 实测资源报告（MDU 组合版 vs 流水版） |
| [`v9/sim/README_iverilog.md`](./v9/sim/README_iverilog.md) | iverilog 测试台怎么用、plusarg、期望值表、踩过的环境坑 |
| [`v9/experimental/README.md`](./v9/experimental/README.md) | 时序化 MDU 的验证情况与接入状态 |
| [`v9/CPU设计说明.pdf`](./v9/CPU设计说明.pdf) | 上板改造**之前**的设计说明（数据通路图、立即数生成、扩展建议） |
| [`v9/交付说明.md`](./v9/交付说明.md) | 本次上板改造的交付清单与「本机没能做的部分」 |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | 协作约定：环境、分支、提交、PR、评审、文档同步 |

> 文档有冲突时，**以 `v9/docs/模块阅读文档.md` 为准**（它是改造后的权威说明）。

---

## 已知限制 / roadmap

**已知限制**（都在 [`v9/docs/模块阅读文档.md`](./v9/docs/模块阅读文档.md) §6 / §12 有展开）：

1. **没做真实综合与时序**：`syn/` 里的脚本与约束齐了，但 Fmax/WNS 与实际
   LUT/FF/BRAM/DSP 占用需要你在有 Vivado 或 yosys 的机器上跑。
2. **`board/sync_mem.sv` 是行为模型**：上板请替换成 `xpm_memory_*` 或厂商 BRAM IP。
3. **47 条全指令表 difftest 未跑**：需要 verilator + make；现有 103 项是替代回归。
4. **未做板级实测**：没有比特流，LED/7 段码/UART 的引脚译码还没写。

**欢迎认领的方向**（开 Issue 认领即可）：

- 跑 `cdp-tests` 的 47 条全指令表 difftest，把结果补进文档；
- 用 Vivado/yosys 出真实时序报告，把 `syn/timing_sweep.tcl` 的结果写进 `syn/`；
- 把 `board/sync_mem.sv` 换成真实 BRAM IP，加 XDC 引脚约束与板级测试；
- 指令/数据 Cache 的写回策略（当前写直达）与关联度改造；
- BPU 升级（2-bit BTB → 更深的 gshare/局部历史混合）；
- 约束随机验证（cocotb / SystemVerilog 断言 / 形式化）。

---

## 许可

本仓库**尚未指定开源许可证**（`LICENSE` 文件缺失）。在添加许可证之前，
默认版权归作者所有，他人**没有**复制、修改、再发布的法定许可
（虽然 GitHub 上仍可 Fork/开 PR，但那只是平台功能，不构成授权）。

如果打算长期多人协作，建议尽快补一个，例如：

- `MIT` —— 最宽松，最省事；
- `Apache-2.0` —— 宽松 + 显式专利授权，适合可能有商业使用的场景；
- `CERN-OHL-S-2.0` / `Solderpad-2.0` —— 硬件专用（如果你希望它更像硬件项目）；
- 若是**课程作业/竞赛作品**，请先确认学校或赛事的作品归属规定再选。

需要的话我可以直接帮你加（并同步更新本节的说明）。
