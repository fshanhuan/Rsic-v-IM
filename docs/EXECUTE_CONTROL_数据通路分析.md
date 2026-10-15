# EXECUTE / CONTROL 数据通路分析（v9, xc7z020-1, 50 MHz）

证据基线（全部为实测报告，非估算）：
- 后布线时序：`project_src/timing_post_route.rpt:392-483`（WNS +3.445 ns @ 20 ns ⇒ 实际最长通路 **15.897 ns**）
- 后布线资源：`project_src/util_post_route.rpt:35-45`（LUT 13006 / FF 14765 / BRAM 38.5 / DSP 12）
- 相同关键路径的 Quartus 侧独立实测：`syn/quartus_modelsim_实测.md:256-276`（Fmax 78.2 MHz，数据延迟 12.717 ns，路径同为 `EXU.alu_opcode_reg → ALU → Control → EXU 控制寄存器`）
- 已知待办：`syn/修复进度_C系列.md:220-225`（C7b「打断 EXU↔Control 关键路径冲 100 MHz」，未开始）

---

## 1. Control 路径的实际实现

### 1.1 前递优先级与网络深度

`Data_hazard.sv:66-102` 是唯一裁决源，优先级由**近到远**固定为：

```
EXU(3'b001) > MEM(3'b010) > MEM_PIPE(3'b101) > MEM2(3'b011) > WB(3'b100) > 不前递(3'b000)
```
- rs1：`Data_hazard.sv:81-85`；rs2：`Data_hazard.sv:98-102`（两棵树完全独立，无共享）
- EXU 级必须带 `~EXU_mem_ren`（`Data_hazard.sv:66,92`）：load 在 EX 的 `EX_result` 是地址不是数据
- MEM / MEM_PIPE 级必须带 `~mem_ren`（`Data_hazard.sv:69-70`）：load 数据一律由 **MEM2** 提供
- WB 级必须带 `WB_valid`（`Data_hazard.sv:77,97`）：因为 WBU 送出的 `WB_R_Wen` 未与 valid 门控（`WBU.sv:161` 内部才是 `R_wen_reg & valid_reg`）

裁决结果只是 **3 位编码**，真正取数据在 `Control.sv:316-328`：两个 **6 路 32 位** mux（5 个前递源 + 寄存器堆兜底），每路 5 层三目 ⇒ 综合后约 **2 级 LUT6 + F7/F8**（总设计 F7=1651 / F8=638，见 `util_post_route.rpt:43-44`）。
⇒ ID 级操作数路径深度 = **操作数命中判定 ≈2 级 + 选择译码 ≈1 级 + 32 位 mux 2 级 ≈ 5 级**，之后还要进 IDU 的 `add_src1/add_src2` 32 位加法器（`IDU.sv:347-356`）再进 EXU 寄存器。

### 1.2 load-use 冒险：检测方式与气泡数

判定在 `Data_hazard.sv:116-123`，三个分级并列：

| 分级 | 位置 | 源码 |
|---|---|---|
| `exu_load_use` | EXU 级是 load 且 rd==rs1/rs2 且 rd≠0 | `Data_hazard.sv:116-117` |
| `mem_load_use` | MEM 级是 load（带 `MEM_valid`） | `Data_hazard.sv:118-119` |
| `pipe_load_use` | MEM_PIPE 级是 load（带 `valid`） | `Data_hazard.sv:120-121` |
| `load_use_stall` | 三者相或 | `Data_hazard.sv:123` |

**没有** MEM2 分级 —— MEM2 的数据已可用，由 `3'b011` 正递（`Data_hazard.sv:122-123`、`Control.sv:319`）。三级的**优先级不对称**也被显式写成不变量：`exu_*` 不带 `EXU_valid`（`Data_hazard.sv:113-114`），因为被 `EXU_inst_clear` 作废那拍 `EXU_R_Wen/EXU_mem_ren` 已归零，命中与停顿必须同时消失。

**代价：不是固定 N 拍，而是「停到 load 到 MEM2 为止」** —— 每次 1 条死拍 + 1 条 replay：
- 消费者被 EXU **提前收走**（`Control.sv:293` 的 `load_use_stall` 项 → `EXU_inst_clear`），EXU 那拍把它清成空操作（`EXU.sv:289-300`）；`IFU_stall`/`IDU.ready_last` 冻结前端不动（`myCPU.sv:175`、`IDU.sv:120`）
- 停顿解除那一拍 IDU **再送一次**同一条指令（`EXU.sv:87-96` 的 `up_stall` 不变量就是为这条 replay 立的），此时 load 已在 M3
- 所以：**EXU 级 load → 3 拍死 + 1 拍 replay；MEM 级 → 2 拍；MEM_PIPE 级 → 1 拍**。若其间 ICache/DCache `hold` 拉高（`myCPU.sv:175-176`、`ICache.sv:107`、`DCache.sv:139`），还会再叠加，因为 `load_use_stall` 与 hit-LOAD 无关，hold 期间它保持为 1（一致，不抖动）。

### 1.3 分支误预测冲刷：死几拍 / 错路径有无副作用

判定：`Control.sv:196-198`（3 个活项：`actual_taken != EXU_pred_taken`、`actual_taken & (actual_target != EXU_pred_target)`、`EXU_ctrl_valid & ~(intr_take|system_redirect|trap_redirect)`）。冲刷动作分布在三处：

1. `bp_hold_exu`（`Control.sv:251`）：只挡 EXU **接收**新指令，不挡放行 —— `EXU.sv:259,301` 用 `~bp_pend` 门控数据/控制寄存器，`valid_next`/`ready_last` 不受影响（`EXU.sv:195,367`）
2. `EXU_inst_clear`（`Control.sv:291-293`）含 `bp_mispredict`：清掉 EX 级那条的控制位（`EXU.sv:289-300`），保证错路径的 `R_wen/mem_wen/csr_wen/jump/branch` 全 0
3. `dnpc_flag`（`Control.sv:279`）→ IDU `flush`：把 ID1/ID2 **两级**寄存器灌 NOP 并清 valid（`IDU.sv:130-137`、`IDU.sv:152-159`）；IFU 用同拍 `dnpc` 拨 PC（`IFU.sv:91-92`）

⇒ **死 2 拍**：判定拍（T）错路径指令在 EX 被清；T 拍在 IFU 的那条 T+1 被 flush。IFU 里 T 拍取回、尚在 IFU 寄存器的那条由 T+1 的 `dnpc_flag` 顺带清掉（`IDU.sv:130`）。
⇒ **错路径指令不会产生副作用**：EX 级唯一可能的错路径指令就是判定拍在 EX 的那条（更年轻的都还没出 IDU），它当拍就被 `EXU_inst_clear` 清；T+1 起 IDU 输出的是 NOP（`IDU.sv:131,153`，`para.sv:173` 保证 NOP = `addi x0,x0,0` 无副作用）。**结论：最早能带副作用的级（EX）与判定级同拍，所以没有超过 1 条的错路径指令能活到 MEM/WB。**
⇒ 未决风险：IFU 的 PC 拨向依赖 `dnpc`，而 `dnpc` 的选择信号与 `dnpc_flag` 的或项顺序错开一位（见 §3.6），这是同一条长链的另一半；当前没有失败端点，说明顺序自洽，但改结构时必须同步改这两处。

### 1.4 MDU 停顿：乘法不阻塞，除法阻塞整机 34 拍

- `mdu_start`：`EXU.sv:178`；`mdu_stall = alu_opcode_reg[4] & ~mdu_res_vld`（`EXU.sv:181`）
- 乘法：`MDU_pipelined.sv:126-128` 单拍寄存，`busy = div_active`（`MDU_pipelined.sv:199-201`）⇒ **乘法 busy 恒 0，不停机**，只是「发射拍 + 结果拍」两拍
- 除法：`MDU_pipelined.sv:148-158` 32 拍迭代 + 1 拍 `div_hold` ⇒ `busy=1`
- `mdu_busy` 的扇出（`EXU.sv:183`）：`Control.IFU_stall`（`Control.sv:297`）冻结 IFU/IDU；`LSU.lsu_freeze`（`LSU.sv:152`）冻结整条访存流水；`EXU.valid_next` 冻结在 `EXU.sv:195`
⇒ **除法把三级（前端 + 访存 + EXU）同拍冻死，整机吞吐降到 1/34**；期间 `Control.sv:125,130` 还用 `~mdu_busy` 屏蔽分支判定，`Control.sv:270` 用它排除中断接收。功能正确，但对含除法的工作负载是硬性 34 拍停顿，且 `prog_div` 类的回归把它当作预期行为。

### 1.5 异常/中断仲裁优先级（含一个沉睡的抢占漏洞）

**当前配置 `TRAP_ENABLE = 0`（`Control.sv:18`，`myCPU.sv:361` 未覆盖参数）** ⇒
`exc_any` 恒 0（`Control.sv:158-159`）⇒ `exc_pending=0` ⇒ `trap_take=0`、`trap_redirect=0`、`trap_take_q_r` 恒 0（`Control.sv:177,180-184`）。**整块同步异常逻辑是死逻辑**，`fault_addr`/`fault_inst` 也无人消费（`Control.sv:173-174`）。

`TRAP_ENABLE=1` 时的仲裁：
- 异常**种类**优先级（`Control.sv:165-169`）：`iaddr_mis(bit3) > ill(bit0) > load_mis(bit1) > store_mis(bit2)`，load/store 用 `funct3[2:1]` 再分组（`Control.sv:148-151`）
- `dnpc_flag` 优先级（`Control.sv:279`）：`intr_take > trap_redirect > bp_mispredict > system_redirect`；而 `system_redirect` 内部又含 `trap_redirect`（`Control.sv:260`）
- `dnpc` 取值链（`Control.sv:307-309`）：`intr_take→mtvec` / `bp_mispredict→bp_redir_target` / `mret→mepc` / 其余→`mtvec`
- 异常 vs 误预测：`trap_redirect` 进 `bp_misp_det` 的排除项（`Control.sv:196`）⇒ 异常一律赢，且不会出现「脉冲发了、PC 走另一个源」
- 中断 vs 分支/跳转：`intr_safe` 硬件上排除（`Control.sv:268-271`）
- **中断 vs 同步异常无互斥**：`trap_redirect` 只进 `bp_misp_det` 的排除项，**没进 `intr_safe`**。若同拍 `intr_pending=1` 且 `intr_safe=1`（`IDU_valid` 且 IDU 不是 branch/jump/fence/mret/ecall 且无停顿），`dnpc_flag` 同时来自两源、`dnpc` 取 `mtvec`、CSR 同时收到 `intr_take`（写 mepc=IDU_pc）与 `trap_take`（写 mepc=EX 出错地址）——`CSR.sv:182` 的 `mepc_wen` 是同一项或，`always_ff` 的 if 链顺序决定谁赢。这是一条**未验证的抢占路径**；因 `TRAP_ENABLE=0` 当前不可触发，但 C4 打开时必须补 `intr_safe &= ~trap_redirect`。

---

## 2. 关键路径 / 时序分析

### 2.1 实测最长路径（`timing_post_route.rpt:392-483`）

```
Source:      EXU_Inst0/add2_reg_reg[3]/C
Destination: IDU_Inst0/pi_d_reg[4]/R   （IDU 第一级预测索引寄存器的**复位脚**）
Data Path Delay: 15.897 ns  (logic 3.365 ns = 21.2% ; route 12.532 ns = 78.8%)
Logic Levels: 15  (CARRY4=3 LUT2=1 LUT3=2 LUT5=3 LUT6=6)
Slack: +3.445 ns @ 20 ns   ⇒ 该通路上限 Fmax = 1e3/15.897 = 62.9 MHz
```
按 `timing_worst_paths.rpt:17-60`，WNS 前 20 条端点**同源**（`add2_reg[3]`），扇出到 IDU 的 `pi_d/pi_s1/pc_d/pc/flush` 一族寄存器，slack 3.445~3.877 ns。**这是唯一的瓶颈路径；修掉它 Fmax 才会上台阶。**

### 2.2 逐级拆解（netlist 实测）

| # | 段 | 位置 | 增量 | 累计 |
|---|---|---|---|---|
| 0 | `add2_reg[3]/Q` | `EXU_Inst0:SLICE_X94Y17` | 0.518 | 7.110 |
| 1 | net `add2_reg[3]` **fo=128** | — | **1.574** | 8.685 |
| 2 | LUT5 `Control_inst0_i_563` | Control | 0.124 | 8.809 |
| 3 | LUT6 `Control_inst0_i_552` | Control | 0.124 | 9.752 |
| 4 | LUT3 `Control_inst0_i_477` | Control | 0.148 | 10.923 |
| 5 | LUT6 `Control_inst0_i_335` | Control | 0.328 | 12.232 |
| 6 | LUT6 `Control_inst0_i_210` | ALU `add_inst0` 附近 | 0.124 | 12.946 |
| 7 | net `Ex_result[9]` **fo=5** | — | 0.534 | 13.480 |
| 8 | LUT6 `ALU_i0/add_inst0/Control_inst0_i_23` | ALU | 0.124 | 13.604 |
| 9 | net `Ex_result[9]` | — | **1.385** | 14.989 |
| 10 | LUT3 `bp_update_target[9]_INST_0` | Control | 0.120 | 15.109 |
| 11 | net `bp_update_target[9]` **fo=66** | → BTB 分布式 RAM | 0.799 | 15.908 |
| 12 | LUT6 `bp_hold_exu_INST_0_i_13` | Control | 0.327 | 16.235 |
| 13 | CARRY4 ×3 `bp_hold_exu_INST_0_i_{8,4,3}`（**32 位目标比较器**） | Control | 0.743 | 16.978 |
| 14 | net `bp_misp_det2` | — | 0.660 | 17.638 |
| 15 | LUT5 `bp_hold_exu_INST_0_i_1` | Control | 0.313 | 17.951 |
| 16 | LUT6 `EXU_inst_clear_INST_0_i_1` | Control | 0.124 | 18.399 |
| 17 | net `EXU_inst_clear_INST_0_i_1_n_0` **fo=34** | — | 0.797 | 19.196 |
| 18 | LUT5 `dnpc_flag_INST_0` | Control | 0.124 | 19.320 |
| 19 | net `IDU_Inst0/flush` **fo=36** | — | 0.928 | 20.248 |
| 20 | LUT2 `IDU_Inst0/inst_d[11]_i_1`（NOP 灌入） | IDU | 0.124 | 20.372 |
| 21 | net `IDU_Inst0/inst0` **fo=278** | — | **2.118** | 22.490 |

### 2.3 逻辑级数统计与结论

**Control 自身只有 3 级 LUT**（第 18/19 段 `dnpc_flag` 与 `bp_hold_exu` 的最终或，各 1 级；`bp_misp_det` 的先导 LUT3/LUT6 各 1 级）。真正的深度来自它**前后两端**：

- **上游**：EXU `add2_reg` → ALU 32 位加法器（3 个 CARRY4）→ `Ex_result` → Control 的 `actual_target` 32 位 mux → 32 位目标比较器（3 个 CARRY4）。**两条 32 位进位链串在一个周期里。**
- **下游**：`bp_hold_exu`/`EXU_inst_clear`/`dnpc_flag` 三级组合 → IDU flush（fo=36，0.928 ns）→ `inst0`（fo=278，**2.118 ns**）。第 19-21 段合计 **3.17 ns**，全部是"高扇出 + 远距离布线"。

**两条 32 位进位链 + 一条 278 扇出的广播网**就是 >10 ns 组合通路的成因。若把第 9~15 段（1.385+0.124+0.120+0.799+0.327+0.743+0.660+0.313 ≈ 4.47 ns）替换成「1 拍寄存器 + 2 级 LUT（≈1.0 ns）」，即得 ≈12.4 ns ⇒ **≈80 MHz**。要再往 100 MHz 走，还必须处理第 19-21 段（3.17 ns）的扇出/局部性，以及第 1 段（fo=128，1.574 ns）。

### 2.4 ALU.sv 结构（回答"是否有 barrel shifter / 32 位进位链 / 减法实现的比较器"）

- **没有 barrel shifter**：`ALU.sv:66-77` 是 `d1 << d2[4:0]` / `>>` / `$signed(d1) >>>`，综合成 5 级 2:1 mux（LUT+F7/F8），延时与面积都在合理范围，**不是瓶颈**（关键路径上无 LUT1/SRL）。
- **有一条共享 32 位进位链**：`add.sv:18` 唯一一行 `result = add_1 + (choose_add_sub ? add_2_inv : add_2) + carry`；`ALU.sv:86-94` 全 ALU 只有 **1 个** add 实例 ⇒ add/sub 已共享（`ALU.sv:41-48`），设计是对的。
- **比较器用两条不同实现**：`alu_unsigned_comparator` 用 `(d1 < d2)`（`ALU.sv:37-40`，综合成比较器，面积小、不占 ALU 的 CARRY4）；`alu_signed_comparator` 复用 `add_result[BW-1]`（`ALU.sv:32-36`）——**有符号比较的差值计算压在 ALU 关键路径上**（作者已在 `ALU.sv:85` 注明），但这是 ID/EX 路径，不是当前最差路径。
- `alu_equal` 实际给的是"**不**相等"（`ALU.sv:61-64`，宏名误导），方向由 EXU 的 `inv_flag` 异或翻转（`EXU.sv:360`）——功能正确，但在 Control 侧造成了一次额外的语义绕行（§3.3）。

---

## 3. 具体低效点（均带 file:line）

### 3.1 【最贵】32 位目标比较器落在同一条链里 — `Control.sv:196-198`
`(actual_target != EXU_pred_target)` 被综合成减法式 32 位不等比较：反相链 + **3 个 CARRY4**（`timing_post_route.rpt:444-451`，0.743 ns）+ EXU_pred_target 的 32 位复制，估计 **≈40 LUT + 8 CARRY4**。
**关键观察**：因为 **`actual_taken == EXU_pred_taken` 时才需要比目标**，方向不等的那一拍目标比较是冗余的 —— 32 位减法的整个进位链在逻辑上可以完全省掉，只保留"方向相等时的 32 位 XOR-OR"。当前表达式写成 `||` 使综合器必须实现完整减法以避免阻塞。

### 3.2 【最贵】前递选择码"编码—再译码" + 5 深 mux — `Data_hazard.sv:81-102` → `Control.sv:316-328`
- `Data_hazard` 输出 3 位编码，经两级三目优先链（`Data_hazard.sv:81-85,98-102`）；
- `Control` 又把它**比较回 5 个常量 ×2 端口 = 10 次 3 位比较**（`Control.sv:316-320,323-327`）去驱动两个 **6:1×32** mux；
- 估算：Control 两路前递 **≈150~200 LUT**（32 位 6:1 mux 在 7 系列上约 32 LUT/路 + F7/F8，加上译码）。
改成 6 位独热（`exu_hit|mem_hit|pipe_hit|mem2_hit|wb_hit|rf`）直接驱动 mux 的 one-hot 输入，可省掉这 10 次比较（≈20~30 LUT + 1 级）。

### 3.3 同一组条件被编成 3 个活项 — `Control.sv:125,130,196`
`branch_flag & Ex_result[0] & ~mdu_busy & EXU_ctrl_valid`（L125）、`(branch_taken|jump_flag) & ~mdu_busy & EXU_ctrl_valid`（L130）、`EXU_ctrl_valid & ~(intr_take|system_redirect|trap_redirect)`（L196）——`~mdu_busy` 出现 2 次、`EXU_ctrl_valid` 出现 3 次。综合器会把共同子式提出（关键路径第 2 段 LUT5 就是它的痕迹），所以**实际收益很小**，只值 1 个 `masked = EXU_valid & ~mdu_busy` 中间信号的可读性收益。**不建议单独作为优化项。**

### 3.4 `assign EXU_ctrl_valid = EXU_valid;` 是空别名 — `Control.sv:124`
纯冗余，对面积/时序零影响（综合器直接连过去）。**不值得改**，列在此仅为完整性。

### 3.5 `EXU_inst_clear` 用组合逻辑驱动 15 个寄存器的清零端 — `Control.sv:291-293`
- 源：`intr_take | bp_mispredict | trap_redirect | (mem_stall & ~(branch_flag|jump_flag)) | load_use_stall`，其中 `load_use_stall` 自带 4~5 级（`Data_hazard.sv:116-123`：3 个 5 位比较 + 零检测 + 或树）
- 汇：`EXU.sv:197,289`（`valid_next` 与 9 个控制寄存器）、`EXU.sv:330`（5 个异常标志）
- **它是「一条指令是否作废」的判据，却是本拍从最多 5 级逻辑算出来的组合信号**；同时 `dnpc_flag`（`Control.sv:279`）与它共享大部分或项，两条树各自重复实现。

### 3.6 同选择信号的 32 位 mux 树重复两遍 — `Control.sv:219-220` 与 `Control.sv:307-309`
- `bp_redir_target`：`bp_misp_pend ? bp_pend_target : (actual_taken ? actual_target : EXU_pc+4)` —— 三级 32 位 mux（≈32 LUT + 1 个 32 位 +4 加法器 ≈32 LUT/8 CARRY4）
- `dnpc`：`intr_take ? mtvec : bp_mispredict ? bp_redir_target : (mret ? mepc : mtvec)` —— 又一级 32 位 mux
- 两条链的**选择信号几乎相同**，但 `bp_redir_target` 是 `dnpc` 的子表达式，综合器可共享；真正的问题是它们和 `actual_target` 一起构成 **三层 32 位 mux 串联**，把 Control 的 `dnpc` 输出推到 IFU 的 PC 寄存器前，深度 ≈5 级。

### 3.7 只用到 2 位却做了 32 位加法 — `EXU.sv:153`
`assign branch_target_low2 = (add1_reg + add2_reg) & 32'h3;` —— 只用 bit[1:0]，却让综合器在 EXU 里放（共享的）**32 位加法器**（估算 ≈32 LUT + 8 CARRY4）。等价写法 `branch_target_low2 = add1_reg[1:0] + add2_reg[1:0]` 只需 2 位加法器（≈2 LUT）；或者直接复用 ALU 的 `alu_res[1:0]`（`EXU.sv:345`）。**这条在 Quartus 的关键路径报告里出现过 `alu_opcode_reg → … → pred_*_reg`，属 ID/EX 侧路径，值得顺手改。**

### 3.8 `TRAP_ENABLE=0` 时的死逻辑 `EXU.sv:323-342,376-379` + `Control.sv:146-187`
`iaddr_misalign_reg` 与 `branch_target_low2`（≈33 FF + 8 LUT）每拍都在算，但 `exc_any≡0` 使其结果永远无人使用；`trap_cause` 四路优先编码器（`Control.sv:165-169`）、`trap_take_q_r`（`Control.sv:180-184`）同样。**综合器会删掉下游，但上游这部分状态仍在**（`illegal_exc` 等被 myCPU 引到 debug/CSR，见 `myCPU.sv:433-437`）。这是"功能开关"的合理代价，**不建议为省 40 FF 去动它**，但要知道：当前交付物的异常通道是**未验证死路**（`ila_使用说明.md:230-235` 已记录 `sim/tb_exc.sv` 不通过）。

### 3.9 未使用的端口 `Control.MEM_Rdata` — `Control.sv:36`（模块体内 **0 处引用**）
`myCPU.sv:379` 接的是 `LSU_Rdata`（`LSU.sv:176` 的已扩展读数据）。综合器会剪掉，但它是"接口意图残留"，会让后续读者以为 MEM 级 load 前递存在。**零成本删除，建议清掉。**

### 3.10 load-use 三个分级的比较器冗余 — `Data_hazard.sv:116-123`
`(EXU_rd==IDU_rs1)||(EXU_rd==IDU_rs2)` 与上面的 `exu_hit` 共用同一组 5 位比较器，但各自又配了独立的 `rd != 0` 与 valid 门控。估计三个分级合计 **≈25 LUT**，且它们各自是 4~5 级链，汇入 `Load_use_stall → IFU_stall → IDU_ready → EXU_inst_clear` 这条**贯穿 4 个模块的握手链**。

### 3.11 Data_hazard 每拍做 10 个 5 位比较 — `Data_hazard.sv:66-77,92-97`
`mem2_hit_rs1/rs2`（`Data_hazard.sv:71,96`）是**纯前递命中**，不参与任何 stall 判定。两个端口的零检测 `!= 0` 在综合里可合并，但 10 组 `(rd==rs)` 比较每拍都要付（估算 ≈50 LUT 逻辑 + 160 LUT 的 32 位 mux 选择逻辑）。**这是"5 级全互锁"的固有代价**，收益最大的改法是 §4.3 的"独热 + 需求位"组合。

### 3.12 资源预算（诚实标注为**估算**）

**重要限制**：仓库内**没有任何 per-module 资源报告**（已检查 `project_src/util_post_route.rpt`、`util_post_synth.rpt`、`v9_ila/.../board_top_gui_utilization_synth.rpt` 均无层次化表格），因此下表的 Control/Data_hazard/前递部分是我**按 RTL 结构逐位推算**的，**不是工具实测**：

| 模块/功能 | 估算 LUT | 依据 |
|---|---|---|
| Control 前递译码 + 两路 6:1×32 mux（`Control.sv:316-328`） | 150~200 | 6:1×32 ≈32 LUT/路 + F7/F8；10 次 3 位比较 ≈20 |
| Control 误预测判定（含 32 位比较器，`Control.sv:196-198`） | 55~75 | 32 位不等比较 ≈40 LUT + 8 CARRY4；或项/掩码 ≈15 |
| Control 重定向链（`Control.sv:219-220,307-309`） | 60~90 | 3 层 32 位 mux + 1 个 32 位 +4 加法器 |
| Control 其余（stall/clear/hold/intr/trap 编码 `Control.sv:251,268-301`） | 40~60 | 约 12 个一拍宽的或/与树 + 4 路优先编码器 |
| **Control 合计** | **≈300~420** | 约占 13006 LUT 的 2.3~3.2% |
| Data_hazard（10 组 5 位比较 + 3 分组 load-use + 2 条三目优先链 `Data_hazard.sv:56-123`） | 60~90 | 10×5 位比较 ≈50；零检测/门控 ≈20；优先链被 mux 吸收 |
| EXU 额外加法器（`EXU.sv:153`） | 32 | 32 位加法器 ≈32 LUT/8 CARRY4 |
| EXU 异常状态寄存器（`EXU.sv:323-342`） | 33 FF + 8 | `fault_inst_reg` 32 FF + 若干 |

参考锚点（实测，来自 `util_post_route.rpt`）：LUT 13006（逻辑 12232 / 分布式 RAM 124 / 移位寄存器 650，后者主要来自 ILA 采样管线，见 `util_post_route.rpt:196-211` 的 SRL16E=758 / SRLC32E=478）、FF 14765、DSP 12（=3 个 32×32 乘法器，`syn/vivado_50mhz_实测.md:188`）、BRAM 38.5（ILA 占 16.5，`ila_使用说明.md:278`）。

---

## 4. 优化机会（按性价比排序）

> 量化口径：WNS 3.445 ns @ 20 ns ⇒ 当前上限 62.9 MHz。迁就现实的结论见 §4.9。

### P1 —— 把误预测判定搬进 EXU 并寄存（**唯一能一次性搬走 3 级以上 + 32 位进位链的改动**）
- **RTL**：在 `EXU.sv` 新增（与 `add1_reg/add2_reg/pred_target_reg` 同处，物理贴在 ALU 旁）
  ```systemverilog
  // EX 拍组合算出"方向"和"2 位目标比较"，只寄存 5 位旁路信息
  wire        ex_taken  = branch_flag_reg | jump_flag_reg;
  wire [1:0]  ex_tgt_cmp = branch_flag_reg ? (branch_target_low2 ^ pred_target_reg[1:0]) : 2'b00;
  wire        ex_dir_mm  = ex_taken ^ pred_taken_reg;
  wire        ex_tgt_mm  = ex_taken & (|ex_tgt_cmp);
  logic ex_taken_q, ex_dir_mm_q, ex_tgt_mm_q;
  always_ff @(posedge clock) if (reset) {…} else if (valid_last & ready_next & ~mdu_stall) { … }
  ```
  一个 1 位方向 XOR + **2 位**目标 XOR（不是 32 位减法！`branch_target_low2` 的 bit[1:0] 恒为 0，所以目标比较只需 2 位）即可判定误预测，然后用 3 个 FF 送到下一拍。`Control.sv:196-198` 改成消费 `ex_dir_mm_q | ex_tgt_mm_q`（再加 `EXU_ctrl_valid` 掩码，改从 EXU 打拍输出）。
- **代价**：+3 FF（若同时寄存 `actual_target`/`actual_taken` 供挂起逻辑用则 +33 FF）、LUT **≈-40**（32 位 CARRY4 比较器消失）、周期 **-2**（误预测多 1 拍）
- **Fmax**：实测关键路径第 9~15 段合计 **≈4.47 ns** 消失，替换为 1 拍寄存器 + 2 级 LUT（≈1.0 ns）⇒ 15.90 → **≈12.4 ns，Fmax ≈80 MHz**
- **风险**：**中**。`bp_misp_pend` 的"先来先服务 + 只发一次"不变量（`Control.sv:222-247`）必须重新验证——判定晚一拍后，`bp_misp_det` 与 `bp_redirect_pending` 的清零条件（`Control.sv:245`）要重新推时序；`bp_update_*` 也必须跟着晚一拍（`Control.sv:254-256`）**或者**把 BTB 写口用原来的 EX 级值（两者其一，不能混）
- **工作量**：10~14 h（含 `sim/` 全量回归 7 个 prog + 重新实现）

### P2 —— 寄存 `EXU_inst_clear`（把它从"本拍算出的组合判据"变成"随指令携带的状态位"）
- **RTL**：`EXU.sv` 新增 1 位 `kill_reg`；`EXU_inst_clear` 只作为**置位**源（`kill_reg <= EXU_inst_clear&…`），清零端改用 `kill_reg`
- **代价**：+1 FF/级；LUT 中性
- **Fmax**：关键路径第 16~18 段（0.124+0.797+0.124 ≈ **1.05 ns**）+ 消除 fo=34 广播 ⇒ 再 **+0.8~1.0 ns**
- **风险**：**高**。`EXU_inst_clear` 必须与 `valid_next` 同拍生效（`EXU.sv:197` 与 `EXU.sv:289` 的顺序就是优先级），改成寄存后要保证"被冲刷的指令当拍就不产生副作用"这个语义不变。**这是三个不变量文件里反复强调的地方，必须先加断言再改。**
- **工作量**：6~10 h

### P3 —— 切分 `dnpc_flag` 的高扇出（IDU flush 用寄存器、IFU 重定向走本拍）
- **RTL**：`Control.sv:279` 派生两路：`id_flush = dnpc_flag`（→ IDU，改由 FF 输出）、`pc_redirect = dnpc_flag`（→ IFU，保持组合）
- **代价**：+2 FF；LUT 中性
- **Fmax**：第 19~21 段 **3.17 ns** 中的 `flush`（fo=36，0.928 ns）与 `inst0`（fo=278，2.118 ns）改善 **≈1.2~1.8 ns**。注意：这只是把扇出压力从组合网挪到寄存器输出网，**收益主要来自布线**，逻辑级数不变，所以 P3 单独实施只能拿到一部分。
- **风险**：**中**。IDU 的 flush 晚一拍 ⇒ IDU 会多活一拍错路径指令，必须同时把 `EXU_inst_clear` 的窗口覆盖住（与 P2 联动），否则错路径指令有机会进 EX。**必须与 P1 同批验证。**
- **工作量**：4~6 h

### P4 —— `Data_hazard` 输出 6 位独热 + 3 位需求位，`Control` 只做 mux
- **RTL**：`Data_hazard.sv:81-102` 改输出 `{exu,mem,pipe,mem2,wb,rf}` 独热；`Data_hazard.sv:116-123` 只输出 `exu_req/mem_req/pipe_req`
- **代价**：LUT **≈-30**
- **Fmax**：**≈-0.3~0.5 ns**（ID/EX 路径）。**明确说：单独做这一项不值得**（见 §4.9）
- **风险**：低；**工作量**：3~4 h

### P5 —— 打断 `load_use_stall` 的 5 级链（改由 EXU 侧输出需求位）
- **RTL**：把 req 位就近在 EXU/MEM/MEM_PIPE 寄存器旁算出（5 位比较挨着 rd 寄存器），只用 `IDU_rs1/rs2` 作为比较对象
- **代价**：LUT 中性；FF +4
- **Fmax**：`IFU_stall → IDU_ready → EXU_inst_clear` 链 **≈-1.0 ns**
- **风险**：中（分级口径必须与 `Data_hazard.sv:116-123` 严格一致，否则 §HAZARD-1 的"两份口径不同步"缺陷会复发）；**工作量**：4~6 h
- **周期收益**：顺带可以让 load-use replay 提前一拍，**每个 load-use 对省 1 拍**（EXU 级 3 拍 → 2 拍）

### P6 —— `branch_target_low2` 降到 2 位加法器
- **RTL**：`EXU.sv:153` 改 `(add1_reg[1:0] + add2_reg[1:0])`（bit0 恒 0，实际只需 1 位 XOR）
- **代价**：**-32 LUT / -8 CARRY4**
- **Fmax**：不在当前最差路径上，**单项 0 ns**；但它是 Quartus 报的 `alu_opcode_reg → pred_*_reg` 路径的一环，在 P1 之后可能上升为瓶颈
- **风险**：极低；**工作量**：0.5 h。**建议顺手做。**

### P7 —— 目标比较器降到 3 位（仅当 P1 不做时的替代）
- `Control.sv:197-198` 改成 `actual_taken & (EXU_pred_taken | (actual_target[2:0] != EXU_pred_target[2:0]))` 之类的窄比较。**只要 P1 做了，P7 自动被覆盖**（P1 用的是更彻底的 2 位方案）。**不要为 P7 单独排期。**

### P8 —— 删除死端口 `Control.MEM_Rdata`（`Control.sv:36`）
- 0 LUT / 0 ns，纯可维护性。**工作量**：0.1 h。建议随手清。

### P9 —— EX/MEM 之间插一级（结构性方案）
- **RTL**：ALU 结果与分支判定都进 EX2 寄存器，误预测判定放到 EX2；`EXU_inst_clear`、`dnpc_flag` 全部在 EX2 拍产生
- **代价**：+≈200 FF、+≈150 LUT；流水线 6→7 级；误预测惩罚 +1~2 拍；`para.sv` 里所有跨级参数与 `sim/` 全部 7 个 prog 需重跑
- **Fmax**：**≈+60~80%**（每级深度减半）
- **风险**：**极高**；**工作量**：40~80 h
- **建议**：**P1+P2+P3 做完若仍到不了 85 MHz 再考虑**。以本设计的文档密度（`syn/修复史_全量.md` 记录了每条不变量的踩坑史）来看，这个改动的回归成本会远超其频率收益。

### 4.9 诚实的结论：不要指望 100 MHz

1. **实测数据说明瓶颈不是纯逻辑深度**：`timing_post_route.rpt:400` 给出 logic 3.365 ns / route 12.532 ns，**布线占 78.8%**。即使把逻辑砍到 8 级（≈1.8 ns），只要布线仍占 80%，路径就是 ≈9 ns，Fmax ≈110 MHz——**理论上到得了**，但这条推理依赖"布线会同比改善"，而实际上：`add2_reg[3]` 的 fo=128（1.574 ns）、`Ex_result[9]` 的 1.385 ns、`inst0` 的 fo=278（2.118 ns）都是**扇出导致的远距离布线**，它们**不会因为逻辑变浅而自动消失**。P1/P2/P3 的真正价值在于**去掉了那些高扇出网本身**（32 位比较器、fo=34/36/278 的广播）。
2. **量化预期**：P1 ≈80 MHz；P1+P2 ≈83~85 MHz；再加 P3+P5 有机会摸到 **85~90 MHz**。**100 MHz 需要 P9 级别的结构改动，不划算。**
3. **不建议动的地方**：`ALU.sv` 的 barrel shifter（不是瓶颈）、`add.sv` 的共享加法器（已经是对的）、`MDU_pipelined` 的 3 个乘法器（已经把 2150 LC/419 CARRY4 压到 1/5，见 `syn/synth_report.md:38-42`，现在 12 DSP + 单拍寄存，**不是关键路径**）、`Data_hazard` 的 5 级全互锁（改成"用不到就不选"省不了多少，因为 mux 宽度才是成本）。
4. **更便宜的一条路**：`docs/vivado/vivado_50mhz_实测.md:149-154` 已经指出 ILA 版比引脚版低 4.8 MHz（67.95→63.14）。若目标是**让现有设计跑得更快**而不是"改 RTL 提速"，**把 ILA 采样宽度从 322 位降下来**（`ila_使用说明.md:283-286`：288 位→34 位探针的增量）是 0 风险的即得收益。

---

## 5. 与主流设计的差距

| 维度 | 本设计 (BigBird v9) | Rocket (5-stage) | BOOM (OoO) | CVA6 / Ariane | SweRV EH1 | VexRiscv |
|---|---|---|---|---|---|---|
| 发射宽度 | **1**（单发射，`myCPU.sv:361-444` 单套 EXU） | 1 | 2~4（可配置） | 1（可配 2） | **2**（双发射） | 1 |
| 流水级数 | **6**（IF / ID1 / ID2 / EX / MEM(+MEM_PIPE+MEM2) / WB；`myCPU.sv:9-13`、`IDU.sv:5-7`、`LSU.sv:9`） | 5 | 10+（乱序） | 6 | 4~5 | 2~5（可配） |
| 前递/旁路深度 | **5 级旁路**（EXU/MEM/MEM_PIPE/MEM2/WB，`Data_hazard.sv:81-102`），ID 级"隐式旁路 mux"在 Control（`Control.sv:316-328`） | 2~3 级（EX/MEM/WB） | 深度较大的旁路网络 + 唤醒 | 2~3 级 | 3 级 | 2~3 级（可配） |
| 投机恢复 | 分支在 **EX** 解析；误预测冲刷 **2 拍**（`Control.sv:279`+`291`）；错路径最远只到 EX | 分支在 **ID** 解析（更快），恢复 2 拍 | 需重命名/ROB 回滚 | 分支在 ID，恢复 1~2 拍 | 分支在 ID，恢复快 | 分支在 ID 或 EX（可配） |
| ALU 结构 | **单周期**，共享一个 32 位加法器（add/sub/有符号比较复用，`ALU.sv:86-94`），移位是 5 级 mux（`ALU.sv:66-77`） | 单周期 | 单周期（多发射） | 单周期 | 单周期 | 单周期 |
| 乘法 | **3 个 32×32 组合乘法器 → DSP48E1×12**，**单拍寄存**（`MDU_pipelined.sv:63-80,126-128`；DSP 数见 `vivado_50mhz_实测.md:188`） | 迭代或 DSP 映射 | **流水线乘法器**（1~4 拍吞吐） | DSP 映射、可流水 | DSP 映射 | 可选 DSP / 迭代 |
| 除法 | **32 拍恢复余数迭代，整机冻结**（`MDU_pipelined.sv:148-158`、`EXU.sv:181-183`） | 迭代，**不冻流水**（多周期单元 + 反压） | 迭代/流水 + 乱序掩盖 | 迭代，反压 | 迭代，反压 | 迭代，反压 |
| 冒险处理哲学 | **"停到数据可用"**（load-use 最长 3 拍 + 1 replay，`Data_hazard.sv:116-123`）；**MDU 忙冻结整机**（`EXU.sv:195`、`LSU.sv:152`）；除法期间分支判定都被屏蔽（`Control.sv:125,130`） | 只停必要的拍数；MDU 忙只反压发射级 | 乱序掩盖 | 精确选择性停顿 | 精确选择性停顿 | 可配置停顿 |
| 频率（同级别器件） | **62.9 MHz** 实测（本条路径） | ~100+ MHz @ 7 系列 | 较低（乱序开销大，实测常 <100 MHz @ 7 系列） | ~100 MHz | ~100+ MHz | ~100~200 MHz（无 Cache/无 BP） |

**差距定性**：
1. **前递网络比主流深 2 级**：主流 5 级流水只需要 2~3 个旁路源，本设计因为把 ID 拆成两级（`IDU.sv:129-169`）且 MEM 拆成三级（`LSU.sv:9`），被迫提供 5 级旁路。这**换来了"两个读口都在 ID 级组合读出 + 时序余量"**（`IDU.sv:149-150` 注释说明了动机），代价是 Control 里的两个 6:1×32 mux 与 10 组命中比较。**这是本设计 Fmax 只有典型 5 级单发射设计一半的根本原因之一。**
2. **投机恢复比主流慢**：Rocket/CVA6/SweRV 都在 **ID** 级解析分支（借用预测器给出的目标 + 更早的比较），本设计在 **EX** 级解析（`Control.sv:125,196`），且解析结果还要穿过一段长组合链才变成 flush。**把分支解析搬到 ID 能同时解决"恢复拍数"和"关键路径"两个问题**，但需要把 `branch_pc = pc_d + imm`（`IDU.sv:339`）的比较逻辑前移，且要处理 ID 级操作数还没前递完（`IDU.sv:347-356` 的 `add1/add2` 正是为此存在）——这也是 IDU 里那个加法器（`IDU.sv:339,362`）与 `mem_misalign` 早判（`IDU.sv:363-366`）存在的原因。**这是比 P1 更彻底的方向，风险也更高。**
3. **MDU 策略比主流保守**：主流把除法当"多周期功能单元 + 反压发射级"，前端继续跑；本设计直接冻死整机（`EXU.sv:195`、`LSU.sv:152`、`Control.sv:297` 三处同拍冻结）。对教学/验证是"正确性优先"的合理取舍，但吞吐代价是 34 倍。
4. **异常/中断通道比主流弱**：主流有精确异常的完整优先级与互锁；本设计 `TRAP_ENABLE=0`（`Control.sv:18`）、`sim/tb_exc.sv` 不通过（`ila_使用说明.md:230-235`）、且中断与同步异常之间**缺少互斥**（§1.5）。这是功能缺口，不是频率问题，但会限制本设计与主流对照的可比性。

---

## 附：复现与验证清单

- 关键路径全文：`project_src/timing_post_route.rpt:392-483`；前 20 条端点：`project_src/timing_worst_paths.rpt:17-60`
- 资源：`project_src/util_post_route.rpt:35-45,106,121`
- 改了 RTL 后的最短验证路径：`build_project_ila.tcl` 的 `DO_IMPL=0`（只到综合，约 5 分钟，`ila_使用说明.md:137-138`）
- 功能回归：`sim/run_iverilog.bat <prog>`（7 个 prog 全过才算通过，`ila_使用说明.md:215-226`）
- 每项改动必须同步更新的不变量文档：`syn/修复史_全量.md`（CONTROL-1..31 / HAZARD-1 / EXU-1..11 / IFU-1 / IDU-1..5）
