# C 工具链 / CoreMark / FreeRTOS（v13）

> 一句话：**rv32 工具链在这台机器上跑通了**（无需 sudo、无需 newlib），
> `hello` / `memtest` 能编能跑；CoreMark 与 FreeRTOS 也已经能编、能跑起来，
> 但在把两者跑到"完整通过"的过程中，**挖出了一个真实的 CPU 缺陷并已修复**
> （store→load 同地址读旧值），另有一处**尚未根因**的乱码现象（见 §6）。
> 本文只写"怎么用 / 验证到哪一步 / 哪些不能改回去"。

---

## 1. 工具链：不装系统、不要 sudo

宿主 Windows 上没有 RISC-V GCC；WSL（Ubuntu 24.04）的 apt 里有
`gcc-riscv64-unknown-elf 13.2.0`，但 `sudo` 要密码。做法是**只下载 deb 再解包**：

```bash
# 一次性（WSL 内）
mkdir -p ~/rv32/dl && cd ~/rv32/dl
apt-get download gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf
mkdir -p ~/rv32/sysroot
dpkg -x gcc-riscv64-unknown-elf_*.deb      ~/rv32/sysroot
dpkg -x binutils-riscv64-unknown-elf_*.deb ~/rv32/sysroot
```

`sw/env.sh` 负责把 `~/rv32/sysroot/usr/bin` 加进 PATH，并定义：

```bash
export ARCH="-march=rv32im_zicsr -mabi=ilp32"
```

★ **`zicsr` 必须显式写**。gcc 13 起 `csrr/csrw` 不再隐含在 `rv32i` 里，
漏了会报 `unrecognized opcode 'csrr a0,mcycle', extension 'zicsr' required`。
libgcc 仍然落在 `rv32im/ilp32` 那一份 multilib 上。

★ **没有 newlib**：C 头文件只有 gcc 自带的那几个。所以：

| 缺什么 | 我们怎么补 |
|---|---|
| `stdlib.h` / `string.h` / `stdio.h` | `sw/freertos_port/` 下的空壳头（只有声明） |
| `memcpy/memset/memcmp/strlen` | `sw/coremark_port/libc_mini.c`（单字节循环实现） |
| `math.h` 的 `modf`（ee_printf 打 `%f` 用） | `sw/coremark_port/math.h` + `libc_mini.c` 里的软浮点实现 |

---

## 2. 内存布局：哈尔佛教的硬约束

本核取指走 IROM、load/store 只走 DRAM（两套独立地址空间），所以：

- `.text` → **IROM**（v13 起 64 KB）
- `.rodata` / `.data` / `.bss` / 栈 → **DRAM 的 0x1_0000 以上**（v13 起 DRAM 128 KB）
- ★ `.rodata` 也必须放 DRAM：`lw/lb` 读不到 IROM，C 的字符串常量不放在数据口就没法读。

`sw/coremark_port/link.ld` 就是这份布局；`sw/elf2hex.py` 把 `objcopy -O binary`
出来的平坦镜像在 `0x10000` 处**切两半**，分别喂 IROM 和 DRAM。

★ 没有"把 .data 从 LMA 拷到 VMA"那段（普通哈佛平台都靠它）：做不到，`lw` 读不到
IROM。初始值靠**引导时把数据镜像单独写进 DRAM**（见 §3）。

---

## 3. 引导协议 v13：IROM 帧 + DRAM 帧 + GO

`board/boot_loader.sv` 从"只能灌 IROM"扩成三种命令（8N1 / 115200 / 全大端）：

| magic | 含义 | 负载 |
|---|---|---|
| `0x42` `'B'` | IROM 帧 | `len(4B) + len×4B + cks(4B)` |
| `0x43` `'C'` | DRAM 帧 | 同上 |
| `0x47` `'G'` | GO | 无 —— 收到才释放 CPU |

一次会话：`'B'` → （可选 `'C'`）→ `'G'`。

- 收完一帧后 loader **留在引导态**等下一个 magic（多镜像要分几帧发）。
- 收过帧后 IDLE 超时（5 s）也会自动释放，ok=1（宿主忘了发 `'G'` 不会把板子冻住）。
- 一帧都没收到就超时 → 释放，err=1，CPU 跑 IROM 里原有程序（脱机启动不退化）。

宿主脚本：`_diag/load_uart.ps1 -Hex <irom.hex> -DramHex <dram.hex> [-DryRun]`。

★ 不变量（改动前必读）：
1. 校验和是**按字累加**、大端；`load_uart.ps1` 与 RTL 必须逐字一致。
2. loader 的 `mem_sel` 必须把写分流到 IROM 或 DRAM；IROM 的 `wen` 要
   `& ~mem_sel`，DRAM 的 `wen`（引导期）要 `& mem_sel`。
3. `sync_mem` 的 `reset` 只能接 `cpu_rst`，**不能**接 `cpu_rst_eff`
   （写逻辑在 `else` 分支里，复位期间写会被吞掉）。

---

## 4. 怎么用

```bash
# 工具链 + 三个演示程序
python3 sw/make_port.py                 # 从 vendor 的 ee_printf.c 生成端口文件
bash sw/build_hello.sh                  # → sw/build/hello_{irom,dram}.hex
bash sw/build_coremark.sh               # → sw/build/cm_{irom,dram}.hex（ITER=40 可调）
bash sw/vendor_freertos.sh              # 一次性：把内核 vendor 进 sw/freertos
python3 sw/make_rtos_port.py            # 生成 CSR 定时器版端口
bash sw/build_rtos.sh                   # → sw/build/rtos_{irom,dram}.hex

# 仿真（Verilator，几千万拍/分钟级）
bash sw/run_coremark.sh +irom=sw/build/hello_irom.hex +dram=sw/build/hello_dram.hex
bash sw/run_coremark.sh +irom=sw/build/rtos_irom.hex  +dram=sw/build/rtos_dram.hex +max=30000000

# 上板
_diag\load_uart.ps1 -Port COM9 -Hex sw\build\hello_irom.hex `
                    -DramHex sw\build\hello_dram.hex -DurationSec 45
```

`sim/tb_cm.sv` 是这条链的仿真台：64 KB IROM + 128 KB DRAM（**与 board_top 默认值逐字一致**）、
串口写直接 snoop 成字符、`+hexout` 打成十六进制、`+trace` 打前 64 次写回、
每 50 万拍报一次 PC（卡死时用它定位）。它不实例化 `uart_tx`（115200 下一个字节
4340 拍，纯浪费），**CPU 侧软件不用改**。

---

## 5. ★ v13-BUG-1：store→load 同地址读到旧值（已修）

**症状（三条独立线索）**

1. 独立内存测试 `sw/memtest.c` 的 T4（"写一个地址、立刻读回"重复 4000 次）：
   **错 3999 次**。
2. FreeRTOS 起来后第一个 `vTaskDelay` 就挂 `configASSERT( uxSchedulerSuspended == 1U )`
   （tasks.c:2446）—— 那是 `++counter` 之后立刻读它。
3. CoreMark 在 `matrix_test` 里循环上界变成天文数字（指针读回旧值），150 M 拍跑不完。

**窗口宽度（`sw/gen_storelw.py` 量的）**：`sw` 与 `lw` 之间
**0 个 nop → 错；1~4 个 nop → 全对**。窗口**正好 1 拍**。

**根因**（`rtl/DCache.sv`）：store 在 `store_fire`（请求拍 F）发出，但缓存行的命中合并
是在 `store_req_r`（F+1）那一拍做的：

```verilog
if (store_req_r && store2_hit)  data[store2_index] <= ...   // 赋值在 F+1 末才生效
```

而 load 的命中判定 `hit_now` 用的是**当前拍**的 `data[]`。紧跟 store 的那条 load
正好在 F+1 拍做判定 —— 合并还没生效，于是读到旧行。整条链就差这 1 拍。

**修法**：合并挪到 **store 的请求拍**，直接用同一拍的 `cpu_wdata/cpu_mask/cpu_addr`：

```verilog
if (store_fire && store_hit_now) data[index] <= merge(cpu_wdata, cpu_mask, cpu_addr[1:0]);
```

★ 不变量：**不能**同时保留"F+1 合并"和"F 合并"。两条背靠背 store 打同一字时，
晚一拍的那次合并会拿更老的载荷覆盖新数据（非阻塞赋值的覆盖顺序由语句先后决定）。
`store2_wdata/store2_mask` 只留给"发往存储器的写脉冲"（`mem_wen = store_req_r`，
那一拍的 `cpu_mask` 已经推进到下一条指令了）。

**验证**
- `sim/tb_mini +prog=sim/storelw.hex`（6 项检查，gap 0~4 + 不同地址对照）**PASS**；
- `sw/memtest.c` 的 T4 **4000/4000 对**（此前 1/4000）；
- 全量回归 **36/36 PASS**（含 storelw / mret / boot_scan 等定向项，`_diag/regress.ps1`）。

---

## 6. ★ 重访存负载下的数据错乱：三个 DCache 缺陷 + 一个 LSU 缺陷（全部已修）

`sw/memtest.c` 在跑完 4 KB 阵列读写之后，串口字节会出现内存里根本不存在的值
（`0xd7`/`0xab`），而结束时 dump DRAM，`.rodata` 与 ELF **完全一致** —— 是**读回来
的值错**。CoreMark 则在 `core_bench_list` 里把链表指针读成 `0xb` 后陷入。
用 `sim/tb_cm.sv` 里新加的两件工具（`+wtrace=<addr>` 单地址访问史、
“命中值必须等于 DRAM”自检）逐层剥出来，根因一共**四处**，都在数据通路上：

### 6.1 `LSU.sv`：地址的 bit[17:16] 被硬件吃掉

```verilog
assign addr = {Ex_result_addr_reg_pipe[31:18], 2'b00, Ex_result_addr_reg_pipe[15:0]};
```

v12 时代 DRAM 只有 64 KB（`perip_addr[15:2]` 索引），bit[17:16] 恒 0，这句从未生效。
v13 把 DRAM 扩到 128 KB、`.rodata` 放到 `0x1_0000` 之后，**bit16 被清零** →
`0x10038` 变成 `0x00038`，所有数据访问回卷到低 64 KB。
修法：原样透传（宽度由 `mask` 决定，字节通道靠 `addr[1:0]`）。

### 6.2 `DCache.sv`：store 命中合并晚了一拍

`store_fire`（请求拍 F）与合并（`store_req_r` = F+1）差一拍，而 load 的 `hit_now`
用**当前拍**的 `data[]` 判定 → 紧跟 store 的那条 load 读到旧行。
窗口**正好 1 拍**（`sw` 与 `lw` 之间 0 个 nop 错、1 个 nop 对）。
修法：合并移到请求拍，直接用 `cpu_wdata/cpu_mask/cpu_addr[1:0]`。

### 6.3 `DCache.sv`：回填与 store 合并撞同一行时，让 merge 赢（不是让 fill 赢）

同一拍两者打同一 index 时，`data[]` 只能有一次赋值。第一版写成"放弃 merge"，
结果那行仍然 valid、tag 仍然匹配 → 变成 **tag 对、data 是旧值**的脏行，之后所有读
该地址的 load 全部命中脏行。改成"放弃 fill"（load 的数据照样从 `mem_rdata` 返回，
不依赖 `data[]`），行由 store 独占，一致。

### 6.4 `DCache.sv`：**假回填**把栈上的新值冲掉（最隐蔽的一个）

原来 `fill_now = access_en & ~hit & ~uncacheable`，**没有检查本拍是不是一条 load**。
`hit` 对 store 恒 0（`hit_now` 里有 `~cpu_wen`），于是：

```
[S] c=14112 addr=0001ff9c wd=00000007 store_hit=1        ← sw 命中，合并 7
[F] c=14113 addr=0001ff9c mem_rdata=00000000             ← 假回填，用陈旧读数据覆盖成 0
[L] c=14223 addr=0001ff9c rdata=00000000 dram=00000007   ← 之后一直读到 0
```

`sw` 与 `lw` 打**同一个地址**是编译器最常干的事（函数序言/尾声、`x = f(); return x;`），
所以表现为"栈上的值偶尔莫名其妙变成 0"。
修法：`fill_now = access_en & cpu_en & ~cpu_wen & ~hit & ~uncacheable`。

### 验证

| 项 | 修前 | 修后 |
|---|---|---|
| `sw/memtest.c` T1/T2/T3/T4/T5 | T4 错 3999/4000、输出乱码 | **全 0，`MEMTEST-PASS`，输出干净** |
| `sim/tb_mini +prog=sim/storelw.hex` | gap=0 失败 | **6/6 PASS**（永久回归项） |
| “命中值 == DRAM”自检（`tb_cm`） | 大量 `HITBAD` | **0** |
| `sw/hello.c` | OK | OK |
| CoreMark | 22 k 拍卡死 | **跑完全程并打印报告** |
| 全量回归 | 32/32 | **33/33** |

★ 新增不变量（都不能改回去）：
1. 缓存行的合并必须发生在 **store 的请求拍**；`store2_wdata/mask` 只给存储器写脉冲用。
2. "回填 vs 合并"撞行时，**合并优先**（放弃回填），绝不能反过来。
3. 回填必须**同时**要求 `cpu_en & ~cpu_wen`（本拍确实是一条 load）。
4. `LSU` 的数据地址不允许再对任何位做"清零"假设 —— 容量由顶层译码决定。


---

## 7. FreeRTOS：**tick 已修通**（v13.2 / P0）

> ★ 2026-10-19 更新：本节记录的"tick 只来一次"**已经解决**。根因不在端口，
> 而在 CPU：ID 级那条 `ecall` 在"被更老的重定向冲刷"的那一拍也把 CSR 改了，
> 到了错路径上却生效，于是同一条 ecall 提交三次、`MPIE` 被写成 0。
> 修法与逐拍证据见 `docs/CHECKPOINT_v13.md` §7（`sys_commit_ok` 门控）。
> 下面保留的是**当初的排查过程**，作为"端口侧看起来坏、其实是 CPU 侧"的教训。


**已完成**：
- 内核 vendor 在 `sw/freertos/`（V11.1.0，见 `VERSION.txt`）；
- 端口补丁 `sw/make_rtos_port.py` 改三处 —— 因为本核的定时器是**两条 CSR**
  （`mtime` 0x7C0 / `mtimecmp` 0x7C1，500 kHz），不是 SiFive CLINT 的 MMIO：
  1. `vPortSetupTimerInterrupt()` → `csrr 0x7c0` / `csrw 0x7c1` + `csrs mie, 0x80`；
  2. `portUPDATE_MTIMER_COMPARE_REGISTER` → `mtimecmp = mtime + 周期`（回绕安全）；
  3. `uxTimerIncrementsForOneTick` → `configMTIME_TICKS_PER_TICK`（**500**，不是
     `CPU_CLK/TICK = 50000`；写错会让 tick 慢 100 倍）。
- 编译链接通过、`mtvec` 由 `main()` 指向 `freertos_risc_v_trap_handler`，
  两个任务都创建成功并各打印一次、各自阻塞在 `vTaskDelay`。

**卡在哪（已定位到 RTL，最小复现已做出来）**：

`sw/gen_mrettest.py` → `sim/mrettest.hex` 只做一件事：

```asm
csrw mstatus, 0x1880    # MIE=0, MPIE=1, MPP=3  （FreeRTOS 的 portRESTORE_CONTEXT 就是这么干的）
mret                    # 规格要求: MIE <= MPIE(=1), MPIE <= 1  → 期望 0x1888
csrr x10, mstatus       # 实测 x10 = 0x00001880  ← MIE 丢了
```

```
[FAIL] x10 = 6272 (0x1880), expect 6280 (0x1888)
```

**根因**：本核的 CSR 写是 **WB 级**落盘，而 `mret`／`ecall` 对 mstatus 的更新是在 **ID 级**
（由 IDU 的 `mret_flag` 直接驱动 `CSR.sv:227`）。于是
`csrw mstatus` 的写（WB，晚）**覆盖**掉 `mret` 刚做的 `MIE<=MPIE`（ID，早），
顺序颠倒。任何"改 mstatus 然后马上 mret"的陷入返回都会丢掉中断使能位 ——
FreeRTOS 的 `portRESTORE_CONTEXT` 正是这个形状。

**影响范围**：所有裸机陷入返回（异常处理里改 mstatus 再 mret）、FreeRTOS 的每次任务切换。
CoreMark 不受影响（它不陷入）。

**修法方向**（还没做，按侵入性排序）：
1. 把 `mret`/`ecall` 对 mstatus 的更新也搬到 **WB**（与软件写同拍），顺序自然正确
   —— 需要把 `mret_flag`/`ecall_flag` 沿流水打 4 拍伴随 CSR 写口；
2. 或让 ID 级的 `csrw mstatus` 也立刻生效（ID 与 WB 双写，并抑制重复的 WB 写）；
3. 或给 mret 的 mstatus 更新加"看见在途 mstatus 写"的前递（利用已有的 CSR 影子链）。

★ 验收标准：`vvp tb_mini +prog=sim/mrettest.hex +x10=6280` 通过，然后 FreeRTOS
能持续打印 `B/C`（tick 10 ms 一次）。

### 修了一处（v13，有回归），但当时 FreeRTOS 仍未通

`rtl/CSR.sv`：新增"mret 在途窗口"——当**软件写 mstatus** 落盘时，若 8 拍内有更年轻
的 mret，就把 mret 的效果（`MIE<=MPIE, MPIE<=1`）叠加到这次写上。
`sim/mrettest.hex` 由 `0x1880` 变为 `0x1888` ✅，并已加入回归（现状 36/36 PASS）。

但 FreeRTOS 仍然只有一次 tick。新证据（`[E]`=`ecall_flag`、`[R]`=`mret_flag`）：

```
[E] cyc=33240 pc=000002d8 mstatus=00001888   ← 空闲任务里的 ecall，MIE=1
[E] cyc=33272 pc=000002d8 mstatus=00001880   ← 同一个 PC，MIE 已经被清
[E] cyc=33299 pc=000002d8 mstatus=00001800   ← 再下一次，MPIE 也被清成 0
```

`0x2d8` 是 `prvIdleTask` 里的 `ecall`（`portYIELD`）。**同一条 ecall 被反复执行**，
每执行一次 mstatus 就掉一位（MIE→0，再 MPIE→0），最终中断永久关闭。
这指向 **mepc 没有被 +4 生效**：端口的同步异常路径会把 `mepc+4` 存进任务栈帧
（`portASM.S:345`），返回时再用 `csrw mepc, t0` 装回去 —— 若这次写被后面/前面
的某次更新覆盖，就会回到同一条 ecall。

★ 下一步只需盯一件事：在 `0x2d8` 这次陷入里，`csrr mepc` 读到的值是 `0x2d8`
还是 `0x2dc`，以及 `portRESTORE_CONTEXT` 里那条 `csrw mepc` 落盘后 `mret` 用的是不是它。

---

## 8. CoreMark：**已跑通并给出正式分数**（v13 结束状态）

```
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 513688456
Total time (secs): 10.273769        ← 满足 >=10 s 的正式计分要求
Iterations/Sec   : 116.802313
Iterations       : 1200
Compiler version : GCC13.2.0
Compiler flags   : -O2 -march=rv32im -mabi=ilp32
seedcrc          : 0xe9f5
[0]crclist       : 0xe714           ← 与官方值一致
[0]crcmatrix     : 0x1fd7           ← 一致
[0]crcstate      : 0x8e3a           ← 一致
[0]crcfinal      : 0x988c
Correct operation validated. See README.md for run and reporting rules.
CoreMark 1.0 : 116.802313 / GCC13.2.0 -O2 -march=rv32im -mabi=ilp32 / STACK
```

**CoreMark 1.0 = 116.80 iterations/s @ 50 MHz ⇒ CoreMark/MHz = 2.34**
（1 次迭代 ≈ 428 244 拍）

★★ **这份成绩同时由 Verilator 仿真与真实板卡给出，而且 `Total ticks` 逐位相同**
（513 688 456）。这不是巧合而是"周期级等价"的直接证据：仿真模型就是上板那份 RTL。
上板实测（COM9，115200，ITER=1200 镜像经串口引导灌入）：

```
[uart] text: 2K performance run parameters for coremark..
  Total ticks      : 513688456.
  Total time (secs): 10.273769.
  Iterations/Sec   : 116.802313.
  Iterations       : 1200.
  crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a.
  Correct operation validated.
  CoreMark 1.0 : 116.802313 / GCC13.2.0 -O2 -march=rv32im -mabi=ilp32 / STACK
```

（引导方式见 §3 与 `docs/BOOT_UART.md`：宿主先灌 0x00 前导把"配置瞬间落在载荷
中间"变成"落在无害填充里"，再灌 IROM/DRAM 两帧。详见 §9 第 6 条。）

★ 复现命令：

```bash
ITER=1200 bash sw/build_coremark.sh          # 1200 次迭代 ≈ 513 M 拍 ≈ 10.3 s
bash sw/run_coremark.sh +max=700000000       # 约 10~15 分钟（Verilator）
```

★ 编译上必须的两条（都不是"优化选项"，是**让代码语义正确**）：
1. `-fno-delete-null-pointer-checks`：CoreMark 的 mergesort 在空链表时执行
   `tail->next = NULL`（core_list_join.c:583，tail==NULL）是 UB，gcc 13 -O2 会把它
   变成 `__builtin_trap`（`sw zero,0(0); ebreak`），一跑到就陷入。
2. `-fno-strict-aliasing`：CoreMark 在同一块 byte 数组上既当 `list_head` 又当
   `list_data` 用（指针双关），属于 strict-aliasing 违规。

★ 与 x86 的交叉验证（强烈建议保留这套对拍手段）：
`sw/run_probe.sh` 把**同一份** CoreMark 算法代码在 x86 与 rv32 上各跑一遍，
用探针自己写的十六进制打印输出同一批中间量（链表节点 idx/data16、矩阵 N、
各阶段 CRC）。x86 侧输出 `CRC=0xe714 / CM=0x1fd7 / CS=0x8e3a`（官方值），
rv32 侧逐行比对 ——「第一个不同的一行」就是 CPU 算错的起点。

### 最终定位到的四个 CPU 缺陷（详见 §6）

| # | 位置 | 一句话 |
|---|---|---|
| 1 | `LSU.sv` | 数据地址 bit[17:16] 被清零（64KB 时代的遗留），128KB DRAM 下 .rodata 被折叠到低 64KB |
| 2 | `DCache.sv` | store 命中合并晚一拍 → `sw` 后紧跟同地址 `lw` 读到旧值 |
| 3 | `DCache.sv` | 回填与 store 合并撞同一行时方向反了 → 造出"tag 对、data 是旧值"的脏行 |
| 4 | `DCache.sv` | 回填**没检查"本拍是不是 load"**，且读返回**没校验地址归属** → 用别人的读数据回填 |

### 8.1 分数解读：2.34 CoreMark/MHz 落在哪一档（v13 实测）

拍数口径先钉死：`Total ticks` 就是**拍数**（`mtime` 每 100 拍 +1，端口再 ×100；
同一次仿真 `mcycle=482 971` 与 TB 的 `cyc=482 987` 只差复位/启动的 16 拍），
所以 **1 次迭代 = 428 244 拍 ⇒ 1e6/428 244 = 2.335 CoreMark/MHz**。

| 核 | 结构 | CoreMark/MHz | 相对本核 |
|---|---|---|---|
| Cortex-M0 | 3 级，无 C | **2.33** | 1.00×（同一档） |
| Cortex-M0+ | 2 级 | 2.46 | 1.05× |
| **本核 BigBird v13** | 6 功能/8 物理级，RV32IM | **2.34** | — |
| SiFive E31 | 3 级，RV32IM**AC** | 2.73 | 1.17× |
| Cortex-M3 | 3 级 + 分支预测 | 3.34 | 1.43× |
| Cortex-M4 | 3 级 + DSP | 3.42 | 1.46× |
| Cortex-M7 | 6 级双发射 | 5.29 | 2.26× |

（ARM 值取自 Arm 官方 Cortex-M 对比表；E31/E51 取 SiFive 发布数据。）

三条必须一起看的限定：
1. **我们没有 C 扩展**，M0+/M3/E31 都有 —— 压缩指令对小核的 CoreMark 通常有
   10~20% 的直接收益（取指字节数减半）。
2. **存储器是 BRAM、0 等待**，而 ARM 那些数字多数跑在带 flash 等待的目标上，
   这一点我们**占便宜**。
3. `-O2`、无 `-fprofile`、`Memory location: STACK`，是按规则报分的配置，没做特调。

结论：**稳稳的 "Cortex-M0 一档"**，是 M3 的 ~70%、E31 的 ~86%。对一个自己写的
8 物理级顺序单发射核，这个分数是"合格但不惊艳"，而且**下面有明确的提升空间**。

### 8.1b v14 更新：**120.41 iter/s ⇒ 2.41 CoreMark/MHz**（分支预测 64→256 行）

上面 §8.1 的 2.34 是 **v13.5 基线**（BTB/PHT 64 行、GHR 6 位）。v14 把预测器加宽到
**256 行 / GHR 8 位**（`rtl/para.sv`，扫描依据见 `docs/CHECKPOINT_v14.md` §1）后，
上板（ITER=**1300**，10.797 s）实测：

```
Total ticks      : 539832473     ← 415 256 拍/迭代（v13 是 428 074）
Total time (secs): 10.796649     ← 必须 >= 10 s
Iterations/Sec   : 120.407725    ← 原 116.802313，+3.09%
⇒ CoreMark/MHz   = 2.408         ← 原 2.335
[0]crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a
Correct operation validated.
```

误预测从 10 680 降到 **7 753**（分支 73 694 条 ⇒ 14.5% → 10.5%）。
再往 1024 行只能多 1.4%，代价 ~900 LUT 与 1024 选 1 的取指 mux，**不值得**。

★ **迭代次数必须从 1200 提到 1300**：核快了 3% 之后，1200 次只跑 9.97 s，
CoreMark 直接判 `ERROR! Must execute for at least 10 secs`（实测被拒）。
复现：`ITER=1300 bash sw/build_coremark.sh` → `_diag/board_run.ps1 ... -Repeat 2`。

### 8.1c v15 更新：**128.82 iter/s ⇒ 2.576 CoreMark/MHz**（load-use 2 拍 → 1 拍）

§8.1b 的 2.408 又被一次 RTL 改动超过：给 DCache 加**第二个只读读口**（M1 命中探测），
load-use 从 2 拍压到 1 拍（细节与代价见 `docs/CHECKPOINT_v14.md` §5b）。上板实测：

```
Total ticks      : 543407157     ← 388 148 拍/迭代（v14 是 415 256，−6.5%）
Total time (secs): 10.868143
Iterations/Sec   : 128.816853    ← 120.407725 → 128.816853，+6.98%
Iterations       : 1400
⇒ CoreMark/MHz   = 2.576
[0]crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a  +  Correct operation validated
```

同一次改动把 `load_use` 停拍从 **50 339 压到 22 681（−55%）**，总拍数 468 263 → 440 656；
代价是 WNS 1.187 → **0.645 ns**（仍为正）与两个 256:1 读 mux。

★ 迭代次数再改一次：**1300 → 1400**（1300 次现在只剩 ~10.1 s，贴线不安全）。

### 8.1d 三代对比（同一套板卡、同一份工具链）

| 版本 | 关键改动 | iter/s | CoreMark/MHz |
|---|---|---|---|
| v13.5 | 基线（BTB 64 / GHR 6 / load-use 2 拍） | 116.80 | 2.335 |
| v14 | BTB/PHT 256 + GHR 8；IROM 双读口；P4 修复 | 120.41 | 2.408 |
| **v15** | 再加 DCache M1 探测口（load-use 1 拍） | **128.82** | **2.576** |

### 8.2 停顿普查（`+perf`）：26.7% 的拍没在退休指令

`sim/tb_cm.sv` 新增了 `+perf` 普查（只统计、不改行为），1 次迭代实测：

```
[PERF] cyc=482987 minstret=353984 wb_high=378385 |
       ifu_stall=71167 load_use=50343 mdu_busy=20884 dc_hold=4545
       mispred=10680 trap=0 inst_clear=65337 | dc_hit=72474 dc_miss=30485
```

归因（整轮 482 987 拍 / 353 984 条 ⇒ **CPI 1.364**）：

| 类别 | 拍数 | 占比 | 说明 |
|---|---|---|---|
| 退休（有效） | 353 984 | 73.3% | 稳态 1 IPC |
| load-use 重放 | 50 343 | 10.4% | M1/M2/M3 三级访存 ⇒ 消费者要等 2 拍 |
| 分支误预测重填 | ≈53 291 | 11.0% | 10 680 次重定向，**每次约 5 拍** |
| MDU 迭代 | 20 884 | 4.3% | 乘/除多拍忙碌 |
| DCache hold | 4 545 | 0.9% | 见下 |

（`IFU_stall = load_use | mdu_busy`：71 167 vs 50 343+20 884=71 227，重叠仅 60 拍；
残差 `482 987 − 353 984 − 71 167 − 4 545 = 53 291` 即误预测重填。）

★ **反直觉的一条：数据 Cache 命中率只有 70%，却几乎不要钱。**
`dc_hit=72 474 / dc_miss=30 485`（缺失率 **29.6%**），但 hold 只占 **0.9%** ——
因为 miss 是在 M1 就发出去的，数据赶在 M3 前回来，代价已经被"load-use 重放"
那一栏**预先付掉了**。也就是说**当前瓶颈不是存储带宽，而是 load 的固定 3 拍延迟**。

各优化项的收益上限（若该项完全消除，按窗口 428 244 拍折算）：

| 优化 | 省下的拍 | 分数 → | 相对涨幅 | 代价/风险 |
|---|---|---|---|---|
| load-use 前递/提前返回 | 44 654 | 2.61 | **+11.6%** | 高：动 M1/M2/M3 那条路，P4 缺陷就在旁边 |
| 分支预测（BTB/历史加宽） | 47 269 | 2.62 | **+12.0%** | 中：BP 模块独立，可先在仿真里扫参数定天花板 |
| 乘法改 DSP 单拍 | 18 524 | 2.44 | +4.3% | 低-中：DSP 只用了 4/220，17 拍迭代 → 2~3 拍 |
| DCache（已接近无收益） | 4 031 | 2.36 | +0.9% | 不建议单独投入 |

复现（约 2 分钟）：

```bash
ITER=1 bash sw/build_coremark.sh          # 1 次迭代的镜像（不覆盖 ≥10 s 的报分镜像时先备份）
bash sw/run_coremark.sh +max=2000000 +perf
```

---

## 9. 踩坑清单（新增）

1. **改完 RTL 忘了重编仿真模型 = 静默看旧结果**。`sw/run_coremark.sh` 已加
   `find -newer` 自动判新旧；手工编 iverilog 时务必先 `rm` 掉 `.vvp`。
2. `objcopy -O binary` 出来的**平坦镜像**在两个地址空间之间是"空洞+尾段"，
   切分点必须与 `link.ld` 的 `ORIGIN(dram)` 一致（我们就是 0x10000）。
3. `Verilator --Mdir` 会 `make -C <Mdir>`，命令行里的源文件路径**必须绝对**。
4. 串口 snoop 只能认 `0x1000_0000`；写成 `perip_wen && is_mmio` 会把写 LED /
   写 DONE 标志的字节也当字符打出来（本轮自己踩的）。
5. `configASSERT` 打印的是 `__LINE__`，**不带文件名**——多文件工程里会误导，
   建议编译期把 `__FILE__` 也传进去（我们暂时只打行号）。
6. **引导流的"帧同步"是个真坑（上板 3 次里 1 次成功）**：`boot_loader` 在 S_IDLE 里
   逐字节扫描 magic，而载荷里天然有 `0x42/0x43/0x47`（实测一份 67 886 B 的会话里
   `'B'×10 / 'C'×27 / 'G'×79`）。于是"FPGA 配置完成的瞬间宿主发到哪儿"决定成败：
   - 撞上假 `'G'`：旧版无条件响应 `'G'` → `st<=S_FIN`，整个会话**当场报废**，
     之后所有帧都被忽略。板上读数 `debug_status = 0x001ff880`
     （`boot_rx_cnt=0x3FF` 饱和、`ok=0`、`err=0`、`busy=0`）正是这个状态；
     `err` 还是 0 是因为 S_FIN 只清 busy、不碰 err。
   - 撞上假 `'B'/'C'`：会按"垃圾长度"往 IROM/DRAM 写垃圾（实测写掉 28 652 个 DRAM
     字），校验和不过再重新扫描。
   - 零成本复现：`python sw/gen_boot_stream.py …` 造逐字节流，再用
     `sim/tb_boot_scan.sv` 从**任意偏移**喂进 `boot_loader` 看结果
     （`vvp … +off=5000`）。off=0 成功、off=40/200/5000 全部 `w_irom=0`。
   - 现在的对策：宿主在会话前先发 **0x00 前导**（0x00 不是 magic），把配置瞬间
     变成"落在无害填充里"，填充结束后紧跟会话第一个字节 `'B'` —— 确定性成功。
     `_diag/load_uart.ps1 -PadSec <秒>` + `board_run.ps1 -PadSec`；
     RTL 侧同时加了 `'G'` 必须 `have_r=1` 才认的门（去掉"当场报废"这条路）。
     彻底做法是给帧加**帧首静默/双字节 magic**（未做，见 `docs/BOOT_UART.md`）。
