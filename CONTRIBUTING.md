# 协作指南（CONTRIBUTING）

欢迎一起改这颗 RV32IM 教学核。本文件是**多人协作的硬约定**：
凡是被 CI 卡住或让人踩坑的事，都写在下面。

---

## 0. 一句话流程

```bash
git clone git@github.com:fshanhuan/Rsic-v-IM.git
cd Rsic-v-IM
git checkout -b feat/your-topic
# ...改代码 / 改文档...
bash v9/sim/run_all.sh          # 必须全过，否则别开 PR
git commit -m "feat(icache): 同步读回填支持 hold 重试"
git push -u origin feat/your-topic
# 在 GitHub 上开 Pull Request，等 CI 绿 + 1 个 approve
```

`main` 是**受保护分支**（建议开启，见根 README「邀请协作者」一节）：
只能通过 PR 合入，且必须通过 `iverilog 回归 (v9)` 与 `编译门禁 (iverilog -g2012)` 两项检查。

---

## 1. 环境

**必需**：`iverilog` 12.0（`iverilog` + `vvp`）。

```bash
# Ubuntu / Debian
sudo apt-get install -y iverilog
# macOS
brew install icarus-verilog
# Windows：装 Icarus Verilog 后，改 sim\run_iverilog.bat 顶部的路径，或直接用 .sh（装了 bash/Git Bash）
```

**可选**（只在做特定任务时需要）：

| 工具 | 用途 | 差什么就跑不了 |
| --- | --- | --- |
| `verilator` 5.x + `make` | `cdp-tests` 的 47 条全指令表 difftest | 那个回归**至今没跑过**，欢迎补 |
| `yosys`（含 abc） | `v9/syn/synth_core.ys` 出资源报告 | 面积/时序结论目前来自缺环境的估算 |
| `Vivado` | 真实实现、Fmax/WNS、BRAM IP | 板级实测完全没做 |
| `python3` | `sim/vcd2svg.py`、`sim/mkwave.py` 出时序图 | 只是看图，不影响功能 |
| `GTKWave` | 看 VCD | 同上 |

> **不要在仓库里提交工具链产物**。`.gitignore` 已挡掉 `sim/build/`、`obj_dir/`、
> `.Xil/`、`*.jou`、`*.bit` 等；VCD（`v9/wave/`）与 SVG（`v9/figures/`）是**刻意入库**的
> 可视证据，可以更新，但不要放历史调试波形（仓库里只保留三个程序对应的一套）。

---

## 2. 改代码之前请先读

1. [`v9/docs/模块阅读文档.md`](./v9/docs/模块阅读文档.md) **§0 一页速查** + **§1 的握手约定**
   —— 不读这段直接看代码，几乎一定会踩坑：
   - **load 的数据只在 MEM 第三级（M3）可前递**，EX 级拿到的是地址；
   - **重定向必须是一次性脉冲**（电平信号会连环触发，整机死循环）；
   - **不能靠拉低 `valid` 挡指令**（payload 是冻结保持的，写了就写了）；
   - **`hold` 期间整条访存流水要一起冻结**（否则 hold 会把自己解掉）。
2. 同文档 §2~§8 按 `myCPU → IFU → IDU → EXU → LSU → WBU → Data_hazard` 看模块 I/O。
3. §9 上板改造的三个机制、§10 典型指令走查（含逐拍波形）。

---

## 3. 硬性规则

| # | 规则 | 为什么 |
| --- | --- | --- |
| 1 | **`bash v9/sim/run_all.sh` 必须全过**（7 项：3 程序 + 3 严格模式 + D-Cache 单元测试） | 这是唯一的自动化护栏；CI 用同一脚本 |
| 2 | **不要为了让测试变绿而改测试台** | 尤其别在 `sim/tb_iverilog.sv` 里加 `force`/改期望值。严格模式（`+no_wbu_force +raw_rf`）就是专门防这个的 |
| 3 | **改 RTL 必须同步改文档** | 改端口/信号 → 更新 `v9/docs/模块阅读文档.md` 的 I/O 表；改行为 → 更新对应章节 |
| 4 | **不要改命名风格** | 模块名、信号名、`_next`/`_last` 后缀、`valid`/`ready` 语义保持原样；新增端口/信号带中文注释说明用途 |
| 5 | **中文注释保持中文**，术语用项目既有写法（如「前递」「重定向」「停拍」「冻结」） | 文档与代码注释是同一套词汇表，混用会让人对不上 |
| 6 | **一次 PR 只做一件事** | 便于评审与回滚；「顺手重构」请另开 PR |
| 7 | **新增/删除编译单元必须同步所有地方** | 编译清单出现在 5 处：`sim/run_iverilog.bat`、`sim/run_iverilog.sh`、`sim/README_iverilog.md`、`sim/tb_iverilog.sv` 头注释、`board/tb_board_top.sv` 头注释、`.github/workflows/ci.yml`。**曾经因为漏改导致 bash 流程编译不过** |
| 8 | **测试台必须能自己失败** | `run_iverilog.sh` 曾经因为 `\| tee` 吃掉退出码而永远返回 0；改动脚本时注意 `set -o pipefail` 与退出码 |

---

## 4. 分支与提交

**分支名**：`feat/…`、`fix/…`、`docs/…`、`refactor/…`、`chore/…`、`test/…`
（例：`feat/dcache-writeback`、`fix/load-use-forward`、`docs/board-pins`）

**提交信息**：Conventional Commits。

```
<type>(<scope>): <一句话摘要>

为什么这么改（问题现象 / 根因）
怎么验证的（跑了什么命令、看到什么结果）
```

- `type`：`feat` / `fix` / `docs` / `refactor` / `test` / `chore` / `perf`
- `scope` 用模块名或目录：`ifu` / `idu` / `exu` / `lsu` / `wbu` / `icache` / `dcache` /
  `bpu` / `csr` / `mdu` / `hazard` / `board` / `sim` / `syn` / `docs`
- 例：

```
fix(lsu): hold 期间同步冻结整条访存流水

现象：ICache 未命中拉高 hold 后，LSU 下一拍自己把 hold 解掉，回填数据错位。
根因：mem_hold 只并进了 EX 级 freeze，没并进 MEM/MEM2/MEM3 的 valid。
验证：bash v9/sim/run_all.sh —— 7/7 全过（含严格模式）。
```

**绝不要**：`git push --force` 到 `main`；把 `sim/build/`、`obj_dir/`、`.Xil/` 提交进来；
用 `--no-verify` 跳过检查；一个 commit 里混入不相关的格式化改动。

---

## 5. Pull Request

PR 描述请按这个模板写（GitHub 上可直接粘贴）：

```markdown
## 改了什么
（1~3 条）

## 为什么
（问题现象 + 根因；如果是 feature，说清使用场景）

## 怎么验证的
- [ ] `bash v9/sim/run_all.sh` → 7/7 PASS
- [ ] 新增/修改了哪些检查项（如有）
- [ ] 波形 / 仿真日志（如有，贴关键几行）

## 影响面
- [ ] 改了端口或信号 → 已同步 `v9/docs/模块阅读文档.md`
- [ ] 新增/删除文件 → 已同步 6 处编译清单（见 CONTRIBUTING §3 规则 7）
- [ ] 影响综合 → 已说明对面积/时序的预期影响

## 已知遗留
（没做完的部分，以及为什么可以先合）
```

**评审规则**：

- 至少 **1 个 approve** 才能合；涉及 `myCPU.sv` / `Data_hazard.sv` / `Control.sv`
  等核心控制路径，建议 2 个（其中一个是熟悉该模块的人）。
- 评审请重点看：**冒险处理的时序前提是否被破坏**、**是否靠测试台兜底**、
  **文档是否同步**。
- 合并方式建议 **Squash and merge**（保持 `main` 线性、每个 PR 一个 commit）。
- 有分歧时：在 Issue 里把「现象 + 波形 + 期望」写清楚再讨论；**用波形说话，不用感觉说话**。

---

## 6. 加检查项（新功能的标准动作）

新增一条功能，请顺手补上它对应的检查，否则下一个人改坏了不会有人知道：

1. **整机层**：往 `v9/sim/prog.hex`（或新增 `prog_xxx.hex`）里加指令，
   并在 `sim/tb_iverilog.sv` 的期望值表里加一个 `PROG_ID`；
2. **模块层**：仿照 `v9/sim/tb_dcache_unit.sv` 写一个只打该模块的测试台
   （边界行为在整机回归里很难被逼出来）；
3. **接进 `v9/sim/run_all.sh`**，让 CI 自动跑；
4. 在 `v9/sim/README_iverilog.md` 里补一行说明。

---

## 7. 求助 / 认领任务

- **有 bug**：开 Issue，贴 `sim/build/<prog>.log` 的关键行 + 相关 VCD 时间段。
- **想加功能**：先在 Issue / Discussions 里说一声，避免两个人做同一件事。
- **不知道从哪下手**：根 README 的「roadmap」列了 6 个可认领方向，
  其中「跑 `cdp-tests` 47 条全指令表」和「出一份真实综合时序报告」最缺人手。

---

## 8. 许可

本仓库**尚未指定许可证**（见根 README「许可」一节的说明）。
在补上 `LICENSE` 之前，请把贡献视为「仅供本项目内部使用」。
如果你想把自己的 fork 用作其他用途，先开 Issue 问一下作者。
