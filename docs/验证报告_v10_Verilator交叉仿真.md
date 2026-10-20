# v10 验证报告 —— Verilator 交叉仿真 / 覆盖率 / 随机差分

> 本文是 **v10 五项优化**（前端解耦、IROM 门控、MDU 合一 + Radix-4、异常补全、布局策略）的
> **独立验证报告**：用 WSL2 下的 **Verilator 5.020** 与前文的 iverilog 12.0 并行跑同一份 RTL，
> 并补上 iverilog 做不到的三件事 —— 静态 lint、行/翻转覆盖率、随机指令差分（对拍黄金模型）。
>
> 结论先说：**五项优化全部通过验证**；同时**测出一个真实功能缺陷并已修复**
> （DCache 连续 store 丢数据），修完后 18/18 固定用例 + 1000 个随机程序全部通过。
>
> **v10.2 追加（§14）**：按 §11 点名的空白补了定向用例，又抓出 **4 个系统指令区的真缺陷**
> （`csrrc` 语义、CSR 读口无前递、只读 CSR 的 rd 选错源、`fence.i` 跳 `mtvec`），
> 补全了 `csrrw/i·csrrs/i·csrrc/i` 与 `ebreak`；用例从 18 项扩到 **22 项**，
> 交叉验证仍 **22/22 逐行等价**，随机差分仍 **1000 程序 0 失败**，
> 新增的 7 个定向变异**全部被抓到**（`mutate_sys.py`）。
>
> **v10.3 追加（§15）**：把 **Zicsr 的每一条规范原文**逐条对着 RTL 审计（不再靠"想起来"），
> 结果：6 条指令编码早就齐了，但**"什么时候必须报非法指令"和"哪些位可写"这两类约束基本没做**。
> 修了 2 个真缺陷（写只读 CSR 不报非法、访问不存在的 CSR 读回 0）+ 4 处"假实现"
> （`mtval`/`mtime` 可读不可写、`misa` 宏定义了没接线、`mstatus`/`mie`/`mtvec`/`mepc` 无 WARL 掩码）；
> 打掩码时又**自己踩出一个**更隐蔽的错（前递链存 ALU 原值、不过掩码 → 同一 CSR 两条读路径给两个答案，
> §15.7），是新增用例当场抓出来的。用例从 22 项扩到 **23 项**，交叉验证 **23/23 逐行等价**，
> 定向变异 **14/14 全部按预期被抓到**。
>
> 配套文档：`docs/IMPLEMENTATION_v10.md`（实现与面积/时序）、`docs/CPU优化评审_汇总.md`（评审汇总）。
> 全部工具与产物在本仓库 `_diag/vsim/` 下，可原样复跑（§12）。

---

## 0. 结论一览

| # | 检查项 | 工具 | 结果 |
|---|---|---|---|
| 1 | 静态 lint（位宽/悬空/位宽截断） | Verilator `--lint-only` | 8 条，**全部良性**（见 §3） |
| 2 | 未使用信号 / 死参数 | Verilator `-Wall` | 48 条（32 `UNUSEDSIGNAL` + 6 `WIDTHEXPAND` + 6 `PINCONNECTEMPTY` + 2 `UNUSEDPARAM` + 1 `WIDTHTRUNC` + 1 `TIMESCALEMOD`），**挖出 3 处真死代码**（§10）；**0 条 `IMPLICIT`**（v10.2 曾因隐式 1 位网出过真 bug，见 §14.4） |
| 3 | 两套仿真器逐拍等价 | iverilog 12.0 vs Verilator 5.020 | **23/23 等效，周期差 0**（v10.1 18/18 → v10.2 22/22 → v10.3 23/23；§4） |
| 3b | **第三套仿真器**（v10.3 补跑） | ModelSim SE-64 10.5（`sim/run_msim.ps1`） | **23/23 ALL PASS**；`tb_sys` 5 个用例周期数与上面两个**逐拍相同**（§15.11），并抓出缺陷八 |
| 4 | 行覆盖率 | Verilator `--coverage-line` | 固定用例 **48.00%** → 加 40 个随机程序 **73.00%**（§5） |
| 5 | 随机指令差分（黄金模型对拍） | `randtest.py`（自写 RV32IM ISS） | **1000 程序 / 55000 指令 / 0 失败**（§6） |
| 6 | 变异测试（测试有没有牙） | `mutate.sh` / `mutate_sys.py` | 算术：**4 抓到 / 2 按预期抓不到（死代码）**（§7）；系统指令：**14/14 抓到**（§14.5、§15.8） |
| 7 | **真 RTL 缺陷** | 随机差分 + 定向用例 + 规范审计 | v10.1：背靠背 store 丢第二条；v10.2：4 处系统指令缺陷；**v10.3：写只读 CSR 不报非法、访问不存在 CSR 读回 0、前递不过 WARL 掩码** → **全部已修复**（§8、§14、§15） |
| 8 | 验证设施缺陷 | 交叉仿真 + 随机差分 | 4 条已修复（§9）；v10.2 又查出并修了 3 条（§14.6：隐式 1 位网 / PS 5.1 的 GBK 吞行 / 复位释放竞争） |
| 9 | 综合 / 实现（Vivado 2025.2） | `_diag/vivado_noila.ps1` | 综合+布局布线闭环通过，**WNS 见 §14.6 / §15.10**（关键路径在 MDU 乘法器上，不在本轮改动上） |

修复后的最终状态（两套仿真器都跑过）：

- iverilog（Windows）：`[REGRESSION] ALL PASS (23 runs)`，7 个整机程序周期数
  **36/42/94/55/83/110/97** 与 v10 文档完全一致（v10.2/v10.3 的改动**没有改变任何一条指令的节拍**）；
- Verilator（WSL）：同 23 个用例 **全 PASS**，且**功能签名逐行相同、周期差 0**；
- 随机差分：**1000 程序 / 55000 指令 / 0 失败**，含测试台自身断言（write-once / fetch-align / ecall-redirect）；
- 定向系统用例：`tb_sys` 5 个程序共 **64 项检查**（CSR 16 + 中断 9 + fence.i 5 + ebreak 9 + Zicsr 25）。

---

## 1. 环境

| 项 | 版本 / 位置 |
|---|---|
| WSL | Ubuntu（WSL2，kernel 6.6.87.2），root |
| Verilator | **5.020**（apt `verilator`），`g++` + `make` |
| iverilog | **12.0**（Windows `D:\eda_tools\iverilog`，WSL `apt iverilog 12.0`） |
| Python | 3.12（跑黄金模型 ISS，见 §6） |
| 工作目录 | `/opt/v9v`（WSL 原生盘，`_diag/vsim/*.sh` 自动从仓库 rsync） |

> 为什么要挪到 WSL 原生盘：`/mnt/e` 的 9p 文件系统上 Verilator 编译慢 3~5 倍，且 `$readmemh`
> 相对路径最省事。脚本里 `REPO` / `WORK` 两个环境变量可覆盖。

---

## 2. 方法总览

五层，逐层独立，任何一层都能单独打脸：

```
① lint          Verilator --lint-only  -Wall      → 结构性问题（位宽/悬空/死代码）
② 交叉等价      同一 TB 用 iverilog 与 Verilator 各跑同一组用例（v10.1 是 18 个，v10.2 扩到 22 个）→ 逐拍对拍
③ 覆盖率        Verilator --coverage-line/toggle  → 哪些 RTL 从来没被跑到
④ 随机差分      RV32IM 随机程序 + 自写黄金模型 ISS → 32 个寄存器全量比对
⑤ 变异测试      故意注入 6 个缺陷          → 证明④真的能抓错
```

②③④⑤ 的分工：②证明「两套仿真器对同一份 RTL 理解一致」（能抓仿真器语义差异 / 竞争），
③证明「没跑到的地方在哪」，④证明「跑到的路径算得对」（独立黄金模型，不是人工期望值），
⑤证明「④不是瞎的」。

---

## 3. Verilator lint

### 3.1 默认告警：8 条，全部良性

```
WIDTHEXPAND  DCache.sv:101(×3) / :190 / :208     cpu_wen_r 声明成 [1:0]，实际按 1 位用
WIDTHTRUNC   DCache.sv:101                       cache_rd_req 由 2 位 AND 截到 1 位
WIDTHEXPAND  MDU_pipelined.sv:193                div_cnt(5 位) == DIV_ITER-1(32 位常量)
TIMESCALEMOD myCPU.sv:15                         本模块没写 `timescale，子模块写了
```

逐条判断：

- **`cpu_wen_r` 多了一位**（`logic [1:0] cpu_wen_r`，只赋 1 位值）：bit1 恒 0，`~cpu_wen_r` 的
  高位恒 1，与 1 位信号 AND 后截断 → **功能正确，但多一个 FF 的语义噪声**。建议改成 `logic`。
- **`div_cnt == DIV_ITER-1`**：两侧零扩展到 32 位比较，值正确；综合会自动裁到 5 位。
- **`myCPU.sv` 缺 `timescale`**：混合 timescale 在 Verilator 是告警，在部分工具是 error。
  顶层补一行 `` `timescale 1ns/1ps `` 更稳。

> 结论：**没有真实的结构性缺陷**（无 latch 推断、无组合环 `UNOPTFLAT`、无隐式线网 `IMPLICIT`、
> 无多驱动 `MULTIDRIVEN`、无 `always_comb` 内变量未赋值 `LATCH`）。

### 3.2 `-Wall`：35 条 UNUSED（33 信号 + 2 参数），其中 3 处是真死代码

有用的是这几条（完整清单见 `_diag/vsim/out/lint_unused.log`）：

| 位置 | 告警 | 判断 |
|---|---|---|
| `Control.sv:39` | `MEM_Rdata` 输入**从未被使用** | ★ 真死代码：它唯一的上游是 LSU 整条 M1 级 load 扩展链（§10.1） |
| `IDU.sv:253` | `sys_is_special` **既没驱动也没使用** | ★ 纯残留声明 |
| `Control.sv:126-128` | `exu_load_use_dbg` / `mem_load_use_dbg` / `pipe_load_use_dbg` | ★ 调试残留，只赋不读 |
| `CSR.sv:55` | `csr_wen[15:8]` 未使用 | 16 位 CSR 地址译码只有低 8 位有效 → 8 根使能位随流水空转 |
| `Control.sv:81` / `Data_hazard.sv:30,31` | 未使用输入端口 | 接口冗余，可删（要同时改 myCPU 连线） |
| `IFU.sv:77` | `QMAX` 参数未使用 | 参数残留 |
| `myCPU.sv` 多处 | `IDU_a0_value`/`EXU_mdu_done`/`LSU_pc`/`LSU_funct3`/`LSU_Ex_result_pipe`/`exc_pending`/`load_use_stall` | 未接的中间网 |
| `myCPU.sv` | `bp_*_cnt`/`icache_hit`/`icache_miss`/`dcache_hit`/`dcache_miss`/`LSU_Rdata_raw` | **不是死代码**：接到 `board_top_gui.sv` 的 ILA 探针，必须保留 |

> `IFU.advance_en` 也被报未使用，但它是**测试台层次化引用**的观测点（`u_cpu.IFU_Inst0.advance_en`），
> 不能删 —— 这是 lint 的已知盲区（看不到 XMR）。

---

## 4. 交叉仿真等价性：18/18，周期差 0（v10.2 扩到 22/22 → v10.3 23/23，见 §14.7 / §15.8）

> 本节记录 v10.1 那一轮的 18 个用例。v10.2 增加 4 个系统指令用例后是 **22/22 等价、
> `dCYC` 全 0**（含新加的 4 个），那张表在 §14.7。

### 4.1 方法

同一份 RTL、同一个 TB、同一组 plusarg，两套仿真器各跑一遍，然后比**功能签名**：

```
统一顺序：WB 事件序列（pc/inst/ena/reg/val，剥掉 cyc=）       ← 序，逐拍顺序
无序集合：x0..x31 终值 + mepc/mcause/mstatus/mtvec + dram[0x1000]
          + IFU_stall/wb events/store/load/redirects/ICache/DCache/BPU 计数器
          + 每条 [PASS]/[FAIL]/[SKIP] 判定 + [SELFCHECK] 状态
```

`cyc=` 和 `31 / 36` 这种**窗口累加量**从签名里剥掉（原因见 §9.1 与 §9.4：那是 TB 计数器口径，
不是 RTL 语义）。

### 4.2 结果（`_diag/vsim/xcheck.sh cmp`）

```
RUN                        IV_cyc  VL_cyc  IV     VL     dCYC   SIG   VERDICT
tb_dcache_unit.unit        -       -       PASS   PASS   n/a    SAME  ok
tb_exc.illegal             -       -       PASS   PASS   n/a    SAME  ok
tb_exc.misalign            -       -       PASS   PASS   n/a    SAME  ok
tb_exc.jal_misalign        -       -       PASS   PASS   n/a    SAME  ok
tb_iverilog.prog.norm      36      36      PASS   PASS   0      SAME  ok
tb_iverilog.prog.strict    36      36      PASS   PASS   0      SAME  ok
tb_iverilog.prog_mul.norm  42      42      PASS   PASS   0      SAME  ok
tb_iverilog.prog_mul.strict 42     42      PASS   PASS   0      SAME  ok
tb_iverilog.prog_div.norm  94      94      PASS   PASS   0      SAME  ok
tb_iverilog.prog_div.strict 94     94      PASS   PASS   0      SAME  ok
tb_iverilog.prog_load_lane.norm 55 55      PASS   PASS   0      SAME  ok
tb_iverilog.prog_load_lane.strict 55 55    PASS   PASS   0      SAME  ok
tb_iverilog.prog_load_use.norm 83  83      PASS   PASS   0      SAME  ok
tb_iverilog.prog_load_use.strict 83 83     PASS   PASS   0      SAME  ok
tb_iverilog.prog_loop.norm 110     110     PASS   PASS   0      SAME  ok
tb_iverilog.prog_loop.strict 110   110     PASS   PASS   0      SAME  ok
tb_iverilog.prog_div_pair.norm 97  97      PASS   PASS   0      SAME  ok
tb_iverilog.prog_div_pair.strict 97 97     PASS   PASS   0      SAME  ok

runs=18  signature-diffs=0  bad=0
[XCHECK] verdict=EQUIVALENT
```

**18/18 用例的功能签名逐行相同、总周期数完全相同。** 这是比"两边都 PASS"强得多的结论：
两套仿真器对同一条波形、同一批写回事件、同一组架构状态的理解完全一致。
它对**新写的多拍除法器**和**新写的取指队列**尤其有价值 —— 多拍状态机最怕的就是
非阻塞赋值调度顺序差异，而这里一次都没露头。

### 4.3 顺带发现的 iverilog 缺陷（不是本设计的 bug）

`iverilog 12.0` 的 `$display` 遇到非 ASCII 会**把每个 UTF-8 字节展开成 4 字节 `ff ff ff XX`**
（od 实测：`0xE5 0x85 0xA8` → `ff ff ff a8` 且前两个字节被吞），Verilator 则原样输出 UTF-8。
所以：

- TB 里的 `$display` **必须只用 ASCII**（这也是既有 `sim/tb_iverilog.sv` 头部的约定）；
- 交叉比对脚本必须按「第一个非 ASCII 字节截断」再比，否则会得到假 DIFF。

---

## 5. 覆盖率

`verilator --coverage-line --coverage-toggle`，只统计 RTL（`tb_iverilog.sv` 自身排除）：

| 用例集 | 覆盖率 | 说明 |
|---|---|---|
| 18 个固定用例（7 程序 + dcache unit + 3 exc） | **1059/2167 = 48.00%** | 与"固定用例只覆盖了一半 ISA"的直觉一致 |
| 再加 **40 个随机程序** | **1602/2167 = 73.00%** | 提升 25 个百分点，几乎全部来自 ALU/移位/比较/访存宽度 |

对未覆盖行清单（`%000000`）按文件统计的**排序**：

| 文件 | 仅固定用例 | +随机程序 |
|---|---|---|
| myCPU | 59 | 59 |
| CSR | 47 | 47 |
| IDU | 38 | 31 |
| Control | 31 | 27 |
| EXU | 26 | 24 |
| Reg_Stack | 20 | 20 |
| LSU | 20 | 20 |
| IFU | 15 | 13 |
| DCache | 15 | 9 |
| WBU | 11 | 11 |
| ICache | 10 | 10 |
| Branch_Predictor | 11 | 10 |
| **ALU** | **15** | **0** |
| **MDU_pipelined** | **15** | **1** |
| 合计 | 333 | 282 |

> **口径提醒（必须说明）**：Verilator 的 annotate 对**端口/线网/声明行**也会给计数，
> 所以上面这些"0 计数行"包含了 `input ...`/`logic ...` 这类没有语句的行（例如
> `Control.sv:39 input MEM_Rdata` 计 0，但它是"没人读"，不是"没执行"）。
> 因此**只把 always_comb/case 项里的 0 计数当结论**，逐行总数只当排序参考。
> 权威比率用 `verilator_coverage` 自己报的 48.00% / 73.00%。

### 5.1 最有价值的一条：ALU 的一半指令此前从未执行

`cov/annotate/ALU.sv`（固定用例），计数是十六进制命中数：

```
 000399      `alu_add:            // 921
 000061      `alu_signed_comparator:  // slt
 000008      `alu_equal:
%000000      `alu_unsigned_comparator:  ← sltu  从未执行
%000000      `alu_xor:                    ← xor   从未执行
%000000      `alu_sll:                    ← sll/slli 从未执行
%000000      `alu_srl:                    ← srl/srli 从未执行
%000000      `alu_sra:                    ← sra/srai 从未执行
%000002      `alu_sub:                    // 只 2 次
```

也就是说：**原来的 18 个用例几乎没用过移位、异或、无符号比较**。这不是"设计错了"，而是
"验证不足" —— 而这正是 §6 随机差分存在的理由（加随机程序后 ALU 未覆盖行 15 → 0）。

---

## 6. 随机指令差分（黄金模型对拍）

### 6.1 为什么要自己写黄金模型

两套仿真器对拍只能抓"仿真器理解差异"，抓不到"两边都错"。所以 `_diag/vsim/randtest.py`
里带了一个**独立实现的 RV32IM 解释器**（约 200 行 Python），随机程序的期望值由它算，
不是人工填表。

### 6.2 程序生成策略（可停机是硬约束）

- 覆盖 RV32I 整数全表 + RV32M：`add/sub/and/or/xor/sll/srl/sra/slt/sltu`、
  `addi/andi/ori/xori/slli/srli/srai/slti/sltiu`、`lui/auipc`、
  `lb/lh/lw/lbu/lhu`、`sb/sh/sw`、`beq/bne/blt/bge/bltu/bgeu`、`jal`、`jalr`、
  `mul/mulh/mulhsu/mulhu/div/divu/rem/remu`；
- **只允许前向控制转移**（`+4/+8/+12`，分支用 `beq x5,x5`——恒跳 / `bne x5,x5`——恒不跳，
  不依赖数据），所以程序**必然前进、必然停在末尾的 `ECALL`**，不会死循环；
- 尾部固定 `AUIPC x28,0` + `JALR x29,8(x28)`，正好测到"auipc 取值 + jalr 跳转 + 链接"；
- `x28`（auipc 基址）与 `x31`（数据区基址 0x2000）不做随机目的寄存器，避免地址变野；
- 种子寄存器有 1/3 概率取 MDU 边界值（0 / 1 / -1 / INT_MIN / INT_MAX / 0x7FFF / -32768），
  **专门打除零、INT_MIN÷-1、有符号/无符号乘高处**。

### 6.3 结果

```
[RANDTEST] programs=1000  instructions=55000  failures=0
[RANDTEST] verdict=PASS
```

每个程序比 **32 个通用寄存器全部**（1000×32 = 32000 次寄存器级比对），
并且同时检查测试台自己的断言（write-once / fetch-align / ecall-redirect）。

> 这条测试**抓到过 2 次真问题**：一次是 §8 的背靠背 store 缺陷，一次是我自己 ISS 的
> LB 符号扩展写错（RTL 是对的）。两个方向都出现过，说明对拍是双向可信的。

---

## 7. 变异测试：证明随机差分"有牙"

`_diag/vsim/mutate.sh`：给每个变异**声明期望结果**，全部符合才算有效。

| 变异 | 位置 | 期望 | 实测 |
|---|---|---|---|
| `sra_as_srl` | `ALU.sv` 算术右移 → 逻辑右移 | caught | **FAIL（3 个程序）** |
| `mdu_div_q_bit2` | `MDU_pipelined.sv` radix-4 第 2 位商用成第 1 位 | caught | **FAIL（3）** |
| `mdu_div_ge2` | `MDU_pipelined.sv` 第 2 级试减 `<=` 边界差一 | caught | **FAIL（2）** |
| `lbu_wbu_live` | `WBU.sv` LBU 零扩展 → 符号扩展（**活代码**） | caught | **FAIL（1）** |
| `lbu_lsu_m1` | `LSU.sv` M1 级 LBU 扩展 | missed | PASS（0） |
| `lbu_lsu_wb` | `LSU.sv` M3 级 LBU 扩展 | missed | PASS（0） |

后两条 `missed` **不是漏洞，是证据**：load 的字节/半字扩展在 RTL 里写了三份，只有 WBU 那份
生效（改它立刻被抓），LSU 里两份改了毫无反应 → 那两份是死代码（§10.1）。
除零/溢出/INT_MIN 这些边界也由 `mdu_*` 两个变异顺带证明"随机程序确实打到了除法器内部"。

---

## 8. ★ 发现并修复的真 RTL 缺陷：背靠背 store 丢数据

### 8.1 现象与最小复现

随机差分在 1000 个程序里报了 3 个不一致，最小化后得到一个 **3 条指令**的复现
（`_diag/vsim/probe_store.py` 的 A 变体）：

```asm
sh  x23, 174(x31)     # x31 = 0x2000，存半字 0xFC18
sb  x6,  168(x31)     # 紧接着存字节 0x3F
lb  x16, 168(x31)     # 读回 → 期望 0x3F
```

实测：读回 **0**。总线级波形（`_diag/vsim/dbg_store.sh` 打的 `perip_wen` 监视）：

```
[DST]  t=185000 store_fire addr=000020ae          ← 第 1 条 store 有 fire
[BUS-W] t=195000 addr=000020ae wdata=fffffc18 mask=01
[BUS-R] t=215000 addr=000020a8                    ← lb 的读
[WB ]  cyc=17 pc=... lb reg=x16 val=00000000      ← 读到 0
                                                  ← 第 2 条 store 一次 fire 都没有！
```

**第二条 store 从来没有上过总线。**

### 8.2 根因

`rtl/DCache.sv` 原来用一个三态状态机给 store 生成单拍脉冲：

```systemverilog
localparam WR_IDLE = 2'd0, WR_ISSUE = 2'd1, WR_WAIT = 2'd2;
assign store_fire = cpu_en & cpu_wen & (store_state == WR_IDLE);   // ← 只有 IDLE 才发
case (store_state)
  WR_IDLE:  if (cpu_en & cpu_wen) store_state <= WR_ISSUE;
  WR_ISSUE: if (cpu_en & cpu_wen) store_state <= WR_WAIT; else store_state <= WR_IDLE;
  default:  if (!(cpu_en & cpu_wen)) store_state <= WR_IDLE;       // ← 只有"空一拍"才回 IDLE
endcase
```

状态机只在"出现一拍没有 store"时回到 `WR_IDLE`，于是**两条背靠背的 store 里第二条永远等不到
IDLE，脉冲被吞掉、数据被静默丢弃**（不报错、不重放）。同理任何连续 store 序列只有第一条生效。

为什么原来没被发现：旧的三条回归程序里 `sw` 只有孤立的一条；`tb_dcache_unit` 也是单条激励。
**这类"相邻同类操作"的缺陷，固定用例几乎不可能覆盖到，必须靠随机程序。**

### 8.3 修复（两个方向的坑都踩过）

第一版修复直接写 `store_fire = cpu_en & cpu_wen`（纯电平）→ 随机差分立刻报出
**294/1000 个程序"同地址连写 4 拍"**（被测试台 write-once 断言抓到）：因为 `cpu_en/cpu_wen`
是**电平**，MDU 忙 / 下游不就绪时同一条 store 会保持多拍。

最终修复 = **用"本拍这次访存是否真的被受理"来判定**：

```systemverilog
// DCache.sv：新增端口 cpu_adv
assign store_fire = cpu_en & cpu_wen & cpu_adv;

// myCPU.sv：与 LSU 内部推进条件同式（lsu_freeze = mem_hold | mdu_busy）
assign lsu_adv = WBU_ready & ~dcache_hold & ~EXU_mdu_busy;
```

状态机整体删除（连同 2 个状态 FF）。三条判据缺一不可：

| 写法 | 背靠背 store | 冻结期间（MDU 忙） |
|---|---|---|
| 纯电平 `cpu_en & cpu_wen` | ✅ 两条都写 | ❌ 同一条写 4 次 |
| 三态状态机 | ❌ 第二条丢失 | ✅ 只写 1 次 |
| **`& cpu_adv`（本修复）** | ✅ 两条都写 | ✅ 只写 1 次 |

### 8.4 修复后的验证

| 检查 | 结果 |
|---|---|
| `probe_store.py` A/B/C/D（连续 store、同字内 sh+sb、除法后连续 store） | 全部 OK（修复前 A/C/D 全错） |
| iverilog 固定回归 18 用例 | **ALL PASS**，周期数 36/42/94/55/83/110/97 **一字不差** |
| Verilator 交叉 18 用例 | **EQUIVALENT，dCYC=0** |
| 随机差分 1000 程序 / 55000 指令 | **0 失败**（含 write-once 断言） |

> 影响面：这是**会静默破坏程序正确性**的缺陷（相邻两次写内存，后一次丢失），
> 在真实软件里表现为"某些全局变量/数组元素莫名不更新"。它不在 v10 五项优化的范围内，
> 是这轮验证**顺带挖出来的**。

---

## 9. 发现并修复的验证设施缺陷（4 条）

工具换了一套，才暴露出这些"测试台自己错了"的问题。它们不改变 RTL，但会让回归结论失真。

### 9.1 复位释放竞争：两套仿真器整体差 1 拍

`tb_iverilog.sv` / `tb_exc.sv` / `tb_msim.sv` 原来都写成：

```systemverilog
repeat (8) @(posedge clk);
rst = 1'b0;                    // ← 时钟沿"同一时刻"用阻塞赋值拉低
```

这等于在时钟沿那一瞬改复位，各 `always_ff` 是否看到新值取决于进程调度顺序（LRM 不保证）。
实测：**iverilog 的 FF 在那一拍仍看到 rst=1，Verilator 看到 rst=0**，于是整条流水线整体差 1 拍
（首个 WB 事件 `cyc=10` vs `cyc=9`），而所有功能结果一致 —— 典型复位竞争。

修复：`repeat (8) @(posedge clk); @(negedge clk); rst = 1'b0;`。
修复后两套仿真器**周期差 0**（§4.2），且 iverilog 的 36/42/94/55/83/110/97 一个没变
（说明只消除了竞争，没改变行为）。

### 9.2 `// Verilator` 被当成元注释指令

`sim/tb_iverilog.sv` 里有一行注释以 `//   Verilator 会把...` 开头。Verilator 的元注释语法是
`/*verilator ... */` **或** `// verilator ...`（关键字前后可带空白、大小写不敏感），于是它把整行
当成未知指令直接报错：

```
%Error: sim/tb_iverilog.sv:729:9: Unknown verilator comment: '/*verilator ...'
```

iverilog / Vivado 完全不介意，所以这个问题只有在 Verilator 下才暴露。三处已改成 `// - Verilator`
（`tb_iverilog.sv`、`tb_msim.sv`、`experimental/MDU_tb.sv`）。

### 9.3 write-once 断言只比地址 → 误判合法程序

`tb_iverilog.sv` 的断言①原来只看 `perip_addr` 是否连续两拍相同。修复 §8 之后，
**两条写同一个字的不同 store**（例如 `sh x6,0(x2)` 紧跟 `sb x7,2(x2)`）会合法地连续两拍拉高
`perip_wen`，于是断言把它误判成"重复写"：1000 个随机程序里 3 个假失败。

修复：比较 **(地址, 数据, 掩码) 三元组** —— 真正的重复写三者全同。改完后同一个断言仍然能抓到
第一版修复引入的"连写 4 拍"（294/1000），所以灵敏度没有下降。

### 9.4 GPR 快照窗口对"末尾 load"太短

`tb_iverilog.sv` 的快照时刻固定在 **ecall 进 ID 那一拍 + 8**（`DRAIN_CYCLES`）。而一条 load
会让访存流水多停 1~2 拍，所以当 ecall 前面紧邻 load 时，**最后那条 load 的写回可能落在窗口外**，
快照少读一个寄存器（实测：`probe_store.py` E 变体，load 写回 `cyc=20`，快照在 `cyc=19`）。

处理方式：**不动 TB 的快照口径**（36/42/94/… 这些数字都基于它，改口径会让全部历史数字失效），
而是在随机程序末尾固定补 4 条 ALU 指令（`randtest.py` 里有注释说明），把 ecall 推后 4 拍。
固定用例不受影响（它们 ecall 前面没有 load）。

> 这条列入"TB 已知局限"：如果以后要加大规模 load-heavy 用例，正确做法是把快照点改成
> "ecall 自己的 WB 事件那一拍"，而不是继续调大 `DRAIN_CYCLES`（调大就会采到 post-trap 重启
> 的写回，反而污染快照）。

### 9.5 附加：Verilator 5.020 的 `--binary` 不写覆盖率文件

`--binary` 自动生成的 `main()` 是 `eval 循环 → final() → return 0`，**没有** `VL_COVERAGE_SAVE()`，
所以加了 `--coverage-line` 也永远拿不到 `coverage.dat`。改用 `--cc --exe` + 自写 `main`
（`_diag/vsim/covmain.cpp`，末尾 `coveragep()->write($VCOV_FILE)`），覆盖率才落地。

---

## 10. 死代码清单（建议下一轮清理）

综合已经把无读者逻辑裁掉，所以清理这些**不影响面积/时序**，纯粹是可维护性 ——
但它们会误导阅读者（例如 §7 那两条"变异改不动"的 LSU 扩展链）。

### 10.1 ★ LSU 里整条 load 扩展链（最大一处，约 80 行 + 4 个 sext 实例）

证据链：

1. `LSU.sv:176 assign LSU_Rdata = rdata_ex;` —— `rdata_ex` 由 M1 级
   `rdata_byte_sel/rdata_half_sel` + `sext_i8/sext_i16` + `rdata_8i/16i/8u/16u` 产生；
2. `LSU.sv` 里还有一份 M3 级的同构拷贝（`rdata_*_2`、`sext_i8_2/sext_i16_2`、`rdata_wb2`）；
3. 但 `LSU_Rdata` 的唯一读者是 `myCPU.sv:405 .MEM_Rdata(LSU_Rdata)` → `Control.MEM_Rdata`，
   而 **Control 从来没有读过这个输入**（Verilator `-Wall` 明确报 `UNUSEDSIGNAL`）；
4. 真正生效的是 `WBU.sv:141-150` 的那份扩展（`rdata_wb` → `rd_value_next`）—— 变异它立刻被抓。

可删清单：`rdata_byte_sel/half_sel`、`rdata_byte_sel2/half_sel2`、`rdata_8i/16i/8u/16u`、
`rdata_8i2/16i2/8u2/16u2`、`rdata_ex`、`rdata_wb2`、`sext_i8/sext_i16/sext_i8_2/sext_i16_2`、
`LSU_Rdata` 端口、`Control.MEM_Rdata` 端口、`myCPU` 对应连线。

### 10.2 其它

| 位置 | 内容 | 处理 |
|---|---|---|
| `IDU.sv:253` | `sys_is_special` 声明后既没驱动也没使用 | 删声明 |
| `Control.sv:126-128` | 三个 `*_load_use_dbg` 只赋不读 | 删 |
| `Control.sv:81` | `EXU_mem_misalign_funct3` 输入未使用 | 删端口（非对齐判别改用 opcode，见 v10 §4） |
| `Data_hazard.sv:30,31` | `IDU_valid` / `EXU_valid` 输入未使用 | 删端口 |
| `CSR.sv:55` | `csr_wen[15:8]`、`CSR_WIDTH` 参数未使用 | 收窄到 8 位（要同时改 LSU/WBU 的流水位宽） |
| `IFU.sv:77` | `QMAX` 参数未使用 | 删 |
| `DCache.sv:73` | `cpu_wen_r` 声明成 `[1:0]`，只按 1 位用 | 改 `logic` |
| `myCPU.sv:15` | 缺 `timescale` | 补 |

---

## 11. 覆盖率点名时"完全没跑过"的四块（v10.2 已补）

1000 个随机程序之后仍有 27% 的覆盖率点没打上。当时按"最该补"排了四块，**v10.2 已全部补上**
（做法与结果见 §14）：

| # | v10.1（§11 原文） | v10.2 |
|---|---|---|
| 1 | **中断通路完全没测**：`intr_take` 从来没被激励过，`mtime` / `mie & mip` / `mstatus.MIE·MPIE` 硬件翻转全是空白 | `sys_intr.hex`：MSI 一次 + MTI 一次，验证 `mcause=0x8000_0007`、`mepc` 指向**未执行**的那条（累加和 55 = 被打断的指令真的重执行了）、`mstatus=0x1880` |
| 2 | **CSR 软件写路径**：只验过 `csrw mepc`+`mret`；`mscratch`/`mtvec` 改写、`csrrs`/`csrrc` 的置位/清位、`csrr` 的软件读都没进回归（且 `csrrc` 语义是错的） | `sys_csr.hex` 16 项检查覆盖六种形式 + 写后读前递 + 只读 CSR；顺带修掉 3 个缺陷（§14.1~14.3） |
| 3 | **`fence` / `fence.i`**：`fence.i` 跳 `mtvec` 而不是 `pc+4`，且无用例触发 | 修掉并验证（§14.4）：3 次 `fence.i`、每次 `dnpc == EXU_pc+4`、`icache_clr` 3 次 |
| 4 | **`ebreak` / `wfi`**：未测 | `ebreak` → `mcause=3`、`mepc=mtval=PC`（§14.5）；`wfi` 按"合法空操作"放过并**明确记录**为已知偏差 |

**仍然没有验证的（下一轮）**：

1. **`csrrw` 写只读 CSR 不退陷**：规范要求写只读/未实现 CSR 报非法指令，本核是"静默忽略"
   （`csr_onehot==0` 就不产生写位）。这是**已知偏差**，要改只需在 IDU 加一项
   `csr_op & csr_wr & (csr_onehot==0)`，但会让"读写未实现 CSR"从无害变成陷入，属语义收紧，
   本轮没动。
2. **自修改代码**：本设计的 IROM（取指）与 DRAM（数据）是两块独立存储，软件**无法**改指令，
   所以 `fence.i` 只验了"清 I-Cache + 顺序继续"，没验"改完代码立刻取到新指令"。
3. **中断优先级仲裁**：`MEI(11) > MSI(0) > MTI(7)` 的 if 链顺序从未被"两个同时挂起"激励过
   （`meip` 恒 0，硬件上没有外部中断源）。
4. **`prog_loop` 每轮仍误预测 1 次**（PHT 初值 `2'b01`、无跳转旁路），属已知性能项。

---

## 12. 复现命令（全部在 WSL 里跑）

```bash
# 0) 一次性环境（root）
apt-get install -y verilator iverilog python3

# 1) lint
bash _diag/vsim/xcheck.sh build          # 顺带把两套仿真器都编好

# 2) 两套仿真器交叉等价（22 用例；跑完打印 dCYC / SIG / VERDICT 表）
bash _diag/vsim/xcheck.sh all

# 3) 覆盖率（固定用例 + 40 随机；NRAND 可调）
NRAND=40 bash _diag/vsim/cov.sh

# 4) 随机差分（黄金模型对拍；-n 程序数，-v 逐条打印）
python3 _diag/vsim/randtest.py -n 1000

# 5) 变异测试：算术语义（4 caught + 2 missed 死代码）
bash _diag/vsim/mutate.sh 100

# 5b) 变异测试：系统指令（7 个变异，判据 = tb_sys 的 4 个定向用例）
python3 _diag/vsim/mutate_sys.py

# 6) §8 缺陷的最小复现（修复前 A/C/D 会 DIFF）
python3 _diag/vsim/probe_store.py

# 7) 总线级信号追踪（临时改 TB 副本，不动仓库文件）
bash _diag/vsim/dbg_store.sh /opt/v9v/rand/r00392.hex
```

Windows 侧（v10.3 起 23 runs，含 5 个系统指令用例）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\regress.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sim\run_msim.ps1            # ModelSim，23 项
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\vivado_noila.ps1 -Mode default   # 综合+实现
```

产物归档在 `_diag/vsim/out/`：`results.tsv`、`uncovered.txt`、`uncovered_all.txt`、
`annotate/`（逐行覆盖标注）、`lint_wall.log`、`lint_v102.log`、`lint_v103.log`、`probe*.log`、
`rand1000*.log`、`mutate_final.log`、`mutate_sys.log`、`cov_final.log`、`logs_xcheck.tgz`（44 份仿真日志）。
Vivado 报告在 `project_src/`：`util_noila_{synth,route}.default.rpt`、`timing_noila.default.rpt`、
`timing_noila_worst.default.rpt`。

---

## 13. 局限与没做的事

- **带 ILA 的实现跑不了**（本机沙箱 fork 受限，见 `_diag/vivado_env.ps1`；v10.2 这轮虽然拿到了
  完整权限，但上一轮尝试在 `opt_design → Phase 1.1.1 Generate And Synthesize Debug Cores`
  生成 `dbg_hub` 时挂死 15 分钟以上，本轮没有再试），所以时序 A/B 用的是**无 ILA 顶层**
  （`_diag/noila_top.sv`），绝对值不能与含 ILA 的历史数字直接比。
- **ModelSim 流程（v10.3 已补跑，见 §15.11）**：`sim/run_msim.ps1` 扩成 23 项
  （v9 的 7 程序×2 + D-Cache 单元测试 + 新增 `tb_sys`×5 + `tb_exc`×3），
  在 ModelSim SE-64 10.5 上 **23/23 ALL PASS**；`tb_sys` 的 5 个用例周期数与
  iverilog/Verilator **逐拍相同**。
  ⚠ 更正：本文 §14 曾写"本机没有 ModelSim，未验证" —— **那句是错的**，
  ModelSim 一直在 `E:\FPGA\ModelSim_10.5se\win64\`，`sim/README_msim.md` 里记着 v9 的结果。
  第一次跑 ModelSim 就抓出一个真缺陷（`IDU.sv` 三根信号先用后声明，vlog 直接拒绝编译），
  详见 §15.11.1 —— 这条顺带说明"两个仿真器都过"不等于"代码合法"。
- **随机差分不测异常/CSR/中断**：随机程序只用合法编码、对齐地址、不碰 CSR。
  `randtest.py` 的黄金模型里连 `mcause` 都没有 —— 这几块由 `tb_exc`（20 项）+ `tb_sys`
  （**64 项**：CSR 16 / 中断 9 / fence.i 5 / ebreak 9 / Zicsr 25）的定向用例覆盖，
  属于"用例驱动"而不是"随机驱动"，覆盖面靠**对着规范逐条抄**来保证（v10.3 的做法，见 §15.1）。
- **黄金模型只做架构状态比对**：不比周期数（周期数由 iverilog ↔ Verilator 交叉保证）。
- **面积/时序只测了 default 一种实现策略**：v10 那一轮跑过 `strategy` / `synth_only` /
  `fanout_only` 四种对照（见 `IMPLEMENTATION_v10.md` §6.6），v10.2 只重跑了 `default`
  （目的是给"修复后"一个新数字，不是重新做策略对照）。
- **`tb_sys` 的中断用例依赖"中断落在哪条指令"**：它能证明"被中断的指令会重执行"
  （累加和必须等于 55），但**不检查 `mepc` 的具体值**（那个值取决于实现时序），
  只检查它落在主程序地址范围内。

---

## 14. v10.2：把 §11 点名的空白补上 —— 抓出 4 个真缺陷

§11 说过"中断、CSR 软件写、`fence`/`fence.i`、`ebreak` 从来没被执行过"。这一轮先补用例
（4 个定向程序 + 一个专用测试台）。

**★ 诚实交代发现方式**：4 个缺陷里**只有第 1 个（`csrrc`）是补完用例当场跑红的**，
另外 3 个是**写用例时读代码判定的**（这套 RTL 的注释很全，顺着"CSR 读口 / `dnpc` 仲裁 /
`|csr_wen` 的三种用法"读一遍就看得见）。为了让"读出来的缺陷"也能被**可复现地**证明，
每个都补了一个定向变异（`_diag/vsim/mutate_sys.py`）：把修复回退掉 → 用例必须红。
下面的"现象"因此分两类：**实测红** 与 **变异复现**，逐条标出。

新增文件：

| 文件 | 作用 |
|---|---|
| `sim/gen_sys_progs.py` | 生成 4 个定向程序（纯 Python 汇编，无外部工具链） |
| `sim/sys_csr.hex` | CSR 六种形式（rw/rs/rc × 寄存器/立即数）+ 写后读 + 只读 CSR |
| `sim/sys_intr.hex` | 机器软件中断（MSI）+ 机器定时器中断（MTI），各一次 |
| `sim/sys_fencei.hex` | `fence.i` 顺序继续（含循环里的 `fence.i`） |
| `sim/sys_ebreak.hex` | `ebreak` → `mcause=3`，`mepc=mtval=ebreak` 的 PC |
| `sim/tb_sys.sv` | 上述 4 个程序的判据台（39 项检查，全部走顶层 debug 口 + XMR 读现场） |
| `_diag/vsim/mutate_sys.py` | 7 个定向变异，证明这 39 项检查**真的能抓到缺陷** |

### 14.1 ★ 缺陷一：`csrrc` 写进 CSR 的是 `rs1 + CSR 地址`

**现象**（`tb_sys +kind=csr` 第一次运行，16 项里 4 项失败）：

```
  regs  : x5=00000000 x6=00000001 x7=12345678 x8=12345678 x9=1234f678 x11=1234f678
          x12=00000000 x13=00000000 x14=00000000 x15=0000001f x16=0000001f x17=00000000
  [FAIL] csrrc rs1=x0 is pure read
  [FAIL] csrrc cleared only the given bits
  [FAIL] csrrwi returns old value
  [FAIL] csrrci clears bit1 -> 29
```

读**之前**的旧值都是对的（`x11=0x1234F678`），从 `csrrc x11` 这一条**写**下去之后，
`mscratch` 就被写成了垃圾值，后面所有读（x12/x13/x14/x17）跟着全错。

**根因**（`rtl/IDU.sv`）：

1. `csrrc` 的 funct3 = `011`，而 `cond_add/signed/unsigned/xor/or/and/...` 里**没有一档**
   匹配 `funct3==011`，于是 `alu_opcode` 落到链尾的默认值 `alu_add`；
2. 同一处 `add_src2` 只处理了 `funct3==001`（取 0）和 `funct3==010`（取 CSR 旧值），
   `011` 落到了 `imm` 分支 —— 而 `imm` 在这条指令上是 **`csr_addr`**（`imm_I = inst[31:20]`）。

所以 `csrrc` 写回去的值是 `rs1 + csr_addr`，**既不是**规范要求的 `csr & ~rs1`，
也完全脱离了原值。

**修法**：给 ALU 加一档"清位"`alu_bitclr = 5'b01011`，IDU 把三种 CSRRC 形式统一映射到
`d1 = 源操作数（rs1 或 uimm）`、`d2 = CSR 旧值`，于是新值 = `旧值 & ~源`。

**这里又踩了一次坑（被同一条用例抓到）**：第一版把 ALU 那档写成 `d1 & ~d2`（"字面更顺"），
于是 `csrrci x16, mscratch, 2` 算成 `2 & ~31 = 0` —— **清一位**变成了"只留这一位的反"，
mscratch 被写成 0。`tb_sys` 的 `csrrci clears bit1 -> 29` 一项直接报 FAIL。
所以这一档的名字与注释都写死了操作数顺序（`d2 & ~d1`、`d1_inv` 复用 sub/xor 的反相器）。

### 14.2 ★ 缺陷二：CSR 读口没有 RAW 前递（静默读旧值）

**发现方式**：这一条不是"跑红了"才发现的，而是**读代码时判定必然发生**（读口与写口差三级、中间
只有 `mepc` 有专门前递）；随后 `mutate_sys.py` 的 `csr_no_read_fwd` 变异把它变成可复现的失败 ——
`csrw mscratch, x1` 紧跟一条 `addi` 再 `csrr x7, mscratch`，`x7` 就是**旧值**。

**根因**：CSR 的读口在 ID 级组合读出，写口在 WB 级才落盘，两者天然差三级；v10 只给
`mret` 读 `mepc` 做了前递（C10 的 4 深影子链），**普通的 `csrr/csrrs/csrrc` 走的是
`Reg_Stack` 里那排纯组合 mux**，没有任何前递。

**修法**（复用现成结构，不新增状态）：把 C10 的影子链变成通用前递 —— IDU 把
"本拍要读哪个 CSR"的**独热码**（`csr_sel`，位映射与 `csr_wen` 完全一致）送给 Control，
Control 用 `|(在途写位图 & 读选通)` 判命中，按
`EX 级 > sh[0]=M1 > sh[1]=M2 > sh[2]=M3 > sh[3]=WB > 寄存器本体` 的优先级挑出**最新一次在途写**
的值（`csr_rd_fwd`/`csr_rd_fwd_en`），IDU 用它覆盖 `csrs`。

- 命中判据必须用**写位图**而不是"这是 CSR 指令"标记（见 §14.3），否则纯读会被当成写；
- 多档同时命中时"最新的赢"，与既有 `mepc_fwd` 的覆盖顺序严格一致；
- 只影响**读值**，不改变"写在哪一级落盘"，所以不带任何新的暂停/冒险。

### 14.3 ★ 缺陷三：读只读 CSR 时 `rd` 选的是"新值"而不是"读值"

**发现方式**：同上，读代码时发现的（三处下游都拿 `|csr_wen` 当"这是 CSR 指令"用）；由
`csr_no_marker` 变异复现：`csrrs x18, mvendorid, x4`（x4=0x7EF）读回 `0x79737FFF`
（`0x7EF | 0x79737978`，即 `Ex_result`），而正确值是 `0x79737978`。

**根因**：下游三处（`WBU.wb_sel_jmp_csr`、`LSU` 的两级 `forward_val`、`myCPU` 的两级前递选择）
都用 **`|csr_wen`** 判"这是不是 CSR 指令、`rd` 该取 `csrs` 还是 `Ex_result`"。而
`csr_wen` 是**写使能**位图：读 `mvendorid`/`marchid`/`mtime`/`mtval`/`misa` 时**没有任何写位**，
`|csr_wen == 0` → `rd` 取 `Ex_result`，而 `Ex_result` 对 `CSRR*` 只是"准备写进 CSR 的新值"。

**修法**：`csr_wen` 的 **bit8** 定义成"本拍这条指令是 CSR 指令"标记（`CSRW_OP`），
读也置位；`CSR.sv` 只认 bit0..bit7，对这一位完全透明。这样 `|csr_wen` 严格等于
"是 CSR 指令"，与"要不要写"解耦。

### 14.4 ★ 缺陷四：`fence.i` 把 PC 拨到 `mtvec`（整机级别）

**现象**（变异复现）：把 `dnpc` 的这一档改回 `mtvec_out`，`tb_sys +kind=fencei` 立刻报
`fence.i did not jump to mtvec`，且 `icache_clr` 的那几次 `dnpc` 断言全部失败。
真实后果：任何含 `fence.i` 的程序，执行到它就跳进异常处理程序；`mtvec` 默认 0 时就是**整机重启**。

**根因**：`Control.sv` 的 `dnpc` 三元链把 `fence.i` 落在了最后一个分支上：
`intr ? mtvec : bp_mispredict ? … : (mret ? mepc_fwd : mtvec_out)` ——
`fence.i` 既不是中断也不是 `mret`，于是取到了 `mtvec_out`。
而 `fence_i_flag` 本来就在 `system_redirect` 里（会发 `dnpc_flag` 冲刷流水），
所以现象不是"没反应"，而是"干干净净地跳错了地方"。

**修法**：`dnpc` 里给 `fence.i` 单独一档，目标是**它自己后面的那条指令**：
`fence_i_flag ? (EXU_pc + 32'd4) : …`。`fence_i_flag` 来自 EX 级（`EXU_fence_i_flag`），
`EXU_pc` 正是这条 `fence.i` 的 PC，不需要新增端口。
`tb_sys +kind=fencei` 逐次检查 `icache_clr` 脉冲（3 次）并且断言
**每一次的 `dnpc` 都等于 `EXU_pc+4`、且从不等于 `mtvec`**。

### 14.5 顺带补全/收紧的三处（对着规范核代码发现的）

这一节不是"发现缺陷"，而是补用例时**对着规范把这三条对了一遍**，发现要么缺、要么松：

| 项 | v10.1 行为 | v10.2 |
|---|---|---|
| `csrrwi/csrrsi/csrrci`（funct3 101/110/111） | **判非法**（`legal_sys` 只允许 000..011）→ 一陷入，整机就跑飞 | 正常实现（`rs1` 域当 5 位零扩展立即数） |
| `csrrs/csrrc` 的 `rs1=x0`（纯读） | 照样写 CSR（`csrrc mip, x0` 会把 mip 清 0） | 规范语义：**源为 0 就不写**；`csrrw` 恒写 |
| SYSTEM `funct3=000` 的合法性 | "funct3=000 一律合法" → `sret`/`dret`/任意编码都被当空操作放过 | 只认 `ecall/ebreak/mret/wfi` 四条完整编码，其余判非法 |
| `ebreak` | 当合法空操作静默执行 | `mcause=3`、`mepc=mtval=ebreak 自己的 PC`，走既有陷入通路（复用 `trap_cause[0]`，不新增第 5 个异常位） |

★ 顺带的等价优化：这 5 条特权指令原来各用**一个 32 位全宽相等比较**（5×32 位），
但它们的 `opcode/funct3/rs1/rd` 都固定，真正的自由度只有 `imm[11:0]` ——
改成"固定字段判一次 + 12 位比较"后是等价的（12+5+5+3+7 = 32 位全覆盖），
面积少 **13 LUT**。⚠ 但**时序没有跟着变好**：两次实现的 WNS 是 3.078 → 2.203，
更差的正好是面积更小的那次 —— 原因见 §14.7 的归因（关键路径在 MDU，不在 IDU）。

### 14.6 本轮自查出来的 3 个验证设施 bug（都是"设施骗人"，不是 RTL）

| # | 问题 | 症状 | 修法 |
|---|---|---|---|
| 1 | `IDU.csrs_rd` **漏声明** | Verilog 按隐式 **1 位** wire 处理，`rd_value_next` 只拿到 CSR 读值的 bit0 → `csrrs x21, mepc` 读回 0、handler 把 `mepc` 写成 4 → `tb_exc` 三个用例全红 | 显式 `logic [31:0] csrs_rd;`，并在注释里写明这个坑；lint 侧加查 `IMPLICIT`（当前 0 条） |
| 2 | `_diag/regress.ps1` 里写了中文注释 | Windows PowerShell 5.1 把**无 BOM** 的 `.ps1` 按 GBK 解码，UTF-8 的中文注释吃掉了**下一行**（`$sysFiles = …` 整行消失）→ iverilog 报 `no source files` | `_diag/*.ps1` 保持**纯 ASCII**（脚本里已写死这条约定） |
| 3 | `tb_sys` 复位释放竞争 | `@(negedge clk); rst=0;` 那一沿"采样块看到 0 还是 1"是竞争（iverilog 与 Verilator 调度不同）→ 计数器整体差 1，`dCYC=-1` | 改成 `@(negedge clk); #1 rst = 0;`，`dCYC` 归零 |

### 14.7 结果

**iverilog 回归（Windows，22 项）**

| 用例 | 周期 | 结果 |
|---|---|---|
| prog / prog_mul / prog_div / prog_load_lane / prog_load_use / prog_loop / prog_div_pair ×{norm,strict} | 36/42/94/55/83/110/97 **（与 v10 一字未变）** | 14/14 PASS |
| tb_dcache_unit | — | PASS |
| tb_exc ×3（illegal / misalign / jal_misalign） | — | 3/3 PASS |
| **tb_sys ×4（csr / intr / fencei / ebreak）** | 40 / 82 / 46 / 39 | **4/4 PASS，39 项检查** |

**交叉验证（`xcheck.sh all`，22 项）**：`runs=22 signature-diffs=0 bad=0 verdict=EQUIVALENT`，
`tb_iverilog` 的 14 项 `dCYC=0`，4 个系统用例 `dCYC=0`（修掉 §14.6-3 之后）。

**随机差分**：`programs=1000 instructions=55000 failures=0`（v10.2 的改动不影响 RV32IM 路径）。

**变异测试（`mutate_sys.py`）**：7 个定向变异**全部被抓到**，且都是被**指定的那一个**用例抓到
（其余 3 个用例仍 PASS），说明这 39 项检查是定向的、不是"整机崩了才报"：

| 变异 | 抓到它的用例 | 抓到的判据 |
|---|---|---|
| `csrrc` 退回 `alu_add` | csr | `csrrc rs1=x0 is pure read` |
| CSRR* 纯读也写 | **intr**（不是 csr！） | `two interrupts taken` |
| 去掉 bit8 标记 | csr | `read-only CSR with rs1!=0 -> readval` |
| 去掉 CSR 读口前递 | csr | `csrr right after csrw sees new (fwd)` |
| 立即数形式判非法 | csr | `no traps: all CSR forms legal` |
| `fence.i` 重定向回 `mtvec` | fencei | `fence.i did not jump to mtvec` |
| `ebreak` 不陷入 | ebreak | `ebreak trapped exactly once` |

> 第二条值得单独说：`csrrc` 的 ALU 值修成 "旧值 & ~src" 之后，`rs1=x0` 的误写写回去的是
> **同一个值**，在同一段顺序代码里根本看不出来。真正暴露它的是"**陈旧读值盖掉硬件写**"：
> handler 里 `csrr x22, mstatus` 读到 `MIE=0` 的现场（0x1880），这条误写回落在 **`mret` 之后**
> （`mstatus` 是 ID 级就恢复的），把 `MIE` 又清成 0 → 第二次中断永远不来。
> 这类缺陷只有"中断 + 现场保存"才抓得到，正是 §11 点名的那块空白。

**lint**：`-Wall` 47 条（32 `UNUSEDSIGNAL` + 6 `WIDTHEXPAND` + 6 `PINCONNECTEMPTY` +
2 `UNUSEDPARAM` + 1 `WIDTHTRUNC`），**0 条 `IMPLICIT`**，无 `UNOPTFLAT`/`LATCH`/`MULTIDRIVEN`。
（`PINCONNECTEMPTY` 6 条是 `IDU` 里 `Reg_Stack` 的那 6 个观察口空接，历史遗留。）

**Vivado 2025.2（`_diag/vivado_noila.ps1 -Mode default`，无 ILA 顶层，综合→布局→布线闭环）**

| 项 | v10.1 | v10.2 第一版（全宽比较） | **v10.2 最终（比较收窄后）** |
|---|---|---|---|
| Slice LUTs（post-route） | 10 499 | 10 646 | **10 633** |
| Slice Registers（post-route） | 9 732 | 9 761 | **9 760** |
| Block RAM Tile / DSP | 20 / 4 | 20 / 4 | **20 / 4** |
| WNS（50 MHz 约束，周期 20 ns） | 3.553 ns | 3.078 ns | **2.203 ns** |
| WHS | 0.040 ns | 0.019 ns | **0.032 ns** |
| 关键路径 | IFU 取指队列 `q_ptg_reg[*]/CE`（~16.4 ns） | → MDU 16.93 ns | **MDU 17.76 ns** |

**怎么读这张表 —— 四件事必须分清：**

1. **前 20 条里没有一条经过本轮新增的逻辑。** 排在最前面的是两组，**都挂在 MDU 上**：

   | 路径 | 级数 | slack | 说明 |
   |---|---|---|---|
   | `EXU_Inst0/add1_reg[0] → MDU_i0/mul_res_reg[*]` | 24（CARRY4×17 + DSP48E1×2 + LUT×5） | **2.203** | 乘法的 `|a|·|b|` 归一：**`abs32` 条件取负（4~5 ns）→ DSP48 级联（5.5 ns）→ 64 位符号修正取负（3~4 ns）** 三段串联 |
   | `EXU_Inst0/alu_opcode_reg[4] → IFU_Inst0/q_ptg_reg[*]/R` | — | 2.650~2.665 | `mdu_busy`（= `alu_opcode_reg[4] & ~mdu_res_vld`）→ Control 的误预测仲裁/`dnpc` → IFU 取指队列的同步清空脚 |
   | `EXU_Inst0/alu_opcode_reg[4] → EXU_Inst0/iaddr_misalign_reg/D` | — | 2.485 | 同一个 `mdu_busy` 分叉 |

   v10.2 新增的 `csr_fwd` / `csr_sel` / `csrwen_sh` 相关路径**一条都没进前 20**。
   也就是说：**把这个设计的 Fmax 卡住的，是 MDU 的"归一化乘法"以及 `mdu_busy` 进入控制面
   的组合深度，不是本轮的系统指令逻辑。**

2. ~~**两次 v10.2 实现之间差的 0.83 ns 是"实现差异"，不是"逻辑差异"。**~~ **这一条已在 v10.3 撤回**
   —— 见 §15.10：同一份网表连跑两次，Vivado 报告**逐位相同**（2.814/2.814、1.827/1.827），
   flow 是确定性的。那两个 v10.2 数字之间只能差在 **RTL**（全宽比较版 vs 收窄版），
   不是"同逻辑的随机实现差异"。当轮的原始记录保留如下作为审计痕迹：
   两次的路径构成**完全**
   相同（24 级、同样 17 个 CARRY4 + 2 个 DSP48E1），但布线延迟 5.99 → 6.39 ns、单元延迟
   10.94 → 11.37 ns（CARRY4 的 `CO`/`O` 引脚用法不同）。而且**面积更小的那次（10 633 LUT）
   时序反而更差**，所以不能把 WNS 下降归因于"多出来的逻辑"。

3. **和 v10.1 的 3.553 ns 相比整体差了 ~1 ns，但也只能说"事实如此"。** v10.1 那轮的最差路径
   是 `q_ptg_reg[*]/CE`（16.45 ns）；本轮它的同类路径（`/R`，2.665 ns slack = 17.34 ns）**也差了
   0.9 ns**。**仓库里没有 v10.1 的 RTL 快照（`_baseline_v9/` 是 v9），所以没有做单变量 A/B，
   这里只报告事实，不做归因断言。**（v10.3 后来证明了 flow 是确定性的，所以这个差异必定来自
   RTL 或约束的某个不同 —— 但没有快照，无法定位到具体哪一处。）

4. **要真正把 Fmax 做上去，动的地方是 MDU，不是 CSR**（详见 `IMPLEMENTATION_v10.md` §11.9）：
   - 给 `|a|·|b|` 归一链加一拍流水 → 关键路径砍掉 ~5 ns（≈78 MHz），代价是 `mul` 从 1 拍变 2 拍，
     **所有含乘法的用例周期数会变**（`prog_mul` 42 / `prog_div_pair` 97 是本文多处引用的基准值）；
   - 把 `mdu_busy` 从 `dnpc` 仲裁里挪走（例如给"EX 里是 M 且未完"单独立一个寄存的
     `exu_mdu_pending`，只挡接收、不参与组合仲裁）→ 收掉 2.65 那条。后者不改延迟语义，
     属于纯结构优化，是**下一步性价比最高的一项**。

---

## 15. v10.3：Zicsr 逐条对规范审计 —— 抓出 1 个自己造成的真缺陷 + 补 4 处"假实现"

§11 说过"CSR 指令区本轮只做到能跑通用例的程度"。这一轮换了做法：把 **Zicsr 的每一条规范原文**
抄下来，逐条对着 RTL 核 —— 不再靠"写用例时想起来"。规范原文引自
[Zicsr v2.0 §5.1.1](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html)
与[特权架构 §1.1](https://docs.riscv.org/reference/isa/v20260120/priv/priv-csrs.html)。

结论先说：**6 条指令编码是齐的，但"什么时候必须报非法指令"和"哪些位可写"这两类**约束**基本没做**。
前者是 Zicsr 的语义核心（软件靠它探测 CSR 是否存在/可写），后者是 WARL 的基本要求。

**★ 诚实交代发现方式**：这轮抓到的 3 个缺陷里，
- **缺陷七（前递不过 WARL 掩码）是补完 `sys_zicsr.hex` 当场跑红的**；
- **缺陷五（写只读不报非法）、缺陷六（不存在 CSR 读回 0）是读规范对代码判定的**，
  它们不会让任何既有用例变红 —— 因为既有用例根本不写只读 CSR、也不碰空地址。
  同样给每个补了定向变异（`zicsr_*.` 7 条），把修复回退掉必须红。

### 15.1 条款对照表（12 条，逐条给判据）

| # | 规范条款（原文见上两个链接） | v10.2 | **v10.3** | RTL 判据 |
|---|---|---|---|---|
| 1 | 6 条指令：CSRRW/S/C + CSRRWI/SI/CI（funct3 = 001/010/011/101/110/111） | ✔ | ✔ | `IDU.csr_op = is_SYS & funct3!=000`；`legal_sys` 放行 001..011、101..111 |
| 2 | funct3=100 未定义 → 非法指令 | ✔ | ✔ | `legal_sys` 里 `funct3 != 3'b100` |
| 3 | "A CSRRW with rs1=x0 will attempt to write zero"（`csrw` 伪指令） | ✔ | ✔ | `IDU.csr_wr = csr_op & ((csr_f3==01) \| (csr_src != 0))` |
| 4 | CSRRS/CSRRC（含立即数）源为 0 → **不写**，且不触发写副作用 | ✔ | ✔ | 同上（`csr_src != 0` 那一项） |
| 5 | CSRRW/CSRRWI 且 rd=x0 → **不读** CSR、不触发读副作用 | N/A | N/A | 本核没有任何"读即产生副作用"的 CSR（无计数器、无读清标志），这条不可观测；见 §15.9 |
| 6 | "Attempts to write a read-only register raise illegal-instruction exceptions." | ✘ 静默丢弃 | **✔** | `csr_rdonly = csr_addr[11:10]==2'b11`；`csr_illegal = csr_op & (~csr_known \| (csr_rdonly & csr_wr))` |
| 7 | 只读 CSR 的**纯读**不许陷入（规范原文明确写了 `nor raise illegal-instruction exceptions`） | — | **✔** | 第 6 条靠 `csr_wr` 门控，纯读 `csr_wr=0` |
| 8 | "Instructions that access a non-existent CSR are reserved."（保留 = 不得"成功"） | ✘ 读回 0 | **✔** | `csr_known` **16 地址白名单**，进 `csr_illegal` |
| 8b | 但 `mimpid` 属于反例："This register **must be readable in any implementation**, but a value of 0 can be returned"（§2.1.1.4） | ✘ 陷入 | **✔ 读 0**（v10.3b，缺陷九） | `para.sv:CSR_mimpid` 进白名单 + `Reg_Stack` 读 0 |
| 9 | "A read/write register might also contain some bits that are read-only, in which case writes to the read-only bits are ignored." | 仅 `mip` 有位掩码 | **✔** | `para.sv` 的 `CSR_WMASK_*`：mip/mie/mstatus/mtvec/mepc |
| 10 | 显式读返回**指令执行前**的值；写完紧跟的指令读到新值 | ✔（v10.2 前递） | **✔ + 前递也过掩码** | `Control.csrval_now`（缺陷七） |
| 11 | 陷入/非法指令必须**零副作用**（不写 GPR/CSR/内存/PC） | ✔ | ✔ | `no_side_effect` 乘进 `csr_wen_next/R_wen_next/mem_*` |
| 12 | 单指令原子 RMW；访问在程序序上可见 | ✔ | ✔ | 读在 ID、写在 WB，中间靠前递补齐（v10.2 §14.2 + 本轮 §15.7） |

### 15.2 ★ 缺陷五：写只读 CSR 不报非法指令，"静默丢弃"

**规范**：特权架构 §1.1.1 原文 —— *"Attempts to write a read-only register raise
illegal-instruction exceptions."* 只读判定看地址编码的**高两位**：
*"The top two bits (csr[11:10]) indicate whether the register is read/write (00, 01, or 10)
or read-only (11)."*

**v10.2 的行为**：`IDU.csr_onehot` 里只有 8 个"可写 CSR"的位，`mvendorid(0xF11)`/`marchid(0xF12)`
不在表里 → `csr_wr_mask = 0` → 位图里没有该位 → **写入什么也没发生，也不报错**。

**为什么这比"少个功能"更坏**：软件探测"某个 CSR 能不能写"的**唯一**手段就是写一下看有没有陷入。
现在的结果是"没陷入、也没写" —— 探测结论与真实能力**正好相反**。同理，任何把只读 CSR 当
"可写但无效果"用的代码（例如误用 `csrs mvendorid, x1`）都会静默跑过去。

**修复**（`rtl/IDU.sv`，与合法性判定放在同一段）：

```systemverilog
assign csr_known  = (csr_addr == `CSR_mstatus) | (csr_addr == `CSR_misa) | ... ;   // 16 个地址
assign csr_rdonly = (csr_addr[11:10] == 2'b11);
assign csr_illegal = csr_op & (~csr_known | (csr_rdonly & csr_wr));
assign legal_sys = is_SYS && ((funct3 == 3'b000) ? sys_priv_ok
                                                : ((funct3 != 3'b100) & ~csr_illegal));
```

**★ 这里唯一的坑，也是修复的关键**：`csr_rdonly` 必须与 `csr_wr` 相与，**不能**直接判地址。
规范紧接着写（Zicsr §5.1.1，讲 CSRRS/CSRRC 的 rs1=x0）：

> "...will not write to the CSR at all, and so shall not cause any of the side effects that might
> otherwise occur on a CSR write, **nor raise illegal-instruction exceptions on accesses to
> read-only CSRs.**"

也就是说 `csrr x5, mvendorid` 必须**合法**。所以"要不要写"（`csr_wr`）必须与"要不要报非法"
共用同一根线，两处各写一份判据迟早会分叉。变异 `zicsr_rdonly_blocks_read`（把 `& csr_wr`
去掉）就是往这个方向错，被 `sys_zicsr` 的"6 次陷入"和 `sys_csr` 的"无陷入"同时抓到。

### 15.3 缺陷六：访问不存在的 CSR 读回 0

**v10.2 的行为**：`Reg_Stack` 的读多路 `default` 是 `32'd0`，写侧没有对应位。
于是**任意 12 位地址都"读得通、写无声"**：读 `mimpid(0xF13)`、`mhartid(0xF14)`、
`mcycle(0xB00)`、`cycle(0xC00)`、`pmpcfg0(0x3A0)`、整个 S/H 段、以及
`0x7B0-0x7BF`（debug-only，规范要求"机器模式访问这类寄存器应当报非法"）全部返回 0 且不报错。

**规范**：*"Instructions that access a non-existent CSR are reserved."* "reserved" 给了实现自由，
但**没有一个合规实现会让它"成功返回一个值"** —— 那等于向软件宣称"这个 CSR 存在且读为 0"。
本核按惯例报 `mcause=2`。

**修复**：`csr_known` 白名单（v10.3b 起 16 个地址），不在名单里一律 `csr_illegal`。
名单与 `Reg_Stack` 的读多路**必须一一对齐**（多一个 = 假实现，少一个 = 正常 CSR 反而跑飞），
这条不变量写在 `IDU.sv` 的注释里。

### 15.4 "假实现"一：`mtval` / `mtime` 可读不可写

| CSR | 地址 | 规范给的属性 | v10.2 | v10.3 |
|---|---|---|---|---|
| `mtval` | 0x343 | **MRW**（可读可写） | 只有陷入时由硬件写，**软件写静默丢弃** | 新增写位 `CSRW_MTVAL=9`，优先级 陷入 > 软件写 |
| `mtime` | 0x7C0 | 落在 `0x7C0-0x7FF` **Custom read/write** 段 | 连写位都没有 | 新增写位 `CSRW_MTIME=10`，写时同时清零分频计数器 |

`mtval` 不可写这一条，v10 的注释里还专门论证过"位图里没有 mtval 的写位（理由见 mtval_wen 一节）"——
那个理由（"异常时硬件要填它"）本身没错，但它推不出"软件不许写"。**规范说它是 MRW**。
陷阱处理程序把 `mtval` 清 0 是常规写法，本核以前会静默丢掉这个写。

`mtime` 的写位还顺带修了一个精度问题：写 `mtime` 时把 `mtime_divcnt` 一起清零，
否则刚写完 0、下一拍就可能 +1，软件没法用它做基准。**实测**：写 `0x1000` 后隔 6 条指令读回
**恰好** `0x1000`（`sys_zicsr` 的 `mtime is software-writable`）。

### 15.5 "假实现"二：`misa` 的宏存在、但从来没接线

`para.sv` 里 `CSR_misa 12'h301` 这个宏**从 v9 就定义了，一次都没被引用**
（`grep` 全仓只有定义处）。于是 `csrr x, misa` 走 `default` 读回 0 —— 而 0 的语义是
"**一个扩展都不支持**"，与事实（RV32IM）正好相反。它是唯一的**自描述**寄存器，
启动代码/CoreMark 之类一读就判定本核是空壳。

**修复**：`Reg_Stack` 里加常量 `MISA_VALUE = 32'h4000_1100`
（`MXL[31:30]=01`=RV32，`bit8='I'`，`bit12='M'`）。写侧：地址 `0x301` 的 `csr[11:10]=00`
（R/W 段）所以写它**不报非法**，但写位图里没有这一位 → 写入被忽略（WARL 允许）。
同时补了 `mhartid(0xF14) = 0`（单 hart）—— 它是启动路径上最先被读的几个 CSR 之一，
以前一读就撞一次非法指令陷阱。

### 15.6 WARL：`mip` 有掩码，其余全裸

v9 起 `mip` 的软件写就带 `& 0x1`（只有 MSIP 可写，`MEIP`/`MTIP` 由硬件驱动），
但其余四个可写 CSR 是**整字覆盖**：

| CSR | v10.2 写入 | 问题 | v10.3 掩码 |
|---|---|---|---|
| `mstatus` | `mstatus_nxt = csrd` | 写 `0xFFFFFFFF` 能读回 `0xFFFFFFFF`，凭空造出 SD/FS/XS/MPP 等 29 个不存在的字段；`MPP` 被写成 0（U 模式），而本核只有 M 模式 | `csrd & 0x1888 \| 0x1800`（MIE/MPIE 可写，**MPP 恒 11**） |
| `mie` | `mie_reg <= csrd` | 写 `0xFFFFFFFF` 读回 `0xFFFFFFFF`，宣称有 29 个中断源；实际 `pending = mie & mip` 把它们全屏蔽了，所以从来没暴露 | `csrd & 0x881`（MSI/MTI/MEI） |
| `mtvec` | `mtvec_reg <= csrd` | `[1:0]` 是 MODE；本核只有 direct。写 `0x301` 会存下"MODE=1 + base=0x300"，而 `dnpc` 直接拿整字当 PC → 陷入目标变成 `0x301`（指令地址非对齐，`mcause=0`），**整个异常体系跟着塌** | `csrd & 0xFFFF_FFFC` |
| `mepc` | `mepc_reg <= csrd` | 规范要求 `mepc[1:0]` 恒 0（IALIGN=32）。写个奇数再 `mret` 就会跳到非对齐地址 | `csrd & 0xFFFF_FFFC` |

`mtvec` 和 `mepc` 那两条不是洁癖：它们是**真的会把一次正常返回/陷入变成另一种异常**。

### 15.7 ★ 缺陷七（本轮自己引入、又被本轮用例当场抓出）：前递链存的是 ALU 原值

加完 WARL 掩码后第一次跑 `sys_zicsr`，19/21 通过，红的两条之一：

```
[FAIL] mip: only MSIP writable
  x18=ffffffff        ← 期望 00000001
```

**根因**：CSR 读口的前递链（v10.2 §14.2 建的）里存的是 `Ex_result`，也就是 **ALU 算出来的
原始新值**；而寄存器落盘时还要过一遍掩码。两者不一致时：

- `csrw mip, 0xFFFFFFFF` 紧跟 `csrr x18, mip`（间隔 ≤5 条）→ 走**前递** → 读到 `0xFFFFFFFF`；
- 隔 7 条再读 → 走**寄存器本体** → 读到 `1`。

**同一段程序读同一个 CSR 得到两个答案**，这是比"没实现 WARL"更严重的错。

**修复**：`Control.csrval_now = (Ex_result & fwd_wmask) | fwd_force`，掩码按在途写的独热码选；
`csrval_sh[0]`、`mepc_fwd`、`csr_rd_fwd` 全部改用 `csrval_now`。
掩码常数放在 `para.sv` 的 `CSR_WMASK_*` / `CSR_FORCE_*`，与 `CSR.sv` **共用同一组宏** ——
两处各写一份就等着分叉，注释里写死了"改一处必须改两处"。

**这个 bug 是被测试逼出来的，不是想出来的**，而且它反过来证明了一件事：
**"写一个 CSR 再读回来"必须测两条路（前递路径 + 寄存器路径）**。
所以 `sys_zicsr` 的 `mip` 用例读两次：距离 5 读（前递）与距离 7 读（寄存器），
两条都必须是 `0x1`。变异 `zicsr_fwd_no_warl` 就专门打第一条。

### 15.8 结果（全部在最终 RTL 上重跑）

| 项 | 结果 |
|---|---|
| iverilog 回归（Windows，23 项） | **23/23 PASS**；7 个整机程序周期 **36/42/94/55/83/110/97 一字未变** |
| `tb_sys` ×5 | csr 39 / intr 82 / fencei 46 / ebreak 39 / **zicsr 189** 拍，**5/5 PASS（16+9+5+9+25 = 64 项检查）** |
| 交叉仿真 `xcheck.sh all` | **runs=23 signature-diffs=0 bad=0 verdict=EQUIVALENT**，23 项 `dCYC` 全 0 |
| **ModelSim 回归 `run_msim.ps1`** | **23/23 ALL PASS**（v9 的 15 项 + `tb_sys`×5 + `tb_exc`×3）；`tb_sys` 周期数三者逐拍相同（§15.11） |
| 随机差分 | `programs=1000 instructions=55000 failures=0` |
| 定向变异 `mutate_sys.py` | **14 个变异全部按预期被抓到**（`verdict=ALL-AS-EXPECTED`），其中 7 条是 v10.3 新增 |
| Verilator `-Wall` | 48 条（32 UNUSEDSIGNAL + 6 WIDTHEXPAND + 6 PINCONNECTEMPTY + 2 UNUSEDPARAM + 1 WIDTHTRUNC + 1 TIMESCALEMOD），**0 条 IMPLICIT** |

> 那 1 条 `TIMESCALEMOD` 是 "`myCPU.sv` 文件头没有 `` `timescale ``"（其余模块都有）。
> v9 起就是这样，本轮没动那个文件头；只在**显式指定 `--top-module myCPU`** 时才会报出来。

**新增/更新的文件**

| 文件 | 作用 |
|---|---|
| `sim/sys_zicsr.hex`（`gen_zicsr()`） | Zicsr 一致性专项：6 次非法指令陷入 + 只读/不存在地址 + mtval/mtime 可写性 + mip WARL + misa/mhartid |
| `sim/tb_sys.sv` | 加 `+kind=zicsr`，**25 项检查**（含"mepc 精确指向非法指令本身"、"两种读路径一致"、"mimpid/mconfigptr 可读且为 0"） |
| `sim/gen_sys_progs.py` | 修 `gen_csr()` 里一条**现在会陷入**的写法（`csrr x18, mvendorid, x4`，见下） |
| `_diag/vsim/mutate_sys.py` | 加 5 个用例维度 + 7 条 `zicsr_*` 变异；放宽为"多个 kind 可以同时被抓" |
| `sim/run_msim.ps1` | 新增 `[2b/3]` 段：`tb_sys`×5 + `tb_exc`×3，ModelSim 回归从 15 项扩到 **23 项** |
| `sim/README_msim.md` | 记录 v10.3 的 23/23、三仿真器周期数对照，以及 `vlog-2388` 这个坑 |

> **改了既有用例的一处**：`gen_csr()` 里原来有一条 `csrr x18, x4, mvendorid`，`x4 = 0x7EF`。
> v10.2 用它证明"读只读 CSR 时 rd 取的是读值而不是 ALU 新值"；**v10.3 加了只读地址检查后，
> 它变成一个写尝试，必须陷入** —— 是用例写错了（它本该是纯读），不是 RTL 退化了。
> 所以改成 `csrr x18, x0, mvendorid`（保持原来的验证意图），"写只读要陷入"由 `sys_zicsr` 专测。

### 15.9 还差什么（明确的"没做"清单）

| 项 | 现状 | 值不值得补 |
|---|---|---|
| CSRRS/CSRRC 的**字段级**写副作用（规范：只对 `rs1` 置位覆盖到的字段触发副作用） | 不适用：本核没有任何带字段级副作用的 CSR | 无 |
| CSRRW 且 `rd=x0` 时"不读 CSR" | 逻辑上没做，但**不可观测**（无读副作用寄存器） | 无 |
| `Zicntr`：`cycle`/`time`/`instret`/`mcycle`/`minstret` 及高 32 位 | **未实现 → 访问报非法**。这是合规的：Zicntr 是**可选扩展**，本核 `misa` 只声明 I/M；而且规范在 Zihpm 一节明说 *"Accessing an unimplemented counter may cause an illegal-instruction exception or may return a constant value."* | 要做得**完整**做（64 位、只读、单调、`instret` 不数异常指令）；详见 §15.12 |
| `mcounteren`（0x306） | 未实现 → 访问报非法 | 规范只在**实现 U 模式时**才要求；本核 M-only，没有"下游"可门控 → 不做的代价为零 |
| `medeleg`/`mideleg`（0x302/0x303） | 未实现 → 访问报非法 | 无 S 模式 → 没有可委托的对象 |
| `pmpcfg*`/`pmpaddr*`（0x3A0-0x3BF） | 未实现 → 访问报非法 | 规范允许 **0 项**；本核 M-only 无保护对象。真做 16 项 ≈ 1.5~2.5k LUT + 一条新的判定路径 → 不做 |
| `mimpid`（0xF13）/ `mconfigptr`（0xF15） | **v10.3b 改为可读、读 0**（原来是陷入，是错的，见 §15.12） | 已修 |
| 特权级检查（`csr[9:8]` 编码的最低特权级） | 本核只有 M 模式，M 模式下所有 M 级 CSR 都可访问 → 无需检查 | 引入 U/S 模式时必须补 |
| `mstatus.MPRV`/`SUM`/`MXR` 等 | 掩码后读恒 0（正确） | 无 |
| 计数器/`mip` 的**读**副作用 | 无 | 无 |

### 15.10 面积与时序（Vivado 2025.2，`_diag/vivado_noila.ps1 -Mode default`）

| 项 | v10.1 | v10.2 | v10.3（mimpid 修复前） | **v10.3b（最终）** |
|---|---|---|---|---|
| Slice LUTs（post-route） | 10 499 | 10 633 | 10 774 | **10 783**（+9） |
| Slice Registers（post-route） | 9 732 | 9 760 | 9 717 | **9 717** |
| Block RAM Tile / DSP | 20 / 4 | 20 / 4 | 20 / 4 | **20 / 4** |
| WNS（50 MHz 约束，周期 20 ns） | 3.553 ns | 2.203 ns | 2.814 ns | **1.827 ns** |
| WHS | 0.040 ns | 0.032 ns | 0.029 ns | **0.005 ns** |
| 关键路径 | IFU 取指队列 `q_ptg_reg[*]/CE` | MDU 17.76 ns / 24 级 | MDU 17.195 ns / 22 级 | **`alu_opcode_reg[3]` → `iaddr_misalign_reg` 17.95 ns / 23 级** |

**★ 必须先撤回我上一轮的一个说法。** 我之前写过"同一条路径在 16.4~17.8 ns 之间**随实现抖动**，
是 run-to-run 差异" —— **这个说法站不住**。本轮拿到了直接的对照数据：

| RTL | 跑了几次 | WNS |
|---|---|---|
| v10.3（mimpid 修复前） | **2 次**（16:39 / 16:5x） | **2.814 / 2.814**（逐位相同：LUT 10 774、路径 17.195 ns / 22 级） |
| v10.3b（加 mimpid/mconfigptr，+9 LUT） | **2 次**（21:08 / 21:5x） | **1.827 / 1.827**（逐位相同：LUT 10 783、路径 17.952 ns / 23 级） |

Vivado 这套 flow 是**确定性**的：同一份网表跑两次，报告一字不差。所以之前那些"同一逻辑、
不同数字"的对比，实际上是**不同 RTL**（v10.2 第一版全宽比较 vs 收窄后）之间的差异 ——
归因结论不变（那次确实是收窄比较带来的），但"抖动"这个解释要删掉。

**本轮真正发生的事：+9 LUT 把关键路径**换了一条**。** 看数字：

```
修复前   add1_reg[0] → MDU/mul_res_reg[30]/D      17.195 ns  logic 64% / route 36%   slack 2.814
修复后   alu_opcode_reg[3] → iaddr_misalign_reg/D 17.952 ns  logic 28% / route 72%   slack 1.827
         Logic Levels 23 (CARRY4=9 LUT3=1 LUT4=1 LUT5=5 LUT6=7)
```

新关键路径的真实构成（从报告逐级读出来的，不是猜的）：

```
alu_opcode_reg[3]/Q →(net fo=47, 2.03 ns)→ ALU_i0/add_inst0/result_carry_i_5 (LUT5)
                    → result_carry / __0 / __1 / __2 … 的**9 级 CARRY4 进位链**
                    → iaddr_misalign_reg/D
```

也就是说：`iaddr_misalign` 的判据只需要目标地址的 **bit[1]**，但综合器把
`jump_target_low2 = add1[1:0] + add2[1:0]`（2 位加法）**塞进了 ALU 那只 32 位加法器的低位进位链**，
于是这条路径从"2 级逻辑"变成"9 级 CARRY4 + 14 个 LUT、router 占 72%"。而这只是加了 9 个 LUT
到 ID 级白名单引起的**placement 位移**——离边界这么近的设计，9 个 LUT 就能吃掉 1 ns。

**可选的修法（没做，留给下一轮决策）**：把"跳转目标低 2 位"改成**不经过加法器**的显式式：

```verilog
// 2 位加法的 bit1 = a1 ^ b1 ^ (a0 & b0)；bit0 只用来判 jalr 的 bit1，本核 jalr 的 bit0 被硬件清零
assign jump_target_low2 = { (add1[1] ^ add2[1] ^ (add1[0] & add2[0])), 1'b0 };
```

功能完全等价（2 位加法的定义），但断开与大加法器的共享，综合器不必进进位链。
预期收益：这条路径掉到 2 级逻辑，WNS 回到 **下一条最差路径 2.632 ns**（即 **+0.8 ns**），
代价约 **2 个 LUT**。**本轮没动**：它会再次作废全部已跑的回归数字，且当前 1.827 ns
在 50 MHz（周期 20 ns）下仍有 9% 余量，不是交付阻塞项，应该由你决定要不要现在换这 0.8 ns。

> 另外两条保持不变的结论：
> - 前 20 条里仍然 **0 条**经过 `csr_known` / `csr_illegal` / `csrval_now`（`grep IDU|csr|illegal` 命中 0）；
> - 真正提 Fmax 的两个结构性办法仍然没做：给 `|a|·|b|` 加一拍流水（≈78 MHz，但 `mul` 变 2 拍），
>   或把 `mdu_busy` 挪出 `dnpc` 仲裁。

**关于 +150 LUT 的分解**（v10.3 的 +141 与本轮 +9）：唯一**实测**的是用
"把 `csr_known` 恒置 1"做的单变量 A/B（同一脚本 `-Mode synth_only`）：

| 版本 | post-synth Slice LUTs |
|---|---|
| v10.3 完整 | 10 834 |
| `csr_known = 1'b1`（去掉 12 个 12 位地址比较 + 12 输入或树） | 10 794 |
| **差** | **40 LUT** |

也就是说白名单只占一小半；剩下的是 `csr_onehot` 从 8 个比较变 10 个、
`Control` 里那个 32 位的 `(Ex_result & fwd_wmask) | fwd_force`、以及 `misa`/`mhartid`/`mimpid`/`mconfigptr`
四个新的读多路分支。**这几项的分解是估算，不是实测**。

> ⚠ 归档提醒：上面那次 A/B 用的是 `-Mode synth_only`，它把 `project_src/*.synth_only.rpt`
> 覆盖成了**"`csr_known` 恒 1"变异体**的数据。当前 RTL 的数字只看 `*.default.rpt`。

### 15.11 第三个仿真器：ModelSim SE-64 10.5 —— 23/23 PASS，并抓出缺陷八

**先更正我上一轮的错话。** §14/§13 里我写过"本机没有 ModelSim，未验证" —— **这是错的**。
ModelSim 就在 `E:\FPGA\ModelSim_10.5se\win64\`（SE-64 10.5，2016.02），`vsim/vlog/vlib` 都在 PATH 上，
而且 `sim/README_msim.md` 里本来就记着 v9 的 "15/15 ALL PASS"。我当时没查就下了结论。

#### 15.11.1 ★ 缺陷八：三根信号"先用后声明"，只有 vlog 拒绝编译

第一次跑就**编译失败**（不是跑错，是根本编不过）：

```
** Error (suppressible): rtl/IDU.sv(291): (vlog-2388) 'ebreak_flag' already declared in this scope (IDU).
** Error (suppressible): rtl/IDU.sv(292): (vlog-2388) 'wfi_flag' already declared in this scope (IDU).
** Error (suppressible): rtl/IDU.sv(293): (vlog-2388) 'sys_priv_ok' already declared in this scope (IDU).
```

**根因**：v10.2 把这三根的**赋值**挪到了 `priv_id/sys_rs1z/...` 那一块（`IDU.sv:243~250`），
而**声明**留在了 `legal_sys` 那一段（`~291`）。SystemVerilog 对"先用后声明"的标识符会先建一个
**隐式 1 位网**，于是后面那行 `logic` 成了"重复声明"。

**为什么前两个仿真器没拦住**：

| 仿真器 | 反应 |
|---|---|
| iverilog 12.0 | 只给 `sorry/warning`，继续编译 → 用例全过 |
| Verilator 5.020 | `-Wall` 下**也没报**（它按模块两遍解析，隐式网被消解）→ 我上轮"0 条 IMPLICIT"的结论看着很干净 |
| **vlog -sv 10.5** | **直接拒绝编译** |

**功能上侥幸没错**：这三根都是 1 位信号，隐式 1 位网恰好等价。但这正是 v10.2 踩过的**同一个坑**的变体
（那次是 `csrs_rd` 隐式 1 位网，代价是 `tb_exc` 三个用例全红）。**同一个类别的错在同一个文件里又犯了一次，
而且是更宽松的仿真器放过去的** —— 这条值得单独记：*"两个仿真器都通过"不等于"代码合法"*。

**修复**：三根声明上移到第一次赋值之前（`IDU.sv:230` 附近），并写死一条不变量：
> 本文件任何 `logic` 声明都必须出现在它的第一处使用之前。

#### 15.11.2 把 v10 的用例接进 ModelSim 回归

`sim/run_msim.ps1` 原来只跑 v9 的 7 程序 ×2 模式 + D-Cache 单元测试（15 项），
本轮加了 `[2b/3]` 一段：`tb_sys` ×5 + `tb_exc` ×3（这两个 TB 没有 `$dumpvars`，
不需要像 `tb_iverilog.sv` 那样先过一个生成器，直接 `vlog -sv` 就能编）。

#### 15.11.3 结果：23/23 ALL PASS

```
=== [2/3] 7 programs x {normal, strict} + dcache unit ===
  [OK  ] prog / prog_mul / prog_div / prog_load_lane / prog_load_use / prog_loop / prog_div_pair
         normal 与 strict 全部 PASS（35/35 与 34/34 项检查）
  [OK  ] tb_dcache_unit   PASS
=== [2b/3] v10 system tests: tb_sys x5 + tb_exc x3 ===
  [OK  ] tb_sys  csr 16 / intr 9 / fencei 5 / ebreak 9 / zicsr 25 项检查全 PASS
  [OK  ] tb_exc  illegal 7 / misalign 8 / jal_misalign 5 项检查全 PASS
  RESULT: ALL PASS (23 项，0 failures)
```

**三个仿真器的周期数对照**（这是"逐拍等价"的第三份证据）：

| 用例 | iverilog | Verilator | **ModelSim** |
|---|---|---|---|
| `tb_sys` csr / intr / fencei / ebreak / zicsr | 39 / 82 / 46 / 39 / 189 | 39 / 82 / 46 / 39 / 189 | **39 / 82 / 46 / 39 / 189** ✅ 完全相同 |
| 7 个整机程序 | 36/42/94/55/83/110/97 | 36/42/94/55/83/110/97 | 35/41/93/54/82/109/96（**各少 1**） |

那 1 拍差异**不是功能差异**：`sim/tb_msim.sv` 是 v9 用 `mk_msim_tb.py` 从 `tb_iverilog.sv` 生成的副本，
里面还是 `@(negedge clk); rst = 1'b0;`（没有 v10.2 §9.1 加的 `#1` 那一拍保护），
所以计数器起点差 1。**自检项数一个不少**（35/35、34/34），只是 `cycles` 这个计数器的起点不同。
`tb_sys`/`tb_exc` 是新写的 TB，本来就带 `#1`，所以与另外两个仿真器**逐拍相同**。

> 要不要把 `tb_msim.sv` 重新生成一次？可以做（`python sim/mk_msim_tb.py`），
> 但那会把 v10 之后 `tb_iverilog.sv` 的改动一起带进来（含 `$dumpvars` 过滤规则），
> 属于"改验证设施"而不是"改验证结论"，本轮没动，只把差异记在这里。

#### 15.11.4 修完之后把全部结论重跑了一遍（都在同一份最终 RTL 上）

声明顺序的修复**不改变网表**，所以各项数字应当完全一致 —— 逐项重跑确认了这一点：

| 项 | 修复前 | 修复后 |
|---|---|---|
| iverilog 回归 | 23/23 PASS，周期 36/42/94/55/83/110/97 | **完全相同** |
| `xcheck.sh all` | 23/23 EQUIVALENT，`dCYC` 全 0 | **完全相同** |
| `mutate_sys.py` | 14/14 ALL-AS-EXPECTED | **完全相同** |
| Verilator `-Wall` | 48 条 / 0 IMPLICIT | **完全相同** |
| Vivado `-Mode default` | LUT 10 774 / FF 9 717 / WNS 2.814 / WHS 0.029 / post-synth 10 834 | **完全相同**（`RESULT NOILA MODE=default WNS=2.814 WHS=0.029`） |

### 15.12 ★ 缺陷九：`mimpid` "不实现" ≠ "不可读" —— 我把规范读漏了一条

**这一条不是"没做"，是"做错了"。** v10.3 我按"只放真正实现了的东西"一刀切，把
`mimpid`(0xF13)、`mconfigptr`(0xF15) 也划进了"未实现 → 访问报非法"。查规范原文才发现
`mimpid` 属于**必须能读**的那一类：

> 特权规范 §2.1.1.4：*"The `mimpid` CSR provides a unique encoding of the version of the
> processor implementation. **This register must be readable in any implementation**, but a
> value of 0 can be returned to indicate that the field is not implemented."*
> （`mvendorid`/`marchid` 的措辞一样，`mhartid` 则是"must be readable"且没有任何"可以返回 0"的退路。）

也就是说"没有版本号"的正确表达是**读回 0**，而不是发一次 `mcause=2`。
所以 `csrr x5, mimpid` 在 v10.3 上会陷入 —— 这是一个**真缺陷**，而且比"少个功能"更糟：
它会让"探测实现版本"的启动代码/工具链在一条规范保证可读的 CSR 上直接掉进异常。

**修复**：

| 文件 | 改动 |
|---|---|
| `rtl/para.sv` | 新增 `CSR_mimpid 12'hf13`、`CSR_mconfigptr 12'hf15`（并把 `mhartid` 的注释改成引用"must be readable"） |
| `rtl/IDU.sv` | 两者加入 `csr_known` 白名单（13 → **16** 个地址） |
| `rtl/Reg_Stack.sv` | 读多路补两条常量 0（"信息拿不到就给 0"，与 `mvendorid`/`marchid` 同口径） |
| `sim/gen_sys_progs.py` + `sim/tb_sys.sv` | 新增 2 项检查：先塞非零（`0x12345`/`0x23456`）再读，必须读到 **0 且不陷入** |

**顺带确认的几个"不做"是对的**（这次每条都去查了原文，不再凭印象）：

| CSR | 规范口径 | 本核 | 判定 |
|---|---|---|---|
| `mcounteren`(0x306) | 只在**实现 U 模式时**才要求（它门控的是"低特权级读计数器"） | 无 U 模式、无计数器 | 不做**不是**缺陷 |
| `pmpcfg*`/`pmpaddr*` | 允许 **0 项** PMP | M-only，无保护对象 | 不做**不是**缺陷；真做 16 项 ≈ 1.5~2.5k LUT |
| `Zicntr`(`cycle`/`time`/`instret`/`mcycle`/`minstret`) | **可选扩展**；且 Zihpm 一节明说 *"Accessing an unimplemented counter may cause an illegal-instruction exception **or** may return a constant value."* | `misa` 只声明 I/M | **报非法是合规的**（但要做就得完整做：64 位、只读、单调、`instret` 不数异常指令） |
| `medeleg`/`mideleg` | 仅在有 S 模式时有意义 | M-only | 不做不是缺陷 |

**结果**：`tb_sys zicsr` 从 23 项增到 **25 项**（189 拍），全部通过；三套仿真器
（iverilog / Verilator / ModelSim）在最终 RTL 上重跑：

| 项 | 结果 |
|---|---|
| iverilog 回归 | **23/23 PASS**，7 个程序周期 36/42/94/55/83/110/97 未变 |
| ModelSim 回归 | **23/23 ALL PASS**（`tb_sys zicsr PASS 25 checks`） |
| `xcheck.sh all` | **23/23 EQUIVALENT**，`dCYC` 全 0（zicsr 189/189） |
| `mutate_sys.py` | **14/14 ALL-AS-EXPECTED** |
| Verilator `-Wall` | 48 条 / 0 IMPLICIT |
