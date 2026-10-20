# v13 状态快照（2026-10-18 21:30）

> 用途：不重读历史也能继续干活。上一版见 `docs/CHECKPOINT_v12.md`。

## 1. 一句话现状

**FreeRTOS tick 已修通并上板验证**（P0）；**串口 monitor + 软件重新引导**（P3）与**帧首静默引导**（P1）也已上板跑通；**CoreMark 跑通并给出正式分数**（10.27 s / 1200 iterations / **116.80 iter/s @ 50 MHz
⇒ CoreMark/MHz = 2.34**，CRCs 与官方值逐位一致），且**已在真实板卡上复现同一分数**
（`Total ticks 513688456` 与仿真逐位相同）；全量回归 **36/36**；
hello / memtest / divtest / multest 全 PASS。串口引导（TX/RX + IROM/DRAM 双帧）
**已在板上打通**。FreeRTOS 能起来但 tick 只来一次（未解决）。

## 2. 本轮新增的软件基础设施（都在 `sw/`）

| 文件 | 作用 |
|---|---|
| `sw/env.sh` | rv32 工具链环境（deb 解包到 `~/rv32/sysroot`，**不需要 sudo**） |
| `sw/build_hello.sh` / `build_simple.sh` | 单文件 C 程序 → `<name>_irom.hex` + `<name>_dram.hex` |
| `sw/build_coremark.sh` | CoreMark（`ITER=` 迭代次数、`OPT=` 优化档、`CORE_DEBUG=1`） |
| `sw/build_rtos.sh` | FreeRTOS demo（含 `make_rtos_port.py` 的 CSR 定时器补丁） |
| `sw/elf2hex.py` | 平坦 bin 在 `0x10000` 切成 IROM/DRAM 两个镜像 |
| `sw/run_coremark.sh` | Verilator 编译 + 跑（`+irom= +dram= +max= +trace +hexout +wtrace=`） |
| `sw/check_all.sh` | 一次性跑 hello/memtest/divtest/multest |
| `sw/run_probe.sh` | **x86 ↔ rv32 同源对拍**（打印同一批中间量，逐行 diff） |
| `sw/gen_storelw.py` / `gen_abitest.py` | 生成定向汇编测试（store→load 冒险窗口、ABI 保持性） |

自检程序：`sw/hello.c`、`memtest.c`、`divtest.c`、`multest.c`、`mtimetest.c`、
`timertest.c`、`cm_probe.c`（对拍探针）。

## 3. ★ 本轮修掉的八个缺陷（细节见 `docs/C_工具链与RTOS.md` §6/§7）

| # | 位置 | 症状 | 修法 |
|---|---|---|---|
| 1 | `rtl/LSU.sv` | 地址 bit[17:16] 被强制清零（64KB 时代遗留）→ 128KB DRAM 下 `.rodata` 地址折叠 | `assign addr = Ex_result_addr_reg_pipe;`（原样透传） |
| 2 | `rtl/DCache.sv` | store 命中合并发生在 F+1，load 在 F+1 判定 → `sw` 后紧跟同址 `lw` 读旧值（窗口正好 1 拍） | 合并移到 **store 请求拍** |
| 3 | `rtl/DCache.sv` | 回填与合并撞同一 index 时"放弃合并"→ 留下 tag 对/data 旧的脏行 | **让合并赢、让回填让位**（`fill_blocked`） |
| 4 | `rtl/DCache.sv` | 回填没检查"本拍是不是 load"；读返回没校验地址归属 → 用别人的读数据回填/返回 | `fill_now` 加 `cpu_en & ~cpu_wen`；新增 `rd_addr_r` 并同时校验 `resp_for_now` |
| 5 | `rtl/CSR.sv` | `csrw mstatus` 紧跟 `mret` 时，WB 落盘的软件写覆盖了 mret 的 `MIE<=MPIE` | `mret_inflight` 窗口：软件写落盘时把 mret 的效果叠加上去 |
| 6 | `rtl/CSR.sv` | 一次陷入被**重复提交**（同一条 ecall 在流水里待几拍）→ `MPIE<=MIE` 时 MIE 已 0，mstatus 掉成 0x1800 | `trap_blank`：提交后消隐 8 拍不再更新 mstatus |
| 7 | `board/boot_loader.sv` | 没有帧同步：载荷里的 `0x42/0x43/0x47` 会被当成命令（假 `'G'` 直接报废会话，假 `'B'/'C'` 按垃圾长度写垃圾） | **帧首静默**：`S_IDLE` 只在"线路静默 ≥ 1 ms"后才认 magic（v13.3 / P1；宿主帧间留 50 ms，见 `docs/BOOT_UART.md` §12） |
| 8 | `rtl/Control.sv` + `rtl/IDU.sv` | ID 级的 `ecall/mret` 在"被更老的重定向冲刷"的那一拍也把 CSR 改了 → 同一条 ecall 提交三次、`MPIE` 写成 0，FreeRTOS tick 只来一次 | `sys_commit_ok = IDU_valid & IDU_ready & ~(intr_take\|trap_redirect\|bp_mispredict)`，门控送 CSR 的那一份（v13.2 / P0，见 §7） |

第 5、6 两个是 FreeRTOS tick 失效的直接原因（都在 `mstatus` 的陷入/返回语义上）。

★★ 必须保留的不变量（改回去就会重犯）：
1. 缓存行合并只能在 **store 请求拍**做；"回填 vs 合并"撞行时**合并优先**。
2. 回填必须同时要求 `cpu_en & ~cpu_wen`；读返回必须校验 `rd_addr_r == cpu_addr_r`。
3. `LSU` 不许再对数据地址做任何"某些位恒 0"的假设 —— 容量由顶层译码决定。
4. `mret` 对 mstatus 的更新必须与"在途的软件 mstatus 写"顺序正确（用 `mret_inflight` 窗口）。
5. 一次陷入只能**提交一次**（`trap_blank` 消隐 8 拍）。

## 4. 仿真台（`sim/tb_cm.sv` + `sim/cm_main.cpp`）

Verilator 主循环（每循环 = 1 拍），内存 64KB IROM + 128KB DRAM，
DRAM 镜像装在**字偏移 0x4000**（地址 0x1_0000）。

内置三个硬不变量自检（写直达，所以这些检查是精确的）：

| 检查 | 含义 |
|---|---|
| `[HITBAD]` | 命中的 load 返回值 ≠ DRAM 内容 |
| `[MBAD]` | 未命中的 load 读返回 ≠ DRAM 内容 |
| `[WBAD]` | store 落地后 DRAM 内容 ≠ 按 mask 合并的期望值 |

诊断开关：`+hexout`（串口字节打成十六进制）、`+trace`（前 64 次写回）、
`+wtrace=<addr>`（单地址访问史）、`+max=<cycles>`、`+irom= +dram=`。

## 5. CoreMark 结果（可复现）

```bash
ITER=1200 bash sw/build_coremark.sh
bash sw/run_coremark.sh +max=700000000
# → Total ticks 513688456 / 10.27 s / 116.802313 iter/s
#   crclist 0xe714 crcmatrix 0x1fd7 crcstate 0x8e3a  "Correct operation validated"
#   CoreMark/MHz = 2.34
```

**上板同款**（一条命令，约 3 分钟：100 s 0x00 前导 + 2 个会话 + 监听；前导必须
长于编程耗时，`-Repeat 2` 保证流结束在会话边界，`-NoGo` 让 CPU 等宿主腾出串口）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\board_run.ps1 `
    -Port COM9 -Hex sw\build\cm_irom.hex -DramHex sw\build\cm_dram.hex `
    -PadSec 100 -Repeat 2 -NoGo -ListenSec 45
# → [uart] CoreMark 1.0 : 116.802313 ...  Correct operation validated.
```

编译必须带：`-fno-delete-null-pointer-checks`（mergesort 空链表 UB）+
`-fno-strict-aliasing`（同一 byte 块上的指针双关）。

## 6. 板级状态（2026-10-19 13:55 —— **P0/P1/P3 全部上板验证通过**）

- **当前 bitstream**：`v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.bit`
  （13:39:52，`RESULT build OK`，**WNS 0.927 / WHS 0.009 / THS 0.000**；
  资源 LUT 31 057 = 58.4% / FF 22 770 = 21.4% / BRAM 66.5 = 47.5% / DSP 4 = 1.8%）。
  备份：`_bak/board_top_gui_boot_p013b_1345.bit/.ltx`（工程目录之外）。
- **四条上板验证（都是本轮实际跑出来的）**：

  | # | 验证项 | 命令 | 结果 |
  |---|---|---|---|
  | 1 | P1 静默引导 + monitor | `board_run.ps1 -Hex monitor_irom.hex -DramHex monitor_dram.hex -Repeat 2 -NoGo` | `boot_ok=1`、`rx_cnt` 饱和、ILA PC 落在 monitor 的 `getc_to` 轮询环 |
  | 2 | P3 monitor 命令通路 | `mon_cmd.ps1 -Cmd c` | 回出 `mstatus=0x00001800 / mcycle=2011890194 / minstret=4204453174 / mtime=63068574` + `> ` 提示符 |
  | 3 | P3 软件重新引导 | `board_run.ps1 -SkipProgram -PreCmd b -Hex mt_irom.hex …` | `MEMTEST-PASS`（T1..T5 全 0），**全程 12 s**（换程序不再需要重配 FPGA） |
  | 4 | P0 FreeRTOS tick | `board_run.ps1 -Hex rtos_irom.hex -DramHex rtos_dram.hex -Repeat 2 -NoGo` | `RTOS-BOOT / C0 / B0 / … / B14 / C8 / RTOS-DONE`，`mstatus=0x00001888` 全程不掉、`mcause=0x80000007` 周期进入 |
  | 5 | CoreMark 未回归 | 同 #4 换 `cm_*.hex` | `Total ticks 513688456` / `116.802313 iter/s` / CRCs `e714,1fd7,8e3a` —— **与 P0 之前逐位相同** |

- ★ 一次"看起来失败"其实是**读窗口开晚了**：`-NoGo` 下 CPU 在最后一个字节后 5 s
  被释放，而 monitor 的横幅只打一次（~10 ms）。`-ReleaseWaitMs` 必须**小于** 5 s
  才能在横幅出现前打开串口（本轮第一版用了 6000 ms，正好错过）。想让"一次性输出"
  稳拿：`-ReleaseWaitMs 500 -ListenSec 20`。
- ★ 时间口径：`program_only.tcl` 冷启动 53~57 s、热启动约 13.5 s。
  现在编程期间由**稀疏保活**（1 个 0x00 / 50 ms，编程一结束就停）占住 loader，
  "从配置完成到开始灌镜像"的等待 ≈ 0；换程序总时间 ≈ 6 s（一帧 64 KB 镜像）
  + 5 s（超时释放）。软件重新引导（P3）则完全没有编程这一步。
- ⚠ 已知残留（见 §9）：CPU 的 MMIO 读会被发两次；外设侧已用 peek/pop 免疫。

## 6b. 上板工具

| 脚本 | 作用 |
|---|---|
| `_diag/board_run.ps1` | 一条命令完成"起串口流 → 编程 → 收串口" |
| `_diag/board_run.ps1 -Repeat N -NoGo` | 正式姿势：稀疏保活 → 编程完成即发帧 → 超时自释放（换程序 ~7 s） |
| `_diag/board_run.ps1 -SkipProgram -PreCmd b` | **不重配 FPGA 换程序**：让已在运行的 monitor 重新武装 loader |
| `_diag/load_uart.ps1` | 帧 v13：`'B'`/`'C'`/`'G'`，`-FrameGapMs`（帧首静默）、`-PadUntilFile`、`-PreCmd` |
| `_diag/program_only.tcl` | 只编程（冷 53~57 s / 热 13.5 s） |
| `_diag/capture_ila.tcl` | 抓 ILA（必须先 `$env:ILA_LTX` 指向 boot 版 ltx） |
| `_diag/dis_rtos.sh` | 反汇编 FreeRTOS 镜像的关键片段（P0 定位用） |
| `sw/gen_boot_stream.py` | 把镜像拼成**逐字节**引导流（喂 `sim/tb_boot_scan.sv` 用） |
| `sim/tb_boot_scan.sv` | `boot_loader` 的"中途插入"测试（**关掉静默**，测历史缺陷） |
| `sim/tb_boot_sync.sv` | 帧首静默的专项单测（进回归；证明"无静默的完整合法帧被忽略"） |
| `sim/tb_cm.sv +win_s/+win_e` | 逐拍窗口打印（P0 就是靠它定位的） |
| `sw/monitor.c` | 板级串口 monitor：`d/p/w/c/l/b`（见 §7b） |
| `sim/tb_monitor.sv` | monitor 的 **RX 命令通路**端到端测试（进回归，iverilog 约 3 分钟）|
| `sw/gen_console_demo.py` | console 演示程序生成器（v13.5 起按 peek+pop 契约生成）|
| `sw/elf2hex.py --trim` | 去掉镜像尾部全零字（CoreMark 64KB→22.5KB） |


## 7. ★ FreeRTOS tick：**已修通**（v13.2 / P0）

### 7.1 现象

第一次 `ecall`（空闲任务的 `taskYIELD`）之后 `mstatus` 从 `0x1888` 掉到 `0x1800`
（MIE=0、MPIE=0），`mip.MTIP=0x80`、`mie.MTIE=0x80` 都在，但中断再也不进 —— tick 只来一次。

### 7.2 根因（逐拍波形 + 反汇编交叉确认）

`[E]` 打印（`sim/tb_cm.sv`）显示**同一条 `ecall`（pc=0x2d8）被提交了三次**：

```
[E] cyc=33240 pc=000002d8 mstatus=00001888
[E] cyc=33272 pc=000002d8 mstatus=00001880   ← 第二次提交：MPIE 被写成 0
[E] cyc=33299 pc=000002d8 mstatus=0001800   ← 之后 MIE 永久为 0
```

反汇编（`_diag/dis_rtos.sh`）确认 0x2d8 是 `prvIdleTask` 里的 `ecall`，
它的下游 0x2d4 是 `bgeu s1,a5,2c8`。`+win_s/+win_e` 逐拍窗口显示：

* 33272 那一拍：`ecall=1, dnpc=1, rdy=1`，下一拍 PC 去的是 **0x2c8（分支目标）**，
  不是 `mtvec`；
* 也就是说：**更老的误预测分支在 EX 同拍成立**，`dnpc` 按优先级
  （`intr_take > bp_mispredict > fence.i > mret/ecall`）取了分支目标并 flush 掉 ID，
  但 ID 级那条 `ecall` **已经把 mstatus/mepc/mcause 改了** —— 它在错路径上却生效了；
* 循环再走到 0x2d8 时又提交一次（MPIE 已是 0）→ `mret` 之后 MIE 永远是 0。

机制上的病根：`ecall_flag`/`mret_flag` 是**纯译码电平**（只要指令还在 ID 就恒为 1），
而 CSR 的副作用在 ID 级**组合提交**，既不看"下游收不收"（`ready`），
也不看"本拍有没有更老的重定向"。原来那个 8 拍 `trap_blank` 只是把窗口缩小，
遇到 30 拍后的重复提交就完全无效。

### 7.3 修法（`rtl/Control.sv` + `rtl/IDU.sv` + `rtl/myCPU.sv`）

```verilog
// Control.sv
assign sys_commit_ok = IDU_valid & IDU_ready
                     & ~(intr_take | trap_redirect | bp_mispredict);
assign system_redirect = ((mret_flag | ecall_flag) & sys_commit_ok)
                       | fence_i_flag | trap_redirect;
```

`sys_commit_ok` 直通给 IDU，只门控**送给 CSR 的那一份**：

```verilog
// IDU.sv (Reg_Stack 例化)
.ecall_flag (ecall_flag & sys_commit_ok),
.mret_flag  (mret_flag  & sys_commit_ok),
```

IDU 自己的 `ecall_flag/mret_flag` 输出仍是原始译码（Control 的 `intr_safe`
和 `system_redirect` 要用）。

★ 不变量（改回去就复发）：**系统指令的 CSR 副作用必须与"这条指令真的会提交"
同口径** —— `IDU_valid & IDU_ready & ~更老的重定向`，三项一个都不能少；
`fence.i` 不在门控里（它来自 EX，天然不年轻）。

### 7.4 验证

```
[E] cyc=33272 ... mstatus=00001888   ← 错路径那次不再改 mstatus
C0 / B0 / [IRQ]task ... mcause=0x80000007 mtc=0x00000311
B1 / C1 / [IRQ]post-delay mstatus=0x00001888 ... mtc 每次 +0x2710(=20 ms @500 kHz)
... B14 / C5
```

两个任务交替打印、`mstatus` 恒 `0x1888`、定时器中断周期性进入、`mtimecmp` 每次
推进 20 ms。回归 37/37 PASS（含 ecall/mret/异常全部定向项）。


## 7b. ★ 串口 monitor 与"软件重新引导"（v13.4 / P3）

### 7b.1 新增的硬件能力：软件可以重新武装 boot_loader

`0x1000_0014` bit0 写 1 → `board_top` 产生一个 **7 拍**复位脉冲，把 `boot_loader`
和它的 `uart_rx` 一起复位回 S_IDLE（`boot_rx_cnt` 同时清零）；脉冲结束后 loader
自己 `busy=1` 把 CPU 按住（`cpu_rst_eff = cpu_rst | boot_busy`），宿主随后照常灌镜像。

★ 不变量（实现时踩过）：
* 复位必须是**有限宽度**的脉冲；一直按住会 busy 恒 1、CPU 永久停机。
* 复位要同时给 `boot_loader` 和它的 `uart_rx`（否则残留半帧状态让第一个字节错位）。
* 不需要额外的"保持"寄存器 —— `boot_busy` 本身就是保持源。

### 7b.2 `sw/monitor.c`

★ v13.5 起串口 RX 的寄存器契约变了（原因见 §9）：

| 地址 | 语义 |
|---|---|
| `0x1000_0008` RXDATA | 只读队头，**不弹**（幂等读） |
| `0x1000_0018` RXPOP  | 写 1 → 弹一个字节 |

软件写法：`while (!(RXSTAT & 1)); c = RXDATA; RXPOP = 1;`
（`sw/monitor.c` 与 `sim/gen_console_demo.py` 都已按这个口径改过）

```
h            帮助
d <a> <n>    从地址 a dump n 个字（每行 8 个，最多 256）
p <a>        读一个 32 位字
w <a> <v>    写一个 32 位字（外设寄存器也走这条，例如 w 10000010 7f 点灯）
c            dump CSR：mstatus/mie/mip/mcause/mepc/mtvec/mcycle/minstret/mtime/mtimecmp
l <v>        写 LED
b            重新进入引导器（写 0x1000_0014），随后宿主可灌新镜像
```

启动横幅：`=== BigBird RV32 monitor (v13.4) ===` + `mtime` + DRAM 基址，然后打帮助和 `> ` 提示符。
空闲 10 s 会重打 `(idle)` 和提示符。

### 7b.3 用法（不重配 FPGA 换程序，约 7 s）

```powershell
# 板上已经在跑 monitor，下面这条会把新镜像灌进去（含 IROM 帧 + DRAM 帧）
_diag\board_run.ps1 -Port COM9 -SkipProgram -PreCmd b `
    -Hex sw\build\memtest_irom.hex -DramHex sw\build\memtest_dram.hex `
    -Repeat 2 -NoGo -ListenSec 20
```

★ 注意：**镜像会覆盖 IROM，monitor 也随之消失**。要再换一个程序，要么让新程序自己写
`0x1000_0014`，要么按一下 S1（复位同样会把 loader 重新武装 —— IROM 阵列不被复位清空，
所以"按 S1 再灌"这条路一直都在）。

## 8. 踩坑清单（本轮新增）

1. **改完 RTL 忘了重编仿真模型 = 静默看旧结果**。`run_coremark.sh` 已加
   `find -newer` 自动判新旧；手工 iverilog 前先 `rm` 掉 `.vvp`。
2. **绝不能再用 PowerShell 的 `Get-Content/Set-Content` 处理 UTF-8 文件**：
   PS 5.1 按 GBK 解码，中文注释会被写成乱码并**破坏语法**
   （本轮把 `sim/tb_cm.sv` 弄坏过一次，只能重写）。一律用编辑工具或 Python。
3. `Verilator --Mdir` 会 `make -C <Mdir>`，命令行里的源文件路径**必须绝对**。
4. 串口 snoop 只认 `0x1000_0000`；写成 `perip_wen && is_mmio` 会把写 LED /
   写 DONE 标志的字节也当字符打出来。
5. 用 C 写 trap handler 必须自己保存/恢复被中断的寄存器（编译器会随手用
   `a5`/`t0`），否则"看起来像 CPU 跳错地方"。
6. `mtval` 对 load/store 非对齐只保证"某个相关地址"，定位时要用寄存器现场
   （`[TRAP] ... sp=/s8=` 两拍快照）交叉验证。
7. **"板子上没输出"先分清是 TX 还是没跑起来**。本轮 21 字节的 `P0........` 反复出现，
   一度被当成"波特率错/丢字节"，实际是**固化镜像的 `.rodata` 在 DRAM 里而 DRAM 没被
   灌过**（哈佛双口：`lw` 读不到 IROM）。判据：同一份镜像在 Verilator 里配齐 DRAM
   就打出干净的 `PING 0x00000001 t=...`。
8. **`-StreamSec` 这类"按住时间"必须按冷启动给**（编程 53~57 s）。本轮一次"引导失败"
   完全是 `-StreamSec 30` 在配置完成前就发完了；loader 空等 5 s 后走超时释放
   （`err=1`、`rx_cnt=0`），看起来像"RX 坏了"。
9. **一次性输出的程序（CoreMark）要 `-NoGo`**：让 CPU 等宿主放开串口后再启动，
   否则那 10 s 的结果全被"宿主还在灌数据"吃掉。`board_run` 已加
   `-NoGo/-ReleaseWaitMs/-Repeat/-PadSec`。
10. **不要凭分析脚本的归纳下结论**：`an_ila_boot.py` 只解 `debug_status` 的 8~10 位，
    11~20 位是 `boot_rx_cnt`。本轮据此把 `0x001FF880`（rx_cnt=1023）误读成
    "零字节"，多查了一整圈。看原始 CSV 列。
11. **备份 bitstream 千万别放在 `v9_boot/v9_ila.runs/` 里**：`build_project_boot.tcl`
    开头就是 `create_project -force v9_boot`，整个工程目录（含 `impl_1`）会被删掉重建。
    本轮把"已验证可用的 .bit/.ltx"备份到 `impl_1/` 里，下一次构建就被一起删了。
    要备份就放到工程目录**之外**（例如 `_bak/`）。
12. **PowerShell 的 `List[byte].Length` 不是 int**：`$n += $lst.Length` 会报
    `[System.Object[]] does not contain a method named 'op_Addition'`（PS 5.1 上
    `.Length` 解析出两个值）。构建字节段时统一 `.ToArray()` 成 `byte[]` 再用。
13. **`$display` 的 packed-vector 参数别塞 UTF-8 中文**：`task chk(input [8*70-1:0] name)`
    收到中文会按字节截断成乱码，判据本身看不出错。判据名一律 ASCII，中文写在注释里。
14. **"提交"类信号的隐藏前提**：任何"在译码级就产生副作用"的设计（本核的
    `ecall/mret`）都必须自己回答"这条指令真的会提交吗"。只靠"几拍内不会重复"的
    计时补丁（原来的 8 拍 `trap_blank`）早晚被更长的停顿打穿 —— P0 就是被
    30 拍后的重复提交打穿的。

## 9. ★ 已知缺陷（P4，**未修**）：一次 MMIO 读会被总线发两次

### 9.1 现象（仿真证据，不是推测）

`sim/tb_monitor.sv` 加了 `[RD]` 逐次读轨迹（`u_board.perip_ren & mmio_sel & idx==2`）：

```
[RD] c=30329190000 ren=1 pop=0 rp=0 cnt=5 rd=6c   ← 读出 'l'，rp→1
[RD] c=30329230000 ren=1 pop=0 rp=1 cnt=4 rd=20   ← 401 ns 后又读一次，读出 ' '，rp→2
[RD] c=30414330000 ren=1 pop=0 rp=2 cnt=3 rd=33   ← 读出 '3'
[RD] c=30414370000 ren=1 pop=0 rp=3 cnt=2 rd=66   ← 又读一次，读出 'f'
```

**一条 `lw 0x1000_0008` 会让 `perip_ren` 出现两个脉冲**（相隔约 20 拍 / 401 ns）。
统计口径也印证：`[COUNT] RXDATA reads=26  rx_pop pulses=13` —— 读次数恰好是"逻辑读"的两倍。

后果（当时的现象）：monitor 的 `l 3f` 被解析成 `l3`、`LED <- 0x00000003`。
任何"读有副作用"的外设（RX FIFO 出队、读清中断标志、DMA 状态机）都会受害。

### 9.2 根因（定位到 DCache 的 uncacheable 读路径）

`rtl/DCache.sv`：

```verilog
assign cache_rd_req = cpu_en_r & ~cpu_wen_r & ~line_resident & ~mem_req_r;
assign mem_en       = cache_rd_req;          // -> 顶层 perip_ren
assign line_resident = resp_valid_r & ~uncacheable & ...;   // uncacheable 时恒 0
```

* `cpu_en/cpu_wen` 是**电平**（LSU 的 pipe 级寄存器保持，见 DCache.sv 头部第 25 行注释），
  一次访问期间一直为高；
* 对 uncacheable 地址，`line_resident` 恒 0，所以"这次读要不要发"完全靠 `mem_req_r`
  这个"发过没"的标志；
* `mem_req_r` 在数据返回那一拍被清（`mem_data_vld` 成立），而 LSU 往往还要再hold
  若干拍才推进 → 于是**同一个请求又发了一次**。

### 9.3 现在的对策（外设侧，已实现，v13.5）

把"看"和"弹"分开，让读变**幂等**：

| 地址 | 语义 |
|---|---|
| `0x1000_0008` RXDATA | 只读队头，**不弹**（读多少次都一样） |
| `0x1000_0018` RXPOP  | 写 1 → 弹一个字节 |

实测**写是单拍的**（UART TX 从来没出现重复字符），所以"读 peek + 写 pop"对
"读被发两次"免疫。`sw/monitor.c` 已按这个契约改写（`getc_nb()`）。

★ 不变量：`RXDATA` 永远不许再带回"读即弹"的副作用 —— 否则这个 bug 立刻复发。

### 9.4 彻底修法（下一轮，属于 CPU 数据通路）

给 uncacheable 读加"本次访问只发一次"的粘滞位，用**访问完成**而不是计时来清：

```verilog
logic unc_rd_done;   // 本次 uncacheable 访问已经发过读
always_ff @(posedge clk) begin
    if (reset || !cpu_en || cpu_wen || !uncacheable_req) unc_rd_done <= 1'b0;
    else if (cpu_adv)                                    unc_rd_done <= 1'b0;  // 访问被接收
    else if (mem_en)                                     unc_rd_done <= 1'b1;
end
assign cache_rd_req = cpu_en_r & ~cpu_wen_r & ~line_resident & ~mem_req_r & ~unc_rd_done;
```

注意**不能**用"地址变了"来清：轮询同一个寄存器（`while(!(RXSTAT&1));`）是合法且
常见的用法，那样会永远不发第二次读。

验收判据（改完必须重跑）：
1. `sim/tb_monitor.sv` 的 `[COUNT]` 满足 `RXDATA reads ≈ rx_pop pulses`（不再是 2:1）；
2. 全量回归 38/38；
3. CoreMark 分数不得变化（uncacheable 路径只影响 MMIO，但要确认没有把缓存读路径带坏）。
