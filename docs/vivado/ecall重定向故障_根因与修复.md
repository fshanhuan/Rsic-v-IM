# ecall 重定向故障：根因与修复（v9 修复 B9）

> 一句话：**`ecall` 执行了、`mepc`/`mcause` 也写对了，但 PC 从来没有跳到 `mtvec`。**
> 根因是 `IFU.sv` 里用 `dnpc_flag & ready` 门控真实重定向，而系统重定向
> （`ecall`/`mret`/`fence.i`）的请求**只有一拍宽**，撞上 `ready=0` 就**永久丢失**。
> 已改成 `else if (dnpc_flag)`，仿真 7/7 程序 + 新增断言全部通过。

本篇记录的是**上板 ILA 抓出来的一个真实功能 bug**。它的价值不在于改动有多大
（最终只删掉一个 `& ready`），而在于它说明了两件事：

1. **仿真的 35/35 全 PASS 不代表功能正确** —— 原来的测试台在 `ecall` 译码后再等
   8 拍就 `$finish` 打报告，**从来没有人看过 `ecall` 之后的 PC**；
2. **"上板只是验证"是错的** —— 这个 bug 是板上 ILA 用 2048 拍原始数据钉死的，
   仿真是**照着板上的现象**才复现出来的。

---

## 0. TL;DR

| 项目 | 内容 |
|---|---|
| 现象 | 板上 `debug_wb_pc` 在 2048×2 拍里**从不为 0**；程序每绕 IROM 一圈（16KB）又执行一次 `ecall`（`mepc` 每次 +`0x4000`），如此无限循环 |
| 根因 | `IFU.sv` 第 91 行：`else if (dnpc_flag & ready)`。`dnpc_flag` 是**单拍脉冲**，这一拍 `ready`（=`IDU_ready`）为 0 时重定向被静默丢弃 |
| 触发条件 | `ecall` 恰好落在取指 hold 拍（`IFU_stall=1` ⇒ `ready=0`）。实测 `pc=0x34` 的 `ecall` **正好**命中 |
| 修复 | `else if (dnpc_flag)  pc <= dnpc;` —— 一行 |
| 影响面 | 同样的门控还影响 `mret`（异常返回永远回不去）、`fence.i`、同步异常 `trap_redirect`、中断 `intr_take`。即**整个异常/中断体系的重定向都可能失效** |
| 仿真验证 | 7/7 程序 `SELFCHECK PASS`，新增 `ecall-redirect (pc -> mtvec)` 断言 PASS（+2 拍命中 `mtvec`） |
| **板上验证** | **✅ 已在真板确认（2026-10-15）**。烧 B9 版 bitstream 重抓 ILA：`debug_ifu_pc` 范围 `0x00..0x38`（垃圾基址消失）、**PC 到达 `mtvec` 141 次/2048 拍**、`mepc` **恒为 `0x34`**、`icache_miss_cnt` **冻结在 15**、`wb_pc` 只有 13 个值。触发条件 `debug_ifu_pc == 0` **能命中**（修复前必然超时）。时序还更好了：WNS **+4.890 ns** / WHS **+0.021 ns**，DRC 0 Error / 0 Critical Warning。详见 §5.3 |
| 顺带修复 | ① `CSR.sv` 补 `assign mtval_out = mtval_reg;`（原来无驱动）；② `myCPU.sv` 的 `fault_inst_in` 从**未声明的隐式 1 位网** `IDU_inst` 改接 `IDU_inst_d`（IDU 译码级 `inst_d` 引出） |
| 遗留 | ① 板上稳态循环里 47/48 次重定向的 `ready` 都是 1，所以 `ready=0` 分支是**仿真**证明的（§5.3 末）；② `sim/tb_exc.sv` 暴露的**同步异常检测不工作**是既有缺口，未修（§7） |

---

## 1. 板上现象（原始证据）

用**独立的 batch Vivado 会话**接到 GUI 已经起好的 `hw_server`（`localhost:3121`），
不需要点 GUI 就能触发/上传/导出：

```powershell
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
    -source 'E:/FPGA/v9_vivado_ila/dump_ila_csv.tcl' `
    -log 'E:/FPGA/v9_vivado_ila/dump_ila_csv.log'
```

两次抓取（正常触发一次、`debug_wb_value == 0x23` 触发一次），各 2048 拍，逐拍 CSV：

| 检查项 | 结果 |
|---|---|
| `debug_wb_pc` 是否出现过 `0x00000000` | **从未出现**（409 / 410 个不同值，全部带高位基址） |
| `debug_trap_take` 是否出现过 1 | **从未出现**（`ecall` 走的是 `ecall_flag` 系统重定向，不是异常通道） |
| `debug_mcause` | 恒 `0x0B`（= 11，M 模式 `ecall`）—— **说明 `ecall` 确实被识别并登记了** |
| `debug_mepc` 的不同取值 | `0xDEA78034` → `0xDEA7C034`，**正好相差 `0x4000` = 一圈 16KB** |
| `debug_wb_ena==1` 的拍数 | 12（正好是 `prog.hex` 里写寄存器的 12 条指令，与仿真一致） |

**关键推论：**
`mepc` 从 `0x…8034` 变成 `0x…c034`，差 `0x4000` 正好是 IROM 的容量。
这说明 **PC 每绕 IROM 一圈就重新回到 `0x34` 执行一次 `ecall`**，然后**继续顺序爬行**，
而不是被拨到 `mtvec`。所以：

- 所谓"垃圾基址"（`0xDEA7C000` 那一类）**不是另一个 bug**，而是
  `v >> 14` 意义上的**累计绕圈**（IROM 只用 `pc[13:2]` 索引，所以高位基址不影响取指内容）；
- 程序逻辑本身**完全正确**：`mul` 得 35、存/取往返得 12、`beq` 正确不跳、
  `jal` 正确跳过 `0x2C`（由 `ori x10,=63` 证明）—— 14 条指令逐拍全对。

> 撤回一条早期误判：曾怀疑 I-Cache 失效（"miss ≫ hit"）。那是把**整个运行期的累计值**
> 当成了稳态比例 —— 那些计数横跨"正常执行"和"暴走"两个阶段。
> 按窗口内增量算，命中率 **1229:409 = 75%**，与仿真的 `48:16 = 75%` 完全一致。**I-Cache 没问题。**

---

## 2. 仿真复现：一次就命中

原测试台**覆盖不到**这一点：`sim/build/prog.log` 里相关记录只有

```
[RDR] cyc=75 dnpc=00000000 mispredict=0 ecall=1 mret=0 intr=0
[END] ecall reached ID at cyc=75 id_pc=00000034 (snapshot after DRAIN=8 cycles)
```

之后就是 `$finish`。报告只比 GPR / dram / mepc / mcause，**没有人检查 `ecall` 之后的 PC**。

于是给 `sim/tb_iverilog.sv` 加了一段观察窗：`ecall` 译码后继续跑 16 拍，
逐拍打印 `IFU_pc` + `dnpc_flag` + `dnpc` + `ready`，并断言窗口内必须见到 `mtvec`。
**第一次运行就复现了**，而且那一行直接给出了根因：

```
[EPC] cyc=75 +1 ifu_pc=00000038 dnpc_flag=1 dnpc=00000000 ifu_ready=0 ifu_valid=1 ifu_stall=1 ecall=1
```

拆开看：

| 信号 | 值 | 含义 |
|---|---|---|
| `dnpc_flag` | **1** | 重定向请求**已经发出**了 —— 不是 Control 的问题 |
| `dnpc` | `0x00000000` | 目标 = `mtvec`，**完全正确** |
| `ifu_ready` | **0** | ← 真凶：IFU 的重定向分支要求 `ready`，这一拍不满足 |
| `ifu_stall` | 1 | `ready = IDU_ready = ready_next && !stall`，`stall=1` 把它拉低了 |
| `ecall` | 1 | `ecall_flag` 有效 |

此后 `dnpc_flag` 在下一拍就变 0（原因见 §3），PC 便一路
`0x38 → 0x3c → 0x40 → 0x44 …` 顺序爬行 —— **与板上 ILA 的轨迹逐位一致**。

---

## 3. 根因：单拍脉冲 × 错误的门控条件

### 3.1 为什么 `dnpc_flag` 只有一拍

```systemverilog
// Control.sv
assign system_redirect = mret_flag | ecall_flag | fence_i_flag | trap_redirect;
assign dnpc_flag       = intr_take | trap_redirect | bp_mispredict | system_redirect;
```

其中 `ecall_flag`/`mret_flag`/`fence_i_flag` 都是 IDU 由**译码级寄存器 `inst_d`**
组合译出的电平（`IDU.sv:199` 等）。而 `dnpc_flag` 同时就是 IDU 的 `flush`：

```systemverilog
// myCPU.sv
IDU IDU_Inst0 ( ... .flush(dnpc_flag), ... );
```

IDU 在 `flush` 那一拍就把 `inst` / `inst_d` 全部灌成 NOP（`IDU.sv:125,146`）。
所以**下一拍 `ecall_flag` 自动消失** ⇒ `dnpc_flag` 是**单拍脉冲**。

`Control` 里只有**分支误预测**建了 `bp_misp_pend` 的"挂起重发"机制
（见 `Control.sv`"补发脉冲"一节），`ecall` / `mret` / `fence.i` / `trap` **没有任何重发机制**。
一拍被吃掉 = 永久丢失。

### 3.2 为什么用 `ready` 门控是错的

`ready` 的含义是"**下游这一拍能不能接收一条新指令**"：

```systemverilog
// IDU.sv
assign ready_last = ready_next && !stall;   // → IFU.read
```

但重定向这一拍的当前取指**本来就是要作废的**：`dnpc_flag` 同时就是 IDU 的 `flush`，
IDU 在这一拍把译码级全部灌成 NOP。也就是说：

- 重定向**不是**"请求下游接收"；
- 重定向**是**"命令下游丢弃"。

用 `ready`（下游忙不忙）去门控一条"命令下游丢弃"的信号，**因果完全颠倒**。

### 3.3 同一段代码里已经有过一次同样的修正

`IFU.sv` 的 B4/B7 注释里，作者已经为**完全相同的理由**把 `inst_valid` 从门控里去掉了：

> `inst_valid`（ICache.fetch_align）表示"本拍取回的数据确实属于当前 PC"——
> 而重定向本来就是**放弃**当前这次取指、把 PC 拨到确定的目标，与当前取指数据是否对齐无关。

**`ready` 是同一类东西**：它是关于"当前这条取指"的握手信号，而重定向恰恰是要放弃它。
注释里那句"只保留 ready（下游可接收的结构性背压）"就是这次的错误来源 ——
它把 `ready` 当成了"重定向能不能生效"的条件，实际上它是"当前取指能不能被接收"的条件。

---

## 4. 修复

```diff
--- a/IFU.sv
+++ b/IFU.sv
     always_ff @(posedge clock) begin
         if (reset)
             pc <= ResetValue;
-        else if (dnpc_flag & ready)
+        // ★ 真实重定向：既不看 inst_valid，也不看 ready —— 它是控制面已经确认的事实，
+        //   而且这一拍下游被 flush 灌的是 NOP，不存在"下游没接收"的问题。
+        else if (dnpc_flag)
             pc <= dnpc;
         else if (pred_take_en & ready)
             pc <= pred_target;
         else if (stall & valid & ready)
             pc <= pc;
         else if (advance_en)
             pc <= snpc;
     end
```

**为什么去掉 `ready` 是安全的：**

- 优先级最高的 `reset` 不受影响；
- `pred_take_en & ready`（投机跳转）**保留** `ready` —— 它确实必须与 `advance_en`
  用同一个"本拍真的接收了这条指令"的条件（这正是 B4 的修复内容），不能动；
- 同一拍只会有**一个**一致的 `dnpc`/`dnpc_flag`（`Control` 内部已经做了仲裁：
  `bp_misp_det` 排除 `intr_take | system_redirect | trap_redirect`，
  且挂起目标优先），所以去掉 `ready` 不会让 PC 落到错误的地址；
- 即使 `dnpc_flag` 因为某种原因保持多拍，`pc <= dnpc` 是**幂等**的（PC 停在 `dnpc`），
  不会产生额外副作用。

---

## 5. 验证

### 5.1 新增回归断言（这是本次最重要的产出）

```
sim/tb_iverilog.sv：
  parameter ECALL_REDIR_CYCLES = 16;
  · ecall 译码后连续观察 16 拍 IFU_pc，逐拍打印 [EPC] 轨迹
  · 窗口内必须出现 IFU_pc === mtvec，否则报
      ecall-redirect (pc -> mtvec)  [FAIL]
```

**修复前**（就是这个断言让 bug 第一次现形）：

```
ecall-redirect (pc -> mtvec)      [FAIL] pc never reached mtvec=0x00000000 in 16 cycles
[SELFCHECK] status=FAIL  (1 mismatched, 35 passed)
```

**修复后**：

```
[EPC] cyc=76 +2 ifu_pc=00000000 dnpc_flag=0 dnpc=00000000 ifu_ready=0 ...
ecall-redirect (pc -> mtvec)      [PASS] pc hit mtvec=0x00000000 at +2 cycles
[SELFCHECK] status=PASS  (36/36 checks passed)
```

`+2 cycles` 命中 `mtvec`，并且程序**如期从头重跑**（`cyc=86 pc=0` 的 `lui` 再次写回），
这正是硬件上的预期行为（`prog.hex` 的 `mtvec` 复位值是 0，`ecall` 之后从 0 重新执行）。

### 5.2 全量回归

| 程序 | 结果 |
|---|---|
| `prog` | PASS 36/36（比原来多 1 项 = 新断言） |
| `prog_mul` | PASS 35/35 |
| `prog_div` | PASS 35/35 |
| `prog_load_lane` | PASS 35/35 |
| `prog_load_use` | PASS 35/35 |
| `prog_loop` | PASS 35/35 |
| `prog_div_pair` | PASS 35/35 |
| `tb_dcache_unit` | `DCACHE-UNIT: PASS` |

> **测试台的一个副作用，已一并修好**：断言生效后程序会真的重跑，
> 而报告原来是在 `ecall` 后固定读"现场"的值 —— 观察窗一拉长就会读到**第二轮**的中间值。
> 实测 `prog_loop` 因此误报 `x1=1 / x2=0`（应为 `10 / 55`）。
> 修法是把"**何时取快照**"与"**观察窗多长**"解耦：仍在原来那一拍（`drain_cycles`）
> 把 GPR / CSR / 计数器复制进 `snap_*`，之后只为看 PC 重定向继续跑。报告一律读 `snap_*`。

### 5.3 板上确认（2026-10-15，B9 修复版 bitstream）

重建后的工程与原版对比（**都变好了**）：

| 指标 | 修复前 | 修复后（B9） |
|---|---|---|
| WNS / WHS | +4.162 ns / +0.011 ns | **+4.890 ns / +0.021 ns** |
| 建立时间失败路径 | 0 | **0** |
| DRC | 0 Error / 0 Critical Warning | **0 Error / 0 Critical Warning** |
| ILA 探针 | 13 | **16** |
| 综合告警 | 含 `mtval_out does not have driver` ×2 | **已消失** |

烧录与抓取全部由**独立 batch Vivado 会话**自动完成（`dump_ila_b9.tcl`），不需要点 GUI：

```
探针数 = 16
probe(debug_ifu_pc)    = debug_ifu_pc
probe(debug_dnpc_flag) = debug_dnpc_flag
触发条件 = debug_ifu_pc eq32'h00000000
OK -> ila_b9_pc0.csv  (235807 字节)
触发条件 = debug_dnpc_flag eq1'h1
OK -> ila_b9_redir.csv  (235807 字节)
```

> ★ **最有说服力的一点**：抓取①的触发条件就是 `debug_ifu_pc == 0x00000000`。
> **修复前 PC 永远不回 0，这个触发会一直超时抓不到任何东西**；修复后它一秒内就命中了。

**逐拍结果（`analyze_ila_b9.py`）：**

| 检查项 | 修复前（旧抓取） | 修复后（本次） |
|---|---|---|
| `debug_ifu_pc` 取值范围 | （当时无此探针） | **`0x00000000 .. 0x00000038`** —— 整个程序地址空间，高位垃圾基址消失 |
| PC 到达 `mtvec`(=0) 的次数 | **0**（`debug_wb_pc` 从未为 0） | **141 次 / 2048 拍** |
| `debug_wb_pc` | 409 个不同值，`0xDEA7BCE0..0xDEA7C344`（垃圾基址） | **13 个值，`0x00..0x34`** |
| `debug_mepc` | 每绕一圈 `+0x4000`（`0x…8034`→`0x…c034`） | **恒为 `0x34`**（只有一个取值） |
| `debug_icache_miss_cnt` | 与 hit 同速增长 | **冻结在 15**（只有一个取值） |
| `debug_mcause` | 恒 `0x0B` | 恒 `0x0B`（`ecall`，不变） |
| `debug_trap_take` / `debug_mtval` | 恒 0 | 恒 0（`ecall` 不走 trap 通道，符合预期） |

去重后的 PC 序列就是一个标准的程序圈：

```
… 0x28 → 0x30 → 0x34 → 0x38 → 0x00 → 0x04 → 0x08 → 0x0C → 0x10 → 0x14
  → 0x18 → 0x1C → 0x20 → 0x24 → 0x28 → 0x30 → 0x34 → 0x38 → 0x00 → …
```

**环形周期 = 2048 / 47 = 43.6 拍**，与仿真的 ~43 拍、以及"每条指令约 3 拍（取指 hold 节奏）"
完全吻合。`icache_miss_cnt` 冻结在 15 这件事本身就是**PC 被永久锁在程序那一行 Cache 里**的证明 ——
修复前它随着 PC 走远而持续增长。

#### 一个必须诚实说明的边界

板上两次抓取（共 4096 拍、约 95 圈）里，**47/48 次重定向的 `debug_ready` 全都是 1**
（稳态循环里 `ready` 呈 `0/1/1` 节奏，而 `dnpc_flag` 恰好只落在 `ready=1` 那一拍）：

```
[1021] ifu_pc=0x38 dnpc_flag=0 ready=0
[1022] ifu_pc=0x38 dnpc_flag=0 ready=1
[1023] ifu_pc=0x38 dnpc_flag=1 ready=1   ← 重定向请求
[1024] ifu_pc=0x00 dnpc_flag=0 ready=0   ← PC 落到 mtvec
```

也就是说，**这份板上数据证明了"修复后行为完全正确"，但没有直接压到 `ready=0` 那条分支**。
`ready=0` 这一路径的证据来自**仿真**（它逐位复现了板上的原始故障，且 `ready=0`），
两者的一致性由下面三点交叉背书：

1. 修复前仿真与修复前板上的 PC 轨迹**逐位一致**（`0x38 → 0x3c → 0x40 → 0x44 …`）；
2. 修复后仿真与修复后板上的**环形周期一致**（~43 拍/圈）与每指令 hold 节奏一致（3 拍/条）；
3. 修复后仿真的**第一次** `ecall` 仍然是 `ready=0`（且现在能成功重定向），
   而板上的稳态 `ecall` 是 `ready=1` —— 两者不矛盾：第一次是冷 Cache，稳态是热 Cache。

**要在硬件上直接压到 `ready=0`**，需要：① 用测试台手按住复位、让 ILA 先 arm 好再松手；
或 ② 写一个专门让 `ecall` 落在取指 hold 拍上的程序。当前 `prog.hex` 稳态下做不到。
（我试过用"冷启动特征"触发 —— `icache_miss_cnt` 稳态恒为 15，理论上 `< 15` 只在冷启动成立，
但 `run_hw_ila` 比 CPU 跑第一圈慢了几个数量级，等 arm 好时早已进入稳态，抓不到。）

---

## 6. 顺带修掉的两处（都属"综合日志里早有告警、但一直没处理"）

### 6.1 `CSR.mtval_out` 没有驱动

```systemverilog
// CSR.sv —— 补上这一行
assign mtval_out = mtval_reg;
```

综合日志里其实写得很清楚，只是很容易被当成噪声跳过：

```
WARNING: [Synth 8-3848] Net mtval_out in module/entity CSR does not have driver
WARNING: [Synth 8-6014] Unused sequential element mtval_reg_reg was removed
```

后果：`mtval_reg` 写了也没人读（被当死寄存器优化掉），顶层 `debug_mtval` 恒 0。
上板 ILA 的 `probe11` 抓到恒 0，看起来像"ILA 探针没接对"，其实是 **RTL 漏驱动**。

### 6.2 `EXU.fault_inst_in` 接在一个**从未声明**的信号上

```systemverilog
// myCPU.sv（修改前）
.fault_inst_in (IDU_inst),    // ← IDU_inst 在 myCPU.sv 里根本没有声明！
```

`iverilog -Wall` 直接报：

```
myCPU.sv:599: warning: implicit definition of wire 'IDU_inst'.
myCPU.sv:537: warning: Port 27 (fault_inst_in) of EXU expects 32 bits, got 1.
```

即 Verilog 把它**隐式推断成 1 位网**，于是 `mtval` 的低 1 位悬空、高 31 位恒 0。

**正确的源是 IDU 的译码级指令 `inst_d`，不是 `IFU_inst`。**
因为 `illegal_flag` 是 `inst_d` 组合译出来的，`fault_inst_in` 必须与它**同一拍**；
而 `inst_d(T) = inst(T-1) = IFU_inst(T-2)`，**中间隔着两级流水寄存**
（停顿期间更是完全对不上）。接错会把**别的指令**写进 `mtval`，异常现场反而误导人。

做法：给 `IDU` 加一个输出口 `inst_d_out`（`assign inst_d_out = inst_d;`），
`myCPU` 里声明 `IDU_inst_d` 并接到 `EXU.fault_inst_in`。

---

## 7. 这次暴露出的另一个**既有**问题（未修，待决策）

`sim/tb_exc.sv`（异常测试台）在此之前的**任何 iverilog 流程里都编译不过** ——
它第 175 行引用了同一个不存在的 `u_cpu.IDU_inst`：

```
sim/tb_exc.sv:175: error: Unable to bind wire/reg/memory `u_cpu.IDU_inst' in `tb_exc'
```

修掉这个编译错误之后，三个异常用例**全部失败**，而且失败方式很说明问题：

```
CSR now: mcause=0000000b mepc=00000028 mtval=00000000
[FAIL] trap count == 1
[FAIL] mcause == 2 (illegal)
```

`mcause=0x0B`（= `ecall`）说明**根本没有发生非法指令/非对齐异常**，
`trap_cnt = 0` 说明 `debug_trap_take` **一次都没抬起来** ——
即**同步异常检测（`exc_pending` → `trap_take`）在这版 RTL 上不工作**。

**已确认这不是本次改动引入的**：把 `IFU.sv` 单独回退成 `dnpc_flag & ready`
再跑一次，输出**逐字节相同**（`mcause=0000000b mepc=00000028`，同样的 PASS/FAIL 集合）。

这是一个独立于 B9 的既有功能缺口，且**`mtval` 的两处修复只有在这个缺口修好之后才能真正被验证**。
需要单独排查（`EXU` 的 `exc_pending` / `IDU_illegal_flag` / `trap_take` 链路）。

---

## 8. 本次新增的三个 ILA 探针（probe13/14/15）

为了在**真实硬件**上也能做同样的判定，把这三根线引到 ILA：

| probe | 信号 | 宽度 | 作用 |
|---|---|---|---|
| 13 | `debug_dnpc_flag` | 1 | 重定向请求（`Control.dnpc_flag`） |
| 14 | `debug_ready` | 1 | IFU 的 `ready` 输入（= `IDU_ready`） |
| 15 | `debug_ifu_pc` | 32 | 取指级 PC（比 `debug_wb_pc` 直接，不用等它流到 WB） |

**以后任何"重定向没生效"都能一眼定性：**

| 现象 | 结论 |
|---|---|
| `probe13` 恒 0 | 请求根本没发 → 查 `Control`（`dnpc_flag` 的生成与仲裁） |
| `probe13=1` 且 `probe14=0` 且 `probe15` 没变 | 请求被背压吃掉 → 查 IFU 的门控条件（就是这次这个 bug） |
| `probe13=1`、`probe14=1`，`probe15` 没变 | 优先级问题 → 查 IFU 的 `if/else` 顺序 |

**推荐触发条件：** `probe15 == 0x00000000`（抓 PC 回 `mtvec`），或 `probe13 == 1`（抓所有重定向）。

`myCPU` → `board_top` → `board_top_ila` → `board_top_gui` 四层都已加端口，
并且都并进了 `debug_dead` 的或链，保证有真实负载、不会被综合优化掉。

---

## 9. 改动文件清单

| 文件 | 改动 |
|---|---|
| `IFU.sv` | ★ 核心修复：`else if (dnpc_flag & ready)` → `else if (dnpc_flag)` |
| `CSR.sv` | 补 `assign mtval_out = mtval_reg;` |
| `IDU.sv` | 新增输出口 `inst_d_out`（= `inst_d`） |
| `myCPU.sv` | 声明 `IDU_inst_d`；`EXU.fault_inst_in` 改接 `IDU_inst_d`；新增 3 个 debug 输出 |
| `board/board_top.sv` | 新增 3 个 debug 输出并连到 `myCPU` |
| `board/board_top_ila.sv` | 新增 3 个 debug 输出；并进 `debug_dead` 或链 |
| `project_src/board_top_gui.sv` | 新增 3 根线 + `probe13/14/15` |
| `build_project_ila.tcl` | `C_NUM_OF_PROBES` 13 → 16；`ILA_PROBES` 追加 `1 1 32` |
| `sim/tb_iverilog.sv` | ★ 新增 `ecall-redirect` 断言 + `[EPC]` 逐拍轨迹 + 报告快照解耦 |
| `sim/tb_exc.sv` | 修掉 `u_cpu.IDU_inst` 的编译错误（改用 `u_cpu.EXU_fault_inst`） |

---

## 10. 一句话总结

> **重定向是"命令丢弃"，不是"请求接收"。**
> 凡是描述"当前这条取指能不能被接收"的信号（`inst_valid`、`ready`），
> 都**不能**用来门控重定向 —— 因为重定向的语义恰恰是**放弃**当前这次取指。
> 这一段代码里 `inst_valid` 已经因为同样的理由被删过（B4/B7），`ready` 是漏掉的第二个（B9）。
