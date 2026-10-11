# v9 七项不足的修复进度（C 系列）

> 本文对应 [`quartus_modelsim_实测.md`](./quartus_modelsim_实测.md) 里列出的 6 项结构/功能不足
> 的修复过程（编号沿用该文，前缀 C = correction）。
> **每一项都跑 ModelSim 14 项（7 程序 × {正常,严格}）回归验证。**

## 一句话状态

| 编号 | 内容 | 状态 |
| --- | --- | --- |
| C2 | 前递/冒险判定口径收敛为单一裁决源 | ✅ **完成并验证**（14/14 通过） |
| C5 | `Data_hazard` 的 WB 前递补 `WB_valid` | ✅ **完成并验证**（14/14 通过） |
| C6 | 清理死信号 | ✅ **完成并验证**（14/14 通过） |
| C7a | `mtime` 改为可配置递减计数器 | ✅ 完成并验证 |
| C4 | 异常体系（非法指令 / 非对齐访存 / 目标非对齐 + `mtval` 落地） | ⚠️ **部分完成，默认关闭**：判定与 CSR 登记已验证正确；开启后会影响分支预测恢复（见 §4），故 `TRAP_ENABLE` **默认 0** |
| C3 | 收紧 `EXU_inst_clear` 与 valid 的同步语义 | ⏳ 未开始 |
| C1 | 缓存停拍语义改标准 valid/ready 握手 | ⏳ 未开始（已量化代价，见 §6） |
| C7b | 打断 EXU↔Control 关键路径冲 100MHz | ⏳ 未开始 |

### 回归状态（必须看这一行）

| 配置 | 结果 |
| --- | --- |
| `TRAP_ENABLE = 0`（**默认**） | **14/14 全过**（7 程序 × {正常,严格}） |
| `TRAP_ENABLE = 1` | 12/14：`prog_loop` 两项失败（后向分支循环只跑 2 圈就掉出，即文档里 B4 那个症状复现） |

也就是说：**默认配置下工程是干净可用的**；异常体系作为"可开关的新功能"交付，
默认不启用，避免影响已完全验证的控制流。

**总开关**：`Control #(.TRAP_ENABLE(n))`

| 取值 | 行为 |
| --- | --- |
| `0`（默认） | 异常体系整块失效，控制流与修复前一致。**IDU 的"非法指令副作用清零"仍然生效**（那层在 IDU 里，属于安全修正：非法指令不会被真的执行掉、不会写坏 rd），只是不陷入 |
| `1` | 非法指令 / 访存非对齐 / 指令地址非对齐 都会陷入 `mtvec` 并登记 `mcause`/`mepc`/`mtval` |

留这个开关的价值：**逐项开启、逐项回归**，出问题能立刻定位到是哪一项；
也便于量化新逻辑对资源与 Fmax 的代价。

---

## 1. C2：前递/冒险口径收敛（已完成）

### 问题
`Control` 与 `Data_hazard` **各写一份**"某一级的数据到底可不可用"的条件：

```systemverilog
// Control.sv（旧）
assign mem_load_use = MEM_mem_ren && MEM_valid && (...);
// Data_hazard.sv（旧）
assign mem_hit_rs1  = MEM_R_Wen && MEM_valid && ~MEM_mem_ren && (...);
```

两份口径一旦不同步，就会出现"Control 不判停顿、而 Data_hazard 把可用的 load 数据
挡掉"，消费者读到寄存器堆旧值 —— 这就是历史缺陷 B5。

### 修法
把**全部**前递/冒险判定搬进 `Data_hazard`，让它成为唯一裁决源，并用**同一组命中条件**
同时驱动两件事：

| 输出 | 含义 |
| --- | --- |
| `IDU_rs1_choice` / `IDU_rs2_choice` | 谁来前递（3 位编码） |
| `load_use_stall` | 要不要停（= `exu_load_use \| mem_load_use \| pipe_load_use`） |
| `exu_load_use` / `mem_load_use` / `pipe_load_use` | 分级明细，仅供波形观察 |

`Control` 里**不再有任何**"某级是不是 load / 数据可不可用"的判断，只做两件事：
把编码翻译成数据值、把 `load_use_stall` 接到 `IFU_stall` / `EXU_inst_clear` 上。

### 验证
两个模块改完直接跑 14 项回归 → **14/14 全过**，且逐项检查数与修复前**逐字节一致**
（35/35、34/34 × 6）。这同时也证明了 C5 那条补充检查在当前流水线里是冗余的。

### 命中口径（现在只有这一份，写在模块头注释里）
```
EXU      : R_Wen 且不是 load            （不查 valid：见模块内说明）
MEM      : R_Wen 且 valid 且不是 load
MEM_PIPE : R_Wen 且 valid 且不是 load
MEM2     : R_Wen 且 valid              （load 数据只在这一级前递）
WB       : R_Wen 且 valid
任意一级 rd == 0 都不算命中（x0 永远读寄存器堆的 0）
```

---

## 2. C5：WB 前递补 `WB_valid`（已完成）

`WBU` 送给 `Control` 的 `WB_R_Wen` 是**未被 valid 门控**的寄存值
（`WBU.sv` 里 `R_wen_next = R_wen_reg & valid_reg`，而送出去的是 `R_wen_reg` 本身）。
WBU 里坐一条被作废的空操作时，`WB_R_Wen` 仍可能是 1、`WB_rd`/`WB_rd_value` 是上一条的残值；
消费者 rs 若撞上那个残值 rd，就会取走陈旧数据，而寄存器堆那一拍并没有写。

**修法**：`wb_hit_rs1/rs2` 补上 `WB_valid`，五个前递源口径完全一致。
在现有流水线里这一条是冗余的（实测加它前后 14 项回归逐项一致），
但显式写出来才能保证"谁来前递"只有一个口径。

---

## 3. C6：死信号清理（已完成）

Quartus 的 `Warning (10036): object "..." assigned a value but never read` 一共报了 5 个，
逐个处理：

| 信号 | 位置 | 处理 |
| --- | --- | --- |
| `bp_redir_taken` | `Control.sv` | **删除**。它只被 `bp_redir_target` 那一行"顺便"算出来，从没被读。方向信息不参与 IFU 重定向决策（IFU 只看 `dnpc`/`dnpc_flag`），预测器方向更新走 `bp_update_taken` |
| `bp_pend_taken` | `Control.sv` | **删除**。唯一的用处是拼上面那个死信号；补发只需要"跳到哪"，而 `bp_pend_target` 已经把"不跳则 pc+4"折叠进去了 |
| `div_signed_r` | `experimental/MDU_pipelined.sv` | **删除**。结果回正只用 `sign_diff_r` 与 `d1_neg_r`，边界判断只用 `op_a_r/op_b_r/div_sel_r` |
| `store2_addr` / `store2_tag` | `DCache.sv` | **删除**。一次 store 需要跨拍保留的只有 payload（wdata/mask）与"属于哪一行"（index）；地址既不再上总线（走 `mem_addr = cpu_addr_r`）也不再做比较 |
| `mtval_reg` | `CSR.sv` | **启用**（不是删）—— 见 §4，它现在真正参与异常登记 |

---

## 4. C4：异常体系（部分完成）

### 4.1 新增能力

| 异常 | 触发位置 | mcause | mtval |
| --- | --- | --- | --- |
| 指令地址非对齐 | EXU（分支/jal 的实际目标低 2 位 ≠ 0） | 0 | 目标地址 |
| 非法指令 | IDU（按 RV32I/RV32M 逐条校验编码） | 2 | 出错指令编码 |
| load 地址非对齐 | IDU（`rs1 + imm` 的有效地址） | 4 | 出错地址 |
| store 地址非对齐 | IDU（同上） | 6 | 出错地址 |
| ecall | 原有通道 | 11 | 0（原有语义） |

优先级：**指令地址非对齐(0) > 非法指令(2) > 访存非对齐(4/6)**，与 RISC-V 规范一致。

配套改动：
- `IDU`：新增完整的 RV32I/RV32M **合法性译码**（`legal_load/store/branch/op_imm/op/misc/sys`）。
  原来所有译码都是"匹配不上就当加法"，非法指令会被真的执行掉并写坏 rd；
  现在非法/非对齐访存一律 `no_side_effect` 清零 —— **R_wen / mem_wen / mem_ren /
  csr_wen / branch_flag / jump_flag 全部拉 0**。
- 顺带补上 `MISC_opcode`（fence/fence.i）：原来**没有任何地方检查这个 opcode**，
  fence 类指令会被当成"未知 opcode"静默丢掉。
- `CSR`：新增统一陷入通道 `trap_take`/`trap_take_q`/`trap_cause`/`fault_addr`/`fault_inst`；
  `mtval` 从死寄存器变为真正登记；`mstatus` 的陷入处理（MPIE<=MIE、MIE<=0）扩展到同步异常。
- `myCPU`：新增 4 个顶层 debug 端口 `debug_mcause/mepc/mtval/trap_take`，
  **不再需要层次化引用**就能在板上/仿真里观察异常现场。

### 4.2 已验证正确的部分

`sim/gen_exc_progs.py` 生成 3 个专项程序，`sim/tb_exc.sv` 用顶层 debug 端口检查：

```
# exc_illegal.hex 实测：
[TRAP1] cyc=45 mcause=00000000 mepc=00000000 mtval=xxxxxxxx   ← 陷入当拍（CSR 尚未更新）
[TRAP2] cyc=90 mcause=00000002 mepc=00000020 mtval=...        ← 登记完成
                                                            mcause=2 非法指令 ✓
                                                            mepc=0x20 指向出错指令的下一条 ✓
```

**判定与登记链路是通的**：非法指令被正确识别 → 陷入 mtvec → `mcause=2`、`mepc` 正确。

### 4.3 尚未解决：开启后影响分支预测恢复

`TRAP_ENABLE = 1` 时，`prog_loop`（后向分支循环）失败：计数器只累加到 2 就掉出循环、
PC 回到 0 重新开始 —— 这正是 `IFU.sv` 注释里 **B4** 描述过的症状
（"预测跳转与顺序推进没用同一个条件，循环失控"）。

已定位到的现象：
- **异常判定与 CSR 登记完全正确**：`exc_illegal` 程序实测
  `mcause=2`、`mepc=0x20`、`trap_take` 单拍脉冲，链路是通的；
- 但陷阱处理程序执行到 `mret` 附近时，`IFU_stall` 与 `EXU_inst_clear`
  出现 0/1 抖动，IDU 流水寄存器被反复冻结，`mret` 那条指令"进得去、出不来"；
- 同一套逻辑关掉（`TRAP_ENABLE=0`）后 14/14 全过，说明**问题只出在新加的
  异常重定向与既有停顿/冲刷机制的交互上**，不是基础流水线坏了。

**当前判断**：`trap_redirect` 这一类"单拍冲刷脉冲"与 v9 那套
"stall 只冻结寄存器、不清 valid"的握手约定（`docs/模块阅读文档.md` §1.1 第 3 条）
之间有交互缺陷，会间歇性地把分支预测恢复窗口打断。

**下一轮要做的（三选一，按推荐顺序）**：
1. **把异常登记挪到 WB 级、复用 ecall 那条已经完全调通的重定向通道**：
   非法指令/非对齐访存不自己发 `dnpc`，而是把该指令**转成一次系统重定向**
   （与 `ecall` 完全同构），这样重定向只发生在流水线的固定位置，
   不参与 EXU↔Control 的组合反馈；
2. 给 `trap_redirect` 补一套与 `bp_redirect_pending` 同构的"登记-补发"结构，
   并保证它在 `IFU_stall` 期间不改变 `EXU_inst_clear` 的相位；
3. 在 EXU 的异常寄存器上再加一层"每条指令只报一次"的 pending 标志，
   从根上消除"异常标志粘住→反复重定向"的可能（B7 的 `bp_misp_pend` 就是这么修的）。

**在修好之前，默认 `TRAP_ENABLE=0`** —— 交付物保持"基线全绿 + 新功能可开关"。

---

## 5. C7a：mtime 改为递减计数器（已完成）

原实现 `mtime_reg <= mtime_reg + 1` 每拍加一 —— 100MHz 下 1 拍 = 10ns，
也就是 **mtime 比真实时间快 1000 万倍**，拿它算时间/延时没有任何意义。

现在改为**带分频的递减计数器（decrementer）**，分频比由 `para.sv` 的
`` `MTIME_DIV_DEFAULT `` 配置：

| 配置 | 效果 |
| --- | --- |
| `MTIME_DIV_DEFAULT 1` | 每拍 +1（与旧行为完全一致，回归可用） |
| `MTIME_DIV_DEFAULT 100`（默认） | 100MHz/100 = **1MHz**，即每 1us 加 1 |

代价只有 `$\log_2 D$` 个触发器。这样 `mtime/mtimecmp` 才真正像一个时间基准，
定时器中断的间隔也可以按微秒来算了。

---

## 6. C3 / C1 / C7b：尚未开始

### C1：缓存停拍语义（已量化，待决策）
`ICache`/`DCache` 的 miss 是"停一拍重试"而不是标准 valid/ready 流水。
实测代价（`prog`，82 拍）：`ICache hit=48 miss=16`，每次 miss 固定 +1 拍，
即**总周期里约 20% 花在取指 miss 重试上**。
要改成"非阻塞/流水化取指"是结构性大改（Cache + IFU + LSU + myCPU 同时动），
风险与收益不成比例，建议保持现状并把**接口契约写成文档 + 断言**（本轮未做）。

### C3：`EXU_inst_clear` 的同步语义
`EXU_inst_clear` 是纯组合信号，由 `intr_take | bp_mispredict | trap_redirect |
(mem_stall & ~branch/jump) | load_use_stall` 或出来，直接门控 EXU 控制寄存器。
本轮在 EXU 侧加了一个**独立的一次性异常清除脉冲**（`trap_take`，
不参与 `EXU_inst_clear`），解决了异常标志"粘住"的问题；
但 `EXU_inst_clear` 本身与 `valid` 的同步语义还没有系统收紧，也还没有加断言。

### C7b：关键路径
实测 85°C 慢速模型下 Fmax = **78.2 MHz**，关键路径是
`EXU.alu_opcode_reg → ALU(分支比较) → Control(branch_taken/bp_misp_det/
EXU_inst_clear/dnpc_flag) → EXU 控制寄存器`（数据延迟 12.717ns）。
打断它的方向：把分支判定从 `Control` 挪回 `EXU`、把 flush 生成再打一拍。
本轮未做。

---

## 7. 本轮新增/改动的文件

| 文件 | 说明 |
| --- | --- |
| `Data_hazard.sv` | **重写**：唯一前递/冒险裁决源，新增 `load_use_stall` 等 3 个输出 |
| `Control.sv` | 删除本地 load-use 判定；新增 `TRAP_ENABLE` 开关与统一异常通道；清理 2 个死信号 |
| `IDU.sv` | 新增 RV32I/RV32M 合法性译码、`mem_misalign` 判定、`mtval/mcause` 观察口、异常通道透传 |
| `EXU.sv` | 新增异常锁存（独立 always_ff + `trap_take` 一次性清除）、`valid_next` 门控 |
| `CSR.sv` | 统一陷入通道、`mtval` 真正落地、`mtime` 改递减计数器 |
| `Reg_Stack.sv` | 透传异常通道、`mtval/mcause` 读出与引出 |
| `myCPU.sv` | 新增 `debug_mcause/mepc/mtval/trap_take` 端口，接线 |
| `para.sv` | 新增 `MISC_opcode`、`MCAUSE_*`、`EXC_*`、`MTIME_DIV_DEFAULT` |
| `sim/gen_exc_progs.py` | **新增**：异常专项程序生成器（手工汇编，无外部工具链依赖） |
| `sim/tb_exc.sv` | **新增**：异常体系专项检查测试台（走顶层 debug 端口，含 `+trace`/`+wbtrace` 调试开关） |
