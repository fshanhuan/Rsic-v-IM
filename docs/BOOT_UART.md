# v12（A）：串口程序引导（UART bootloader）

## 0. 为什么做这件事

改造前，程序是通过综合参数固化进 BRAM 的：

```
prog.hex --(IROM_INIT 参数)--> board/board_top_ila.sv:34 --($readmemh)--> sync_mem 的 BRAM 初值
```

也就是说 **改一行程序 = 重综合 + 重实现 + 重布线**。实测一次完整构建 **33 分钟**（11:06→11:39）。
对"调 CPU / 试程序"这种需要几十次迭代的工作来说，这是最大的成本项，比任何微架构优化都重要。

做完之后：**构建一次，之后改程序 ~1 秒**（115200 波特率下 16KB 约 1.4 s 传完）。

## 1. 方案选型（为什么是 UART 而不是 JTAG-to-AXI）

| | **UART 引导（本方案）** | JTAG-to-AXI |
|---|---|---|
| 新硬件 | 3.3V USB-TTL + 1 个空闲 PL 脚 | 无 |
| RTL | ~200 行手写 | ~40 行 + AXI 全通道手接（或引入 Block Design 改构建流程） |
| **能否先仿真** | **能**（本方案的三个场景全部在 iverilog 里跑通） | **不能**，只能上板试，每次 33 min |
| 仲裁 | **零**（引导期间 CPU 在复位、IROM 口独占） | 要处理 CPU 与 JTAG 同时访问 |
| 后续价值 | UART 是 RTOS console 的必备外设，不算额外投入 | 纯加载器 |

决定性的两点：**可仿真性** 和 **零仲裁**。实际也验证了 —— 见下面 §5，仿真抓出了两个上板后极难定位的 bug。

## 2. 结构

```
                        ┌──────────────── board_top.sv（参数 IROM_BOOT=1）─────────────────┐
 btn_rst_n ─→ reset_sync ─→ cpu_rst ─┬─→ uart_rx ─→ boot_loader ─→ (mem_we/addr/wdata) ─┐      │
                                     │                                                  │      │
                                     └─→ boot_loader.busy ──┐                           ▼      │
                                                            ├─→ cpu_rst_eff ──→ myCPU   sync_mem(IROM, READ_ONLY=0)
                                     CPU 的 irom_* ─────────┘                    （引导期由 boot_loader 独占，非引导期归 CPU）
                        └───────────────────────────────────────────────────────────────────┘
```

三块新逻辑：

| 文件 | 作用 |
|---|---|
| `board/uart_rx.sv` | 115200 8N1 接收，两级同步器 + 起始位中点复确认 + 每位中点采样 + 停止位校验 |
| `board/boot_loader.sv` | 帧协议状态机：magic → 长度 → 数据 → 校验和；两种超时；失败不变量 |
| `board/board_top.sv` | `IROM_BOOT` 参数把 IROM 从"只读"切到"可写 + 端口 mux"；`cpu_rst_eff = cpu_rst | boot_busy` |

★ **`IROM_BOOT` 默认 0**：已冻结的 v11 ILA 构建的网表完全不变，两份顶层（`board_top_gui.sv` / `board_top_gui_boot.sv`）并存互不影响。

## 3. 帧协议（宿主机 → 板，全大端，无 ACK）

| 字节 | 内容 |
|---|---|
| 0 | `0x42`（`'B'`）magic |
| 1..4 | 字数 `len`（MSB first），必须 1..4096 |
| 5..4+4·len | 每个字 4 字节，MSB first |
| 最后 4 字节 | 校验和 = **全部字按 32 位无符号累加**（不是按字节） |

三种结局：

| 情况 | 行为 |
|---|---|
| 完整且校验通过 | `ok=1`，`busy=0` → CPU 从 0x0 开始跑新程序 |
| 校验和错 / 长度非法 | `err=1`、`ok=0`，回等 magic（允许重发）；再等一个超时窗口后释放 CPU |
| 复位后 `BOOT_TMO_MS` 内没有 magic | `busy=0` → 跑 IROM 里**固化**的旧程序（板子离了主机也能独立启动） |

默认 `BOOT_TMO_MS = 5000`（5 s）：宿主机脚本从按复位到发出第一个字节经常要 1~2 s，0.5 s 会踩线。

## 4. 引脚与接线

EES-331 板上有 **PL 端的 UART 转 USB（J8）**，所以**不需要外部 USB-TTL 模块**，插一根 USB 线即可：

```
EES-331 J8（PL RS232 转 USB）              FPGA 引脚（手册"管脚约束表"）
  J8-1  PL_RS232_RX  方向 IN    ────→      **A16**   ← 本设计的 uart_rx
  J8-2  PL_RS232_TX  方向 OUT   ←────      A17       （本设计只收不发，不用）
```

- 约束：`set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports uart_rx]`
  再加 `set_property PULLTYPE PULLUP [get_ports uart_rx]` —— 没插 USB 时该脚被上拉为高，
  正好是 UART 空闲电平，不会误触发起始位。
- ★ 方向别搞反：手册里 `PL_RS232_RX` 标的是 **IN**，意思是"FPGA 收"，所以要接 A16 而不是 A17。
- ★ 历史的坑：第一版把 uart_rx 放在 **SW0 = AB6**（拨码开关脚）。拨码开关脚物理上不好引线，
  而且若开关把引脚直接接地，外部驱动高电平就是短路。板上有专用 PL 串口就没必要折腾这些。

★ 不要用 5V 的 USB-TTL：本设计按 LVCMOS33；板载 J8 桥本身就是 3.3V。


## 5. 仿真抓出的两个 bug（都是设计者自己写的，都很难靠上板定位）

构建之前用 `sim/tb_boot.sv` 把三条路径一次跑完，抓出两个"上板后只会看到板子没反应"的 bug：

**① IDLE 超时后会无限回到 IDLE → CPU 被永久按在复位里**
第一版把"IDLE 超时"也写成 `st <= S_IDLE`，于是没有 magic 时状态机在 IDLE 里空转、
`busy` 永远不落。上板表现是**上电后毫无动静**，极易误判成时钟/复位/比特流问题。
修法：超时处置**按状态区分** —— IDLE 超时 → `S_FIN`（释放）；收帧中途超时 → `S_IDLE`（允许重发），
而这次 IDLE 再超时必然走 `S_FIN`，所以最多多等一个窗口。

**② 写被复位罩住 → 校验和通过但一个字都没写进去**
`sync_mem` 的写逻辑在 `if (reset) ... else begin ... if (wen) ...` 的 **else** 分支里。
第一版把 IROM 的 `reset` 接成了 `cpu_rst_eff`（= `cpu_rst | boot_busy`），而 `boot_busy`
在引导全程为 1 → **所有写都被丢掉**。表现极具欺骗性：`ok=1`（校验和确实算对了），
但 CPU 起来后执行的是全 0 的 IROM（非法指令），看起来像"CPU 坏了"。
修法：IROM 的 `reset` **只接 `cpu_rst`**。引导期间 CPU 本来就被按住、读口 `ren` 被 mux 成 0，
所以 IROM 不跟着引导复位是安全的。

★ 这两个都属于"不报错地坏掉"，也是"先仿真再上板"这条路线最直接的收益。

## 6. 用法

```powershell
# 1) 首次（或改了任何 RTL）才需要构建：约 33 分钟
_diag\vivado_boot.ps1
#    产物：v9_boot\v9_ila.runs\impl_1\board_top_gui_boot.bit  +  .ltx

# 2) 之后改程序只要：
_diag\load_uart.ps1 -Port COM4 -Hex sim\prog.hex
#    先 DryRun 看帧头和校验和：
_diag\load_uart.ps1 -Port COM4 -Hex sim\prog.hex -DryRun
```

上板顺序：

1. 烧 `v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.bit`（`-ltx` 同目录，Hardware Manager 自动匹配）；
2. **按复位**（S1）；
3. 5 s 内跑 `load_uart.ps1`；
4. 用 ILA 确认：`probe5 = boot_busy`（应回到 0）、`probe6 = boot_ok`（应为 1）；
5. 看 `probe0/1/2/3/4`（写回）是否是新程序的写回序列。

## 7. 不变量（改之前必读）

1. `uart_rx.BAUD` 与宿主机脚本的 `-Baud` 必须一致（默认 115200）；
   `BIT_TICKS = round(CLK_FREQ/BAUD)`，改 CPU 时钟频率必须同步改 `CLK_FREQ`。
2. 帧格式三处必须一致：`boot_loader.sv` 头注释、`load_uart.ps1`、本文档。校验和是**按字累加**。
3. **任何**失败路径最终都必须让 `busy` 回到 0（否则板子永久停在复位）。
4. 引导期间 CPU 必须在复位、IROM 读口必须是 0（否则会读到写了一半的镜像）。
5. IROM 从**只读**变成**可写**后，逻辑上就不存在"取指缓存一致性"问题了 —— 因为
   `rtl/ICache.sv` 已旁路（未例化）。**如果将来重新启用 ICache，必须先处理 fence.i 与可写 IROM 的冲突**，
   否则会执行到缓存里的旧指令。
6. `IROM_BOOT=0` 时网表必须与 v11 完全一致（已用预检 + 参数默认值保证）。

## 8. 验证记录

| 项目 | 结果 |
|---|---|
| `sim/tb_uart_dbg.sv`（UART 单测） | 4/4 字节正确（0x42/0xA5/0x00/0xFF） |
| `sim/tb_boot.sv`（端到端三场景） | **ALL PASS**：①正常镜像 → `ok=1` 且 CPU 跑到新程序（x10=42、x11=99）；②校验和错 → `err=1`、`ok=0`、`busy` 正确释放；③不发数据 → 超时后跑 IROM 固化程序（x1=1、x2=2） |
| elaboration 预检（`_diag/preflight_stubs.sv`） | iverilog 0 errors，端口/位宽/参数全对 |
| `_diag/chk_xdc.py v9_board_boot.xdc` | ENCODING / XDC-LEGAL / TCL-SYNTAX 全 PASS |
| 上板 | 见 `docs/优化_v11_进度.md` 轮次 4 |

## 9. 宿主机侧踩的三个坑（与 RTL 无关，但每次都很费时间）

**① `.ps1` 里绝对不能写中文 —— 否则报的错完全对不上文件**
给 `load_uart.ps1` 加了几行中文注释后，PowerShell 报

```
load_uart.ps1:125 char:6
+     } else {
The Try statement is missing its Catch or Finally block.
```

而文件第 125 行根本不是 `} else {`。根因：PowerShell 5.1 按 **OEM 代码页(936)** 解码
无 BOM 的 UTF-8，中文的第二个字节可能吞掉引号/花括号，于是报错行号整体错位。
**结论：`.ps1` 必须纯 ASCII**（脚本里已加醒目注释），中文说明写在本文档。
检查方式：`([regex]::Matches($t,'[^\x00-\x7F]')).Count` 必须为 0。

**② `-band 0xFFFFFFFF` 在 PowerShell 里等于没做掩码**
`0xFFFFFFFF` 被解析成 Int32 = **-1**，与 uint64 相与是恒等操作，于是校验和累加越过 2^32，
随后 `[uint32]` 转换抛异常。改成 `% 4294967296`。**校验和口径必须与 `boot_loader.sv` 的
32 位回绕加法一致**，宿主机和 RTL 各错一半是最难查的组合。

**③ 一帧的传输时间极易算错 → 窗口错过**
一帧 4 字 = 25 字节 = **2.17 ms**（不是几十毫秒）。第一版用"发 N 次"来对齐烧录，
900 帧只花了 6.5 s，而烧录完成在 30 s 之后 —— 窗口开的时候帧早发完了。
现在 `load_uart.ps1` 支持 **`-DurationSec`**：连续发 N 秒，烧录/复位落在区间内即可。

## 10. 顺带并入的 B 项改动（v12 第二批）

| 改动 | 文件 | 为什么 |
|---|---|---|
| D-Cache 命中计数把 **store 命中**也算进去 | `rtl/DCache.sv:256-267` | 原来 `hit_now` 里带 `~cpu_wen`，store 命中走 `store2_hit` 却**没人计数** ⇒ 一轮 `sw+lw` 只涨 1，用计数器反推访存次数会少一半 |
| `RegisterFile` 内部加 x0 写门 | `rtl/RegisterFile.sv:30` | 原来 x0 只靠"写数据侧把 rd==0 钳成 0"保着（`Reg_Stack.sv:78`）；`jal x0`/`ecall` 的 writeback 确实带 `ena=1,reg=x0`，一旦将来加调试写口就会静默破坏 x0。现在两处互不依赖 |

★ 两项都是**周期中性**的：回归 23/23 PASS 且周期数完全不变
（prog 35 / mul 42 / div 46 / load_lane 54 / load_use 77 / loop 110 / div_pair 97）。

★ 原本计划的 "probe 重排（ICache 计数 → IFU_stall/LSU_hold）" **推迟**：
本版 probe5/6 放的是 `boot_busy/boot_ok`，还要靠它们确认串口加载是否成功；
等加载确认后用一次构建把它们换成停顿类信号。

## 11. 上板实测结果（2026-10-18 14:43 / 14:46）

**构建**：`_diag/vivado_boot.ps1`，14:06→14:42 出 bitstream，`RESULT build OK`；
WNS **1.039 ns** / WHS 0.010 / THS 0 / TNS 0。`board_top_gui_boot.bit` 4 045 694 B，
`.ltx` 同目录。综合日志里那条 `ERROR: [Common 17-354] Could not open '.' for writing.`
**仍然出现且无害** —— 直接查了 IROM 的 `INIT_00`（`...9313B7`，正是 `prog.hex` 的低字节），
初值确实写进了 BRAM。

**串口**：板载 J8 的桥是 **CP210x → COM9**（插上 J8 后新出现）；
COM13 是另一个独立 USB-TTL（FTDI），**没接到板上** —— 第一次往 COM13 发是打空。

| 测试 | 镜像 | 结果 |
|---|---|---|
| ① 加载 demo 程序 | `sim/prog_boot_demo.hex`（4 字 / 25 字节 / cks 0x10200128） | `boot_ok=1`、`boot_busy=0`；写回 **x10=42 / x11=99 / x12=127**；PC 集合 `0x0..0xc`；**4 拍一轮 = 1 条/拍** |
| ② 换一个程序重灌 | `sim/prog.hex`（14 字 / 65 字节 / cks 0x8848D23A） | `boot_ok=1`；写回 x1=0x1000 / x5=0x23 / x10=0x3f；PC 集合 = 14 条程序全序列 |

结论：**改程序从 33 分钟的构建降到 ~1 分钟的下载**（`boot_verify.ps1 -Port COM9` 一条命令）。

★ 重载的通路：烧录（重新配置 FPGA）会复位设计 → 引导窗口打开；**按 S1 复位键**同样会打开窗口
（`boot_loader` 被 `cpu_rst` 复位回 S_IDLE），而 IROM 阵列不会被复位清空，所以
"按 S1 → 跑加载器"就能换程序。远程验证用的是烧录触发的复位（我按不到按钮）。

★ 一个 **分析脚本的坑**：`an_ila_boot.py` 原来把 demo 程序的三条写回写死成期望值，
拿它去判 `prog.hex` 那次会误报"未生效"。现在支持 `python _diag/an_ila_boot.py prog`。
**别把"判据写死"当成"结果正确"** —— 这次是靠人工看 x1=0x1000 才发现的。

---

## 12. ★★ 帧同步缺陷：连续字节流里"扫描 magic"是不可靠的（v13 上板暴露）

### 12.1 现象

同一份 bitstream、同一套 `board_run.ps1`，灌 CoreMark **三次里只成功一次**。
失败时的 ILA 读数（`debug_status`，probe5）：

```
0x001FF880  →  bit7 IDU_ready=1
               bit8 boot_busy=0   bit9 boot_ok=0   bit10 boot_err=0
               bits20:11 boot_rx_cnt = 0x3FF（**已饱和**：至少收到 1023 字节）
```

`busy=0 / ok=0 / err=0` 这个组合很关键：`err` 是 0 说明**没走超时路径**
（超时会 `err<=~have_r`），也没走校验失败路径。全代码里只有一条路能让三者同时为 0：
**S_IDLE 里收到 `'G'`** → `st<=S_FIN; ok<=have_r(=0)`，而 S_FIN 只清 busy、不碰 err。

### 12.2 根因

`boot_loader` 的 S_IDLE 是**在一条连续字节流里逐字节扫描 magic** 的：

* `'B'`(0x42) / `'C'`(0x43) / `'G'`(0x47) 都是**单字节** magic；
* 载荷（指令/数据）里天然有这些字节 —— 实测一份 67 886 B 的 CoreMark 会话里
  `'B'×10 / 'C'×27 / 'G'×79`；
* 而 FPGA **配置完成的瞬间**，宿主正发到流的任意位置（会话本身 5.9 s），
  于是 loader 上电后看到的第一个 magic-like 字节决定命运：

| 先撞上 | 后果 |
|---|---|
| `'G'` | **当场报废**：`st<=S_FIN`，此后所有帧被忽略，CPU 一直跑固化程序（旧版无条件响应 `'G'`）|
| `'B'`/`'C'` | 按"垃圾长度"写垃圾；长度越界就 `err=1` 回 S_IDLE，越界失败的概率其实很高（4 字节随机 < 16384 的概率约 4e-6），但载荷里的 `00 00 xx xx` 会把这个概率放大 |
| 真正的会话起点 | 成功（`off=0`）|

### 12.3 零成本复现（不插板）

```bash
python sw/gen_boot_stream.py sw/build/cm_irom.hex sw/build/cm_dram.hex sim/cm_stream.hex --sessions 2
#   → magic-like bytes inside ONE session: 'B'=10 'C'=27 'G'=79
iverilog -g2012 -I rtl -I board -o _diag/tb_boot_scan.vvp sim/tb_boot_scan.sv board/boot_loader.sv
vvp -n _diag/tb_boot_scan.vvp +stream=sim/cm_stream.hex +off=0      # 成功
vvp -n _diag/tb_boot_scan.vvp +stream=sim/cm_stream.hex +off=5000 +trace
```

`+off=` 就是"配置落在流的第几个字节"。修复前的实测结果：

```
SCAN off=0     w_irom=32768 w_dram=1166 ok=1 err=0 busy=0   ← 只有正好落在会话起点才行
SCAN off=40    w_irom=0     w_dram=0    ok=0 err=1 busy=0 fin_at=543
SCAN off=200   w_irom=0     w_dram=0    ok=0 err=0 busy=0 fin_at=383
SCAN off=5000  w_irom=0     w_dram=0    ok=0 err=0 busy=0 fin_at=619   ← 板上就是这一行
```

`+trace` 直接打出"哪一拍跳进 S_FIN"，不用猜。

### 12.4 对策演进（v13.1 → v13.3，最终形态）

**v13.1（过渡）**：`'G'` 必须 `have_r=1` 才认 + 宿主发 0x00 前导。
前者去掉了"假 `'G'` 当场报废"，后者让宿主总能从帧边界开始；
但 0x00 前导要发满"编程耗时"（100 s），而且假 `'C'` 仍能吞掉真帧
（`tb_boot_scan off=5000` 当时的结果是 `ok=1` 但 IROM 没灌）。

**v13.3（最终，已实现）**：给帧加**帧首静默**（Modbus-RTU 同款）——
`boot_loader` 只在"线路静默 ≥ `SOF_SILENCE_MS`（默认 1 ms）"之后才认 magic。

```verilog
// board/boot_loader.sv
localparam integer SOF_SIL = (CLK_FREQ / 1000) * SOF_SILENCE_MS;   // 1 ms = 50 000 拍
assign sil_ok = (sil_cnt >= SOF_SIL_C);
S_IDLE: begin
    if (rx_valid && sil_ok) begin ... end     // 无静默 = 不认命令
end
```

为什么它比"双字节 magic"好：双字节只是把误判概率从 1/256 降到 1/65536，
而静默是**语义上**不可能误判 —— 载荷内部的字节流不允许出现静默
（帧内相邻字节只隔 87 µs）。

配套（缺一不可）：
* 宿主每个帧之前插空隙：`_diag/load_uart.ps1 -FrameGapMs 50`（默认 50 ms）。
  会话因此变成"分段发送"：`'B'` 帧 → 空隙 → `'C'` 帧 → 空隙 → `'G'`。
* `sim/tb_boot.sv` 同步改成"帧前留 2 ms 空隙"，并把等 magic 的窗口从 1 ms 提到 50 ms。
* 新增 `sim/tb_boot_sync.sv` 专项单测（进回归）：证明**一个内容完全合法、
  但前面没有静默的帧会被彻底忽略**，且不会把会话打进 `S_FIN`。

**宿主侧的另一半：稀疏保活**。引导窗口是 5 s 空闲超时，而编程要 53~57 s，所以宿主
必须在编程期间"喂"点东西让 loader 别超时。现在喂的是 **1 个 0x00 / 50 ms**（约 20 字节/秒），
并且**编程一结束就停**（`board_run.ps1` 落一个 `program.done` 标记文件，
`load_uart.ps1 -PadUntilFile` 等它）—— 于是"从配置完成到开始灌镜像"的等待从 100 s
降到 ~0，换一个程序总共 ~7 s。稀疏还有第二个好处：不会在驱动里积压一堆字节，
否则那些字节会推迟静默空隙。

### 12.5 残余风险与仍然有效的规则

* 静默门限（1 ms）必须**明显小于**宿主的帧间空隙（50 ms），且**明显大于**帧内字节间隔
  （87 µs）。改任何一个都要同时看另外两个。
* `tb_boot_scan.sv` 现在**故意关掉静默**（`.SOF_SILENCE_MS(0)`），因为它测的是
  "没有帧同步时的裸扫描行为"——那是历史缺陷的复现手段，别把它当成生产配置。
* 如果哪天要换回"连续流"的宿主（不分段），就必须把 `SOF_SILENCE_MS` 设 0，
  并且重新接受"配置瞬间决定成败"这个前提。

### 12.6 更省事的一条路：软件重新引导（v13.4 / P3）

不用重配 FPGA 也能换程序：板上跑 `sw/monitor.c` 时，串口发 `b`（或任何程序写
`0x1000_0014` bit0），loader 会被重新武装，宿主随即灌镜像：

```powershell
_diag\board_run.ps1 -Port COM9 -SkipProgram -PreCmd b `
    -Hex sw\build\memtest_irom.hex -DramHex sw\build\memtest_dram.hex -Repeat 2 -NoGo
```

细节见 `docs/CHECKPOINT_v13.md` §7b。
