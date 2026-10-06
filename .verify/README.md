# `.verify/` — 独立验证夹具（第二轮复核）

这里的东西**不属于 CPU 设计本身**，是为了回答一个问题：
「官方回归 7 项全过，能不能说明这颗核是对的？」
答案是不能 —— 于是自建了一套与项目测试台**互相独立**的验证：自己写参考模型、
自己生成程序、逐寄存器/逐内存字比对，最后再拿项目自带测试台交叉复现。

本轮据此发现并修掉了 **7 个 RTL 功能缺陷 + 3 处验证基础设施缺陷**，
完整证据（原始输出、file:line 根因、复现命令）见仓库根目录
[`验证报告_独立复核.md`](../验证报告_独立复核.md)。

## 一条命令跑完全部四道门禁

```bash
bash .verify/verify_all.sh 40      # 参数=随机用例数，默认 40
```

四道门禁（必须同时通过）：

| # | 门禁 | 期望 |
| --- | --- | --- |
| 1 | 官方回归 `v9/sim/run_all.sh` | 15 项通过（7 程序 × 正常/严格 + D-Cache 单元测试） |
| 2 | 板级自检 `v9/board/tb_board_top.sv` | `[BOARD-SELFCHECK] status=PASS (33/33)` |
| 3 | 差分测试（本目录） | `PASS=60 FAIL=0` |
| 4 | 交叉验证（同一批程序喂给自带 `tb_iverilog.sv`） | `交叉验证不一致处数: 0` |

## 环境要求

- Linux / WSL，`python3`，以及 `iverilog` + `vvp`（12.0 验证过）。
- 若机器上没有 iverilog 且没有 root 权限：`bash .verify/install_iverilog.sh`
  （`apt-get download` + `dpkg -x` 解到 `$HOME/ivlocal`，不动系统）。
  之后每个脚本都会自己 `export PATH="$HOME/ivlocal/usr/bin:$PATH"`。
- 所有仿真都在 `$HOME/` 下的副本里跑，**不会改动仓库里的任何文件**。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `verify_all.sh` | **总门禁**：串起下面四件事并给出汇总 |
| `install_iverilog.sh` | 非 root 安装 iverilog（可复现环境） |
| `difftest/rv32.py` | RV32IM 汇编器（已用 `v9/sim/prog.hex` 逐条校准）+ **独立参考模型** |
| `difftest/gen.py` | 用例生成：20 个定向（含最小化用例）+ N 个随机，输出 `.hex` 与期望 `.exp` |
| `difftest/tb_difftest.sv` | 自建测试台：以"magic store + 自跳停车"作为结束条件（避开 `ecall` 重定向重启程序带来的排空窗口问题），导出 32 个 GPR + 全部非零内存字 |
| `difftest/compare.py` | 逐寄存器 / 逐内存字比对，打印第一条不一致 |
| `difftest/run.sh` | 跑差分测试（编译一次，跑全部用例） |
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
