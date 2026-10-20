# v12（C）console 收发 + GPIO，以及两件必须说清楚的事

> 本轮目标（Tier 1 之后的第一步）：**让平台能对话、能看**。
> 交付：串口**接收**（8 深 FIFO）+ 7 个 LED 的 GPIO，一份自己的 console 演示程序
> （横幅 / 回显 / 定时器中断心跳）。
>
> 另外两件比代码本身更重要：
> - §5：**"load-use 0 拍前递"这个需求在本微架构下不成立**，附证据；
> - §6：仿真中发现一个**可疑的分支行为**（handler 里 not-taken 分支之后的指令
>   不执行），已定位到最小复现，但**没有**在本轮修掉 —— 记在这里当待办。

---

## 1. MMIO 映射（在 v12（B）基础上扩展）

| 字地址 | 下标 | 方向 | 名字 | 内容 |
|---|---|---|---|---|
| `0x1000_0000` | 0 | WO | `TXDATA` | 写 → 低 8 位进发送器（忙时丢弃） |
| `0x1000_0004` | 1 | RO | `TXSTAT` | bit0 = busy |
| `0x1000_0008` | 2 | RO | `RXDATA` | **读 → 弹出一个已收字节**（空则读 0、不弹） |
| `0x1000_000c` | 3 | RO | `RXSTAT` | bit0 = FIFO 非空；bit1 = 溢出过（读一次清） |
| `0x1000_0010` | 4 | RW | `LED` | 低 7 位 → 板上 LED1~LED7 |

★ 不变量：窗口按 `perip_addr[31:16] == 16'h1000`、下标用 `perip_addr[4:2]`。
★ 不变量：MMIO 写必须门掉 DRAM 的 `wen`（沿用 v12（B）的那条，见 board_top.sv）。

---

## 2. 接收通路：为什么是"第二个 uart_rx + 8 深 FIFO"

### 2.1 两个接收器，不是一份共享

`board/uart_rx.sv` 的 `valid` 是**单拍脉冲**，两个消费者（boot_loader / console FIFO）
之间没有握手。共用一份就变成"谁先看到谁拿走"：

- 引导期间 console FIFO 会把镜像帧的字节吞掉（镜像直接坏掉）；
- 反过来 console 数据也可能被 boot_loader 当成帧头。

加仲裁能解决，但代价大于收益 —— **两个接收器各监听同一根线**，
每个约 15 个 FF，零交互。console 那一份的 `rst` 接 `cpu_rst_eff`，
引导期间整体保持复位，镜像帧一个字节也进不来。

### 2.2 弹出必须**延迟一拍**

```
rx_pop_req <= perip_ren & mmio_sel & (idx == 2) & rx_avail;   // 寄存一拍
rx_pop      = rx_pop_req;
```

原因：DCache 的读是**两拍契约** —— 请求拍给 `perip_ren` 脉冲，
**下一拍**才采 `perip_rdata`。如果在请求当拍就动 FIFO 头指针，
采样那拍读到的已经是下一个字节，症状是"每读一次丢一个字节"。

### 2.3 满了就丢，但置溢出位

`rx_cnt == 8` 时新字节**丢弃**，并把 `RXSTAT.bit1` 置 1（读一次清）。

★ 不覆盖已有数据：覆盖会让软件读到"看起来正常、其实是后来那个字节"的错误序列，
比丢字节难查得多。

### 2.4 代价

| 项 | 数量 |
|---|---|
| console `uart_rx` | ~15 FF |
| RX FIFO（8×8 位 + 指针 + 计数 + 溢出位） | ~36 FF |
| LED 寄存器 | 7 FF |

---

## 3. 软件：`sim/gen_console_demo.py`

一段程序同时演四件事（`sim/console_demo.hex`）：

```
启动 → 打印 "BigBird v12\r\n"
     → 清空 RX FIFO（引导帧的残留字节会被回显出来，很难看）
     → 主循环：先等 TX 空闲，再看 RXSTAT；有字节就弹出并回显
     → 每 TICK_TICKS 一次定时器中断：tick++，LED = tick 低 7 位，打一个 '.'
```

`TICK_TICKS` 在板上是 5000（10 ms），仿真用 1000（2 ms）——
改的是**生成出来的镜像**，不是 RTL，所以仿真验的仍是同一套硬件行为。

寄存器分工（**故意不重叠**，这不是 RTOS）：

| 谁 | 用哪些 |
|---|---|
| 主程序 | x1 MMIO 基址 / x2,x3 puts / x4..x9 临时 |
| puts | x10,x11,x12,x13 |
| 中断 | x21..x25 |

★ 这只是演示，**不是**"中断安全"的范例：真 RTOS 要在 handler 里保存/恢复
用到的寄存器，或者由硬件压栈。

### 3.1 生成器自带一个两遍汇编

`puts` 的返回判断和 handler 结束都要**前向引用**。第一版用"同地址覆盖"硬凑，
把自己绕晕了（生成出来还留着旧指令）；改成"先记录待回填的跳转、最后统一解算"
反而只有 20 行。

### 3.2 踩过的两个坑（都够隐蔽）

1. **把字符串放在 IROM，然后用 `lw` 去读** —— 本核的 IROM 和 DRAM 是
   **两套独立地址空间**（IROM 只能取指、DRAM 只能读写）。`lw 0x200` 读到的是
   DRAM 里的 0，于是 `puts` 一个字节都不打（横幅完全消失，但程序不报错）。
   正确做法：启动时用立即数把字符串写进 DRAM（`sim/gen_console_demo.py` 里
   `for k, w in enumerate(pack_string(BANNER))` 那一段）。
2. **`puts` 只打了一个字就返回** —— 本字内右移 4 次后没有回到"取下一个字"，
   实测横幅只有 `BigB`。修法是加一个 4 字节计数器，用完 `jal` 回 `puts` 开头。

---

## 4. 验证

### 4.1 `sim/tb_console.sv`（6 条判据全过）

```
[CON] 'B' 'i' 'g' 'B' 'i' 'r' 'd' ' ' 'v' '1' '2' 0x0d 0x0a
  [PASS] C1 banner length == 13
  [PASS] C1 banner bytes == BigBird v12 CRLF
  [PASS] C2 echo of 'A'
  [PASS] C3 echo of 'O','K',CR
  [PASS] C4 timer interrupt ran (LED != 0)
  [PASS] C5 at least one '.' heartbeat
[CONSOLE-SELFCHECK] status=PASS (6 checks)
```

- **激励不用 `uart_tx`，而是 TB 里直接位翻转**（`uart_send`，10 行）。
  第一版例化一个 `uart_tx` 去喂板子的 `uart_rx`，结果 `send` 脉冲在这个环境里
  **从来没被采样到**（加了 `[SAMP]` 探针一行都没打），排查代价远大于省下的代码。
  位翻转只描述"一个真实终端在线上做什么"，不依赖任何被测 RTL。
- 判据里带 `[RAW]/[FIFO]/[TXW]` 三个探针（`+fifotr` 打开），
  用来区分"字节没进来 / 进来了被读走 / 程序根本没写 TXDATA"三种情况 ——
  console 类问题只靠最终字节数永远分不清。

### 4.2 全量回归

```
[REGRESSION] ALL PASS (28 runs)
```

7 个基准程序拍数仍是一个没变（35/42/46/54/77/110/97）——
本轮 RTL 只动了板级（MMIO/GPIO），没碰 CPU 数据通路。

---

## 5. 为什么**没有**做"load-use 0 拍前递"

这是本轮开工时的第一项计划，做到一半发现**需求本身与本微架构矛盾**，如实记录：

### 5.1 现在的时序

设 load 指令在 `EXU@0 → M1@1 → M2@2`，消费者在 `IDU`：

| 周期 | load 在 | 消费者在 | 消费者能否拿到数据 |
|---|---|---|---|
| 0 | EXU | IDU | ✗ 地址都还没算出来 |
| 1 | M1 | IDU（停） | ✗ DCache 请求这一拍才发出去 |
| 2 | M2 | IDU（停） | ✓ `3'b101` 前递 M2 真值（`rdata_ex_pipe`） |

所以消费者在 IDU **停 2 拍**（`exu_load_use | mem_load_use`），第 3 拍进 EXU。
这就是现在的行为，`Data_hazard.sv:129` 的 `load_use_stall = exu_load_use | mem_load_use`。

### 5.2 关键事实：DCache 是 **M2 打的**

```
// rtl/LSU.sv:199
assign addr = {Ex_result_addr_reg_pipe[31:18], 2'b00, Ex_result_addr_reg_pipe[15:0]};
                          ^^^^^ M2 的寄存器
```
`cpu_en/cpu_addr` 全部取自 **M2**，所以 DCache 的数据属于 **M2 那条指令**。
`LSU_Rdata`（M1 级的 `rdata_ex`）因此和 M1 的地址是**错位的**，
它接到 `Control.MEM_Rdata` 却**没有任何读者**（综合报告里那条
`Port MEM_Rdata[31] ... has no load` 就是它）。

### 5.3 结论

- **0 拍不可能**：数据最早在 M2 出现，而消费者最晚在 M1 那一拍就得拿到
  （它的 EXU 是下一拍）。差一拍，物理上没有。
- **要少停 1 拍**，唯一办法是把 DCache 请求从 M2 挪到 M1（地址在 EXU 就算好了，
  M1 完全可以发出去）。但那要重做 DCache 的 `mem_req_r / resp_valid_r / hold`
  全套相对时序契约，牵动 LSU、DCache、`lsu_adv`、miss 路径 ——
  属于**重定时（retiming）工程**，不是"加一条前递线"。

所以本轮把它**移出范围**，改做确定有收益的 console + GPIO。
真要提这一点，建议单开一轮：先把 DCache 请求前移一拍，用
`probe6 = mcycle` 量化 load 延迟（现在能直接量了）。

---

## 6. ★ v12-BUG-1（已定位并修复）：更年轻的 `mret` 吞掉更老分支的误预测

### 6.1 现象

`console_demo` 的第一版里，心跳点是"每 4 个 tick 打一个 `.`"：

```asm
andi x24, x23, 3
bne  x24, x0, hdone      # 不是 4 的倍数就跳过
li   x25, '.'
sw   x25, 0(x1)          # ← 这条从不执行
hdone:
mret
```

**一个点都没打出来**（6 个 tick：x23 = 1..6，tick 4 应该落进 not-taken 分支）。
改成 `andi x24, x23, 1`（应打 3 个点）仍然 **0 个**；
把条件分支整段删掉、改无条件 `sw`，点立刻正常（6 个 tick 6 个点）。

### 6.2 分离：普通代码没问题，问题只在中断上下文

新建了 `sim/gen_brsel_progs.py` + `sim/tb_mini.sv`（最小观察台：只有 CPU + IROM +
DRAM 模型，跑一个 hex 后 dump 寄存器）：

| 程序 | 模式 | 结果 |
|---|---|---|
| `brsel_a` | 普通代码：`andi` → `bne`（1 条间隔）→ 条件 `addi` | x6 = **10** ✓ |
| `brsel_b` | 同上，中间插 nop | x6 = **10** ✓ |
| `brsel_c` | 条件执行的是一条 `sw` | x6 = **10**、x7 = **9** ✓ |
| `brsel_h` | **同样的动态模式放进定时器中断处理程序** | x6 = **0**（应为 1）✗ |

所以：**不是"not-taken 分支"本身的问题，而是"中断上下文 + 紧跟其后的指令"**。

### 6.3 用 `+win` 抓流水级，一条一条看

`tb_mini` 加了 `+win=<起始拍>`，把 IFU/IDU/EXU 三级 PC、valid、dnpc、各重定向源
逐拍打出来。第二次中断（tick 2，x24 应为 0 → not-taken）的关键三拍：

```
cyc=100019  IFU_pc=0x31c  IDU_pc=0x314  EXU_pc=0x310
cyc=100020  IFU_pc=0x324  IDU_pc=0x318  EXU_pc=0x314   ← IFU 直接跳到 0x324，跳过了 0x320
cyc=100021  IFU_pc=0x328  IDU_pc=0x31c  EXU_pc=0x318
cyc=100022  IFU_pc=0x32c  IDU_pc=0x324  EXU_pc=0x31c   ← bne 在 EX；mret 已在 IDU 译码
            ... dnpc=0x3c flag=1 sysred=1 misp=0 clr=0
```

第 100020 拍 IFU 取了 0x324（分支目标），说明**预测器预测 taken**（正确路径是 0x320）。
第 100022 拍 `bne` 进 EX，实际 not-taken、预测 taken —— 应该产生误预测重定向，
但 **`misp=0`**，而同一拍 `sysred=1`（因为 0x324 的 `mret` 正在 IDU 译码）。

### 6.4 根因

```systemverilog
// 修复前（rtl/Control.sv）
assign bp_misp_det = EXU_ctrl_valid & ~(intr_take | system_redirect | trap_redirect) & ...
```

`system_redirect = mret_flag | ecall_flag | fence_i_flag | trap_redirect`，
其中**前三个都是 IDU（译码级）的译码标志**，属于**更年轻**的指令。
把 `system_redirect` 放进屏蔽项，效果就是：

> **更年轻的 `mret` 把更老的分支的误预测吞掉** → 老分支没有重定向 →
> 预测器取的错路径指令（`mret`）被当成正确路径执行 → 中间那条 `addi` 永久跳过。

而且这个 handler 每进一次就丢一条指令，**不报错、不跑飞**，
只是"某段条件代码静默不执行" —— 这是最难查的一类。

顺带发现原注释的前提也是错的："这三个源各自会清掉 EX 级那条指令" ——
`EXU_inst_clear = intr_take | bp_mispredict | trap_redirect | (mem_stall & ~(branch|jump)) | load_use_stall`，
**并没有** mret/ecall/fence.i。

### 6.5 修复

```systemverilog
assign bp_misp_det = EXU_ctrl_valid & ~(intr_take | trap_redirect) & ...
```

只保留两个**真正会抢同一拍 dnpc** 的源：

- `intr_take`：中断优先级最高（`intr_take > trap_redirect > bp_mispredict > system_redirect`），
  被中断打断的那条指令会由 `mepc` 重新执行，误预测可以安全丢弃；
- `trap_redirect`：异常属于**EX 机那条指令自己**，它的分支结果本来就无意义。

去掉 `system_redirect` 之后，老分支的误预测会正常发出；因为
**dnpc 优先级链里 `bp_mispredict` 本来就排在 `system_redirect` 之前**，
所以"老分支先重定向、`mret` 之后被重新取"语义正确 —— 这个优先级早就写对了，
只是屏蔽项把更老的判定提前掐死了。

### 6.6 验证

| 项目 | 修复前 | 修复后 |
|---|---|---|
| `brsel_h` x6（handler 内条件执行次数） | **0** | **1** ✓ |
| `console_demo`（带条件分支的心跳点） | 0 个点 | tick 2/4/6 各 **1 个点** ✓ |
| 全量回归 | 28/28 | **32/32**（新增 4 条 brsel 用例） |
| 7 个基准程序拍数 | 35/42/46/54/77/110/97 | **一个都没变** |

★ 4 条 `brsel_*` 已进 `_diag/regress.ps1`（`tb_mini` + `+x6=` 期望值），
这是**永久回归项** —— 这个 bug 修好之后如果谁再动 `bp_misp_det`，它会立刻红。

★ 教训（写进不变量）：`bp_misp_det` 的屏蔽项**只能包含"会造成同一拍 dnpc 冲突"的源**，
不能顺手把"更年轻指令产生的重定向"也塞进去 —— 那不是冲突，那是**优先级问题**，
而优先级已经由 dnpc 的三元链处理了。

### 6.7 构建 + 上板（含修复）

```
RESULT build OK
WNS = 0.734 ns   WHS = 0.009 ns   TNS = 0   THS = 0
0 Errors / 0 Critical Warnings
```

上板加载 **带条件分支的 console 演示程序**（`sim/console_branchy.hex`：
偶数 tick 才打一个点，正好是修复前 100% 丢掉的那条路径）：

```
[uart] typed: OK
[uart] received 405 bytes
[uart] text: .......OK...............................
[uart] RESULT: OK
```

- 8 秒收到 **405 字节**，其中约 **400 个点** —— tick 10 ms、隔一个打一次 = 20 ms/点，
  8 s ÷ 20 ms = **400**，与实测完全对上；
- 敲 `OK` 被原样回显。

★ 这一段在修复前会是 **0 个点**。所以这不是"仿真通过"，而是
**同一条曾经被静默跳过的指令，现在真的在硅片上执行了**。

---

## 7. 构建结果（2026-10-18 18:09）

```
RESULT build OK
WNS = 0.619 ns   WHS = 0.009 ns   TNS = 0   THS = 0
setup_failing_paths_exist = 0
0 Errors / 0 Critical Warnings
```

| 资源 | v12（B） | v12（C） | 增量 |
|---|---|---|---|
| Slice LUTs | 35 620 | 35 694 | **+74** |
| Slice Registers | 22 717 | 22 777 | **+60** |
| Block RAM Tile | 38.5 | 38.5 | 0 |
| DSP48E1 | 4 | 4 | 0 |

- WNS 从 1.300 掉到 **0.619**（−0.68）。这不是"新增逻辑的关键路径"（console 全是
  慢速外设），而是**布局随机性 + 引脚增多后的布线压力**：本轮多了 7 根 LED 输出，
  综合报告里 `OBUF` 从 2 个变成 9 个。仍在 50 MHz 下收敛，Fmax ≈ 53.3 MHz。
- 面积的增量与设计值吻合：FIFO 被综合成 **Distributed RAM**
  （`rx_fifo_reg` → `RAM32M × 2`），所以 FF 只多了 60 个而不是 ~96 个。
- 产物：`board_top_gui_boot.bit` 4 045 694 B + `.ltx`。

## 8. 上板验证（2026-10-18 18:10）

```
[boot] sent 821 bytes x561 on COM9 in 40.2s        ← 灌 console_demo.hex
RESULT program OK at 18:10:31
...
[uart] typed: Hi
[uart] received 907 bytes
[uart] text: .........Hi..........................
[uart] RESULT: OK
```

两件事同时被证明：

1. **RX FIFO → 主循环 → TX 回显全链路通**：宿主机敲 `Hi`，板上原样回显 `Hi`
   （在上千个心跳点中间，位置正好对应敲键的时刻）。
2. **定时器中断在跑**：9 秒收到 **907 字节**，其中约 900 个是心跳点
   ⇒ **10 ms 一个 tick**，与 `TICK_TICKS=5000`（500 kHz × 2 µs）完全对上。

横幅 `BigBird v12` 这次没出现在日志里，是因为读取是在灌镜像 40 秒之后才开始的 ——
横幅在启动时就打完了（仿真里 C1 已逐字节验证过）。

★ 唯一**没有**在板上直接确认的是 LED —— 它没有回读通路，只能肉眼看板子。
但它和心跳点走的是同一个 handler、同一拍写 MMIO，仿真里 `tb_console` 的 C4
判据（`led != 0` 且随 tick 变化）已经验过。
