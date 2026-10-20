# v12（B）Zicntr 计数器 + UART 发送（console）设计记录

> 目标：把板子从"能跑"变成**能测**。
> Tier 1 四项一次构建交付：
> 1. **Zicntr**：`mcycle` / `minstret`（64 位，可读写）+ 只读影子 `cycle`/`time`/`instret`；
> 2. **UART TX**（115200 8N1，MMIO `0x1000_0000`），软件可以 `sw` 一个字节打出来；
> 3. **状态字探针**（`debug_status`）：把 8 个 1 位量压进一根已有的 32 位探针，
>    不重建 ILA IP、不改任何分析脚本的列号；
> 4. **`trap_seen` 粘滞位**：抓"第一次陷入"不再靠赌抓包恰好停在那 1 拍。

---

## 0. 为什么先做这两件（动机，不是"顺手加的"）

v11 上板验证完，能观察到的事实是：**改一次程序要重跑 33 分钟综合**，
而**板上的性能完全无法量化**：

- `mtime`（CSR `0x7C0`）是 `MTIME_DIV_DEFAULT=100` **分频后的墙钟**，
  50 MHz 下是 500 kHz（2 µs 一个 tick），它量不出"这条指令花了几拍"；
- `mcycle`/`minstret`（Zicntr）v9~v11 一直**没有实现**，当初的理由是"RTOS 用不到"——
  但反过来，"想优化却量不出收益"才是真正的瓶颈；
- 没有 console，程序里唯一的输出手段是往 DRAM 写数再用 ILA 抓，
  等于每条调试信息都要占一个 ILA 抓包。

所以 Tier 1 的顺序是：**先让板子可测（Zicntr + 状态字），再让它能说话（UART TX）**，
微架构优化（load-use 0 拍前递等）放在**有了基线之后**。

---

## 1. Zicntr：寄存器与语义

### 1.1 地址与权限

| 地址 | 名字 | 权限 | 说明 |
|---|---|---|---|
| `0xB00` | `mcycle` | MRW | 时钟拍数，**每拍 +1** |
| `0xB02` | `minstret` | MRW | 退休指令数 |
| `0xB80` | `mcycleh` | MRW | `mcycle[63:32]` |
| `0xB82` | `minstreth` | MRW | `minstret[63:32]` |
| `0xC00` | `cycle` | MRO | `mcycle` 的**只读影子** |
| `0xC01` | `time` | MRO | 映射到已有的 `mtime`（32 位墙钟） |
| `0xC02` | `instret` | MRO | `minstret` 的只读影子 |
| `0xC80` / `0xC81` / `0xC82` | `cycleh` / `timeh` / `instreth` | MRO | 高半（`timeh` 恒 0） |

★ **不变量 1**：`instret(0xC02)` 与 `minstret(0xB02)` 是**同一个 64 位计数器**的两个地址，
不是两份状态。写成两份就会出现"读 `minstret` 和读 `instret` 差出一个数"。

★ **不变量 2**：只读性**不靠 CSR 模块判**，靠 IDU 的地址编码判
（`csr_addr[11:10] == 2'b11` → 只读段）。所以 `csrw cycle, x1` 是 `mcause=2` 的
非法指令，而且**零副作用**（`no_side_effect` 把整张 `csr_wen` 位图清 0）。
CSR.sv 里因此**没有** `cycle` 的写分支 —— 写了也不会到。

### 1.2 `time` / `timeh` 的口径（有意简化，必须写清楚）

`time` 映射到已有的 `mtime`（32 位、500 kHz）。`timeh` **读 0**。

为什么不做 64 位：`mtime` 只做了 32 位。如果 `timeh` 编造高位，
软件用 `time` 算出来的墙钟就是错的（而且是"看起来正常、其实是错"的那种）。
按规范，"不实现"的正确表达是**读 0**，这与 `mimpid`/`mconfigptr` 的处理口径一致。

### 1.3 写优先于自增

```
if (reset)                       mcycle_reg <= 0;
else if (csr_wen[CSRW_MCYCLE])   mcycle_reg[31:0]  <= csrd;
else if (csr_wen[CSRW_MCYCLEH])  mcycle_reg[63:32] <= csrd;
else                             mcycle_reg <= mcycle_reg + 1;
```

写的那个时钟沿**不自增**。反过来（自增后覆盖）会让 `csrw mcycle, 0` 读回 1，
软件无法用它做精确基准。`mtime` 早就是"写优先"口径，这里保持一致。

### 1.4 `minstret` 的计数使能：`retire`，不是 `WBU_valid`

这是本次最容易做错的一处。

`WBU_valid` 看起来是"写回级有没有一条有效指令"，但 **LSU 的 `mem_hold`
（DCache 缺失）/ `mdu_busy` 会把 WB 入口冻住**，此时 `valid_wb` 连续多拍为 1。
拿它当计数使能，一次访存缺失就会被数成 3~4 条指令。

正确的使能是"**本拍真的有一条有效指令推进到 WB**"：

```systemverilog
// rtl/LSU.sv
assign retire_wb = ready_next & ~lsu_freeze & valid_reg_pipe;
```

三项必须与 `always_ff` 的推进条件**逐字一致**（`ready_next & ~lsu_freeze`），
再加 `valid_reg_pipe` 回答"推进的是不是一条真指令"。

口径说明：本核的 `minstret` 计的是"进入 WB 的指令"，**陷入的那一条也算 1**。
规范说陷入指令不算退休，差 1/次陷入；对性能测量无影响，故不为它加门控
（门控还得把 EX 级 `trap_take` 的时间差算进来，得不偿失）。这条偏差写在这里，
不假装没有。

### 1.5 CSR RAW 前递：别名必须映射到同一个 onehot 位

`csr_wen[15:0]` 是写使能位图，`csr_sel[15:0]` 是读选择位图（前递命中判据）。
新增 4 个写位：

| 位 | 寄存器 |
|---|---|
| 11 | `mcycle` |
| 12 | `minstret` |
| 13 | `mcycleh` |
| 14 | `minstreth` |

★★ **这是本次唯一踩到并修掉的 RTL bug**：

第一版把 `csr_onehot` 写成"只有本体有位"（`cycle` 不给位）。结果
`csrw mcycle, x0` 紧跟 `csrr x, cycle` 时：

- 影子链按位与非零判命中 → `cycle` 没有位 → **不命中** → 绕过前递去读寄存器；
- 寄存器的写要到 **WB** 才落盘，而 **ID→WB 有 5 拍**；读的那一拍寄存器还是旧值。

实测（`tb_sys +kind=zicntr`）：期望 `x11 = 0`，实际 `x11 = 0x29 = 41` ——
正好是"清零前一刻的拍数"。

修法：**别名与本体共用同一位**
（`cycle`→bit11、`instret`→bit12、`cycleh`→bit13、`instreth`→bit14、`time`→bit10）。

★ 给别名位**不会**让"写只读影子"变合法：`csrw cycle, x1` 在 IDU 就被
`csr_illegal` 判成非法指令，`csr_wen_next` 被 `no_side_effect` 整体清 0。

### 1.6 代价

- 128 个 FF（两个 64 位计数器）+ 两个 64 位增量器；
- `retire` 是 WB→ID 的 1 位控制信号，**只喂 FF 使能**，不构成组合长路径；
- LUT 增量在 util 报告的噪声范围内（见第 6 节实测）。

---

## 2. UART TX：把 `sw` 变成一串字节

### 2.1 MMIO 地址

| 地址 | 名字 | 方向 | 内容 |
|---|---|---|---|
| `0x1000_0000` | `TXDATA` | WO | 写 → 低 8 位入发送器（忙时**丢弃**，不排队） |
| `0x1000_0004` | `STATUS` | RO | `bit0 = busy`（1 = 上一帧还没发完） |

★ 为什么是 `0x1000_0000`：DCache 的 `UNCACHE_MASK` 默认 `0x0FFF_FFFF`，
**地址 ≥ 0x1000_0000 自动走 MMIO 通路**（不分配缓存行、读直通外设）。
DRAM 只有 64 KB（`perip_addr[15:2]` 索引），两者地址空间天然不重叠，
所以板级只需要一个窗口译码，DCache 一行都不用改。

### 2.2 译码与"必须门掉 DRAM 写"

```systemverilog
assign mmio_uart_sel = (perip_addr[31:16] == 16'h1000) & (perip_addr[15] == 1'b0);
...
assign perip_rdata = mmio_uart_sel ? {31'b0, uart_busy} : dram_rdata;
dram_inst .wen (perip_wen & ~mmio_uart_sel),
```

- 窗口按 `perip_addr[31:16]` 译码（不是 `[31:28]` —— 那是 256 MB 的大窗口，
  会把以后要加的定时器/GPIO 一起吞掉）；
- ★★ **`dram` 的 `wen` 必须被 `~mmio_uart_sel` 门掉**。不门的话，一次
  `sw 0x1000_0000` 会**同时**写掉 DRAM 第 0 个字（`perip_addr[15:2] == 0`），
  症状是"打印一个字符，某个全局变量莫名其妙变了"。
  这条由 `tb_board_top_uart` 的 U2 判据守住：DRAM[0] 预置 `0xCAFE_0000`，
  打印两个字符后必须原样不变。

### 2.3 发送器本身（`board/uart_tx.sv`）

- 参数与 `uart_rx.sv` **完全一致**（`CLK_FREQ=50_000_000`, `BAUD=115200`），
  `BIT_TICKS = (CLK_FREQ + BAUD/2)/BAUD = 434`，误差 0.007%；
- 帧 = 起始位(0) + 8 数据位(LSB first) + 停止位(1) = 10 位 = **4340 拍 = 86.8 µs**；
- `tx` 空闲态为 **1**（UART 规定，反了对面永远等不到起始沿）；
- `busy = (state != S_IDLE)`，软件靠轮询 `STATUS.bit0` 做流控；
- 忙时的 `send` **静默丢弃**：这是外设寄存器的正常语义（写了就写，不排队），
  软件必须自己轮询。有 `tb_uart_tx` 的 T4 专门验这一条。

---

## 3. 状态字探针（`debug_status`）与 `trap_seen`

ILA 的 16 个探针宽度是**冻结的**（`ILA_PROBES {1 32 1 5 32 32 32 32 32 32 32 32 1 1 1 32}`），
改宽度要重建 IP、还要同步所有分析脚本的列号。所以这次**把 8 个 1 位量压进已有的
两根 32 位探针**，一个字节都不用动：

| 探针 | v12（A） | v12（B） |
|---|---|---|
| probe5 | `boot_busy32` | **`debug_status`**（见下） |
| probe6 | `boot_ok32` | **`debug_mcycle`（mcycle 低 32 位）** |

`debug_status` 位分配：

| 位 | 信号 | 用途 |
|---|---|---|
| 0 | `IFU_stall` | 前端冻结（load-use 冒险 / dcache_hold）—— 停顿时长的总分母 |
| 1 | `dcache_hold` | DCache load 缺失（同步 BRAM 的 1 拍回不来） |
| 2 | `mdu_busy` | MDU 多拍迭代未完成（乘/除 17 拍） |
| 3 | `system_redirect` | mret/ecall/fence.i/trap 的重定向（**不含**分支预测失败） |
| 4 | `trap_seen` | **粘滞**：复位后发生过至少一次同步异常/断点 |
| 5 | `dnpc_flag` | 任意重定向请求（与 probe13 同源） |
| 6 | `load_use_stall` | Control 判定的 load-use 冒险（bit0 的子集） |
| 7 | `IDU_ready` | 下游背压（与 probe14 同源） |
| 8 | `boot_busy` | 串口引导（由 `board_top` 填） |
| 9 | `boot_ok` | 同上 |
| 10 | `boot_err` | 同上 |

★ **不变量**：低 8 位**只由 `myCPU` 驱动**，`board_top` 只置 bit8~10 ——
两处驱动同一个 bit 会综合出多驱动。
★ **不变量**：`debug_status` / `debug_mcycle` 必须并进 `board_top_ila` 的 `debug_dead`
或链，否则顶层没有负载、综合会把它们整条删掉（§BOARDILA-3 的老坑）。

`debug_mcycle` 是这次最有用的一个探针：**ILA 每一拍都带着精确拍数**，
任意两个采样点做差就是真实周期数，不用改被测程序、不用在代码里插时间戳。

`trap_seen` 为什么做成粘滞位：`trap_take` **只有一拍宽**，抓包很难恰好停在那一拍。
粘滞位让"第一次出事"变成一个稳定的电平，可以用它做触发条件。

---

## 4. 仿真验证（全部 iverilog，先仿真再上板）

新增两个测试台 + 一个新用例，都已并入 `_diag/regress.ps1`：

| 测试台 | 判据 | 结果 |
|---|---|---|
| `sim/tb_sys.sv +kind=zicntr` | 15 条（见下） | **PASS** |
| `sim/tb_uart_tx.sv` | 11 条，回环 tx→rx | **PASS** |
| `sim/tb_board_top_uart.sv` | 6 条，板级端到端 | **PASS** |

### 4.1 `tb_sys +kind=zicntr`（15 条全过）

实测关键值：

```
x5=00000013  x6=0000001c  x7=00000009   (minstret 差值 = 9)
x8=00000000  x9=00000000                (csrw 后紧跟 csrr，前递给出 0)
x11=00000001 x12=00000000               (清 0 后插 6 条 NOP 再读：寄存器真的清了)
x13=00000024 x14=00000025               (instret <= minstret，同一个计数器)
x15=00000000 x16=00000000               (time 很小 / timeh 恒 0)
x17=00000000                            (csrw cycle 陷入，rd 没被写)
x18=00000034 x19=0000000f               (陷入后计数器继续走，handler 也算)
x23=00000001 x25=0000600d                (1 次陷入 / 走到尾)
```

★ 最强的一条是 **`x7 == 9`**：直线代码里 8 条 `addi` 夹在两次 `csrr minstret` 之间。
把停拍数也算进去、或按 WB 电平重复计数，这个数都会偏大。**这是"每条指令 +1"的硬证据。**

★ 第二条是 **`x11`**：一开始没插 NOP，读到的是清零**前**的 41（就是第 1.5 节那个 bug）。
插 6 条 NOP 让前递窗口（EX + 4 深影子链 = 5 个指令槽）过期之后，
`csrr` 只能读寄存器，才真正验到"寄存器被清零"。

### 4.2 `tb_uart_tx`（11 条全过）

```
[PASS] idle: tx == 1 / busy == 0
[RX ] byte=a5  frame length = 4341 cycles (expect 10*BIT_TICKS = 4340)
[RX ] byte=00 / ff / 5a                 (连续三字节：全 0、全 1、0x5A)
[PASS] busy is high mid-frame
[RX ] byte=3c                           (帧中间的 send 被丢弃，只收到 1 个字节)
[PASS] recovers after dropped send (0xE7)
```

用**真参数**（50 MHz / 115200 / 434 拍）而不是缩小波特：
缩小波特虽然快，但验的就不是板上那条分频路径了。

★ 这个测试台第一版挂死过：在 `posedge` 之后紧跟 `tx_send = 1'b0;` 会与被测模块的
`always_ff`（同样在 posedge 采样）**竞争**，iverilog 下表现为"send 没被看到 →
busy 永远不起 → 死等超时"（日志只剩两行 PASS 然后 TIMEOUT）。
教训：**激励一律在 negedge 驱动**，并且每个 `while` 都要带 guard。

### 4.3 `tb_board_top_uart`（6 条全过，板级端到端）

```
[UART] cyc=4148 byte='H' (0x48) count=1
[END]  marker x10=0x600D at cyc=4391
[UART] cyc=8504 byte='i' (0x69) count=2
x5 (DRAM[0]) = cafe0000   x8 (DRAM[0x40]) = 00001234
dcache hit/miss = 0/2
```

- U1 收到 `'H'`、`'i'`，且**没有多余字节**；
- U2 `DRAM[0]` 仍是 `0xCAFE_0000` —— MMIO 写没有覆盖 DRAM；
- U3 `x8 == 0x1234` —— 普通 DRAM 读写没被 MMIO 译码误伤；
- `dcache hit/miss = 0/2` —— 两次 `lw`（`STATUS` 与 `DRAM[0]`）里，
  MMIO 那次**没有**被分配缓存行（`UNCACHE_MASK` 生效）。

程序（`sim/gen_uart_mmio_prog.py` → `sim/uart_mmio.hex`）做的事就是软件的真实用法：

```asm
lui  x1, 0x10000        # x1 = 0x1000_0000
addi x2, x0, 'H'
sw   x2, 0(x1)          # 打印 'H'
poll: lw x3, 4(x1)      # 读 STATUS
      bne x3, x0, poll  # 忙则轮询
addi x2, x0, 'i'
sw   x2, 0(x1)          # 打印 'i'
...
```

---

## 5. 回归结果

`_diag/regress.ps1`（全量，含 strict 模式）：

```
[REGRESSION] ALL PASS (27 runs)
```

★ **7 个程序的拍数一个都没变**：

| 程序 | 拍数 |
|---|---|
| `prog` | 35 |
| `prog_mul` | 42 |
| `prog_div` | 46 |
| `prog_load_lane` | 54 |
| `prog_load_use` | 77 |
| `prog_loop` | 110 |
| `prog_div_pair` | 97 |

这是"加了两个计数器但没有动任何数据通路"的直接证据。

新增/更新的回归项：

- `tb_sys +kind=zicntr`（新）
- `tb_uart_tx`（新）
- `tb_board_top_uart`（新）
- `tb_boot`（**原来只手工跑，现在进回归** —— A 的功能不能因为改 B 悄悄坏掉）

★ `Run-Vvp` 的判定正则放宽成 `\[[A-Za-z0-9_-]*SELFCHECK\] status=(\w+)`，
并显式匹配 `tb_boot` 的历史格式 `BOOT SIM: ALL PASS/FAIL`。
不放宽的话新测试台只会落到 `PASS(exit)`（vvp 正常退出就是 0），
**FAIL 也会被报成 PASS**。

---

## 6. 综合/实现结果（见第 8 节的实测数字）

要点：

- 新增 1 个板级文件 `board/uart_tx.sv` → 必须加进 `build_project_boot.tcl` 的
  `add_files` 列表（漏了会报 `unknown module type: uart_tx`）；
- 新增引脚 `uart_tx` → `A17`（J8-2 = `PL_RS232_TX`），
  并且**必须**加 `set_false_path -to [get_ports uart_tx]`：
  不加的话 timing summary 会多出 `checking no_output_delay (1)` 并标 HIGH，
  `_diag/chk_holdfix.py` 的第 6 条判据（`no_output_delay` HIGH 计数 = 0）立刻失败。
  `debug_dead` 当年就是这么补的；
- **不重建 ILA IP**：16 个探针宽度一个数字都没改。

---

## 7. 上板怎么用

### 7.1 打印一个字符

```asm
lui  x1, 0x10000       # 0x1000_0000
addi x2, x0, 'H'
sw   x2, 0(x1)         # 字符上总线（10 位 * 434 拍 ≈ 86.8us）
# 要连续打印就先轮询：
poll: lw x3, 4(x1)
      bne x3, x0, poll
```

宿主机：`_diag` 里的串口脚本用 **COM9**（板上 J8 的 CP210x）。
`COM13` 是另一个独立的 FTDI 模块，不是板子。

### 7.2 量一段代码的拍数（不用改被测代码）

1. ILA 抓包（probe6 = `debug_mcycle`）；
2. 找两个关注点的采样点（比如某条 `wb_pc` 两次出现的间隔）；
3. **probe6 的差值就是精确拍数**。

如果要在**程序自己**里量：

```asm
csrr x5, mcycle        # 或 cycle
...被测代码...
csrr x6, mcycle
sub  x7, x6, x5        # x7 = 拍数，再用 sw 打到 UART 或写进 DRAM 给 ILA 看
```

### 7.3 读停顿时长

probe5 = `debug_status`，按位读：

- bit0/bit1：前端是否被冻结、是不是访存缺失造成的；
- bit2：是不是 MDU 在跑（乘除 17 拍）；
- bit3：这次重定向是"系统指令/异常"还是"分支预测失败"（判读方向完全相反）；
- bit4：**复位后是否已经出过一次异常**（粘滞，不会漏）。

---

## 8. 实测结果（构建）

### 8.1 构建（`_diag/vivado_boot.ps1` → `v9_boot`，2026-10-18 16:36）

```
RESULT build OK
RESULT WNS = 1.300 ns     (setup)
RESULT WHS = 0.006 ns     (hold)
RESULT setup_failing_paths_exist = 0
0 Errors, 0 Critical Warnings
```

- **时序收敛**：20 ns – 1.300 ns ⇒ Fmax ≈ **53.5 MHz**（目标 50 MHz）。
  与 v12（A）的 WNS 1.039 / WHS 0.010 相比，**setup 反而好了 0.26 ns、hold 差 0.004 ns**
  —— 这是布线器的随机性（同一份源、同一组约束，工具每次结果略有不同），
  不是"加了计数器变快了"。**结论只能说到"没有变差"**。
- 路由中间报告里 `WHS = -0.389 → -0.331 → +0.005`，最终 `+0.006`：
  说明 `.200 ns` 的 hold 保护带**确实在起作用**（不补这一项，post-route 会是负的）。

### 8.2 面积（post-route）

| 资源 | 用量 | 占比（xc7z020） |
|---|---|---|
| Slice LUTs | 35 620 | 66.95 % |
| Slice Registers | 22 717 | 21.35 % |
| Block RAM Tile | 38.5 | 27.50 % |
| DSP48E1 | 4 | 1.82 % |

Zicntr 本身的代价可以按构造算：2 × 64 位计数器 = **128 个 FF**
+ `uart_tx` 约 30 个 FF + `trap_seen` 1 个。LUT 的增量在噪声里
（两个 64 位增量器各 ~33 个 CARRY4/LUT）。

### 8.3 产物

| 文件 | 大小 |
|---|---|
| `v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.bit` | 4 045 694 B |
| `v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.ltx` | 70 007 B |

★ `.ltx` 里确认了 probe5 = `debug_status`、probe6 = `debug_mcycle`
（`portIndex` 5/6，`boot_busy32`/`boot_ok32` 已不存在）——
所以 CSV 的列名会变成 `debug_status[31:0]` / `debug_mcycle[31:0]`，
`_diag/an_ila_boot.py` 已按新列名实现（并保留旧列名的回退分支）。

### 8.4 上板验证 —— **已通过**（2026-10-18 16:49）

板子接上之后按 §8.4b 的顺序跑，一次成功。证据分三段。

#### （1）串口引导 + console：程序真的"打印"出来了

```
[boot] hex = sim\uart_hello.hex
[boot] words = 15   checksum = 0xE6878231
[boot] frame = 69 bytes
[boot] sent 69 bytes x2674 on COM9 in 45.2s
RESULT program OK at 16:49:03
...
[uart] received 1480 bytes
[uart] text: HiHiHiHiHiHiHiHi... （740 组 "Hi"）
[uart] RESULT: OK
```

- **6 秒收到 1480 字节 = 740 组 `Hi`** ⇒ 每轮 **8.11 ms**。
- 仿真预演是 **8.2 ms**（`tb_board_top_uart` + `uart_hello.hex`：周期 408742 拍）。
  **误差 1%**，落在"DCache 命中率 + 复位初相"能解释的范围内。
- 这段输出证明了**两件事同时成立**：串口引导把 15 字的镜像灌进了 IROM
  （固化镜像 `prog.hex` 里根本没有 `Hi` 这个程序），以及 MMIO `sw` 能打印。

#### （2）Zicntr：`mcycle` 在真板上每拍 +1

`_diag/capture_ila.tcl`（`ILA_LTX` 指向 boot 版 ltx）抓 2048 个采样 = **41.0 µs**：

```
mcycle: 起=2635246542  止=2635248589  跨度=2047 拍
  逐拍差分：2047/2047 个差值为 1        ← 全部为 1，没有一拍漏数
```

这是"计数器真的在数拍"的硬证据 —— 仿真里只能证明它按预期建模，这里证明**硅片上**也这样。

#### （3）状态字：这段代码**一次停顿都没有**

`debug_status` 在 2048 个采样里只有**一个取值 `0x280`**：

| 位 | 信号 | 占比 |
|---|---|---|
| 7 | `IDU_ready` | 100 % |
| 9 | `boot_ok` | 100 %（引导已完成） |
| 0/1/2/3/4/5/6/8/10 | IFU_stall / dcache_hold / mdu_busy / system_redirect / trap_seen / dnpc_flag / load_use_stall / boot_busy / boot_err | **全部 0 %** |

写回事件 **1024 次 / 2048 拍**。这段窗口跑的是延时循环 `addi x20,-1 ; bne`
（每轮 2 条指令、其中只有 1 条写寄存器），所以：

> **1024 轮 × 2 条 = 2048 条指令 / 2048 拍 ⇒ IPC = 1.00，零停顿。**

这是本项目第一次有**板上**的 IPC 数字，而且和"零停顿"的状态字互相印证。

#### ★ 上板时踩到的一个坑（不报错、但结果全错）

第一次抓包忘了设 `ILA_LTX`，`capture_ila.tcl` 用了**默认的 v11 ltx**：

```
PROBE debug_icache_hit_cnt width=32      ← 名字是 v11 的
PROBE debug_icache_miss_cnt width=32
（没有 debug_status / debug_mcycle）
```

整个流程**不报任何错**，只是 CSV 的列名张冠李戴 —— probe5 明明抓的是
`debug_status`，列名却写成 `debug_icache_hit_cnt`。分析脚本照列名取值，
拿到的是"看起来正常、其实对不上信号"的数据。

已修：`capture_ila.tcl` 现在第一行就打 `RESULT ltx = <路径>`，
用错 ltx 时至少能一眼看出来。**v12 的流程必须显式设 `ILA_LTX`。**

### 8.4b 上板命令（复现用）

```powershell
# ① 先起"持续灌镜像"的后台流（引导窗口只有 5 s，必须先开流再编程/复位）
powershell -File _diag\load_uart.ps1 -Port COM9 -Hex sim\uart_hello.hex -DurationSec 45
# ② 另开窗口编程（= 复位，引导窗口打开）
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -source _diag\program_only.tcl
# ③ 读串口（程序每 ~8ms 重复打印，随时可读）
powershell -File _diag\read_uart.ps1 -Port COM9 -Seconds 6
# ④ 抓 ILA（★ 必须设 ILA_LTX，否则用错 v11 的 ltx）
$env:ILA_LTX='E:/FPGA/v9_vivado_ila/v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.ltx'
& 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -source _diag\capture_ila.tcl
python _diag\an_ila_boot.py
```


---

## 9. 明确没做的事（避免"看起来支持"）

| 项 | 状态 | 说明 |
|---|---|---|
| `time` 64 位 | **不做** | `mtime` 只有 32 位；`timeh` 读 0，不编造高位 |
| UART 接收（`uart_rx` 给 CPU 读） | **不做** | 现在的 `uart_rx` 只服务 boot loader；要加 console 输入需要再开一个 MMIO 窗口 + FIFO |
| UART 发送 FIFO | **不做** | 一个字节 87 µs，加 FIFO 不改变可观测行为；等要打整段 trace 再说 |
| `minstret` 排除陷入指令 | **不做** | 差 1/次陷入，对性能测量无影响（见 1.4） |
| ILA 探针宽度调整 | **不做** | 状态字压进已有的 32 位探针，避免重建 IP 与改分析脚本 |

---

## 10. 文件清单（v12（B）改动）

**新增**

- `board/uart_tx.sv`
- `sim/tb_uart_tx.sv`
- `sim/tb_board_top_uart.sv`
- `sim/gen_uart_mmio_prog.py` → `sim/uart_mmio.hex`
- `docs/ZICNTR_UART.md`（本文）

**修改**

- `rtl/para.sv`：10 个 Zicntr 地址 + 4 个写位（`CSRW_MCYCLE`…`CSRW_MINSTRETH`）
- `rtl/CSR.sv`：两个 64 位计数器 + `retire` 输入 + `mcycle_out`/`minstret_out`；
  顺带订正 `mtime` 注释（板上是 50 MHz → 500 kHz，不是 100 MHz → 1 MHz）
- `rtl/Reg_Stack.sv`：读多路 10 个新分支 + `retire`/`mcycle_out`/`minstret_out` 透传
- `rtl/IDU.sv`：`csr_known` 加 10 个地址、`csr_onehot` 加 bit11~14 并**映射别名**、
  `retire` 入、`mcycle_dbg` 出
- `rtl/LSU.sv`：`retire_wb = ready_next & ~lsu_freeze & valid_reg_pipe`
- `rtl/Control.sv`：`system_redirect_dbg` 观察口（纯直通）
- `rtl/myCPU.sv`：`debug_status` / `debug_mcycle` 两个新端口 + `trap_seen` 粘滞位
- `board/board_top.sv`：UART MMIO（译码 / rdata mux / **DRAM wen 门控**）+
  `uart_tx`/`debug_status`/`debug_mcycle` 端口
- `board/board_top_ila.sv`：透传 + 并进 `debug_dead`
- `project_src/board_top_gui_boot.sv`：`uart_tx` 端口、probe5/6 换内容
- `v9_board_boot.xdc`：`uart_tx` → A17 + `set_false_path -to`
- `build_project_boot.tcl`：`add_files` 加 `board/uart_tx.sv`
- `sim/gen_sys_progs.py`：`gen_zicntr()` → `sim/sys_zicntr.hex`
- `sim/tb_sys.sv`：`+kind=zicntr` 分支 + `+csrwtr` / `+cntrtr` 调试开关
- `_diag/regress.ps1`：三个新回归项 + 判定正则放宽
