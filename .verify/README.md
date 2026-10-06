# `.verify/` — 独立验证夹具（第二轮复核）

这里的东西**不属于 CPU 设计本身**，是为了回答一个问题：
「官方回归 7 项全过，能不能说明这颗核是对的？」
答案是不能 —— 于是自建了一套与项目测试台**互相独立**的验证：自己写参考模型、
自己生成程序、逐寄存器/逐内存字比对，最后再拿项目自带测试台交叉复现。

本轮据此发现并修掉了 **7 个 RTL 功能缺陷 + 3 处验证基础设施缺陷**；
第三轮接入商用 ModelSim 后又发现并修掉 **5 处"先用后声明"的隐式网络缺陷
（其中 1 处是 32 位乘除法结果总线）+ 2 处测试台双重驱动**。
完整证据（原始输出、file:line 根因、复现命令）见仓库根目录
[`验证报告_独立复核.md`](../验证报告_独立复核.md)（§2 缺陷清单、§9 第二轮修复、§10 第三轮）。

## 一条命令跑完全部五道门禁

```bash
bash .verify/verify_all.sh 40      # 参数=随机用例数，默认 40
```

五道门禁（必须同时通过）：

| # | 门禁 | 期望 |
| --- | --- | --- |
| 0 | 严格网络检查 `.verify/netcheck.sh` | 4 项全 `[OK]`（无隐式网络 / 无"先用后声明"） |
| 1 | 官方回归 `v9/sim/run_all.sh` | 15 项通过（7 程序 × 正常/严格 + D-Cache 单元测试） |
| 2 | 板级自检 `v9/board/tb_board_top.sv` | `[BOARD-SELFCHECK] status=PASS (33/33)` |
| 3 | 差分测试（本目录） | `PASS=60 FAIL=0` |
| 4 | 交叉验证（同一批程序喂给自带 `tb_iverilog.sv`） | `交叉验证不一致处数: 0` |

**门禁 0 是第三轮新增的，也是最便宜的一道。** 它把每个 `.sv` 顶上加
`` `default_nettype none `` 再编译一遍，于是"未声明就使用"的标识符（隐式网络）
从"静默生成 1 位 wire"变成硬错误。它抓两类问题：

- **先用后声明**：ModelSim 会报 `vlog-2730` 硬错误，iverilog 静默放过（第三轮修掉 5 处）；
- **从未声明**：被 `assign` 驱动在 Verilog 里合法，**连 ModelSim 都不报**
  —— `Control.sv` 的 `bp_mispredict_raw` 就是这样被抓出来的。

好处是 iverilog 也支持这条指令，所以它能进 CI，不必依赖商用工具。

### 第五道门禁（第二仿真器，需 Windows 侧 ModelSim）

```bash
bash .verify/difftest/run_modelsim.sh 40
```

把**同一套差分测试**同时喂给 iverilog 与 ModelSim SE，做三方比对：
ModelSim vs 参考模型、iverilog vs 参考模型、两个仿真器 dump **逐字节**比对。

这道门禁的价值不只是"再确认一遍"：

1. **ModelSim 的编译期检查远比 iverilog 严格。** 首次接入时它当场报出
   5 处"先用后声明"（`vlog-2730`，硬错误且**不可压制**）—— 按 Verilog 隐式网络
   规则，这些标识符会被当成 1 位 wire，其中一个是 32 位的 `mdu_res`（乘除法结果
   总线）。iverilog 对这些**全部静默放过**。也就是说：**在接入 ModelSim 之前，
   这份 RTL 在主流商用工具下根本编译不过，而此前所有验证都没有发现。**
2. **排除"结论只是 iverilog 特有语义解释"的可能。** 两个仿真器的 32 个 GPR +
   全部非零内存字逐字节相同，说明此前的功能结论与仿真器无关。
3. ModelSim 还报出测试台里 `dram` 被 `always_ff` 与 `initial` 双重驱动
   （`vlog-7061`）。注意它是 **Error 级**，vlog 会**拒绝把该模块写入库**，
   随后 vsim 报 `vopt-13130 Failed to find design unit` —— 表现为"编译说成功、
   仿真说找不到模块"。两处已改为 `always @(posedge clk)`。

## 环境要求

- Linux / WSL，`python3`，以及 `iverilog` + `vvp`（12.0 验证过）。
- 若机器上没有 iverilog 且没有 root 权限：`bash .verify/install_iverilog.sh`
  （`apt-get download` + `dpkg -x` 解到 `$HOME/ivlocal`，不动系统）。
  之后每个脚本都会自己 `export PATH="$HOME/ivlocal/usr/bin:$PATH"`。
- 第五道门禁额外需要 Windows 侧 ModelSim SE（默认找
  `E:\FPGA\ModelSim_10.5se\win64`，可用 `MSIM_DIR=` 覆盖）。
  WSL 可直接调用 `vlog.exe`/`vsim.exe`。**注意 ModelSim 是 Windows 程序，
  工作目录必须落在 Windows 可访问的分区且不含非 ASCII 字符**（10.5 对中文
  路径支持不好），所以脚本默认用 `%TEMP%\msim_dt`，可用 `MSIM_WORK=` 覆盖。
- 所有仿真都在 `$HOME/` 或 `%TEMP%` 下的副本里跑，**不会改动仓库里的任何文件**。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `verify_all.sh` | **总门禁**：串起下面四件事并给出汇总 |
| `netcheck.sh` | **严格网络检查**：给每个 `.sv` 加 `` `default_nettype none `` 再编译，把隐式网络变成硬错误 |
| `install_iverilog.sh` | 非 root 安装 iverilog（可复现环境） |
| `difftest/rv32.py` | RV32IM 汇编器（已用 `v9/sim/prog.hex` 逐条校准）+ **独立参考模型** |
| `difftest/gen.py` | 用例生成：20 个定向（含最小化用例）+ N 个随机，输出 `.hex` 与期望 `.exp` |
| `difftest/tb_difftest.sv` | 自建测试台：以"magic store + 自跳停车"作为结束条件（避开 `ecall` 重定向重启程序带来的排空窗口问题），导出 32 个 GPR + 全部非零内存字 |
| `difftest/compare.py` | 逐寄存器 / 逐内存字比对，打印第一条不一致 |
| `difftest/run.sh` | 跑差分测试（编译一次，跑全部用例） |
| `difftest/run_modelsim.sh` | **第二仿真器交叉验证**：同一套用例再喂给 ModelSim，两仿真器 dump 逐字节比对（见上"第五道门禁"） |
| `difftest/crosscheck.sh` / `crosscheck.py` | **交叉验证**：同一批程序喂给项目自带 `tb_iverilog.sv`，看错值是否复现 |
| `difftest/tb_trace.sv` / `trace.sh` / `trace_store.sh` | 逐拍探针（PC/重定向/分支内部信号/MDU 握手/store 通路），定位根因用 |
| `difftest/reftrace.py` / `rtldiff.sh` | 参考模型的**逐指令轨迹**与 `[WB]` 事件流按指令对齐比对，直接指出第一条分歧 |
| `difftest/mkcases.py` / `mkregress.sh` | 由参考模型算出期望值，生成并入到 `v9/sim/` 的回归程序 |
| `showfail.sh` / `stview.sh` | 失败用例明细 / 用自带测试台的 `[ST]` 事件日志定位 store |
| `syncheck.sh` | 按 `syn/synth_core.ys` 的文件清单编译，验证综合脚本能否 elaborate |

## 已知但**未**修复的项（模块级，缺少整机复现）

见验证报告 §2.5 V4/V5：DCache 读响应缺地址跟踪（触发条件已被 B2 的修复覆盖，
但未做定向复现）、背靠背 store 只发一个脉冲（整机未触发）、一次 MMIO load 触发多次
外设读（与测试台长时间保持请求有关）、IFU `valid` 拍里 NOP 偏多（性能，约 7.5 拍/指令）。
这些未改动以避免在缺用例的情况下引入新风险。
