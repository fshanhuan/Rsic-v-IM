# SoC 化路线图（A1 → A4 → 软件）

> 目标：把「CPU + 顶层内联译码」升级为真正的 SoC——有总线、有中断控制器、有标准定时器、有单一地址表。
> 状态图例：✅ 完成并回归 · 🚧 进行中 · ⬜ 未开始

---

## A1 总线化 ✅

| 项 | 结果 |
|---|---|
| 新增 | `rtl/soc_map.sv`（地址表单一来源）、`board/soc_bus.sv`（译码/片选/读回选/写分发） |
| 加外设的改动点 | **4 处 → 1–2 处** |
| 时序 | 未加寄存器、未加等待态，与改造前逐位相同 |
| 判据 | `sim/tb_bus.sv` **4/4**（DRAM 读写 / 代码窗口读 / 代码窗口写 / MMIO+UART） |
| 顺带修 | 读 MMIO 时 DRAM 的无意义读；写使能判断收敛到一处 |
| 文档 | [`总线化_A1.md`](总线化_A1.md) |

---

## A2 中断子系统 ✅

| 项 | 结果 |
|---|---|
| 新增 | `rtl/plic_lite.sv`：8 源、电平语义、固定优先级、claim 清位 |
| CSR | `meip = ext_irq`（原 `assign meip = 1'b0`） |
| 寄存器 | `0x1000_0020` IRQPEND / `0x24` IRQEN / `0x28` IRQID / `0x2C` IRQSW |
| 顺带修 | `mmio_idx` 3 位 → **4 位**（修掉 `0x20` 与 `0x00` 别名、magic `0xF0` 撞 LED） |
| 判据 | `sim/tb_irq.sv` **3/3**，`mcause = 0x8000_000B`（machine external interrupt） |
| 文档 | [`中断_A2.md`](中断_A2.md) |

---

## 全量回归

```
[REGRESSION] ALL PASS (33 runs)
```
含 `tb_monitor`（串口 shell 全链路，此前因缺工具链长期 SKIP）。
工具链已装在 `~/rv32/sysroot`（Ubuntu `gcc-riscv64-unknown-elf 13.2.0`，`apt-get download` + `dpkg-deb -x`，免 sudo）。

---

## A3 CLINT（标准定时器）✅

### 现状问题

`mtime/mtimecmp` 是**非标准 CSR**（`0x7C0/0x7C1`，见 `rtl/CSR.sv:9`），
而 RISC-V 标准把它们放在**内存映射的 CLINT**（machine timer）。

### 设计

1. **新增 `rtl/clint.sv`**：32 位 `mtime` 计数器（分频与 `MTIME_DIV_DEFAULT` 一致，500 kHz）、
   `mtimecmp` 寄存器、`timer_irq = (mtime >= mtimecmp)`（电平）。
2. **单一计数源**：把 CSR 里的计数器**删掉**，改为：
   - CSR 新增输入 `mtime_in` / `mtimecmp_in`，输出 `mtime_we` / `mtime_wdata` / `mtimecmp_we` / `mtimecmp_wdata`；
   - `mtime_out = mtime_in`、`mtimecmp_out = mtimecmp_in`、`mtip = (mtime_in >= mtimecmp_in)`；
   - 端口穿透链：`myCPU → IDU → Reg_Stack → CSR`（与 A2 的 `ext_irq` 同一条路）。
3. **MMIO**：`0x1000_0030` mtime / `0x34` mtime 高 32 位（恒 0）/ `0x38` mtimecmp / `0x3C` mtimecmp 高 32 位（写忽略）。
4. **中断源 2**：`plic_src[SOC_IRQ_TIMER] = timer_irq`。

### 判据

- `tb_sys` 的 zicsr 用例仍全过（CSR 0x7C0/0x7C1 读写语义不变）；
- 新增 `sim/tb_clint.sv`：写 `mtimecmp = mtime + N` → 等 MTI → 陷入计数正确；同时读 MMIO `0x30` 与 `csrr mtime` **必须相等**（证明只有一个计数源）。

---

## A4 地址表单一来源 ✅

> **已完成**：`tools/gen_soc_map.py` 从 `rtl/soc_map.sv` 生成 `sw/soc_map.h` 与 `docs/地址表.md`；
> `--check` 已接入 `_diag/regress.ps1`（用例名 `soc_map`）；`sw/monitor.c` 用 `_Static_assert`
> 做**编译期**比对（手写常量漂了就编译不过）。

生成器做的事：

1. 由它**生成 C 头文件** `sw/soc_map.h`（脚本 `tools/gen_soc_h.py`），`sw/monitor.c` 不再手写 `0x1000_0000` 等常量；
2. 由它**生成文档表格**（`docs/` 里的地址表）；
3. 一致性检查脚本：`soc_map.sv` / `soc_map.h` / 文档三者比对，不一致就报错。

---

## 软件（最后一段）⬜

### S3 完成（ramdisk 文件系统）✅ 2026-11-09

```
[REGRESSION] ALL PASS (36 runs)   ← 新增 tb_prog / fstest
[PROG] PASS  (led=0x2a, cycles=126404)
```

判据：建 1 B / 300 B / 3000 B 三个文件 → 逐字节读回一致 → 删除后读不到 →
重名被拒 → 空闲块数确实减少。

**根因记录（以后一定会再遇到）**：`.rodata` 的字符串在仿真里是 **X** ——
`tb_prog` 原来只载 IROM，不载 DRAM 镜像，`name_copy()` 拷到 X 就永不终止，
表现为"卡在 fs_create 里"。修法：`tb_prog` 加 `+dram=`（`$readmemh(..., mem_ram, 32'h4000)`），
`.data` 里的初值改成 `.bss` + 运行时赋值。

---

### P0 / P1 完成（CoreMark 复测、`run <file>`、FS 回收、增量重绘）✅ 2026-11-10

详见 **`docs/P0P1_完成报告.md`**（含全部原始串口回显与复现命令）。要点：

| 项 | 结果 |
|---|---|
| P0 CoreMark @ v18 | `Total ticks 543407157` / `10.868143 s` / **128.816853 iter/s**，CRCs `e714/1fd7/8e3a`，validated —— **与 v15 逐周期相同**，A1–A3 零性能损失 |
| P1-1 `run <file>` | 容器（32 B 头 + 代码 + 数据 + 校验和）+ `sw/app/start.S` 入口桩（换 gp/sp、清 bss、返回时还原 shell 上下文）；板上 `HELLO-APP` / `acc=15` / `returned to shell` |
| P1-2 FS 回收 | 位图 + 连续分配，160 块 × 256 B；`rm` 后 `df` 152→155，8000 B 文件占 32 块后 120，删掉回 152 |
| P1-3 增量重绘 | 只发改动格子：**2 523 B/帧 → ≈30 B/步**（84×），9 s 窗口 60 553 B → 3 115 B |
| 回归 | `_diag/regress.ps1` 完整模式 **51 runs 全 PASS**（含 tb_runapp / tb_axil / tb_axil_dram / tb_dram_shared / lint）；`tb_monitor` 6 → **9 项检查** |
| RTL | P0/P1 只改了 4 处声明顺序（lint 修复）；#6 新增 AXI 桥与共享端口 DRAM，`AXIL_EN` 默认 0 → 默认路径不变。2026-11-11 用当前源码**重建 v18**：`build OK`、**WNS +0.646 ns**、DRC 0 error |

DRAM 三段划分（128 KB 全用上）：`0x0_0000–0x0_9FFF` 文件系统 40 KB /
`0x0_A000–0x0_FFFF` 应用数据 20 KB + 应用栈 4 KB / `0x1_0000–0x1_FFFF` shell 自己。
应用代码区 `0x6000–0xFFFF`（40 KB）；shell `_etext = 0x4CF4`，余量 780 B ——
一旦 `IROM_APP_MIN` 涨到 `0x6000`，`run`/`L` 会**拒绝**而不是静默踩坏 shell。

---

### S5 完成（贪吃蛇：逻辑 + 渲染 + 操作）✅ 2026-11-09/10

| 文件 | 内容 |
|---|---|
| `sw/snake.c` | 逻辑内核 + 脱屏自测（进回归） |
| `sw/snake_play.c` | **可玩版**：ANSI **增量**重绘（20×12，P1-3）、方向键、`mtime` 节拍（每步 120 ms）、`r` 重开 / `q` 退出、LED 显示分数 |

**真片实测**（v18 比特流）：

```
+--------------------+      ← 棋盘
|        o *         |      ← 竖直的蛇（发 ESC[B 后）
|        o           |
|        O           |
+--------------------+
```

上板修掉的两个**程序 bug**（不是 RTL 问题）：

1. **死了就不重绘**：原来 `render()` 在 `if (alive)` 里面，撞墙后屏幕停住，看起来像"程序不刷了"，排查时被误导过一次。改成每步都重绘。
2. **方向键收不到**：`read_dir()` 收到 `ESC` 后立刻 `getc_nb()` 取后两个字节，而 115200 下下个字节要 87 µs 才到 → 永远拼不出 `ESC [ A`。改成带 5 ms 超时的 `getc_to()`。**真实终端三个字节是连发的**，所以这个超时只要覆盖一个字节时间就够。

---

### S5 过程记录（贪吃蛇，2026-11-09）

`sw/snake.c` 实现**游戏逻辑内核**并做了脱屏自测：

- 网格 20×12，`body[0]` 是头、逐格后移（O(len) 拷贝，len ≤ 64，不值得优化）；
- 规则：撞墙 / 撞自己（尾巴那格除外）→ 死；吃食 → `score+1`、`len+1`；

判据（写 DRAM `0x2000`，LED=0x2A）：

```
[PROG] PASS  (led=0x2a, cycles=2443)
[REGRESSION] ALL PASS (38 runs)   ← tb_prog/snake 已进回归
```

覆盖：直走吃食长身 → 连走三步到位 → 转向 → 转向后不误判自撞 → 一直走到撞墙死亡
（`score=1 / len=4 / alive=0`）。

**还没做的**：ANSI 渲染（增量重绘 + 帧预算）与键盘输入。这两块不改变逻辑内核，
是套在上面的显示/输入层；真机上再加。

---

### S4 完成（从文件系统加载并执行）✅ 2026-11-09

`sw/runtest.c`：在 ramdisk 里建一个 16 B 的 "payload"（4 条 RISC-V 指令）→ `fs_read` 读回
→ 写入 IROM 窗口 `0x2_4000` → `fence.i` → 跳到 `0x4000` 执行 → payload 把
`DRAM[0x2000]` 写成 `0x5A` 后 `jalr` 返回 → 主程序校验。

```
[PROG] PASS  (led=0x2a, cycles=2296)
[REGRESSION] ALL PASS (37 runs)      ← tb_prog/fstest 与 tb_prog/runtest 都进了回归
```

**这是"换程序不用重新综合"的最终形态**：程序不再内嵌在镜像里，而是从文件系统取出来跑。

两个坑（都已记录）：

1. **LED 是只写寄存器**：`board_top` 的 MMIO 读 mux 对 LED 恒返回 0，所以"让 payload
   写 LED 再读回来校验"永远失败。改用 **DRAM `0x2000`** 当判据（可读可写）。
2. **非对齐缓冲区**：把 `uint8_t buf[64]` 强转成 `const uint32_t *` 去读属于**非对齐 load**，
   本核会报异常并复位重启（现象是"还没跳过去就先挂了"，第二遍还因重名失败）。
   改成 `uint32_t buf32[16]` + 字节视图别名。

---

### S3 过程记录（ramdisk 文件系统，2026-11-09）

已写：

| 文件 | 内容 |
|---|---|
| `sw/fstest.c` | ramdisk FS 最小实现 + 自测：块 256 B × 256，超级块（magic/nfiles/next_free）+ 32 项目录 + bump 分配；API `fs_init/fs_create/fs_read/fs_delete/fs_free_blocks` |
| `sim/tb_prog.sv` | **通用软件 TB**：`+prog=<hex>` 载入 IROM，看 `led`（默认 0x2A = PASS、0x7F = FAIL）判据，超时兜底。以后所有软件测试共用它 |

踩到两个坑（都已处理/记录）：

1. **零地址常量指针被优化掉**：`static uint8_t *const disk = (uint8_t *)0;` 在 C 里就是
   NULL，gcc 判定"解引用空指针是 UB"，把**全部访存优化掉了**（编译出来只有 21 个字）。
   改用 `static volatile uint32_t disk_base` + 宏。
2. **`.data` 初值在仿真里是 X**：板级/`tb_prog` 都不预装 DRAM 镜像，`.data` 段没人初始化。
   `static uint8_t pattern[8] = {…}` 因此读到 X，一路污染到判据。改成 `.bss`（crt0 清零）
   再在运行时填值。

**当前状态**：程序跑到 `fs_init()` 之后、`fs_create("tiny")` 内部就停住（进度标记打出 `12`，
然后 2 M 拍超时，`led=0`）。下一轮第一件事：在 `fs_create` 内部加更细的标记（找空目录项 /
算 start / 写数据 / name_copy 各打一个），定位到底卡在哪一句。

> 注：`tb_prog` 只载 IROM，**不载 DRAM 镜像**。凡是依赖 `.data` 初值的程序要么改成
> 运行时赋值，要么给 `tb_prog` 加 `+dram=` 支持。


### S2 完成（软件断点）✅ 2026-11-10

硬件没有单步/暂停位，但**软件断点不需要改 RTL**：把目标指令换成 `ebreak`
（`0x00100073`），陷入后打印现场、还原指令、`mepc += 4` 跳过它。

| 命令 | 作用 |
|---|---|
| `bk <irom_addr>` | 在代码区（`>= IROM_APP_MIN`）打一个断点；先撤旧断点 |
| `bl` | 列出当前断点与原始指令 |
| `bd` | 撤销并还原原始指令 |

**真片实测**：

```
bk 4000        →  breakpoint @0x00004000  (was 0x00000000)
d 24000 1      →   00024000: 00100073          ← ebreak 已写入
bl             →   0x00004000  orig=0x00000000
bd             →   cleared 0x00004000
d 24000 1      →   00024000: 00000000          ← 原指令已还原
```

**局限（写清楚）**：只支持一个断点；命中后会自动还原（要重复命中需重新 `bk`）；
打在 shell 自己的代码上会导致立即命中。

回归：**ALL PASS (38 runs)**。

---

### S1 已修复（2026-11-10）：**根因是同一个 FIFO 有两个消费者**

真片症状：开中断后字节**重复**（`i` → `i0`）、**丢失**（`l 3f` 里 `l` 没了）、
**串入杂字符**（`k 20?000`）。

根因：`getc_nb()` 里那条"环空就退回轮询 FIFO"的**回退路径**，与 ISR 同时在
peek+pop 同一个 RX FIFO —— 两个消费者互相抢字节。

修法（三处，都在 `sw/monitor.c`）：

| 改动 | 作用 |
|---|---|
| `static volatile int rx_irq_on;` | 中断模式标志 |
| `getc_nb()`：`if (rx_irq_on) return -1;` | **开了中断就绝不再碰 FIFO**，只吃环形缓冲 |
| `rx_flush()` + 开机后调用一次 | 丢掉引导期/横幅期间涌进来的残留字节（否则第一条命令被污染） |

修复后真片实测（v18 比特流）：

```
i                → 完整硬件信息
p 10000030       → [10000030] = 0x01a8038c
k 20000          → cksum 0x54113259   （主机侧 djb2 也算出 0x54113259，逐位一致）
d 20000 4        → 00011197 3a418193 00020117 ff810113
```

多参数命令、含空格的命令都正确，说明字节流完整、顺序正确。

> 备注（**P0-1 已把这里彻底查清，原文保留**）：模拟器里那条"开 MIE 后只读 7 个字节
> 就停 / `debug_status` 低两位变 X"的现象，根因不在 RTL，而在两处：
> ① 陷入处理对**中断**也执行了 `mepc += 4` —— 每次接收中断都跳过一条被打断的指令；
> ② `tb_monitor` 只清了 DRAM 低 16 K 字，而栈顶在字 32768 向下长 —— ①跳过的若是
>    `sw`，之后 `lw` 就读到仿真里**未初始化的 X**，X 顺着寄存器流进地址/控制，
>    于是"停顿网络出现 X"。
> 两处都修了（`trap_entry` 中断分支不动 mepc；TB 整块清零 + M9 无 X 检查），
> 现在**中断是默认路径**：`tb_monitor` 9/9、真片 `rx irq ON / exc n=0`。
> 详细证据见 `docs/P0_完成报告.md`。



两次尝试都没通过 `tb_monitor`，证据如下，**别重复踩**：

| 尝试 | 结果 | 判读 |
|---|---|---|
| ① 开 PLIC 源 0 + `mie.MEIE` + `mstatus.MIE`，ISR 抽干 FIFO 进 64B 环 | `M2/M3/M5/M6 FAIL`，`M1` 横幅与 `M4` code-win 仍 PASS | 只要 **MIE=1**，命令解析就坏；输出通路正常 |
| ② 空 ISR + MIE=1 | **全部 FAIL**（连 M1 都挂） | 空 ISR 不 claim → 电平源形成**中断风暴**，主循环饿死。这个实验不可判读，别用 |
| ③ 不开中断，改为在 `putc_` 的 TX 等待空转里轮询预取到环 | `M2 FAIL`（其余 5 项 PASS） | 预取把**第一条命令**（横幅期间塞进 FIFO 的那批）吃掉了，解析路径没变 |
| ④ 开着 MIE + 给 `intr_safe` 加 `& ~EXU_mem_ren & ~MEM_mem_ren`（"不许插在数据访问在途时"） | `M2/M3/M5/M6 FAIL`，**关键计数：TB 发了 119 字节，shell 只 `RXDATA reads=7` / `rx_pop=6`** | 假设**不成立**。不是"解析错了"，而是**第一个中断之后 CPU 就不再发读请求**了（挂死或跑飞） |

④ 的计数是最有价值的证据：对比基线（不开中断）是 **reads=73 / pops=73 / 371 字节**，
一开中断就掉到 **7 / 6**。所以问题不是"丢字节"，是**中断之后主循环停了**。

### ★ 第 5 次实验：找到 X 的签名（2026-11-09）

在 `tb_monitor` 末尾加了 `debug_status` 打印（低 8 位含义见 `rtl/myCPU.sv` 的
`assign debug_status = {…, IDU_ready(7), load_use_stall(6), dnpc_flag(5), trap_seen(4),
system_redirect(3), EXU_mdu_busy(2), dcache_hold(1), IFU_stall(0)}`）。

| 配置 | `debug_status` | 判读 |
|---|---|---|
| 纯轮询（基线，6/6 PASS） | **`00000080`** | bit7=IDU_ready=1，bit0..6 全 0，干净 |
| 开 MIE（4 项 FAIL） | **`000000XX`** | **bit0 `IFU_stall` 与 bit1 `dcache_hold` 是 X** |

结论：**一开中断，"停顿网络"里就出现未定义值**，CPU 从此不再发 MMIO 读请求。
`dcache_hold` 在模块级（`DCache_inst.hold`）读到的是 0，所以 X 不是 DCache 自己产生的，
而是**从别处传进 `IFU_stall` 的**。

**首要怀疑：组合环。** `intr_safe` 依赖 `IDU_valid/IDU_ready`，而 `intr_take` 又驱动
`EXU_inst_clear/dnpc_flag`，进而影响 `IDU_ready`/`IFU_stall_ctrl` —— 若存在
`IDU_ready → intr_safe → intr_take → IFU_stall_ctrl → IDU_ready` 这条环，仿真里就是 X
（综合可能"恰好"选一个解，这也解释了为什么 `irqtest` 那种小程序没暴露）。
**下一步**：用 Vivado 的 `report_design_analysis -check_combinational_loops`（或
`check_design`）直接查环，比继续猜快得多。

### 第 6 次核查：排除了"经 IFU_stall 的环"，但发现一个矛盾（2026-11-09）

代码核查结果（`rtl/Control.sv`）：

- `IFU_stall_ctrl`（Control 输出，`:486`）= `load_use_stall | mdu_busy` —— **不含 `intr_take`**，
  所以"`IDU_ready → intr_safe → intr_take → IFU_stall_ctrl → IDU_ready`"这条环**不成立**；
- 但 `intr_safe`（`:349`）用了 Control 的**输入** `IFU_stall`，而 myCPU 里
  `IFU_stall = IFU_stall_ctrl | dcache_hold`（`rtl/myCPU.sv:235`）—— 也就是说
  `intr_safe` 依赖 `dcache_hold`，而 `dcache_hold` 又是 DCache 的 `mem_hold` 输出
  （`myCPU.sv:867` 的 `.mem_hold(dcache_hold)`）。

**矛盾点（下一步必须解释）**：`tb_monitor` 里层次化打印 `DCache_inst.hold` 得到 **0**，
而 `debug_status` 的 bit1（= `dcache_hold`，`myCPU.sv:379`）却是 **X**。
两者若真是同一根线，不可能一个 0 一个 X ⇒ **层次化路径 `DCache_inst.hold` 很可能不是
myCPU 用的那根 `dcache_hold`**（端口名/作用域对不上，iverilog 不报错）。

**下一步（很具体）**：在 `tb_monitor` 里直接打 `u_board.u_cpu.dcache_hold`、
`u_board.u_cpu.IFU_stall_ctrl`、`u_board.u_cpu.IFU_stall` 三根线（而不是 DCache 内部），
确认 X 的**源头**在哪一级；再顺着它的驱动往回找。这一步不需要改 RTL。

### 第 7 次实验：X 不在那三根线上，但拿到了"跑飞在哪"（2026-11-09）

探针结果（开 MIE 的那次运行）：

```
[COUNT] RXDATA reads=7  rx_pop pulses=6  (bytes received=119)
[DBG] dcache_hold=0  IFU_stall_ctrl=0  IFU_stall=0  DCache.hold=0
[DBG] debug_status=000000XX  wb_pc=00002cb0  mcause=8000000b  mepc=00000194
```

三条结论：

1. **收尾时刻四根停顿线全是 0**，`debug_status` 却仍是 `000000XX` ⇒ X **不是**这几根线
   直接贡献的（或者该时刻已恢复）。上一轮"X 来自停顿网络"的结论**要撤回**。
2. `wb_pc = 0x2cb0` 落在 **main 的 ESC/命令字节解析**里（反汇编：`bltz a0` / 与 10、27
   比较 / `jr a5` 跳表，`main` 从 `0x2ac8` 开始）。**不在 `trap_entry`**（它在 `0x7c`，
   抽 FIFO 的循环在 `0xdc–0x114`）。⇒ CPU 没卡在 ISR 里，而是**死在主循环的解析分支**。
3. **`mepc = 0x194` 与 `wb_pc = 0x2cb0` 不匹配**：一次 0x2cb0 附近的中断，`mepc` 却记了
   `0x194`（那不在 `main` 的地址范围内，`main` 起点是 `0x2ac8`）。这是目前最像"真 bug"
   的一条：**中断登记 mepc 的那一拍，ID 级拿到的 PC 可能不是它自己的**。

**下一步（换打法，别再猜）**：给 `tb_irq` 加一个最小复现——循环 `lw` 一个 MMIO 地址
（比如 TXSTAT）+ 累加，同时用软件源打断它，把每次中断的 `mepc` 和当时的 `wb_pc` 打出来。
只要能看到"mepc ≠ 被中断指令的 PC"，就能直接定位到 `Control`/`CSR` 的那一拍。

### 决定（2026-11-09，暂定）

S1 的"中断驱动输入"**降级为已知缺陷**，不再阻塞主线：

- 现状（纯轮询）已经满足可用性：`tb_monitor` **6/6**、`reads=73/pops=73`、`debug_status=00000080`；
- S1 剩下的理论收益只有"长输出打印期间不丢键"，实际负载下影响很小；
- 全量回归在改动后仍是 **ALL PASS (35 runs)**；
- **下一步转 S3（ramdisk 文件系统）**——不依赖中断。S1 的复现材料（8 次实验）保留在本节，
  以后要啃随时可以接着来。

### 第 8 次实验：最小复现**没复现**（2026-11-09）

把 `sw/irqtest.c` 的空转循环改成"反复读 MMIO"（`(void)TXSTAT`），让中断必然落在
一次 MMIO load 在途的时刻：

```
[IRQ-TEST] led=3 nrecv=2 pc=0000020c mcause=8000000b mstatus=00000080
[IRQ-TEST] PASS  (3/3)
```

⇒ **"中断打断 MMIO load" 不是原因**（这个改动保留在 `irqtest.c` 里，因为它是一条
更强的覆盖：MEI 在 MMIO 密集循环里也必须工作）。

那么 shell 与 irqtest 的**真正差别**收敛到三条：

| 差别 | irqtest | shell |
|---|---|---|
| 中断源类型 | **脉冲**（软件源 3） | **电平**（RX FIFO 非空，源 0） |
| ISR 里做什么 | 只写 IRQPEND | 读 RXSTAT、读 RXDATA、写 RXPOP、写 IRQPEND |
| 代码/栈规模 | ~0.6 KB，无递归 | ~15 KB，含 64 B 环 + 历史/行缓冲 |

**下一步优先查"电平源 + ISR 里读-改-写 MMIO"**：给 `irqtest` 再加一步——把中断源换成
电平源（先往 RX FIFO 灌一个字节，或在 PLIC 里加一个电平测试源），ISR 里做
"读状态 → 读数据 → 写弹出 → 写 claim" 这一整套。若这样也能过，再往 shell 的规模/时序上找。

现状：`monitor.c` 已回退到**纯轮询**（`rx_irq_init()` 注释掉、`putc_` 恢复原样），
`tb_monitor` 回到 **6/6 PASS**。环缓冲/ISR 的骨架留在文件里（未启用），便于下一轮继续。

**下一步要查的**：陷入发生在一次 **MMIO 访问在途**时会发生什么（DCache 的 uncached
通路上有 `req_seq` / `unc_busy` 之类的在途状态）。怀疑点：中断在 `perip_*` 请求发出、
`perip_rdata` 尚未被采样之间被接受，`mret` 回来后那次访问的返回值/时序被破坏。
查法建议：在 `tb_irq` 里加一个"load 一个 MMIO 地址的同时注入中断"的定向用例，
先复现再定位。

**根因假设（有代码依据，待验证）**：中断被接受时，`EXU_inst_clear` 也同时置位，
而此刻 **EX 级那条指令是"比被中断指令更老"的指令**，它必须完成（否则架构状态被吞）：

```verilog
// rtl/Control.sv:346-351
assign intr_safe = IDU_valid
                 & ~(branch_flag | jump_flag | fence_i_flag)
                 & ~mret_flag & ~ecall_flag & ~IFU_stall & ~mdu_busy
                 ...
assign intr_take = intr_pending & intr_safe;

// rtl/Control.sv:371
assign EXU_inst_clear = intr_take | bp_mispredict | trap_redirect | ...
```

`intr_safe` 里**没有**任何"数据访问在途"的条件（没有 `~EXU_mem_ren` / `~dcache_hold`），
于是中断可以插在一个 load 的中间；而 `mepc` 记的是 **ID 级**那条指令，`mret` 回来后
只会从 mepc 重新执行 —— 更老的 EX 级 load 若被清掉，它的写回就永久丢失。
这与现象吻合：**输出（TXSTAT 轮询）正常，输入解析（RXDATA 读取）坏掉**。

验证方法：给 `intr_safe` 加一项 `& ~EXU_mem_ren`（必要时再加 store 的对应项），
然后重跑 `tb_monitor` + `irqtest` + `clinttest`。若 shell 的中断输入恢复正常，
假设成立；代价是中断可能被数据访问推迟几拍（对电平源无害）。
**改之前**先确认 `EXU_inst_clr` 在 EXU 里到底是"作废提交"还是"只掐副作用"——
这决定了是修 `intr_safe`（把中途打断挡掉）还是修 `EXU_inst_clear`（别把更老的指令清掉）。


| 步 | 内容 | 判据 |
|---|---|---|
| S1 | shell 输入：等上面那个问题查清后再上中断；短期可用"每轮主循环 drain"折中 | 连着灌 100 字节不丢，且 `tb_monitor` 6/6 |
| S2 | 串口调试服务：`s`（单步）/ `b`（断点表）/ `t`（trace dump） | 断点命中率 100% |
| S3 | ramdisk 文件系统（DRAM `0x0_0000–0x0_FFFF` 64 KB） | 存 3 KB 文件、复位后读回一致 |
| S4 | `run <file>`：文件系统 → `0x4000` → `fence.i` → 跳转 | 加载运行 hello_app 并返回 shell |
| S5 | 贪吃蛇（20×12） | 帧率实测 ≥ 15 fps，按键不丢 |

---

## Vivado 综合 ✅（实测，2026-11-09）

| 资源 | v17 基线 | **v18（A1+A2+A3）** | 变化 |
|---|---|---|---|
| WNS | +0.048 ns | **+0.250 ns** | **+0.202 ns** |
| WHS | +0.015 ns | +0.005 ns | 仍为正 |
| TNS | — | 0.000 | 无违例 |
| Slice LUTs | 36 150（67.95%） | **35 904（67.49%）** | **−246** |
| Slice Registers | 34 058（32.01%） | **33 762（31.73%）** | **−296** |
| Block RAM Tile | 66.5（47.5%） | **66.5（47.50%）** | **0** |
| DSPs | 4 | **4** | 0 |

结论：**总线化没有把这条只剩 48 ps 的路径压垮**，LUT/FF 反而因为去掉了散落的重复译码而减少。
报告：`reports/util_v18.rpt`、`reports/timing_v18.rpt`；比特流 `board_top_gui_boot.bit`。

> 过程记录：先用 `build_project_boot.tcl` 跑通（`RESULT WNS = 0.250 ns / build OK`）；
> 为拿报告又写了 `_diag/build_v18_quick.tcl`（打开现有工程 → 补 3 个新文件 → 跑 run → 出报告），
> 因为原建工程脚本在 A1–A3 之后曾报 `Could not open 'C'`（后续查明是日志里的无关行，非真实失败）。

## 双核协同三步 ✅（2026-11-11 晚）

> 把 PS 与 RISC-V 从"**能互相读写内存**"推进到"**能分工**"。三步都有仿真证据 + 板上实测。

| 步 | 交付 | 证据 |
|---|---|---|
| **1 PS 当宿主** | `board/ps_ctrl.sv`（AXI 控制平面 `0x2_0000`：HOLD/PS_IRQ/ALIVE/CLR_IRQ_PS）、`sw/ps/stub.S`（20 条指令的 stage-0 搬运器）、`tools/bin2iromhex.py`、`tools/gen_ps_image.py`、`sw/ps/riscv_loader.c`、`IROM_BOOT=2` | `tb_ps_ctrl` **14/14**；板上 `RESULT: PASS` + COM9 上 shell 横幅**完整可读**（`code-win OK w0=00012197`） |
| **2 一致性** | `rtl/DCache.sv` 的 `inval`（四个命中判定都加 `~inval`）+ MMIO `0x1000_001C` bit0 | `tb_dcache_stale` **4/4**：先复现陈旧读（x6=0x1111 而 DRAM=0x2222），再证明修复（x7=0x2222） |
| **3 双向中断** | `irq_ps` 输出 + PLIC 源 4 + BD 接 `IRQ_F2P` + `sw/ps/ps_irq_test.c`（GIC SPI 61..68）+ `sw/pstest.c` | 板上 `SCRATCH=0x600D0001`、`SH_MSG=0xDEADBEEF`、`SH_ACK=0x0000ACED`、`SH_NIRQ=2950`、COM9 `PS-OK` |

回归 **53 runs 全 PASS**（含两个新 TB），lint 38 文件 0 error/0 warning，SVA 0 违约；
PS 设计重建后 **WNS +0.808 ns**。细节与四个上板 bug 见
[`AXI_总线化_6_7.md`](AXI_总线化_6_7.md) 末章"双核协同三步"。

## 旧待办（已解决，保留原文）


A1/A2 改动了顶层与 CSR 端口，**必须重新综合一次**确认：

- 目标：WNS **≥ 0.048 ns**（v17 基线），BRAM 仍 66.5；
- 命令：`vivado -mode batch -source build_project_boot.tcl`（`DO_IMPL=1`）；
- 若 WNS 退化，优先看 `perip_wen` / `bus_we_*` 的扇出（它们现在多驱动一个 PLIC 和 MMIO 译码）。
