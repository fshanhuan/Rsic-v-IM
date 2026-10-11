# v9: RV32IM + Cache + 中断 + 分支预测（已做上板改造）

> **本次上板改造（board-ready）已完成并验证**，详见
> [`docs/模块阅读文档.md`](./docs/模块阅读文档.md)（逐模块 I/O、关键信号、模块间联系、改造清单）
> 与 [`syn/上板改造说明.md`](./syn/上板改造说明.md)（改造前后状态对照）。
> 一句话：ICache/DCache 改成**同步存储握手**、MDU 换成流水化版本、复位同步释放、
> 程序用 `$readmemh` 载入、新增 `board/`，并修掉了 4 个真实 RTL 缺陷
> （load-use 前递拿地址、重定向连环触发、`ecall` 永不产生异常、写回被 valid 掉拍掐掉）。
> 本机 iverilog 三程序回归 **103/103 全过**。
>
> **最新一轮（ModelSim + Quartus II 实测）又修掉 2 个真实缺陷，并给出资源结论**，
> 见 [`syn/quartus_modelsim_实测.md`](./syn/quartus_modelsim_实测.md)：
> - **B8**：`board/board_top.sv` 有 5 处**层次化引用**（`u_cpu.icache_mem_en`、
>   `u_cpu.*_hit/miss_cnt`），而这些并不是 `myCPU` 的端口 —— 仿真器容忍、**Quartus 直接报
>   `Error (10207)` 导致整机综合失败**；现已改为顶层端口（`myCPU.irom_en` + 4 个 `debug_*`）。
> - **B9**：`board/sync_mem.sv` 的初始化清零循环 16384 次，越过 Quartus 的
>   5000 次循环上限（`Error (10106)`）；现已限制为 ≤4096 次（仿真语义不变）。
> - **ModelSim SE-64 10.5 下全量回归 15/15 全过**（7 程序 × {正常,严格} + D-Cache 单测），
>   上板路径测试台 `tb_board_top` 也 **33/33**；`sim\run_msim.bat` 一条命令复现。
> - **Quartus II 13.0 能用**，但必须在 `.qsf` 里加一行
>   `VERILOG_INPUT_VERSION SYSTEMVERILOG_2005`（否则满屏 10170 语法错）。
> - **资源**：CPU 核心 **18,815 LE / 8,995 寄存器**；整机（含 64KB DRAM）
>   **19,175 LE / 9,268 寄存器 / 68 个 M9K / 530,688 存储位 / 201 引脚**。
>   征途板 `EP4CE6E22C8`（6,272 LE、30 M9K、92 脚）**装不下**：
>   逻辑 306 %、存储 192 %、引脚 218 %。缩到 EP4CE30 后逻辑/引脚都够（67 %/61 %），
>   **只有 M9K 差 2 块（68/66）** —— 瓶颈是 64KB DRAM，不是流水线结构。
>
> **结构/功能不足的修复进度**见 [`syn/修复进度_C系列.md`](./syn/修复进度_C系列.md)：
> - ✅ **C2** 前递/冒险判定收敛为单一裁决源（`Data_hazard` 成为唯一口径）
> - ✅ **C5** `Data_hazard` 的 WB 前递补 `WB_valid`，五个前递源口径一致
> - ✅ **C6** 清理 5 个死信号（`bp_redir_taken` / `bp_pend_taken` / `div_signed_r` /
>   `store2_addr` / `store2_tag`），`mtval_reg` 从死寄存器变为真正登记异常现场
> - ✅ **C7a** `mtime` 从"每拍 +1"改为可配置递减计数器（默认 1MHz 时间基准）
> - ⚠️ **C4** 异常体系（非法指令 / 非对齐访存 / 目标非对齐 + `mtval` 落地）：
>   判定与 CSR 登记已验证正确，但开启后会影响分支预测恢复，
>   **由 `Control #(.TRAP_ENABLE)` 控制，默认 0**；默认配置下 **14/14 回归全过**
> - ⏳ C1（缓存标准握手）/ C3（`EXU_inst_clear` 同步语义）/ C7b（冲 100MHz）尚未开始

## 概述

`v9` 在 `v8`（RV32I 教学流水线）基础上完成四项能力升级，并做了可读性整理：

- **RV32IM**：新增 8 条乘除法指令（`mul/mulh/mulhsu/mulhu/div/divu/rem/remu`），
  由独立的 `MDU.sv` 执行（**上板路径已换成时序化的 `experimental/MDU_pipelined.sv`**），
  ALU 编码扩展到 5 位（最高位区分 M 扩展）。
- **Cache**：新增 `ICache.sv`（直接映射指令缓存）与 `DCache.sv`（写直达数据缓存），
  并在波形中提供 `hit_cnt/miss_cnt` 命中/缺失计数。
- **中断**：扩展机器模式 CSR（`mie/mip/mscratch/mtime/mtimecmp` 等），
  支持软件中断（MSIP）与内部定时器中断（MTIP），配套精确陷入/`mret` 返回。
- **分支预测**：`Branch_Predictor.sv` 采用 **gshare**（6 位全局历史 GHR 与 PC 低位
  异或后索引 64 项 2 位计数器）＋ 64 项 BTB；IF 级查询、EX 级校验与更新，
  预测错误时才冲刷前端。
- **可读性**：统一宏命名、补充模块级注释、清理死信号、把 `is_M`(SYSTEM) 改名 `is_SYS`，
  改造前的设计说明见 [`CPU设计说明.pdf`](./CPU设计说明.pdf)（改造后以
  [`docs/模块阅读文档.md`](./docs/模块阅读文档.md) 为准）。

## 结构

- **功能级（经典 5 级）**：`IF / ID / EX / MEM / WB`（`IFU / IDU / EXU / LSU / WBU`）。
- **物理寄存器边界（8 级）**：`IF → ID1 → ID2 → EX → M1 → M2 → M3 → WB`。
  其中 `IDU` 内部拆 2 拍、`LSU` 内部拆 3 拍，因此取指到写回约 7 拍，稳态 1 IPC。
  多出的拍对应 `Data_hazard` 的 `MEM / MEM_PIPE / MEM2` 三个前递点。

```
取指(IFU+ICache+BPU) → 译码(IDU+Reg_Stack+CSR) → 执行(EXU+ALU/MDU)
      → 访存(LSU+DCache) → 写回(WBU)
      ↑ 控制：Control + Data_hazard（前递/暂停/冲刷/重定向/中断接收）
```

各模块的**输入、输出、作用**见 [`docs/模块阅读文档.md`](./docs/模块阅读文档.md)（§0 一页速查）。

## 验证

### 本机可跑（iverilog 12.0，推荐先跑这个）

**一条命令跑全量（推荐）**：

```bash
cd v9
bash sim/run_all.sh     # 3 个程序 × 正常/严格模式 + D-Cache 单元测试 = 7 项，失败时返回非 0
```

分开跑单个程序：

```bat
cd v9
sim\run_iverilog.bat                :: sim/prog.hex      —— 算术/mul/load-use/分支/jal/ecall
sim\run_iverilog.bat prog_mul       :: sim/prog_mul.hex  —— 8 次乘法
sim\run_iverilog.bat prog_div       :: sim/prog_div.hex  —— 4 次除法（MDU 多拍）
```

当前结果：**`prog` 35/35、`prog_mul` 34/34、`prog_div` 34/34，总计 103/103 全过**；
加 `+no_wbu_force +raw_rf`（不用测试台兜底）同样全过。
`bash sim/run_all.sh` 会把上面 6 项（3 程序 × 正常/严格模式）加下面那项 D-Cache 单元测试
一起跑完，共 **7 项**，全过才返回 0 —— CI 用的就是它。
另有 `sim/tb_dcache_unit.sv`（D-Cache 单元测试：miss→fill、二次命中、MMIO 不缓存、外设副作用）全 PASS。

### 原 `cdp-tests`（需要 verilator + make，本机没有）

```bash
cd ../cdp-tests

# 单条指令
make clean
make run TEST=addi CPU_DIR=../v9
make run TEST=mul  CPU_DIR=../v9

# 全量回归：47 条（39 条 RV32I + 8 条 RV32M）
CPU_DIR=../v9 python3 run_all_tests.py

# 中断专项（独立模式，不走 golden model）
python3 tools/gen_intr_test.py
python3 tools/gen_timer_test.py
INTR_TEST=1 make run TEST=intr       CPU_DIR=../v9
INTR_TEST=1 make run TEST=intr_timer CPU_DIR=../v9
```

> 47 条全指令表 difftest **本机无法执行**（缺 verilator/make），上面的三个程序是替代回归，
> 覆盖面不如它，建议在有工具链的机器上补跑。

## 上板化（时序 / 约束 / 资源）

`v9` 已补齐一套**厂商无关**的可综合化工程件，用于回答「这颗 CPU 能不能上板、
能跑多少 MHz、占多少资源」：

| 文件 | 作用 |
| --- | --- |
| [`docs/模块阅读文档.md`](./docs/模块阅读文档.md) | **逐模块阅读文档**：I/O、关键信号、模块间联系、改造清单、验证结果 |
| [`syn/上板改造说明.md`](./syn/上板改造说明.md) | 上板障碍清单、实测数据、分步改造方案（含改造前后状态） |
| [`syn/synth_report.md`](./syn/synth_report.md) | 实测综合资源报告（可复现） |
| [`syn/synth_core.ys`](./syn/synth_core.ys) | Yosys 综合 + 资源报告脚本 |
| [`syn/v9.xdc`](./syn/v9.xdc) / [`syn/v9.sdc`](./syn/v9.sdc) | Vivado / 通用时序约束模板 |
| [`syn/timing_sweep.tcl`](./syn/timing_sweep.tcl) | 时钟周期扫描，测实际可达频率 |
| [`experimental/MDU_pipelined.sv`](./experimental/MDU_pipelined.sv) | 时序化 MDU —— **已接入 `EXU`**（模块级 4968 条向量已验证） |
| [`board/`](./board) | 上板件：`sync_mem.sv`（同步 BRAM 模型）、`reset_sync.sv`（复位同步释放）、`board_top.sv`、`tb_board_top.sv` |

一条命令出资源报告：

```bash
cd v9
yosys -s syn/synth_core.ys      # 需要 yosys（含 abc）
```

关键实测结论：把 MDU 从「单拍纯组合」改成「乘法单拍 + 除法 32 拍迭代」后，
MDU 逻辑规模约降到 **1/5**（2150 → 407 LC），最长进位链约降到 **1/5**（419 → 81）。

> **存储时序（原 P0 障碍）已改造完成**：`ICache`/`DCache` 现在按同步存储握手
> （请求/响应两拍、`hold` 停拍重试），`IFU.valid` 按当拍取指契约产生，
> `LSU` 在 `hold` 期间整条冻结；`board/sync_mem.sv` 就是一拍读延迟的 BRAM 模型。
> 仍未在本机完成的只有：真实综合/时序（需要 Vivado/yosys）、BRAM IP 推断、板级测试、
> `cdp-tests` 47 条全指令表——原因见 [`docs/模块阅读文档.md`](./docs/模块阅读文档.md) §6。

## 波形 / 时序图

`cdp-tests` 的回归波形会把 CPU 内部信号与 `debug_wb_*` 别名掉，不便于阅读。
[`sim/`](./sim) 提供一个自包含、带探针的测试台；跑完 `sim\run_iverilog.bat` 后，
用下面这条命令把 VCD 转成时序图（Windows 下 `run_wave.sh` 需要 bash，直接用 python 更省事）：

```bat
cd v9
python sim\vcd2svg.py wave\tb_iverilog_prog.vcd     figures\v9_postboard_prog.svg
python sim\vcd2svg.py wave\tb_iverilog_prog_mul.vcd figures\v9_postboard_prog_mul.svg
python sim\vcd2svg.py wave\tb_iverilog_prog_div.vcd figures\v9_postboard_prog_div.svg
```

生成的图在 [`figures/`](./figures)（已按**上板改造后**的 VCD 重新生成）：

| 图 | 内容 | 看点 |
| --- | --- | --- |
| [`v9_postboard_prog.svg`](./figures/v9_postboard_prog.svg) | 综合演示程序 | 数据前递、**load-use 暂停五拍**、分支/跳转、`ecall` |
| [`v9_postboard_prog_mul.svg`](./figures/v9_postboard_prog_mul.svg) | 连续 8 条 `mul` | 全程 `stall=0`，MDU 单拍，1 IPC |
| [`v9_postboard_prog_div.svg`](./figures/v9_postboard_prog_div.svg) | 连续 4 条 `div` | `mdu_busy` 冻结流水多拍（不再是一条 32 级组合链） |

波形按**时钟下降沿**采样（与测试台读 `debug_wb_*` 的时刻一致），
总线行直接显示十六进制数值，指令行显示**已译码的汇编**，
底部 `reg x1..x8` 可以看到寄存器堆逐拍被写入的过程。
最新的 VCD 在 `wave/tb_iverilog_{prog,prog_mul,prog_div}.vcd`（逐元素 dump 了 32 个寄存器与 CSR）。

## 产品说明（客户版）

面向选型与采购的介绍性文档已经单独成篇，把**接口规格、性能画像、资源/选型、已知缺陷、优化路线图**
集中在一处，适合直接发给客户或评审：

| 文件 | 内容 |
| --- | --- |
| [`v9_处理器产品说明_客户版.docx`](./v9_处理器产品说明_客户版.docx) | **客户版产品说明（Word，15 页）**：TL;DR 选型速览、微架构总览、端口/总线/中断接口、性能与 Fmax、资源与器件选型、13 项已知缺陷（含影响与规避）、优化路线图、验证与复现、测量条件与免责声明 |
| [`docs/产品说明_v9_客户版.md`](./docs/产品说明_v9_客户版.md) | 同一份内容的 Markdown 源（正文改这里，再跑 `docs/md2docx.py` 重新生成 Word） |
| [`docs/v9_产品说明_预览.pdf`](./docs/v9_产品说明_预览.pdf) | 排版预览 PDF（便于快速分发与评审） |
| [`figures/v9_arch_overview.png`](./figures/v9_arch_overview.png) | 微架构总览图（功能 5 级 / 物理 8 级 + 片外接口 + 控制通路） |
| [`figures/v9_capacity.png`](./figures/v9_capacity.png) | 资源/容量画像（EP4CE6 与 EP4CE30 的占用对比） |

重新生成：`python docs/gen_product_figs.py`（配图）→ `python docs/md2docx.py`（Word）。

## 建议阅读顺序

1. [`docs/模块阅读文档.md`](./docs/模块阅读文档.md) §0 一页速查 + §1 握手语义，先建立全局图景；
2. 同文档 §2 按模块看 I/O 与关键信号；§3 三个必须知道的机制（load 前递点、valid 保持语义、重定向优先级）；
3. §4 改动清单对照 RTL 里的中文注释；§5 复现验证；§6 本机无法完成的部分；
4. 想看改造前的原始设计意图，再翻 `CPU设计说明.pdf`；
5. 最后用 `sim/` 的波形脚本把典型指令的数据/控制通路串一遍。
