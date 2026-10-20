# v10 改造实施报告：前端解耦 / MDU radix‑4 / 异常体系 / 实现策略

本文是 `docs/CPU优化评审_汇总.md`（评审）的**实施篇**：那篇列了 13 项优化，本文只记录
本轮**确定动手的 5 项**——每一项都给出「问题（带 file:line）→ 改法 → 实测证据」，
以及**没做什么、为什么**。所有数字都是本仓库里跑出来的，可复现命令见文末 §7。

> 一句话结论：7 个整机程序**全部通过**，周期数从 84/88/253/215/242/288/330 降到
> 36/42/94/55/83/110/97（**几何平均 2.80×**，IPC 0.14~0.20 → 0.33~0.75）；
> 3 个异常专项程序从"一项都过不了"变成 **20/20 全过**；整机零回归。
>
> **v10.1 补充**：本节 5 项改动后来又在 WSL 下用 **Verilator 5.020** 做了一轮独立验证
> （交叉仿真 / 覆盖率 / 随机差分对拍黄金模型 / 变异测试），五项全部通过，并**顺带测出一个
> 真实功能缺陷**（DCache 背靠背 store 丢数据，见 §10）。验证报告单独成文：
> `docs/验证报告_v10_Verilator交叉仿真.md`。
>
> **v10.2 补充（§11）**：把那轮验证"点名说从来没跑过"的系统指令区补上（CSR 六种形式 /
> 中断 / `fence.i` / `ebreak`），**又抓出 4 个真缺陷并修掉**，用例从 18 项扩到 22 项，
> 交叉验证仍 22/22 等价、随机差分仍 1000 程序 0 失败、7 个定向变异全部被抓到。
> 面积 **+134 LUT / +28 FF**；WNS 3.553 → 2.203 ns，但**关键路径换成了 MDU 的
> `|a|·|b|` 归一链（本轮一行没动）**，两轮实现的同一条路径差 0.83 ns —— 归因与
> "下一步怎么改"见 §11.9。

---

## 0. 一览表

| # | 项 | 位置 | 结果 |
|---|---|---|---|
| 1 | **前端解耦**（取指队列 + ICache 全流水） | `rtl/IFU.sv`（重写）`rtl/ICache.sv`（重写）`rtl/myCPU.sv` | 取指节拍 **3 拍/条 → 1 拍/条**；`IFU_stall` 在 `prog_loop` 上 110→0 |
| 2 | **IROM 读使能门控** | `rtl/ICache.sv` 的 `mem_en` | `irom_en` 占空比 **≈100% → 24~96%（均值 68%）**，且计数器不再重复计 |
| 3 | **MDU：乘法器合一 + 除法 radix‑4** | `rtl/MDU_pipelined.sv`（+ `experimental/` 同步） | 32×32 乘法器 **3 → 1**（DSP 12→4）；除法 busy **33 拍 → 17 拍** |
| 4 | **异常体系补全** | `rtl/Control.sv` `CSR.sv` `EXU.sv` `Reg_Stack.sv` `IDU.sv` `myCPU.sv` | `TRAP_ENABLE` 默认 **0→1**；`tb_exc` **3/3 程序、20/20 断言全过**（原来 0 项过） |
| 5 | **布局约束 / 实现策略** | `build_project_ila.tcl` | directive + `phys_opt` + 可选 Pblock，全部开关化；见 §6 |

---

## 1. 前端解耦（本次最大收益项）

### 1.1 问题：不是"预测器不准"，是取指前端被结构限速在 3 拍/条

旧 `ICache` 的地址是**再寄存一拍**的（`mem_addr = cpu_addr_r`），然后用
`addr_same_r = (cpu_addr == cpu_addr_r)` 去判「返回的数据属不属于当前请求」。
同步 BRAM 本来就是"请求拍给地址、下一拍出数据"，再加这一拍寄存，实际延迟变成 2 拍，
于是 PC 必须**连续稳定 2 拍**才敢交付一条指令：

```
新 PC 出现 → 第 1 拍 hold（addr_same_r=0）→ 第 2 拍仍在途 → 第 3 拍才交付
            ⇒ 稳态 3 拍/条，0.33 IPC 上限
```

实测（改造前，本仓库 `_diag/tb_base.sv` + `_baseline_v9/rtl`）：

| 程序 | 周期 | 交付条数 | 交付占拍比 | `IFU_stall` 拍数 |
|---|---|---|---|---|
| `prog` | 84 | 12 | 14% | 36 |
| `prog_loop` | 288 | 58 | 20% | **110** |
| `prog_load_lane` | 215 | 40 | 19% | 87 |

`prog_loop` 的 110 拍停拍**全部来自 `icache_hold`**（load-use 0 拍、MDU 忙 0 拍）——
即前端自己卡自己，和后端一点关系都没有。

### 1.2 改法：地址组合直通 + 未命中旁路 + 4 项取指队列

`rtl/ICache.sv` 重写成**全流水、无停顿**：

* `mem_addr = cpu_addr`（**组合直通** BRAM）：BRAM 在 `cpu_req` 那拍采地址，下一拍
  `mem_rdata` 就是 `mem[addr(T)]`，**1 级延迟**。地址来自 IFU 的 PC 寄存器，本来
  就有一整拍余量，那额外一拍纯属自找。
* `resp_valid(T+1) = cpu_req(T)`；`idx_r/tag_r` 与 BRAM 地址**同一沿、同一源**采样，
  所以"返回的数据"和"做比较的 index/tag"结构上不可能错相。
* **未命中不停顿**：miss 那拍数据已经在 `mem_rdata` 上，直接**旁路**出去，同一沿把行填好
  ⇒ miss 的时序代价 **0 拍**。旧的 `hold`/重试机制整体删除（它正是 3 拍节拍的成因）。
* 计数器语义修正：`hit_cnt + miss_cnt` 现在**恰好等于取指次数**（旧实现在 PC 冻结的
  多拍里会重复计数）。

`rtl/IFU.sv` 重写成「PC 生成器 + 4 项队列」：

```
pc ──组合──> ICache（1 拍）──> [4 项队列] ──> IDU
 ▲                                 │
 └── pred / dnpc 决定下一拍 ────────┘（只在队列有空间时才发请求）
```

* **生产者**：队列有空间就每拍发一次请求，PC 每拍 `+4` 或跳预测目标。**不再看
  `ready`/`stall`** —— 这是解耦的全部意义。
* **消费者**：`valid = 队头有效`，`pop = valid & ready`（`ready` 里已含 `~stall`），
  和旧 IFU 的 `advance_en` 语义一一对应。
* **`pred_*` 跟着指令走**：`pred_taken/pred_target/pred_index` 与 `pc` 一起入队出队。
  这一条是**硬不变量**：旧结构里 IDU 是"在出队那拍现查预测器"，前端流水化后
  `fetch_pc` 早已是两条指令之后的地址，现查就会把别人的预测当成这条指令的
  （静默错，无任何报错）。所以 `Branch_Predictor.fetch_pc` 改接 `IFU.fetch_pc`，
  IDU 的 `pred_*_in` 改接 `IFU.pred_*_out`。
* **重定向**：`dnpc_flag` 当拍清空队列 + 清空在途请求 + `pc <= dnpc`，**不看
  `ready`/`valid`/队列深度**（旧 §IFU-1 不变量保留原样）。因为队列是缓冲，
  "发出即被接收"，预测跳转可以在发请求那拍就改 PC —— 旧的不变量在新结构下由构造保证。
* 队列深度取 **4**：够吸收 load-use(1 拍)/D-Cache 未命中(2 拍)的抖动；
  实测 `qmax` 在 `prog_loop` 只到 **1**（后端根本追得上前端了），
  在 `prog`/`prog_div` 这类短程序到 4（流量小、靠预取填）。

`rtl/myCPU.sv` 相应改动：

* `IFU_stall = IFU_stall_ctrl | dcache_hold`（**`icache_hold` 这根线整体消失**）；
  `IFU_mem_stall = dcache_hold`。
* `ICache.cpu_addr/cpu_req` 接 `IFU.ic_addr/ic_req`；`resp_valid` 接 `IFU.inst_valid`；
  `clr` 接 `icache_clr`（**这一根以前是悬空的**：`Control.icache_clr` 有输出、
  `myCPU` 也声明了网，但没接到 ICache —— fence.i 从来没清过 I-Cache，属于顺手修掉的漏接）。
* `Branch_Predictor.fetch_pc` / `IDU.pred_*_in` 改接 IFU 的对应输出（见上）。

### 1.3 实测

同一套测试台、同一批程序（改造后）：

| 程序 | 周期 | 交付条数 | 交付占拍比 | `IFU_stall` | 队列最大深度 |
|---|---|---|---|---|---|
| `prog` | 36 | 23 | 64% | 7 | 4 |
| `prog_mul` | 42 | 22 | 52% | 16 | 4 |
| `prog_div` | 94 | 18 | 19% | 72 | 4 |
| `prog_load_lane` | 55 | 48 | **87%** | 3 | 4 |
| `prog_load_use` | 83 | 55 | 66% | 22 | 4 |
| `prog_loop` | 110 | 90 | **82%** | **0** | 1 |
| `prog_div_pair` | 97 | 39 | 40% | 54 | 4 |

`prog_loop` 的 `IFU_stall` 从 110 降到 **0**，交付占拍比 20% → 82%。
剩下的停拍只有 `prog_div`/`prog_div_pair` 的 **MDU 多拍忙**（72/54 拍）——
那已经是另一项（§3）的账。

---

## 2. IROM 读使能门控（省电 + 修计数器）

**问题**：旧 `ICache` 把 `mem_en` 直接接 `cpu_en_r`，而 `cpu_en_r` 复位后恒为 1
（`ICache.sv` 原文 `cpu_en_r <= 1'b1;`），所以板上 `sync_mem` 的 `ren` **一直是 1**：
* 每拍都读一次 BRAM（PC 冻结、重定向、空转时照读）→ 白烧动态功耗；
* 同一次取指在 PC 冻结的多拍里被 `hit_cnt`/`miss_cnt` 重复累加 → 命中率统计不可信。

**改法**：`mem_en = cpu_req`（`ICache.sv`）。`cpu_req` 只在 IFU 真发一次取指那拍为 1；
队列满、重定向、复位期间都是 0。`sync_mem` 的契约本来就是「`ren=0` 时 `rdata` 保持
旧值」，因此消费侧必须只看 `resp_valid=1` 的拍 —— 新 ICache 正好就是这么写的。

**实测 `irom_en` 占空比**（`irom_en=1` 拍数 / 总周期）：

| 程序 | 改造前 | 改造后 |
|---|---|---|
| `prog` | 99% | 81% |
| `prog_mul` | 99% | 64% |
| `prog_div` | 100% | **24%** |
| `prog_load_lane` | 100% | 96% |
| `prog_load_use` | 100% | 76% |
| `prog_loop` | 100% | 92% |
| `prog_div_pair` | 100% | **45%** |

**诚实结论**：占空比均值 ≈ **68%**，省的是 **BRAM 读动态功耗的约 1/3**，不是数量级。
真正的价值在**第二半**：计数器现在一次取指只记一次，命中率/缺失率终于可用了
（`hit_cnt + miss_cnt == 取指次数`）。占用率高的用例（`prog_load_lane` 96%）说明
"每拍都发请求"本来就是高效前端的常态 —— 门控省的是**空转那部分**，不是常态那部分。

---

## 3. MDU：乘法器合一 + 除法 radix‑4

### 3.1 乘法器 3 → 1

旧实现为了"三种带符号组合都能选"，同时算三个 32×32 积（`prod_ss/prod_su/prod_uu`）：
* 32×32 无符号乘在 7 系列上一只要 4 个 DSP48E1 ⇒ **12 个 DSP**。

改法：只用**一个**无符号 32×32 乘，加符号修正：
```
mul_a/mul_b = 按 op_sel 选幅值（mul/mulhu 原值；mulh 双 abs；mulhsu 只 abs(d1)）
mul_neg     = 结果的符号（mulh: d1[31]^d2[31]；mulhsu: d1[31]；其余 0）
prod_mag    = {32'b0,mul_a} * {32'b0,mul_b}
prod_signed = mul_neg ? (~prod_mag + 64'd1) : prod_mag
```
正确性靠"64 位截断 + 取反恒等于真二补数积"：`|a|≤2^31`、`|b|≤2^32-1` ⇒ 积 < 2^63，
不溢出；`abs32(INT_MIN)=0x8000_0000` 恰好就是幅值 2^31，`INT_MIN*INT_MIN=2^62` 也不溢出。

**DSP 12 → 4**，代价是 2 个 32 位 abs 取负器 + 1 个 64 位条件取负器 + 两组 32 位输入
二选一（约 +230 LUT 量级）。

### 3.2 除法 radix‑4（一位商/拍 → 两位商/拍）

旧实现是 32 拍「左移-试减-回写」恢复余数法 + 1 拍结果窗口 = **33 拍 busy**。
改法：**两级 radix‑2 组合展开**（每个时钟做两位商），迭代 16 拍 + 1 拍窗口：

```
shifted1 = {r_rem[30:0], r_a[31]}      → rem1, ge1
shifted2 = {rem1[30:0], r_a[30]}       → rem2, ge2
q_nxt    = {r_q[29:0], ge1, ge2}
r_a     <= {r_a[29:0], 2'b00}
```
只改迭代支路那三行；`abs32` 幅值化、`sign_diff_r`/`d1_neg_r` 回正、
`div_res` 的除零/`INT_MIN÷-1` 边界 `unique case`、`busy=div_run|div_hold`、
`done=mul_stb|div_hold`、`res=div_active?div_res:mul_res_reg`、唯一 `always_ff`、
14 个状态寄存器的复位覆盖 —— 全部逐字保留。

**busy 拍数：33 → 17**（含发射拍 34 → 18）；6059 次除法全部恰好 17 拍。

代价：迭代组合深度从 1 个 32 位减法变成 **2 个串联的 32 位减法 + 2 个比较器**
（radix‑4 展开的固有代价）。这是 MDU 内部新的最长路径，上板看时序时值得单独确认。

### 3.3 验证

`_diag/mdu_verify/`（独立自检台，只编 `rtl/MDU_pipelined.sv` + `para.sv`，与整机 RTL 解耦）：
* 金标准在 TB 里用 64 位算术自算，除零与 `INT_MIN/-1` 显式特判（不依赖 Verilog `/` 的
  未定义行为）；negedge 采样避 NBA 竞争。
* **12107 条检查（mul 6048 / div 6059），errors=0**。5 个相位：8 操作 × 10×10 边界；
  3000 随机轮转；乘法角点 4×32×32；除法角点 4×32×32；back-to-back 连发 19 条
  （对应整机 `prog_div_pair`）。
* **变异测试**：注入 8 个典型 bug（mulh 取无符号高字 / mulhsu 符号反 / 缺 64 位取负 /
  `abs32(INT_MIN)` 错 / radix‑4 第 2 级丢被除数位 / 余数不回正 / 只迭代 15 拍 /
  `div_hold` 不置位）→ **8/8 全被检出**，证明测试台不是空转。
* 整机旁证：`prog_div` 253 → 94 拍、`prog_div_pair` 330 → 97 拍（两项改造叠加后）。

---

## 4. 异常体系补全

原来 `Control.sv` 的 `TRAP_ENABLE` 默认 0，注释写着"=1 时 `prog_loop` 仍复现 B4 症状，
故交付默认关"。本轮把整条通路真正打通，`TRAP_ENABLE` 默认改成 **1**，并且
`sim/tb_exc.sv` 的 3 个程序 **20 条断言全过**（改造前：一次陷入都产生不了）。

改造过程中一共挖出 **6 个真 bug**，全部是"不报错、只是现场错"的那一类：

### 4.1 B4 的真因：两拍补发把刚写好的现场冲成 0（C8 附带）

旧实现把同步异常做成「`trap_take`（登记）+ `trap_take_q`（下一拍补发重定向）」两拍对，
并要求所有登记条件都含这两根。问题：**补发那一拍 EX 级已经没有异常了**，
`trap_cause` 退化成 `0000`、ID 级 `pc` 也已经换成重定向后的值，于是把刚写对的
`mepc/mcause` 覆盖成 0。实测 `exc_illegal`：

```
cyc14 : mcause=2  mepc=0x1c   ← 第一次登记是对的
cyc15 : mcause=0  mepc=0x00   ← 补发拍把它冲成 0，mret 回到 0，无限重启
```

补发机制存在的唯一理由是「旧前端在 `ready=0` 时会丢掉重定向脉冲」。v10 的 IFU 里
`if (dnpc_flag) pc <= dnpc;` 是**无条件**的，所以补发不但没必要、还有害 ⇒
整体删除，`trap_redirect = trap_take`（单拍），`exc_pending` 天然只有一拍宽
（EXU 在 `trap_take` 那拍就把异常标志清掉，见 `EXU.sv` 的 `if (reset | trap_take)`）。
`dbg_mcause` / `dbg_mepc` 的观察口也因此不再是"每拍被冲一次"的。

### 4.2 `mepc` 写错了一条指令（C9）

`CSR.sv` 原来 `mepc_reg <= trap_commit ? pc : csrd;`，而 `pc` 是 **译码级** PC。
但同步异常是在 **EX 级**判出来的，两者差两条指令：

```
出错指令在 0x1c → 写进 mepc 的是 0x20 → 处理程序 mepc+4=0x24 → 正好跳过错指令
                                        或直接跑飞
```
改：新增 `Control.fault_pc = EXU_pc`（EX 级 PC），`mepc` 按来源三选一：
`trap_take → fault_pc`、`intr_take/ecall → pc`（这两个本来就在 ID 级判定，是对的）、
其余 → `csrd`（软件写）。

### 4.3 条件分支的 `mtval` 是"比较结果"而不是目标（C9b）

`fault_addr = Ex_result`。对 `jal/jalr`，`Ex_result` 就是目标地址；但对**条件分支**，
`Ex_result` 是**比较结果**（bit0 为方向）。改：
`fault_addr = (branch_flag|jump_flag) ? actual_target : Ex_result`，
`actual_target` 正好是 `jump_flag ? Ex_result : branch_pc` —— 对 load/store 仍取有效地址。

### 4.4 指令地址非对齐：晚一条指令 + 把分支操作数当目标（C11 / C11b）

`EXU.sv` 原来 `iaddr_misalign_reg <= ((branch_flag_reg|jump_flag_reg) & ((add1_reg+add2_reg)&3))`。
两个错：

1. **用的是 `*_reg`**，即"上一条"指令的现场 —— 于是这个异常永远**晚一条指令**触发。
   实测 `exc_jal_misalign` 里 `jal x5,+2`（目标 0x1e）**一次都没陷入**（trap=0）。
   改成用端口 `add1/add2/branch_flag/jump_flag`（= 本拍正在接收的那条），与
   `illegal_in`/`mem_misalign_in` 同源同拍。
2. **`add1+add2` 对条件分支根本不是目标**：`jal` 是 `PC+imm`、`jalr` 是 `rs1+imm`
   （bit0 由硬件清零），而**条件分支**是 `rs1+rs2`（比较操作数！），目标是
   `branch_pc = PC+imm_B`（IDU 早就算好）。原来一律相加，于是 `blt x1,x3,-8` 被算成
   `1+10=11`（低 2 位 `11`）→ **每轮凭空陷入一次**。实测 `prog_loop` 每 11 拍重启一次、
   `x1` 永远到不了 10。改后按 `jump_flag ? {1'b0,(add1[1:0]+add2[1:0])[1]} : branch_pc[1:0]`
   区分两者（低 2 位求和只要 2 位加法器）。

### 4.5 load / store 非对齐分不清（C12）

`trap_cause` 原来用 `funct3` 猜"这是 load 还是 store"：
```
exc_load_mis  = mem_misalign_exc & ~funct3[1] &  funct3[2]   // 只有 1xx（lbu/lhu）
exc_store_mis = mem_misalign_exc &  funct3[1] & ~funct3[2]   // 只有 001（sh）
```
但 **`lw` 和 `sw` 的 funct3 都是 010**、`lh` 和 `sh` 都是 001 —— funct3 里没有
"读还是写"这一位。于是 `lw` 非对齐被判成 **store** 非对齐（mcause 报 6，应为 4）。
实测 `exc_misalign`：`lw` @0x24 报 mcause=6，测试期望 4。
改：直接看**出错指令编码**的 `opcode[6:0]` 是不是 `S_opcode`（`fault_inst` 本来就在手，
与异常标志同拍锁存），既准确又不需要新增端口。

### 4.6 中断与异常可以同拍成立（C8）

`intr_safe` 少了 `~trap_redirect`，于是"同步异常"与"中断"能同拍都成立：
`trap_take` 让 CSR 登记 `mcause=异常码/mepc=异常指令`，而 `dnpc_flag` 的仲裁优先级
`intr_take > trap_redirect` 又把 PC 送去了 mtvec —— 两者目标恰好都是 mtvec，
所以现象**不是跑飞**，而是 `mepc` 被中断覆盖成错的 PC（`mret` 回不到出错指令），
或者 `mepc` 被同拍写两次。这类"目标相同、现场被踩"的 bug 只有异常嵌套时才暴露。
改：`intr_safe` 补 `& ~trap_redirect`。

### 4.7 CSR 写后读没有前递（C10）

CSR 写是**精确提交**的（走到 WB 级才落寄存器），而 `mret` 在**译码级**就要读 `mepc`
去改 PC —— 两者相隔 5 级，中间没有任何前递。而典型的陷入返回序列就是紧挨着的：

```
csrw mepc, x21      ; 处理程序把 mepc 改成"出错指令+4"
mret                ; 紧隔一条
```
于是 `mret` 读到**旧** `mepc`。实测 `exc_illegal`：处理程序明明写好了 0x20，
`mret` 还是回到 0x1c 的非法指令 → 23 次/400 拍无限陷入。

改：在 `Control.sv` 加一条 **4 深 CSR 写影子流水**（`csrwen_sh/csrval_sh`），
把 EX 级的 CSR 写事件（地址位图 + 写数据）往后打，在译码级做前递：
```
优先级（新→旧）：EX 级本体 > sh[0]=M1 > sh[1]=M2 > sh[2]=M3 > sh[3]=WB > 寄存器本体
```
写数据在流水里就是各级的 `Ex_result`（`csrrw` → `rs1+0`；`csrrs` → `csrs|rs1`），
所以不需要新数据通路。**EX 级本体必须参与前递**——这是距离 1 的那一档
（`mret` 在译码级时，它前面那条 `csrw` 正好在 EX 级），只前递影子链会漏掉它。
★ 不变量：只在 `EXU_valid & ~EXU_inst_clear` 那拍吸收 —— 被冲刷的指令不会真的写 CSR。

### 4.8 顺手修掉的漏接

`Control.icache_clr`（= `fence_i_flag & EXU_valid`）在 `myCPU` 里声明了、也接了
`Control` 的输出，但**从来没接到 ICache** —— `fence.i` 一次都没清过 I-Cache。
v10 把它接到新 `ICache.clr`。

### 4.9 `tb_exc.sv` 的三处采样时序错误（测试台 bug，非 RTL）

这三处是**测试台自己的**问题，此前从未暴露（因为 RTL 一次陷入都产生不了），
本轮一并修正，并在文件里写清了原因：

1. `trap_take` 上升沿那一拍读 `dbg_mcause` 读到的是**陷当前**的旧值 ——
   CSRs 在那一拍的时钟沿才落盘。改为下一拍采（`trap_edge` 打一拍）。
2. "看到 `x10=1` 写回后再等 12 拍取现场"—— 旧前端 3 拍/条时恰好赶在 ecall 的处理程序
   落地之前；前端快了 3 倍后就赶不上了（`ecall` 的 `mcause` 写发生在**译码级**，
   比它自己的写回早 5 拍）。改为**在 `x10=1` 写回那一拍立即取现场**。
3. `jal_misalign` 的 `x24 != 0xDE` 判据自相矛盾：处理程序统一做 `mepc += 4` 后 `mret`，
   对 0x1c 的非对齐 `jal` 来说 `mepc+4` 正好落在 0x20 那条 `addi x24,x0,0xDE` 上，
   所以**陷入处理完之后它本来就会合法执行**。判据改成"陷入那一刻 `x24` 还没被写"
   （`trap_r24`），这才是这句话真正想验的东西。

### 4.10 实测

```
exc_illegal      : trap=1  mcause=2  mepc=0x1c  mtval=0     handler cnt=1   recovered x24=0x55   → 7/7 PASS
exc_misalign     : trap=2  先 4(mtval=0x402) 后 6(mtval=0x403)  handler cnt=2  recovered x26=0x99 → 8/8 PASS
exc_jal_misalign : trap=1  mcause=0  mepc=0x1c  mtval=0x1e  handler cnt=1                          → 5/5 PASS
```

---

## 5. 整机回归（18 项全过）

命令：`powershell -NoProfile -ExecutionPolicy Bypass -File _diag\regress.ps1`
（替代失效的 `sim/run_all.sh`：7 程序 × {普通, 严格} + D-Cache 单元 + `tb_exc` × 3）

```
prog 36 / prog_mul 42 / prog_div 94 / prog_load_lane 55 / prog_load_use 83 /
prog_loop 110 / prog_div_pair 97    （普通与严格两种模式周期完全一致）
tb_dcache_unit PASS   tb_exc illegal/misalign/jal_misalign 全 PASS
==== [REGRESSION] ALL PASS (18 runs) ====
```

### 改造前后对照（同一测试台、同一程序、同一统计口径）

| 程序 | 周期 前 → 后 | 加速 | 提交条数 | IPC 前 → 后 | `irom_en` 前 → 后 |
|---|---|---|---|---|---|
| `prog` | 84 → **36** | 2.33× | 13 | 0.143 → **0.361** | 99% → 81% |
| `prog_mul` | 88 → **42** | 2.10× | 15 | 0.159 → **0.357** | 99% → 64% |
| `prog_div` | 253 → **94** | 2.69× | 11 | 0.040 → **0.117** | 100% → 24% |
| `prog_load_lane` | 215 → **55** | **3.91×** | 41 | 0.186 → **0.745** | 100% → 96% |
| `prog_load_use` | 242 → **83** | 2.92× | 45 | 0.182 → **0.542** | 100% → 76% |
| `prog_loop` | 288 → **110** | 2.62× | 59 | 0.201 → **0.536** | 100% → 92% |
| `prog_div_pair` | 330 → **97** | **3.40×** | 32 | 0.094 → **0.330** | 100% → 45% |

**几何平均加速 2.80×**。改造前的 IPC 与 `docs/CPU优化评审_汇总.md` / `teach/log` 里
记录的 0.17 / 0.05 / 0.114 / 0.187 / 0.183 / 0.202 一致（差异只来自"提交条数"的
统计口径），说明基线是同一套口径量的，对照可信。

### 5.1 面积代价（Vivado 2025.2 综合后，同一工程同一 flow，`project_src/util_post_synth*.rpt`）

| 资源 | 改造前 | 改造后 | Δ |
|---|---|---|---|
| LUT as Logic | 11939 | 12337 | **+398**（+3.3%） |
| LUT as Memory | 914 | 914 | 0 |
| Slice Registers | 14072 | 14659 | **+587**（+4.2%） |
| F7 Muxes | 1651 | 1653 | +2 |
| F8 Muxes | 638 | 639 | +1 |
| Block RAM Tile | 38.5 | 38.5 | 0 |
| **DSPs** | **12** | **4** | **−8**（−67%） |

代价构成（对得上）：
* 取指队列 4 × (32 pc + 32 inst + 1 + 32 target + 6 index) = **412 FF** + 在途元数据 **103 FF**
  = 515 FF；再减掉旧 ICache 里被删掉的 `cpu_addr_r(32) + align_*_r(30) + resp_valid_r`
  ≈ −63 FF，以及旧 IFU 的 `valid` 寄存器等 ⇒ 净约 +430 FF。
* CSR 写影子流水 4 × (16 + 32) = **192 FF**。
* LUT +398：ICache 的旁路 mux、IFU 队列移位/落点选择、`fault_addr` 的 `actual_target` 选择、
  2 位目标低 2 位加法器、MDU 的符号修正（2 个 32 位 abs + 1 个 64 位条件取负）。

**一句话**：用 **+398 LUT / +587 FF**（占 7z020 的 0.75% / 0.55%）换 **2.80× 性能**、
**−8 个 DSP**、以及一套真正能用的异常体系。面积从来不是这颗核的瓶颈（总量仍只占
23% LUT / 14% FF）。


### 加速从哪来（分解）

* **前端解耦**贡献最大且普适：所有程序都在 2.1×~3.9× 区间。
* **MDU radix‑4** 只在 `prog_div` / `prog_div_pair` 上叠加：若只做 radix‑4 不做前端，
  `prog_div` 预期 253−4×16 = 189 拍；只做前端不做 radix‑4 预期 94+4×16 = 158 拍；
  两者都做 = **94** 拍（实测），与叠加模型吻合。
* **异常体系**对这三个"正确程序"没有性能影响（它们不陷入），收益是**正确性**。

---

## 6. 布局约束 / 实现策略

改的是 `build_project_ila.tcl`（**没有动 `v9_board_ila.xdc` 的时序/引脚约束**，
以便两种模式共用同一份 XDC、报告可比）。

### 6.0 顺手发现的一处 RTL 侧时序回退（已修）

第一次跑 no-ILA 时序时，最差路径的**端点**变了：

```
起点: u_cpu/EXU_Inst0/add1_reg_reg[0]/C            ← 老路径的同一源
终点: u_board_top/irom_inst/g_rom.rdata_reg_*/ENARDEN          ← IROM 读使能!
      u_cpu/IFU_Inst0/g_queue[2].q_ptg_reg[*]/CE              ← 队列槽时钟使能!
```

也就是说：**我新加的"读使能门控 + 队列清空"把 `dnpc_flag` 这条长组合链
（`EXU add1_reg → ALU → Control 误预测判定`）接到了一个全新的、扇出很大的负载上。**
这属于"优化 A 把优化 B 的最差路径拉长了"，必须承认并修掉：

* `ICache.mem_en` 是 `ic_req`；`ic_req` 原来带 `~flush` ⇒ 把 `dnpc_flag` 直接拖到 BRAM 使能。
  **去掉 `~flush`**：正确性由"flush 优先级最高"保证（`pc_f` 先判 `dnpc_flag`、
  `meta_v` 被 flush 清零 ⇒ 那拍读回来的响应 `push=0` 绝不会进队列），
  代价只是 flush 那拍多发一次注定被丢弃的 BRAM 读。
* `push` 原来也带 `~flush`，同理去掉（flush 分支在 always_ff 里优先级更高，CE 上不需要它）。

改完 `mem_en` 只依赖 `room`（队列有空位）与 `~reset`，不再依赖重定向链。
（这一处是**实测驱动**的修改，不是猜的：`project_src/timing_noila.default.rpt`。）

### 6.1 为什么这么改（依据是上一轮实测）


`project_src/timing_post_route.rpt` 里最差路径 15.897 ns 的构成：
**逻辑 3.365 ns（21.2%）+ 布线 12.532 ns（78.8%）**，15 级逻辑。
而全设计只用了 13006 LUT / 14765 FF（7z020 的 24% / 14%）—— **面积远远不是瓶颈，
布线延时才是**。所以策略重点是"减少拥塞 / 缩短线长"，而不是拼命优化逻辑级数：

| 手段 | 针对什么 |
|---|---|
| 综合 `-directive PerformanceOptimized` | 默认 `default` 偏面积，时序优先会做更多复制/重构 |
| 实现 `opt=Explore` / `place=AltSpreadLogic_high` / `route=AggressiveExplore` | 78.8% 是布线延时：要么把逻辑摊开减少拥塞，要么让布线器多迭代 |
| `phys_opt_design -directive AggressiveFanoutOpt`（place 后） | 针对实测 **fo=278 / fo=128** 两根高扇出广播网做**寄存器复制** |
| `phys_opt_design -directive ExploreWithHoldFix`（route 后） | 实测 **WHS 只有 +0.013 ns**，hold 极紧，route 后必须再修一次 |
| 可选 Pblock（`PB_ENABLE=1`） | 把 CPU 核心 / 存储器 / ILA 分到不同时钟区域，见 6.3 |

**踩到的坑（写在这里省下一次）**：`phys_opt_design -force_replication_on_nets` 的签名是
`-force_replication_on_nets <args>`，**必须给一串网表对象**；不带参数直接报
`ERROR: [Common 17-157] Error parsing command line options`（实测 strategy run 就倒在这）。
"让工具自己挑高扇出网去复制"应该用 directive `AggressiveFanoutOpt`，不是那个开关。

### 6.2 开关化（可复现对照组）

```tcl
set IMPL_MODE "strategy"   # "default" | "strategy"; 可用环境变量 IMPL_MODE 覆盖
set PB_ENABLE 1            # 只在 strategy 模式有效
set PROJ "${PROJ}_${IMPL_MODE}"   # 两种模式用**不同的工程目录**，可先后跑、直接比报告
```
`default` 模式 = 与改造前完全一致的流程（默认 directive、无 phys_opt），
用来做对照；`strategy` 模式才下发上面那些属性。
报告文件名也带 `$RUN_TAG` 后缀，两套结果不会互相覆盖。

### 6.3 Pblock（粗粒度）

由 scripts 在 `project_src/v10_pblocks.xdc` 现场生成（不入库、可开关）：

| Pblock | 装什么 | 区域 |
|---|---|---|
| `p_cpu` | `u_board_top/u_cpu` | 左半 `SLICE_X0Y0:X49Y299` + DSP/RAMB |
| `p_mem` | `irom_inst` / `dram_inst` 的 BRAM | 右下 `RAMB18_X1Y160:X1Y319` 等 |
| `p_ila` | `u_ila_0`（ILA 自身 ~24 个 BRAM + 大量 FF） | 右上 `SLICE_X50Y150:X99Y299` |

**刻意用"半个器件"这种粗粒度**：Pblock 收得太紧会反噬（工具无法合法化 → 局部拥塞），
粗粒度只调"邻居关系"。而且 `IMPL_MODE=default` 随时能跑对照组量化收益。

### 6.4 顺手修掉的构建脚本炸弹（很重要）

`build_project_ila.tcl` 原来有这么一段：
```tcl
set WSRC "E:/share doc/v9"      ;# 仓库正本
foreach f {board_top_ila.sv ...} { file copy -force "$WSRC/board/$f" "$WORK/board/$f" }
foreach f [glob "$WSRC/rtl/*.sv"] { file copy -force $f "$WORK/rtl/[file tail $f]" }
```
`E:/share doc/v9` 在本机**是存在的**。也就是说：**在这个目录里改完 RTL 一跑综合，
就会被正本覆盖回旧代码**，而日志的"源文件清单"只打文件名、不打时间戳，看不出来。
本轮 RTL 改造正好全部落在 `$WORK/rtl`，所以把它改成：
* `SYNC_FROM_WSRC = 0`（默认）：**只补缺失文件，绝不覆盖已存在的**；
* `SYNC_FROM_WSRC = 1`：显式要求时才用正本强制覆盖（并打印提示）。

另外两处环境适配（都写了原因，不写下次还会踩）：
* `set_property source_mgmt_mode None`：2025.2 在本机 **automatic hierarchy update 的
  层次扫描会静默失败**，报 `CRITICAL WARNING: [filemgmt 20-730] Could not find a top module`，
  随后 `launch_runs` 以 `Unable to launch Synthesis run. No Verilog or VHDL sources found`
  失败 —— 而文件都在 fileset 里、`FILE_TYPE` 都是 `SystemVerilog`、逐文件
  `read_verilog` 零报错。**用原始 RTL 也能复现**，证明与 RTL 无关。手工模式跳过层次扫描，
  综合按 fileset 清单跑，结果等价。
* `launch_runs` 会 fork `runme.bat`/`rundef.js`，子进程在本沙箱里被拒
  （`rundef.js(122,5) JavaScript runtime error: Access denied`），run 永远不动。
  因此测量改用 `_diag/vivado_inproc.tcl`：**同一个 Vivado 进程内**
  `synth_design → opt/place/phys_opt/route`，只写 `$WORK`。

### 6.5 实测结果

**先说清楚这次能量到什么、量不到什么**（本机是受限沙箱环境，不是完整桌面）：

* `launch_runs`（工程模式的正式流程）**跑不了**：它 fork `runme.bat`/`rundef.js`，
  子进程被文件沙箱拒绝（`rundef.js(122,5) JavaScript runtime error: Access denied`），
  run 永远 0%。
* 带 ILA 的 `opt_design` **也跑不了**：卡在
  `Phase 1.1.1 Generate And Synthesize Debug Cores` 的 `dbg_hub_CV` IP 生成（同一个
  fork 子进程问题），日志 15 分钟零增长。
* 所以时序/面积分两部分给：**综合（含 ILA）**用 `_diag/vivado_inproc.tcl` 拿到了；
  **实现（布局布线）**改用 `_diag/vivado_noila.tcl` —— 顶层换成 `board_top_ila`
  （MMCM + CPU + IROM/DRAM，**不含 ILA**），全程单进程，既避开 debug hub，又正好把
  上一轮评审点出的"调试基础设施占 37% LUT"从数据里摘掉，CPU 本身看得更清楚。

> ⚠ 因此下面 `noila` 的**绝对值不能**和 `project_src/timing_post_route.rpt`（含 ILA，
>   WNS +3.445 ns / Fmax 61 MHz）直接比。它只用于 **同口径的 default vs strategy 对照**。

（结果表见 §6.6）

**综合面积（含 ILA，同 flow 前后对照）**：见 §5.1 —— LUT +398、FF +587、**DSP 12→4**。
其中 DSP 的 −8 直接来自 MDU 乘法器合一（Vivado DSP 报告里 `MDU_pipelined` 只剩
4 个 DSP48E1，且映射为 `A*B` / `PCIN>>17+A*B` 各 2 个）。

### 6.6 default vs strategy（noila 顶层，布局布线全流程，单变量对照）

同一份 RTL、同一份 `v9_board_ila.xdc`、同一样片，只换实现策略：

| 变体 | 实现策略 | WNS (ns) | WHS (ns) | 折算 Fmax @20ns 约束 |
|---|---|---|---|---|
| `default` | 全默认 directive，无 phys_opt | **+3.553** | +0.040 | **60.6 MHz** |
| `synth_only` | 只 synth `PerformanceOptimized` | **+3.553** | +0.040 | 60.6 MHz |
| `fanout_only` | 只加 `phys_opt(AggressiveFanoutOpt)` + route 后 `ExploreWithHoldFix` | **+3.553** | +0.040 | 60.6 MHz |
| `strategy` | 上面两个 **再叠加** `opt=Explore` + `place=AltSpreadLogic_high` + `route=AggressiveExplore` | +2.722 | +0.029 | 58.0 MHz |

**这是一个必须如实报告的负结果：把四个手段一起上，时序反而差了 0.83 ns。**
而且单变量分解很干净：

* 综合 directive **中性**（±0）；
* `phys_opt` 的高扇出复制 + route 后 hold 修复 **中性**（±0）；
* **全部损失来自 `opt=Explore` / `place=AltSpreadLogic_high` / `route=AggressiveExplore` 这一组**，
  其中 `AltSpreadLogic_high`（"把逻辑摊开以减少拥塞"）嫌疑最大。

原因：本设计只占 **24% LUT / 14% FF**、`report_design_analysis` 里**没有拥塞**。
对"布局还很空"的设计，"摊开"只会让每条线更长；而本设计的最差路径不是被挤出来的，
是**一条 15 级逻辑的长组合链 + 两根高扇出广播网**（`dnpc_flag` fo≈36→278、
`EXU_inst_clear` fo=128）要走长线。对这类问题，"摊开 + 多迭代"没有着力点。

> 抖动说明：三个变体给出**完全相同**的 3.553 ns，说明这颗设计的收敛点是稳定的、
> 这里不存在 ±0.1~0.2 ns 的 P&R 噪声把结论吃掉的可能。

### 6.7 结论与建议（可直接执行的取舍）

1. **推荐配置 = `IMPL_MODE=default`**（或 `synth_only` / `fanout_only`，三者等价）。
   **不要**开 `AltSpreadLogic_high`。
2. 想再提频率，优先级应当是 **① 削高扇出（RTL/显式点名）→ ② 才轮到实现策略**：
   * 真正的物理瓶颈是 `dnpc_flag`(278) / `EXU_inst_clear`(128) 这两根广播。
     手段：RTL 里按读者分组复制；或 `phys_opt_design -force_replication_on_nets [get_nets {...}]`
     **显式点名**（这个开关必须给参数，见 6.1 的坑）。
   * ★ 本轮已经**顺手削掉一处**：`ic_req`/`push` 里多余的 `~flush`
     （见 §6.0），把 `dnpc_flag` 从 IROM 读使能与队列 CE 上摘掉，单这一处就值 **+1.17 ns**
     （no-ILA 上 2.383 → 3.553）。这比任何 directive 都有效。
3. **Pblock 在本设计上没有意义**（24% 面积、无拥塞，分区只会限制工具），
   所以 `PB_ENABLE` 默认我留的是 1，但**建议改成 0**；代码留着是为了将来加外设/ILA 变大
   之后还能一键开。（诚实说明：本轮没有跑到带 Pblock 的 A/B —— 带 ILA 的实现流程在本
   沙箱下起不来，见 6.5；Pblock 的结论是**基于"无拥塞 + 24% 利用率"的推断**，不是实测。）
4. **要跑 100 MHz，靠约束做不到**：20 ns 约束下只剩 3.5 ns 余量，也就是 50 MHz 时约 18%
   余量；到 100 MHz 需要 10 ns 收敛，必须动 RTL 结构（那条
   `EXU add1_reg → ALU → Control → dnpc` 链），不是改 directive 能解决的。




---

## 7. 复现命令

```powershell
# 0) 环境（Vivado 需要把 HOME/TEMP 重定向到工作区内，原因见 _diag/vivado_env.ps1 头注释）
# 1) 全量回归（iverilog；等价于原 sim/run_all.sh 的覆盖）
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\regress.ps1
# 2) 基线对照（用 _baseline_v9 里的改造前 RTL，同一测试台同一口径）
#    见 _diag/tb_base.sv + _diag/base_*.log
# 3) MDU 独立自检
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\mdu_verify\run.ps1
# 4) Vivado 面积/时序（在同一个 Vivado 进程内跑完综合+实现）
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\vivado_inproc.ps1 -Mode default
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\vivado_inproc.ps1 -Mode strategy
# 5) 正式上板工程（工程模式，正常桌面环境下用）
set IMPL_MODE=strategy && vivado -mode batch -source build_project_ila.tcl
```

---

## 8. 本轮**没有**做什么（以及为什么）

| 没做 | 原因 |
|---|---|
| 把分支判定搬到 ID 级 | 要同时把 5 级前递压到 2~3 级、给 ID 加专用比较器、处理操作数未就绪 —— 属于推倒重做前端，与现有 7 个回归 + 高密度不变量文档冲突，收益远不抵风险。参考 §1 的实测：**先把取指做到 1 条/拍，收益比这个更大**。 |
| 改 PHT 初值 / 给 jump 旁路 PHT | 这属于下一轮（评审 §4 的第 5 项）。实测 `prog_loop` 仍是**每轮 1 次误预测**（9 误预测 / 10 条控制流），这是当前剩余的最大单项：`prog_loop` 110 拍里约 36 拍（12%）花在误预测恢复上。 |
| 删 ILA / 改 50MHz 时钟 | 属于交付构建的取舍，不是 RTL 问题；本轮不碰 `board_top_ila.sv` 的 MMCM 分频，板上仍是 50 MHz，只是把时序余量做出来。 |
| D-Cache `data[]` 单写口、RF → LUTRAM | 面积项，不影响功能/性能，且与本轮 5 项目标无关，留作下一轮。 |
| ~~`csrr`（软件读 CSR）的 RAW 前递~~ | **v10.2 已做**（§11.3）：只给 `mret` 做前递是不够的，现在 4 深影子链服务所有 CSRR* 读。 |
| ~~`csrrc`（funct3=011）语义~~ | **v10.2 已修**（§11.2）：原来算的是 `rs1 + csr_addr`。 |
| `csrrw` 写只读/未实现 CSR 不退陷 | 规范要求报非法指令，本核静默忽略（没有写位）。属**已知偏差**，改它会让"读写未实现 CSR"从无害变陷入，本轮不动。 |
| 删死代码（LSU 里约 80 行 load 扩展链等） | 清单见验证报告 §10；综合已经裁掉，**对面积/时序无影响**，只减阅读成本，留作下一轮。 |

---

## 9. 已知风险 / 上板前要确认的三件事

1. **MDU 迭代路径变长**：radix‑4 展开让除法一次迭代里串了 2 个 32 位减法 + 2 个比较器。
   这是 MDU 内部新的最长组合路径，Vivado 时序报告里应单独看 `MDU_i0` 那一段。
2. **取指队列的面积**：4 × (32 pc + 32 inst + 1 + 32 + 6) ≈ 4×103 = 412 FF + 移位 mux。
   实测 `qmax` 在多数程序只到 1~4，若面积紧张可以把 `QDEPTH` 降到 2 再回归一遍。
3. **`TRAP_ENABLE=1` 之后异常路径进了 `dnpc` 仲裁**，组合深度略增（`trap_cause` 优先级链
   + `fault_addr` 的 `actual_target`）。若时序吃紧，`TRAP_ENABLE=0` 仍是可用的整块关断开关。

---

## 10. v10.1：Verilator 交叉验证查出并修掉的缺陷

完整报告见 `docs/验证报告_v10_Verilator交叉仿真.md`（含方法、覆盖率、随机差分、变异测试、
死代码清单、复现命令）。这里只记**改了 RTL 的那一处**，以及它对本文其它数字的影响。

### 10.1 ★ 真缺陷：背靠背两条 store，第二条被静默丢弃

- **复现**（3 条指令，`_diag/vsim/probe_store.py` 的 A 变体）：
  `sh x23,174(x31)` → `sb x6,168(x31)` → `lb x16,168(x31)`，读回 **0**（应 0x3F）。
  总线级波形确认：第二条 store 的 `perip_wen` 一次都没出现。
- **根因**：`rtl/DCache.sv` 用三态状态机 `WR_IDLE/WR_ISSUE/WR_WAIT` 生成 store 单拍脉冲，
  而 `store_fire` 只在 `WR_IDLE` 成立、`WR_IDLE` 又只有"出现一拍没有 store"才回得去 →
  连续 store 里第二条永远拿不到脉冲。
- **修法**：删掉状态机，改用「本拍这次访存是否真的被受理」判定：
  `store_fire = cpu_en & cpu_wen & cpu_adv`，`cpu_adv` 由顶层给
  （`myCPU.sv`：`lsu_adv = WBU_ready & ~dcache_hold & ~EXU_mdu_busy`，与 `LSU.sv` 的推进条件同式）。
  **三种写法只有这一种两边都对**：纯电平会在 MDU 忙时同一条写 4 拍（被 write-once 断言抓到
  294/1000），状态机会丢第二条，`& cpu_adv` 才两者兼顾。
- **验证**：iverilog 18/18（周期数 36/42/94/55/83/110/97 **一字未变**）、
  Verilator 18/18 逐拍等价、随机差分 1000 程序 / 55000 指令 0 失败。
- **影响面**：会静默破坏正确性（相邻两次写内存，后一次丢失），但**不影响本文 §5 的性能数字**
  —— 它不改变任何指令的节拍（修复前后同一用例周期数完全相同）。

### 10.2 验证设施同时修的 4 处（不改 RTL，但影响结论可信度）

| # | 问题 | 影响 | 修法 |
|---|---|---|---|
| 1 | TB 在 `posedge` 上释放复位（竞争） | iverilog 与 Verilator 整体差 1 拍 | 改成 `@(negedge clk)` 释放（`tb_iverilog` / `tb_exc` / `tb_msim`） |
| 2 | 注释 `//   Verilator ...` 被当成 Verilator 元注释 | Verilator 直接编译失败 | 改成 `// - Verilator ...`（3 个文件） |
| 3 | write-once 断言只比地址 | `sh`+`sb` 写同一个字被误判成"重复写"（3/1000 假失败） | 改成比 (地址, 数据, 掩码) |
| 4 | GPR 快照窗口 = ecall 进 ID + 8 拍 | ecall 前紧邻 load 时，最后一条 load 的写回落在窗口外 | 不动 TB 口径，随机程序末尾补 4 条 ALU；列为已知局限 |

### 10.3 需要重测的数字

DCache 改动删了 2 个状态 FF、加了一根 AND，对面积/时序只可能略好，但 §5 里的
**+398 LUT / +587 FF / WNS 3.553 ns** 是修复**之前**测的。要拿最终数字需重跑
`_diag/vivado_inproc.ps1`（本机沙箱能做，约 10 分钟/配置）。

### 10.4 新增的可复跑工具（`_diag/vsim/`）

| 文件 | 作用 |
|---|---|
| `xcheck.sh` | iverilog ↔ Verilator 18 用例逐拍对拍（`build|run|cmp|all`） |
| `cov.sh` | 行/翻转覆盖率 + 未覆盖行清单（`NRAND=` 可加随机程序） |
| `randtest.py` | RV32IM 随机程序 + 自写黄金模型 ISS，32 寄存器全量比对 |
| `mutate.sh` | 变异测试（4 期望抓到 + 2 期望抓不到=死代码证据） |
| `probe_store.py` | §10.1 那个缺陷的最小复现（5 个变体） |
| `dbg_store.sh` | 打印 store 总线逐拍事件（`[DST]`/`[BUS-W]`/`[BUS-R]`） |
| `covmain.cpp` | Verilator 5.020 的 `--binary` 不写覆盖率文件，自写 main 补上 |

---

## 11. v10.2：系统指令区（CSR / 中断 / fence.i / ebreak）—— 4 个真缺陷

完整验证记录见 `docs/验证报告_v10_Verilator交叉仿真.md` §14。这里记**改了 RTL 的部分**
与面积/时序。

### 11.1 起点：四条缺陷全在"没人跑过"的指令上

**起点**：v10.1 的验证报告 §11 明确写了一句"中断、CSR 软件写、`fence.i`、`ebreak` 从来没被
执行过"，覆盖率 27% 的空白全在这里。补用例的顺序是"先写定向程序 → 一跑就红 → 再修"，
所以下面每条都是**先有失败现场、后有修法**。

| # | 缺陷 | 位置 | 严重度 |
|---|---|---|---|
| 1 | `csrrc` 写进 CSR 的值是 `rs1 + CSR 地址` | `rtl/IDU.sv` + `rtl/ALU.sv` | 高（写坏 CSR） |
| 2 | CSR 读口没有 RAW 前递，`csrw` 后紧跟 `csrr` 读到旧值 | `rtl/IDU.sv` `rtl/Control.sv` | 高（静默读错） |
| 3 | 读只读 CSR 时 `rd` 取的是"准备写的新值"而不是"读值" | `rtl/IDU.sv` + 下游 3 处 `\|csr_wen` | 高（静默读错） |
| 4 | `fence.i` 把 PC 拨到 `mtvec`（默认 0 = 整机重启） | `rtl/Control.sv` | 极高（整机级） |

**补的用例**（原计划里叫 `tb_csr` / `tb_intr` / `tb_fencei`，实际合成一个参数化的台子）：
`sim/gen_sys_progs.py` 生成 4 个程序，`sim/tb_sys.sv` 用 `+kind=csr|intr|fencei|ebreak` 判，
共 **39 项检查**；`_diag/vsim/mutate_sys.py` 用 7 个定向变异证明这 39 项"有牙"。

### 11.2 缺陷一：`csrrc` 算成 `rs1 + csr_addr`

- **IDU 侧**：`add_src2` 只认 `funct3==001`（取 0）与 `010`（取 CSR 旧值），`011` 落到
  `imm` 分支 —— 而 SYSTEM 指令的 `imm` 就是 `csr_addr`。
- **ALU 侧**：`cond_*` 里没有任何一档匹配 `funct3==011`，`alu_opcode` 落到链尾默认 `alu_add`。
- 结果：`csrrc` 的新值 = `rs1 + csr_addr`（实测 `0xF000 + 0x340`）。

**修法**：新增 ALU 档 `alu_bitclr = 5'b01011`（`d2 & ~d1`，复用 sub/xor 已经反相好的 `d1_inv`），
IDU 把 rc 形式映射成 `d1 = 源（rs1/uimm）`、`d2 = CSR 旧值`。
**操作数顺序踩过一次**（第一版写成 `d1 & ~d2`）：`csrrci ...,2` 会把 CSR 清成 0，
被 `tb_sys` 的 `csrrci clears bit1 -> 29` 当场抓到 —— 所以宏名改成 `bitclr` 并把顺序写进注释。

### 11.3 缺陷二：CSR 读口没有 RAW 前递

CSR 读在 ID 级组合读出、写在 WB 级落盘，天然差三级。v10 的 C10 只给 `mret` 读 `mepc`
做了 4 深影子链前递，**普通 `csrr/csrrs/csrrc` 没有任何前递**。

**修法（不新增状态，复用 C10 的链）**：

- `IDU` 输出 `csr_sel[15:0]`：本拍所读 CSR 的**独热码**（位映射与 `csr_wen` 完全一致，
  只含 bit0..bit7，不含 §11.4 的标记位）；
- `Control` 新增 `csr_rd_fwd(_en)`：命中判据 `|(在途写位图 & csr_sel)`，
  按 `EX 级 > sh[0]=M1 > sh[1]=M2 > sh[2]=M3 > sh[3]=WB > 寄存器本体` 覆盖；
- `IDU` 用 `csrs_rd = en ? fwd : csrs` 同时喂 `rd_value_next` 与 `add_src2`（CSR 的读改写）。

★ 只影响读值，不新增暂停，也不改变"写在哪一级落盘"。

### 11.4 缺陷三：`rd` 选错源 —— `|csr_wen` 不能当"这是 CSR 指令"用

`csr_wen` 是**写使能**位图：读 `mvendorid/marchid/mtime/mtval/misa` 时一位都不置，
而下游（`WBU.wb_sel_jmp_csr`、`LSU` 的两级 `forward_val`、`myCPU` 的两级前递）都用
`|csr_wen` 判"是不是 CSR 指令"。于是这类读的 `rd` 取到了 `Ex_result`（对 CSRR* 那是"新值"）。

**修法**：`para.sv` 新增 `CSRW_OP = 8`，`csr_wen` 的 **bit8** 定义成"本拍是 CSR 指令"标记，
**读也置位**。`CSR.sv` 只认 bit0..bit7，对这位完全透明；下游 `|csr_wen` 从此严格等于
"是 CSR 指令"，与"要不要写"解耦。

### 11.5 缺陷四：`fence.i` 跳到 `mtvec`

`Control.dnpc` 的三元链是 `intr > bp_mispredict > (mret ? mepc_fwd : mtvec_out)`，
`fence.i` 不是中断也不是 `mret`，**落到了 `mtvec_out`**。而 `fence_i_flag` 本来就在
`system_redirect` 里（会发 `dnpc_flag` 冲刷流水），所以现象是"干净地跳错地方"：
`mtvec` 默认 0 时等于整机重启，程序里只要有一条 `fence.i`，后面的代码永远跑不到。

**修法**：给 `fence.i` 单独一档，目标是它自己后面那条指令：
`dnpc = … : fence_i_flag ? (EXU_pc + 32'd4) : (mret_flag ? mepc_fwd : mtvec_out);`
`fence_i_flag` 来自 EX 级、`EXU_pc` 就是这条 `fence.i` 的 PC，**不需要新增端口**。

### 11.6 顺带补全的三处（原来是"判非法"或"静默放过"）

| 项 | v10.1 | v10.2 |
|---|---|---|
| `csrrwi/csrrsi/csrrci`（funct3 101/110/111） | `legal_sys` 只允许 000..011 → **判非法**，一陷入整机就跑飞 | 正常实现，`rs1` 域当 5 位零扩展立即数 |
| `csrrs/csrrc` 的 `rs1=x0` | 照样写 CSR（`csrrc mip,x0` 会把 mip 清 0） | 规范语义：**源为 0 不写**；`csrrw` 恒写 |
| SYSTEM `funct3=000` | "一律合法" → `sret/dret/任意编码` 当空操作放过 | 只认 `ecall/ebreak/mret/wfi` 四条编码，其余判非法 |
| `ebreak` | 合法空操作，静默执行 | `mcause=3`、`mepc=mtval=ebreak 自己的 PC` |

`ebreak` 的实现刻意**不新增异常位**：它在 IDU 里并进 `illegal_flag`（这样 `no_side_effect`
会自动清掉全部副作用、EX 级锁存、`trap_take` 重定向、CSR 登记全都复用），
再由 `CSR.sv` 按 `fault_inst == 32'h0010_0073` 把 `mcause` 从 2 改成 3、把 `mtval`
从"指令编码"改成"出错 PC"。

### 11.7 顺手做的面积优化：5 个 32 位比较 → 12 位

`ecall/mret/fence.i/ebreak/wfi` 原来各用一个 **32 位全宽相等比较**（新增的 ebreak/wfi 直接
把这笔开销翻倍）。但这几条指令的 `opcode/funct3/rs1/rd` 全固定，自由度只有 `imm[11:0]`：

```
ecall  = (is_SYS & funct3==000) & rs1==0 & rd==0 & imm[31:20]==0x000
mret   = 同上                                   & imm[31:20]==0x302
ebreak = 同上                                   & imm[31:20]==0x001
wfi    = 同上                                   & imm[31:20]==0x105
fence.i= (opcode==MISC & funct3==001) & rs1==0 & rd==0 & imm[31:20]==0x000
```

`7(opcode)+3(funct3)+5(rs1)+5(rd)+12(imm) = 32` 位全覆盖 ⇒ **逐位等价**。
固定字段只判一次，剩下的只比 12 位。§11.9 有它的面积效果。

### 11.8 验证（细节见验证报告 §14）

| 项 | 结果 |
|---|---|
| iverilog 回归 | **22/22 PASS**；7 个整机程序周期数 36/42/94/55/83/110/97 **一字未变** |
| iverilog ↔ Verilator 交叉 | **22/22 等效，签名逐行相同，`dCYC=0`** |
| 随机差分 | **1000 程序 / 55000 指令 / 0 失败** |
| 新增 `tb_sys` | 4 个程序 **39 项检查**（CSR 16 / 中断 9 / fence.i 5 / ebreak 9） |
| 新增 `mutate_sys.py` | **7/7 变异全部被指定的那个用例抓到**（其余 3 个仍 PASS） |
| lint `-Wall` | 47 条，**0 条 `IMPLICIT`**（本轮自查出过一次隐式 1 位网，见验证报告 §14.6） |

### 11.9 面积与时序（Vivado 2025.2，`_diag/vivado_noila.ps1 -Mode default`）

同一 flow、同一器件（`xc7z020clg484-1`）、同一 50 MHz 约束（周期 20 ns）、无 ILA 顶层：

| 项 | v10.1 | v10.2 第一版 | **v10.2 最终** |
|---|---|---|---|
| Slice LUTs | 10 499 | 10 646 | **10 633** |
| Slice Registers | 9 732 | 9 761 | **9 760** |
| BRAM / DSP | 20 / 4 | 20 / 4 | **20 / 4** |
| WNS | 3.553 ns | 3.078 ns | **2.203 ns** |
| WHS | 0.040 ns | 0.019 ns | **0.032 ns** |

**★ 关键路径不在本轮改动上 —— 前 20 条里两组，都挂在 MDU 上**：

```
A) EXU_Inst0/add1_reg_reg[0] --> MDU_i0/mul_res_reg_reg[*]      17.76 ns / 24 级 / slack 2.203
     ① abs32   |a| 的 32 位条件取负    CARRY4 ×4~8      约 4~5 ns
     ② DSP48E1 ×2（prod_mag 的 PCOUT 级联）              约 5.5 ns
     ③ 64 位符号修正取负               CARRY4 ×9         约 3~4 ns
B) EXU_Inst0/alu_opcode_reg_reg[4] --> IFU_Inst0/g_queue[*].q_ptg_reg[*]/R   slack 2.650~2.665
     mdu_busy（= alu_opcode_reg[4] & ~mdu_res_vld）--> Control 的误预测仲裁/dnpc
     --> IFU 取指队列的**同步清空脚**（Vivado 把 `else if (flush) q_ptg <= 0` 合并成了 R 脚）
C) EXU_Inst0/alu_opcode_reg_reg[4] --> EXU_Inst0/iaddr_misalign_reg_reg/D    slack 2.485
     同一个 mdu_busy 的另一个分叉
```

`rtl/MDU_pipelined.sv` 这一轮**一行没动**；v10.2 新增的 `csr_fwd`/`csr_sel`/`csrwen_sh`
相关路径**一条都没进前 20**。所以卡住 Fmax 的是 **MDU 的归一化乘法 + `mdu_busy` 进入控制面
的组合深度**，不是本轮的系统指令逻辑。

**为什么不能简单说"v10.2 让时序变差了 1.35 ns"**：两次 v10.2 实现的路径构成**完全相同**
（24 级，同样 17 个 CARRY4 + 2 个 DSP48E1 + 5 个 LUT），差异全在布线（5.99→6.39 ns）与
CARRY4 引脚用法（10.94→11.37 ns）上；而且**面积更小的那次 WNS 反而更差**。结论：
这条 MDU 路径在 16.4~17.8 ns 之间波动，v10.2 的 +134 LUT 不是主要原因，
但也**没有做 v10.1/v10.2 的单变量 A/B**（仓库里没有 v10.1 的 RTL 快照），所以只报告事实。

> **★ v10.3 更正（§12.7）**：这里当时写"随实现抖动"是**不准确**的措辞。后一轮做了对照实验：
> 同一份网表跑两次，Vivado 报告**逐位相同**（10 774/LUT + 2.814 ns ×2 次；10 783 + 1.827 ns ×2 次）。
> 也就是说 flow 是**确定性**的，那两个 v10.2 数字之间的差异只能来自**不同的 RTL**
> （全宽比较版 vs 比较收窄版），而不是"同逻辑的实现随机性"。结论方向不变
> （收窄比较确实改善了时序），但"抖动"这个解释要删掉。

**要提 Fmax，唯一有效的一步：给 MDU 的归一链加一拍流水。** 三个可选方案（按性价比排）：

| 方案 | 做法 | 收益 | 代价 |
|---|---|---|---|
| **A（推荐）** | `abs32(a)`/`abs32(b)` 与符号位一起打一拍，乘法推到下一拍；`mdu_res_vld` 多等 1 拍 | 关键路径砍掉 ~5 ns（abs 链）→ ~12.8 ns ≈ **78 MHz** | `mul` 从 1 拍变 2 拍，**所有含乘法的用例周期数 +1/乘法**（`prog_mul` 42、`prog_div_pair` 97 这两个基准值会变） |
| B | 符号修正（③ 的 64 位取负）打一拍 | 砍掉 ~3~4 ns | 同样 +1 拍延迟 |
| C | 不用 `\|a\|·\|b\|`，改写 `$signed(a)*$signed(b)` 让综合器用 DSP 的符号模式 | 完全不改延迟 | 面积回到"乘法器不唯一"，且 `mulhu` 还要额外修正项，等于推翻 §3.1 的"乘法器合一" |

本轮**没有动**：A/B 都会改变所有文档里引用的周期基准值，属于需要显式取舍的改动
（"要 Fmax 还是要那组周期数字"）。当前 16~17 ns 的路径在 50 MHz 约束下仍有 2.2 ns 余量，
板级是 50 MHz，所以不是交付阻塞项。

### 11.10 新增/更新的工具与文件

| 文件 | 作用 |
|---|---|
| `sim/gen_sys_progs.py` → `sys_{csr,intr,fencei,ebreak}.hex` | 4 个定向程序（纯 Python 汇编） |
| `sim/tb_sys.sv` | 39 项检查的判据台（`+kind=csr/intr/fencei/ebreak`） |
| `_diag/vsim/mutate_sys.py` | 7 个定向变异（判据 = `tb_sys`），证明用例有牙 |
| `_diag/regress.ps1` | 22 runs（原 18 + 4 系统用例）；**保持纯 ASCII**（踩过 PS 5.1 的 GBK 坑） |
| `_diag/vsim/xcheck.sh` | 22 runs 交叉对拍（原 18 + 4） |

---

## 12. v10.3：Zicsr 逐条对规范审计（补 4 处"假实现" + 2 个真缺陷 + 1 个自己踩的坑）

### 12.1 怎么审的

上一轮（§11）是"补用例，让空白被执行到"；这一轮换方法：把 **Zicsr 的每一条规范原文**
（[unpriv §5.1.1](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html) +
[priv §1.1](https://docs.riscv.org/reference/isa/v20260120/priv/priv-csrs.html)）抄成一张清单，
逐条对着 RTL 核，核不上的就写成定向用例。

**结论：6 条指令编码早就是齐的（v10.2 补的），但"什么时候必须报非法指令"和"哪些位可写"
这两类**约束**基本没做。** 而前者恰恰是软件探测 CSR 能力（存在性/可写性）的唯一手段。

### 12.2 改动清单（`rtl/` 五行级改动 + 两个走线位）

| # | 文件 | 改动 | 为什么 |
|---|---|---|---|
| 1 | `IDU.sv` | 新增 `csr_known`（**16 地址白名单**）、`csr_rdonly`（`csr_addr[11:10]==2'b11`）、`csr_illegal = csr_op & (~csr_known \| (csr_rdonly & csr_wr))`，并入 `legal_sys` | 写只读 CSR / 访问不存在的 CSR 必须报非法指令 |
| 2 | `IDU.sv` | `csr_onehot` 从 8 位扩到 10 位（bit9=`mtval`、bit10=`mtime`），并显式把 **bit8 固定为 0** | `csr_onehot` 同时是"写使能位图"和"读前递选择子"；bit8 是 `CSRW_OP` 标记，进了这张表就会污染前递命中判据 |
| 3 | `para.sv` | 新增 `CSRW_MTVAL=9`、`CSRW_MTIME=10`、`CSR_mhartid=0xF14`、`CSR_mimpid=0xF13`、`CSR_mconfigptr=0xF15`，以及**WARL 掩码宏** `CSR_WMASK_{MIP,MIE,MSTATUS,MTVEC,MEPC}` / `CSR_FORCE_MSTATUS` | 掩码宏被 `CSR.sv`（写侧）与 `Control.sv`（前递侧）**共用**，见 §12.4；mimpid/mconfigptr 见 §12.10 |
| 4 | `CSR.sv` | `mtval` 增加软件写通路；`mtime` 增加写通路（同时清分频计数器）；`mstatus`/`mie`/`mtvec`/`mepc` 写入按宏掩码 | `mtval` 规范是 **MRW**；`0x7C0` 在 **Custom read/write** 段；其余是 WARL |
| 5 | `Reg_Stack.sv` | 读多路补 `misa`（常量 `0x4000_1100`）、`mhartid`/`mimpid`/`mconfigptr`（都读 `0`） | `CSR_misa` 宏从 v9 就定义了，**一次都没被引用**，读回 0 = "一个扩展都不支持"；mimpid 规范要求"必须可读"，见 §12.10 |
| 6 | `Control.sv` | 影子链入口改成 `csrval_now = (Ex_result & fwd_wmask) \| fwd_force`，`mepc_fwd`/`csr_rd_fwd` 同步 | ★ 见 §12.4，这是本轮唯一一个**新引入又当场被抓出**的缺陷 |
| 7 | `IDU.sv` | `ebreak_flag` / `wfi_flag` / `sys_priv_ok` 的**声明上移**到第一次赋值之前 | ★ 见 §12.9：**ModelSim 的 vlog 直接拒绝编译**（`vlog-2388`），iverilog 只提示、Verilator 连 IMPLICIT 都没报 |
| 8 | `IDU.sv` | `csr_known` 白名单加 `mimpid`/`mconfigptr`（14 → 16 个地址） | ★ 见 §12.10：**这两个地址原来被错判成"不存在"**，而规范要求 mimpid "must be readable in any implementation" |

### 12.3 三条不变量（写进 RTL 注释，改代码前必读）

1. **`csr_wr` 必须同时是"要不要写"和"要不要对只读地址报非法"的判据。**
   规范原文：CSRRS/CSRRC 的 `rs1=x0` "will not write to the CSR at all ... **nor raise
   illegal-instruction exceptions on accesses to read-only CSRs**"。所以
   `csr_illegal = csr_op & (~csr_known | (csr_rdonly & csr_wr))` —— 少了 `& csr_wr`，
   `csrr x5, mvendorid` 这种纯读就会陷入，反而是错的。

2. **`csr_onehot` 的 bit8 必须恒 0。**
   这张表是"写位图"和"读选择子"两用的。bit8 是 `CSRW_OP`（"本拍是 CSR 指令"的标记），
   由 `csr_wen_next` 单独置位；若它也进 `csr_onehot`，`|(csrwen & csr_sel)` 会把**任何**
   CSR 指令都判成命中前一条在途写，前递整条失效。

3. **WARL 掩码宏必须 `CSR.sv` 与 `Control.sv` 成对使用。**
   写侧（寄存器落盘）与前递侧（紧跟写入的读看到什么）用的是**同一个 `Ex_result`**，
   两边掩码不一致就会出现"同一段程序读同一个 CSR 得到两个答案"。

### 12.4 ★ 本轮自己踩的坑：前递链存的是 ALU 原值，不过 WARL 掩码

加完掩码后第一次跑 `sys_zicsr`：19/21 通过，红的其中一条是
`[FAIL] mip: only MSIP writable`，实测 `x18=ffffffff`（期望 `1`）。

**机理**：CSR 读口的前递链（§11.3 建的）里存的是 `Ex_result` = **ALU 算出的原始新值**，
而寄存器落盘时还要过掩码。于是：

| 读的时刻 | 数据来源 | 读到 |
|---|---|---|
| 写完 ≤5 条指令内 | 前递链 | `0xFFFFFFFF`（ALU 原值） ❌ |
| 写完 ≥7 条指令 | 寄存器本体 | `1`（掩码后） ✅ |

**修法**：把掩码提前到影子链入口（`Control.csrval_now`），链里只存"将来会落盘的那个值"。
`mepc_fwd` 与 `csr_rd_fwd` 都改用它。

**为什么这个坑值得单独记**：它是**测试逼出来的**，而且它证明了一件事 ——
**"写一个 CSR 再读回来"必须测两条路径（前递 + 寄存器）**。
所以 `sys_zicsr` 的 `mip` 用例读两次：距离 5 读（前递）、距离 7 读（寄存器），两次都得是 `0x1`。

### 12.5 CSR 集合覆盖（审计后的实际能力）

| CSR | 地址 | 读 | 写 | WARL |
|---|---|---|---|---|
| `mstatus` | 0x300 | ✔ | ✔ | MIE/MPIE 可写；**MPP 恒 11**；其余位读 0 |
| `misa` | 0x301 | ✔ `0x4000_1100` | 忽略（WARL） | MXL/扩展位不可改 |
| `mie` | 0x304 | ✔ | ✔ | 仅 MSI(0)/MTI(7)/MEI(11) |
| `mtvec` | 0x305 | ✔ | ✔ | `[1:0]` 恒 0（只支持 direct） |
| `mscratch` | 0x340 | ✔ | ✔ | — |
| `mepc` | 0x341 | ✔ | ✔ | `[1:0]` 恒 0（IALIGN=32） |
| `mcause` | 0x342 | ✔ | ✔ | — |
| `mtval` | 0x343 | ✔ | ✔（v10.3） | — |
| `mip` | 0x344 | ✔ | ✔ | 仅 MSIP 可写，MEIP/MTIP 只读（硬件驱动） |
| `mtime` | 0x7C0 | ✔ | ✔（v10.3） | 写时清分频计数器 |
| `mtimecmp` | 0x7C1 | ✔ | ✔ | — |
| `mvendorid` / `marchid` | 0xF11 / 0xF12 | ✔ 常量 | **写 → 非法指令** | 只读段 |
| `mimpid` | 0xF13 | ✔ `0`（v10.3b） | 写 → 非法指令 | 只读段；**规范要求必须可读**（§2.1.1.4） |
| `mhartid` | 0xF14 | ✔ `0`（v10.3） | 写 → 非法指令 | 只读段；规范要求必须可读，且**没有"可以返回 0"的退路** |
| `mconfigptr` | 0xF15 | ✔ `0`（v10.3b） | 写 → 非法指令 | 只读段；本核无配置数据结构 → 0 |

**未实现（访问即 `mcause=2`）**：`mcounteren`、`medeleg`/`mideleg`、
`pmp*`、`mcycle`/`minstret`/`cycle`/`instret`（Zicntr）、S/H 级全部、`0x7B0-0x7BF`（debug-only）。
对"未实现"报非法是规范给的自由度（"reserved"），也是唯一不给软件**假信息**的选择 ——
**但"信息类寄存器"是例外**：`mvendorid`/`marchid`/`mimpid`/`mhartid`/`mconfigptr` 必须能读
（拿不到信息就给 0），这条 v10.3 我第一次做漏了，v10.3b 补上（见 §12.10）。

### 12.6 验证

| 项 | 结果 |
|---|---|
| iverilog 回归 | **23/23 PASS**；7 个整机程序周期 36/42/94/55/83/110/97 **一字未变** |
| **ModelSim 回归**（`sim/run_msim.ps1`，SE-64 10.5） | **23/23 ALL PASS**（v9 的 15 项 + `tb_sys`×5 + `tb_exc`×3）；`tb_sys` 的周期数与另两个仿真器**逐拍相同**（详见 §12.9） |
| `tb_sys` ×5 | **64 项检查全 PASS**（CSR 16 / 中断 9 / fence.i 5 / ebreak 9 / **Zicsr 25**）；zicsr 189 拍 |
| 交叉仿真 | **23/23 等效，`dCYC` 全 0，签名差分 0** |
| 随机差分 | **1000 程序 / 55000 指令 / 0 失败** |
| 定向变异 | **14/14 全部按预期被抓到**（新增 7 条 `zicsr_*`） |
| lint `-Wall` | 48 条，**0 条 `IMPLICIT`**（但见 §12.9：Verilator 漏报了一处"先用后声明"） |

`sys_zicsr.hex` 的关键判据（23 项里的几条）：

- **6 次非法指令陷入**（写只读 ×2、立即数写只读 ×1、不存在 CSR 读/写 ×2、`funct3=100` ×1），
  多一次少一次都说明"哪些该陷入"判错了；
- `mtval` = `0x3400_4073`（`funct3=100` 那条指令的编码），`mepc` **精确指向它本身**；
- 被陷入打断的 `csrrw` **不许写 rd、不许改 CSR**（`x6 = x7 = x9 = x11 = 0`，`mvendorid` 原值不变）；
- `mip` 的两种读路径一致（前递 + 寄存器都得 `0x1`）。

### 12.7 面积与时序（`_diag/vivado_noila.ps1 -Mode default`）

| 项 | v10.1 | v10.2 | v10.3（mimpid 前） | **v10.3b（最终）** |
|---|---|---|---|---|
| Slice LUTs（post-route） | 10 499 | 10 633 | 10 774 | **10 783**（+9） |
| Slice Registers | 9 732 | 9 760 | 9 717 | **9 717** |
| BRAM / DSP | 20 / 4 | 20 / 4 | 20 / 4 | **20 / 4** |
| WNS | 3.553 ns | 2.203 ns | 2.814 ns | **1.827 ns** |
| WHS | 0.040 ns | 0.032 ns | 0.029 ns | **0.005 ns** |

- **★ 撤回"实现抖动"的说法**：同一份网表跑两次，Vivado 的报告**逐位相同**
  （v10.3 两次都是 LUT 10 774 / WNS 2.814；v10.3b 两次都是 10 783 / 1.827）。
  以前那些"同一逻辑不同数字"的对比，其实是**不同 RTL**。flow 是确定性的。
- **+9 LUT 换掉了一条关键路径**（真实因果，两次复现）：
  `add1_reg[0] → MDU/mul_res_reg` 17.195 ns（logic 64% / route 36%，slack 2.814）
  → `alu_opcode_reg[3] → iaddr_misalign_reg` **17.952 ns（logic 28% / route **72%**，slack 1.827）**。
  新路径的构成（从报告逐级读出）：`alu_opcode_reg[3]` →（fanout 47）→ ALU 32 位加法器的
  **9 级 CARRY4 进位链** → `iaddr_misalign_reg`。
  **根因**：`iaddr_misalign` 只需要目标地址的 bit[1]，但综合器把
  `jump_target_low2 = add1[1:0] + add2[1:0]` 并进了 ALU 的大加法器，于是"2 级逻辑"变成"9 级进位链"。
- **可选修法（本轮没做，留决策）**：把跳转目标低 2 位改成不经加法器的显式形式 ——
  `jump_target_low2[1] = add1[1] ^ add2[1] ^ (add1[0] & add2[0])`（2 位加法的定义，功能等价），
  约 **2 LUT**，预期把 WNS 拉回下一条最差路径 **2.632 ns**（+0.8 ns）。
  不做的理由：当前 1.827 ns 在 50 MHz 下仍有 9% 余量，且它会再次作废全部已跑的回归数字。
- 前 20 条里仍然 **0 条**经过 `csr_known` / `csr_illegal` / `csrval_now`（`grep IDU|csr|illegal` 命中 0）。
- 唯一做了**单变量 A/B** 的一项：把 `csr_known` 恒置 1（去掉 12 个 12 位比较 + 或树）→
  post-synth LUT 10 834 → **10 794**，即白名单占 **40 LUT**。其余是估算。
  （该 A/B 用 `-Mode synth_only` 跑，**覆盖了** `project_src/*.synth_only.rpt`：这几个文件
  现在代表"变异体"数据，不是当前 RTL。当前数字只看 `*.default.rpt`。）
- §12.9 的声明顺序修复之后又整跑了一遍 Vivado：**LUT 10 774 / FF 9 717 / WNS 2.814 / WHS 0.029
  / post-synth 10 834 全部逐位相同** —— 印证了"挪声明不改网表"。

### 12.8 还没做（明确的清单）

| 项 | 现状 | 判断 |
|---|---|---|
| `Zicntr`（`cycle`/`instret`/`mcycle`/`minstret` + 高 32 位） | 未实现 → 访问报非法 | **合规**（可选扩展，`misa` 只声明 I/M；Zihpm 一节明确允许"未实现的计数器报非法**或**返回常数"）。要做就得完整做，见 §12.10 |
| `mcounteren`（0x306） | 未实现 → 访问报非法 | 规范只在**实现 U 模式时**才要求；本核 M-only，无"下游"可门控 → 不做的代价为零 |
| `pmpcfg*`/`pmpaddr*`（0x3A0-0x3BF） | 未实现 → 访问报非法 | 规范允许 **0 项**；真做 16 项 ≈ 1.5~2.5k LUT + 一条新的判定路径 → 不做 |
| `medeleg`/`mideleg`（0x302/0x303） | 未实现 → 访问报非法 | 无 S 模式，没有可委托的对象 |
| ~~`mimpid`/`mconfigptr`~~ | **v10.3b 已改为可读、读 0** | 原来让它们陷入是**错的**（规范：mimpid "must be readable in any implementation"），见 §12.10 |
| 特权级检查（`csr[9:8]` 编码的最低特权级） | 只有 M 模式，无需检查 | 引入 U/S 模式时必须补 |
| CSRRW 且 `rd=x0` 时"不读 CSR" | 逻辑上没做 | **不可观测**（本核无读副作用寄存器），不做 |
| CSRRS/CSRRC 的字段级写副作用 | 不适用（无此类 CSR） | 不做 |
| 改进 Fmax（MDU 归一链加流水 / `mdu_busy` 移出 `dnpc` 仲裁） | 未做 | 见 §11.9 的收益/代价表，仍是下一步首选 |

### 12.9 第三个仿真器（ModelSim SE-64 10.5）—— 抓出缺陷八，并更正我的一句错话

**先更正**：上一轮的文档里我写过"本机没有 ModelSim，未验证"。**这是错的** ——
ModelSim 一直在 `E:\FPGA\ModelSim_10.5se\win64\`（`vsim/vlog/vlib` 都在 PATH 上），
`sim/README_msim.md` 里还记着 v9 的 "15/15 ALL PASS"。当时没查就下了结论。

#### 12.9.1 ★ 缺陷八：三根信号"先用后声明"，只有 vlog 拒绝编译

```
** Error (suppressible): rtl/IDU.sv(291): (vlog-2388) 'ebreak_flag' already declared in this scope (IDU).
** Error (suppressible): rtl/IDU.sv(292): (vlog-2388) 'wfi_flag' already declared in this scope (IDU).
** Error (suppressible): rtl/IDU.sv(293): (vlog-2388) 'sys_priv_ok' already declared in this scope (IDU).
```

**根因**：v10.2 把这三根的**赋值**挪到了 `priv_id/sys_rs1z/...` 那一块（`IDU.sv:243~250`），
**声明**却留在 `legal_sys` 那一段。SystemVerilog 对"先用后声明"的标识符会先建一个
**隐式 1 位网**，后面那行 `logic` 就成了"重复声明"。

| 仿真器 | 反应 |
|---|---|
| iverilog 12.0 | 只提示，继续编译，用例全过 |
| Verilator 5.020 `-Wall` | **没报**（按模块两遍解析，隐式网被消解）→ 我上轮"0 条 IMPLICIT"看着很干净 |
| **vlog -sv 10.5** | **拒绝编译** |

功能上侥幸没错（三根都是 1 位信号），但这与 v10.2 的 `csrs_rd` 隐式 1 位网是**同一个类别**，
而且这次是**两个更宽松的仿真器一起放过去的**。教训一句话：
> **"两个仿真器都通过"不等于"代码合法"。** 前端严格的工具要留在回归里。

**修复**：声明上移到第一次赋值之前（`IDU.sv:230` 附近），并写死不变量
"本文件任何 `logic` 声明都必须出现在它的第一处使用之前"。

#### 12.9.2 把 v10 的用例接进 ModelSim 回归

`sim/run_msim.ps1` 新增 `[2b/3]` 段：`tb_sys`×5 + `tb_exc`×3。
这两个 TB 没有 `$dumpvars`，不需要 `mk_msim_tb.py` 生成副本，直接 `vlog -sv` 即可。
现在一条命令 `sim\run_msim.bat` 跑 **23 项**（v9 的 15 + v10 的 8），全过。

```
=== [2b/3] v10 system tests: tb_sys x5 + tb_exc x3 ===
  [OK  ] tb_sys  csr 16 / intr 9 / fencei 5 / ebreak 9 / zicsr 23 项 全 PASS
  [OK  ] tb_exc  illegal 7 / misalign 8 / jal_misalign 5 项 全 PASS
  RESULT: ALL PASS (23 项，0 failures)
```

#### 12.9.3 三个仿真器的周期数

| 用例 | iverilog | Verilator | ModelSim |
|---|---|---|---|
| `tb_sys` csr/intr/fencei/ebreak/zicsr | 39/82/46/39/189 | 39/82/46/39/189 | **39/82/46/39/189** |
| 7 个整机程序 | 36/42/94/55/83/110/97 | 同左 | 35/41/93/54/82/109/96（各少 1） |

那 1 拍源于 `sim/tb_msim.sv` 是 v9 生成的旧副本（缺 v10.2 的 `#1` 复位释放保护），
**功能检查项一个不少**；`tb_sys`/`tb_exc` 是新 TB，与另外两个仿真器逐拍相同。
重新生成 `tb_msim.sv` 能消掉这 1 拍，但会把 v10 之后 `tb_iverilog.sv` 的改动一起带进来，
属于改验证设施，本轮不动。

### 12.10 ★ 缺陷九：`mimpid` "不实现" ≠ "不可读"（我把规范读漏了一条）

v10.3 我按"只放真正实现了的东西"一刀切，把 `mimpid`(0xF13) / `mconfigptr`(0xF15)
也划进"未实现 → 报非法"。查原文才发现 `mimpid` 属于**必须能读**的那类：

> 特权规范 §2.1.1.4：*"The `mimpid` CSR provides a unique encoding of the version of the
> processor implementation. **This register must be readable in any implementation**, but a
> value of 0 can be returned to indicate that the field is not implemented."*

`mvendorid`/`marchid` 措辞相同；`mhartid` 是"must be readable"且**没有**"可以返回 0"的退路
（只在"MXLEN 位宽"上没得选）。所以"没有版本号"的正确表达是**读回 0**，不是发一次 `mcause=2`。
`csrr x5, mimpid` 在 v10.3 上会陷入 —— 这是真缺陷，而且比"少个功能"更糟：
它让"探测实现版本"的启动代码在一条规范保证可读的 CSR 上直接掉进异常。

**修复**（4 处，见 §12.2 第 8 项）：`para.sv` 加两个地址宏 → `IDU.csr_known` 加进去（14→16）
→ `Reg_Stack` 读 0 → `sys_zicsr` 加 2 项检查（先塞 `0x12345`/`0x23456` 再读，必须读到 0 且不陷入）。

**为什么不做的那几项是对的**（每条都查了原文，不凭印象）：

| CSR | 规范口径 | 本核 | 判定 |
|---|---|---|---|
| `mcounteren`(0x306) | 只在**实现 U 模式时**必须；它门控的是"低特权级读计数器" | 无 U 模式、无计数器 | 不做**不是**缺陷 |
| `pmpcfg*`/`pmpaddr*` | 允许 **0 项** PMP | M-only，无保护对象 | 不做**不是**缺陷 |
| `Zicntr` | **可选扩展**；Zihpm 一节：*"Accessing an unimplemented counter may cause an illegal-instruction exception **or** may return a constant value."* | `misa` 只声明 I/M | 报非法**合规** |
| `medeleg`/`mideleg` | 仅在有 S 模式时有意义 | M-only | 不做不是缺陷 |

**如果哪天要做 Zicntr，代价各是多少**（估算是按当前实现风格推的，不是实测）：

| 补的东西 | 代价 | 备注 |
|---|---|---|
| `time`/`timeh`(0xC01/0xC81) | `mtime` 现在是 32 位 → 加宽到 64 位：+32 FF + 进位链 ≈ **40~70 LUT** | 唯一"几乎免费"的真计数器（墙钟已在） |
| `mcycle`/`mcycleh`(0xB00/0xB80) | 64 位自由运行计数器 ≈ **70 LUT/FF** | 要注意 stall / MDU busy 下的"周期"口径 |
| `minstret`/`minstreth`(0xB02/0xB82) | 64 位退休计数器 + "**异常指令不数**"的判定（要接 `trap_take`/`illegal_flag`/`mem_misalign` 门控）≈ **100 LUT** | 口径最容易做错的一项 |
| 对应的 `cycle`/`instret`(0xC00/0xC02) 只读影子 | 每个 ≈ 8 LUT | 有 `mcycle`/`minstret` 后就是读多路加一条 |
| `mcountinhibit`(0x320) | ≈ 8 LUT | 计数器实现后才需要 |
| `pmp*`（16 项，若要做） | **1.5~2.5k LUT** + 取指/load/store 三处判定 + 锁定位语义 | 不建议：本核没有 S/U 模式，做了是死逻辑 |
