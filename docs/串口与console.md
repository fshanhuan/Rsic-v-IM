# 串口 / 时基 / console 与 GPIO

> **适用对象**：当前代码（v17）。三份原始设计记录（v12 时期）已按主题合并到本文，
> 内容未删改，只做标题层级归一。
>
> 相关文档：[开发记录](开发记录.md)（本轮改动与验收）、[C 工具链与 RTOS](C_工具链与RTOS.md)、
> [模块说明](模块说明.md)、[../README.md](../README.md)。
>
> 速查：UART **115200 8N1**；MMIO 基址 `0x1000_0000`（+0x00 TXDATA / +0x04 TXSTAT /
> +0x08 RXDATA / +0x0c RXSTAT / +0x10 LED / +0x14 BOOTREQ / +0x18 RXPOP）；时基 `mtime` **500 kHz**。



---

## 1. 串口引导（UART boot loader）

> 上电后由 host 通过 UART 把程序镜像写进 IROM，校验通过后释放 CPU 从 0 地址取指。

原文：`docs/BOOT_UART.md`（v12 时期，已合并）

### 0. 为什么做这件事

改造前，程序是通过综合参数固化进 BRAM 的：

```
prog.hex --(IROM_INIT 参数)--> board/board_top_ila.sv:34 --($readmemh)--> sync_mem 的 BRAM 初值
```

也就是说 **改一行程序 = 重综合 + 重实现 + 重布线**。实测一次完整构建 **33 分钟**（11:06→11:39）。
对"调 CPU / 试程序"这种需要几十次迭代的工作来说，这是最大的成本项，比任何微架构优化都重要。

做完之后：**构建一次，之后改程序 ~1 秒**（115200 波特率下 16KB 约 1.4 s 传完）。

### 1. 方案选型（为什么是 UART 而不是 JTAG-to-AXI）

| | **UART 引导（本方案）** | JTAG-to-AXI |
|---|---|---|
| 新硬件 | 3.3V USB-TTL + 1 个空闲 PL 脚 | 无 |
| RTL | ~200 行手写 | ~40 行 + AXI 全通道手接（或引入 Block Design 改构建流程） |
| **能否先仿真** | **能**（本方案的三个场景全部在 iverilog 里跑通） | **不能**，只能上板试，每次 33 min |
| 仲裁 | **零**（引导期间 CPU 在复位、IROM 口独占） | 要处理 CPU 与 JTAG 同时访问 |
| 后续价值 | UART 是 RTOS console 的必备外设，不算额外投入 | 纯加载器 |

决定性的两点：**可仿真性** 和 **零仲裁**。实际也验证了 —— 见下面 §5，仿真抓出了两个上板后极难定位的 bug。

### 2. 结构

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

### 3. 帧协议（宿主机 → 板，全大端，无 ACK）

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

### 4. 引脚与接线

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


### 5. 仿真抓出的两个 bug（都是设计者自己写的，都很难靠上板定位）

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

### 6. 用法

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

### 7. 不变量（改之前必读）

1. `uart_rx.BAUD` 与宿主机脚本的 `-Baud` 必须一致（默认 115200）；
   `BIT_TICKS = round(CLK_FREQ/BAUD)`，改 CPU 时钟频率必须同步改 `CLK_FREQ`。
2. 帧格式三处必须一致：`boot_loader.sv` 头注释、`load_uart.ps1`、本文档。校验和是**按字累加**。
3. **任何**失败路径最终都必须让 `busy` 回到 0（否则板子永久停在复位）。
4. 引导期间 CPU 必须在复位、IROM 读口必须是 0（否则会读到写了一半的镜像）。
5. IROM 从**只读**变成**可写**后，逻辑上就不存在"取指缓存一致性"问题了 —— 因为
   `rtl/ICache.sv` 已旁路（未例化）。**如果将来重新启用 ICache，必须先处理 fence.i 与可写 IROM 的冲突**，
   否则会执行到缓存里的旧指令。
6. `IROM_BOOT=0` 时网表必须与 v11 完全一致（已用预检 + 参数默认值保证）。

### 8. 验证记录

| 项目 | 结果 |
|---|---|
| `sim/tb_uart_dbg.sv`（UART 单测） | 4/4 字节正确（0x42/0xA5/0x00/0xFF） |
| `sim/tb_boot.sv`（端到端三场景） | **ALL PASS**：①正常镜像 → `ok=1` 且 CPU 跑到新程序（x10=42、x11=99）；②校验和错 → `err=1`、`ok=0`、`busy` 正确释放；③不发数据 → 超时后跑 IROM 固化程序（x1=1、x2=2） |
| elaboration 预检（`_diag/preflight_stubs.sv`） | iverilog 0 errors，端口/位宽/参数全对 |
| `_diag/chk_xdc.py v9_board_boot.xdc` | ENCODING / XDC-LEGAL / TCL-SYNTAX 全 PASS |
| 上板 | 见 `docs/优化_v11_进度.md` 轮次 4 |

### 9. 宿主机侧踩的三个坑（与 RTL 无关，但每次都很费时间）

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

### 10. 顺带并入的 B 项改动（v12 第二批）

| 改动 | 文件 | 为什么 |
|---|---|---|
| D-Cache 命中计数把 **store 命中**也算进去 | `rtl/DCache.sv:256-267` | 原来 `hit_now` 里带 `~cpu_wen`，store 命中走 `store2_hit` 却**没人计数** ⇒ 一轮 `sw+lw` 只涨 1，用计数器反推访存次数会少一半 |
| `RegisterFile` 内部加 x0 写门 | `rtl/RegisterFile.sv:30` | 原来 x0 只靠"写数据侧把 rd==0 钳成 0"保着（`Reg_Stack.sv:78`）；`jal x0`/`ecall` 的 writeback 确实带 `ena=1,reg=x0`，一旦将来加调试写口就会静默破坏 x0。现在两处互不依赖 |

★ 两项都是**周期中性**的：回归 23/23 PASS 且周期数完全不变
（prog 35 / mul 42 / div 46 / load_lane 54 / load_use 77 / loop 110 / div_pair 97）。

★ 原本计划的 "probe 重排（ICache 计数 → IFU_stall/LSU_hold）" **推迟**：
本版 probe5/6 放的是 `boot_busy/boot_ok`，还要靠它们确认串口加载是否成功；
等加载确认后用一次构建把它们换成停顿类信号。

### 11. 上板实测结果（2026-10-18 14:43 / 14:46）

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

### 12. ★★ 帧同步缺陷：连续字节流里"扫描 magic"是不可靠的（v13 上板暴露）

#### 12.1 现象

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

#### 12.2 根因

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

#### 12.3 零成本复现（不插板）

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

#### 12.4 对策演进（v13.1 → v13.3，最终形态）

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

#### 12.5 残余风险与仍然有效的规则

* 静默门限（1 ms）必须**明显小于**宿主的帧间空隙（50 ms），且**明显大于**帧内字节间隔
  （87 µs）。改任何一个都要同时看另外两个。
* `tb_boot_scan.sv` 现在**故意关掉静默**（`.SOF_SILENCE_MS(0)`），因为它测的是
  "没有帧同步时的裸扫描行为"——那是历史缺陷的复现手段，别把它当成生产配置。
* 如果哪天要换回"连续流"的宿主（不分段），就必须把 `SOF_SILENCE_MS` 设 0，
  并且重新接受"配置瞬间决定成败"这个前提。

#### 12.6 更省事的一条路：软件重新引导（v13.4 / P3）

不用重配 FPGA 也能换程序：板上跑 `sw/monitor.c` 时，串口发 `b`（或任何程序写
`0x1000_0014` bit0），loader 会被重新武装，宿主随即灌镜像：

```powershell
_diag\board_run.ps1 -Port COM9 -SkipProgram -PreCmd b `
    -Hex sw\build\memtest_irom.hex -DramHex sw\build\memtest_dram.hex -Repeat 2 -NoGo
```

细节见 `docs/CHECKPOINT_v13.md` §7b。

---

## 2. Zicntr 计数器与 UART 发送

> 机器模式计数器（mtime/mtimecmp/mcycle/minstret）与 console 发送通路的设计记录。

原文：`docs/ZICNTR_UART.md`（v12 时期，已合并）

> 目标：把板子从"能跑"变成**能测**。
> Tier 1 四项一次构建交付：
> 1. **Zicntr**：`mcycle` / `minstret`（64 位，可读写）+ 只读影子 `cycle`/`time`/`instret`；
> 2. **UART TX**（115200 8N1，MMIO `0x1000_0000`），软件可以 `sw` 一个字节打出来；
> 3. **状态字探针**（`debug_status`）：把 8 个 1 位量压进一根已有的 32 位探针，
>    不重建 ILA IP、不改任何分析脚本的列号；
> 4. **`trap_seen` 粘滞位**：抓"第一次陷入"不再靠赌抓包恰好停在那 1 拍。

---

### 0. 为什么先做这两件（动机，不是"顺手加的"）

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

### 1. Zicntr：寄存器与语义

#### 1.1 地址与权限

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

#### 1.2 `time` / `timeh` 的口径（有意简化，必须写清楚）

`time` 映射到已有的 `mtime`（32 位、500 kHz）。`timeh` **读 0**。

为什么不做 64 位：`mtime` 只做了 32 位。如果 `timeh` 编造高位，
软件用 `time` 算出来的墙钟就是错的（而且是"看起来正常、其实是错"的那种）。
按规范，"不实现"的正确表达是**读 0**，这与 `mimpid`/`mconfigptr` 的处理口径一致。

#### 1.3 写优先于自增

```
if (reset)                       mcycle_reg <= 0;
else if (csr_wen[CSRW_MCYCLE])   mcycle_reg[31:0]  <= csrd;
else if (csr_wen[CSRW_MCYCLEH])  mcycle_reg[63:32] <= csrd;
else                             mcycle_reg <= mcycle_reg + 1;
```

写的那个时钟沿**不自增**。反过来（自增后覆盖）会让 `csrw mcycle, 0` 读回 1，
软件无法用它做精确基准。`mtime` 早就是"写优先"口径，这里保持一致。

#### 1.4 `minstret` 的计数使能：`retire`，不是 `WBU_valid`

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

#### 1.5 CSR RAW 前递：别名必须映射到同一个 onehot 位

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

#### 1.6 代价

- 128 个 FF（两个 64 位计数器）+ 两个 64 位增量器；
- `retire` 是 WB→ID 的 1 位控制信号，**只喂 FF 使能**，不构成组合长路径；
- LUT 增量在 util 报告的噪声范围内（见第 6 节实测）。

---

### 2. UART TX：把 `sw` 变成一串字节

#### 2.1 MMIO 地址

| 地址 | 名字 | 方向 | 内容 |
|---|---|---|---|
| `0x1000_0000` | `TXDATA` | WO | 写 → 低 8 位入发送器（忙时**丢弃**，不排队） |
| `0x1000_0004` | `STATUS` | RO | `bit0 = busy`（1 = 上一帧还没发完） |

★ 为什么是 `0x1000_0000`：DCache 的 `UNCACHE_MASK` 默认 `0x0FFF_FFFF`，
**地址 ≥ 0x1000_0000 自动走 MMIO 通路**（不分配缓存行、读直通外设）。
DRAM 只有 64 KB（`perip_addr[15:2]` 索引），两者地址空间天然不重叠，
所以板级只需要一个窗口译码，DCache 一行都不用改。

#### 2.2 译码与"必须门掉 DRAM 写"

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

#### 2.3 发送器本身（`board/uart_tx.sv`）

- 参数与 `uart_rx.sv` **完全一致**（`CLK_FREQ=50_000_000`, `BAUD=115200`），
  `BIT_TICKS = (CLK_FREQ + BAUD/2)/BAUD = 434`，误差 0.007%；
- 帧 = 起始位(0) + 8 数据位(LSB first) + 停止位(1) = 10 位 = **4340 拍 = 86.8 µs**；
- `tx` 空闲态为 **1**（UART 规定，反了对面永远等不到起始沿）；
- `busy = (state != S_IDLE)`，软件靠轮询 `STATUS.bit0` 做流控；
- 忙时的 `send` **静默丢弃**：这是外设寄存器的正常语义（写了就写，不排队），
  软件必须自己轮询。有 `tb_uart_tx` 的 T4 专门验这一条。

---

### 3. 状态字探针（`debug_status`）与 `trap_seen`

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

### 4. 仿真验证（全部 iverilog，先仿真再上板）

新增两个测试台 + 一个新用例，都已并入 `_diag/regress.ps1`：

| 测试台 | 判据 | 结果 |
|---|---|---|
| `sim/tb_sys.sv +kind=zicntr` | 15 条（见下） | **PASS** |
| `sim/tb_uart_tx.sv` | 11 条，回环 tx→rx | **PASS** |
| `sim/tb_board_top_uart.sv` | 6 条，板级端到端 | **PASS** |

#### 4.1 `tb_sys +kind=zicntr`（15 条全过）

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

#### 4.2 `tb_uart_tx`（11 条全过）

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

#### 4.3 `tb_board_top_uart`（6 条全过，板级端到端）

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

### 5. 回归结果

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

### 6. 综合/实现结果（见第 8 节的实测数字）

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

### 7. 上板怎么用

#### 7.1 打印一个字符

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

#### 7.2 量一段代码的拍数（不用改被测代码）

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

#### 7.3 读停顿时长

probe5 = `debug_status`，按位读：

- bit0/bit1：前端是否被冻结、是不是访存缺失造成的；
- bit2：是不是 MDU 在跑（乘除 17 拍）；
- bit3：这次重定向是"系统指令/异常"还是"分支预测失败"（判读方向完全相反）；
- bit4：**复位后是否已经出过一次异常**（粘滞，不会漏）。

---

### 8. 实测结果（构建）

#### 8.1 构建（`_diag/vivado_boot.ps1` → `v9_boot`，2026-10-18 16:36）

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

#### 8.2 面积（post-route）

| 资源 | 用量 | 占比（xc7z020） |
|---|---|---|
| Slice LUTs | 35 620 | 66.95 % |
| Slice Registers | 22 717 | 21.35 % |
| Block RAM Tile | 38.5 | 27.50 % |
| DSP48E1 | 4 | 1.82 % |

Zicntr 本身的代价可以按构造算：2 × 64 位计数器 = **128 个 FF**
+ `uart_tx` 约 30 个 FF + `trap_seen` 1 个。LUT 的增量在噪声里
（两个 64 位增量器各 ~33 个 CARRY4/LUT）。

#### 8.3 产物

| 文件 | 大小 |
|---|---|
| `v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.bit` | 4 045 694 B |
| `v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.ltx` | 70 007 B |

★ `.ltx` 里确认了 probe5 = `debug_status`、probe6 = `debug_mcycle`
（`portIndex` 5/6，`boot_busy32`/`boot_ok32` 已不存在）——
所以 CSV 的列名会变成 `debug_status[31:0]` / `debug_mcycle[31:0]`，
`_diag/an_ila_boot.py` 已按新列名实现（并保留旧列名的回退分支）。

#### 8.4 上板验证 —— **已通过**（2026-10-18 16:49）

板子接上之后按 §8.4b 的顺序跑，一次成功。证据分三段。

##### （1）串口引导 + console：程序真的"打印"出来了

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

##### （2）Zicntr：`mcycle` 在真板上每拍 +1

`_diag/capture_ila.tcl`（`ILA_LTX` 指向 boot 版 ltx）抓 2048 个采样 = **41.0 µs**：

```
mcycle: 起=2635246542  止=2635248589  跨度=2047 拍
  逐拍差分：2047/2047 个差值为 1        ← 全部为 1，没有一拍漏数
```

这是"计数器真的在数拍"的硬证据 —— 仿真里只能证明它按预期建模，这里证明**硅片上**也这样。

##### （3）状态字：这段代码**一次停顿都没有**

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

##### ★ 上板时踩到的一个坑（不报错、但结果全错）

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

#### 8.4b 上板命令（复现用）

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

### 9. 明确没做的事（避免"看起来支持"）

| 项 | 状态 | 说明 |
|---|---|---|
| `time` 64 位 | **不做** | `mtime` 只有 32 位；`timeh` 读 0，不编造高位 |
| UART 接收（`uart_rx` 给 CPU 读） | **不做** | 现在的 `uart_rx` 只服务 boot loader；要加 console 输入需要再开一个 MMIO 窗口 + FIFO |
| UART 发送 FIFO | **不做** | 一个字节 87 µs，加 FIFO 不改变可观测行为；等要打整段 trace 再说 |
| `minstret` 排除陷入指令 | **不做** | 差 1/次陷入，对性能测量无影响（见 1.4） |
| ILA 探针宽度调整 | **不做** | 状态字压进已有的 32 位探针，避免重建 IP 与改分析脚本 |

---

### 10. 文件清单（v12（B）改动）

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

---

## 3. console 收发与 GPIO

> RXDATA 幂等 peek + RXPOP 出队、8 深 RX FIFO、LED 与两块必须说清楚的不变量。

原文：`docs/CONSOLE_GPIO.md`（v12 时期，已合并）

> 本轮目标（Tier 1 之后的第一步）：**让平台能对话、能看**。
> 交付：串口**接收**（8 深 FIFO）+ 7 个 LED 的 GPIO，一份自己的 console 演示程序
> （横幅 / 回显 / 定时器中断心跳）。
>
> 另外两件比代码本身更重要：
> - §5：**"load-use 0 拍前递"这个需求在本微架构下不成立**，附证据；
> - §6：仿真中发现一个**可疑的分支行为**（handler 里 not-taken 分支之后的指令
>   不执行），已定位到最小复现，但**没有**在本轮修掉 —— 记在这里当待办。

---

### 1. MMIO 映射（在 v12（B）基础上扩展）

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

### 2. 接收通路：为什么是"第二个 uart_rx + 8 深 FIFO"

#### 2.1 两个接收器，不是一份共享

`board/uart_rx.sv` 的 `valid` 是**单拍脉冲**，两个消费者（boot_loader / console FIFO）
之间没有握手。共用一份就变成"谁先看到谁拿走"：

- 引导期间 console FIFO 会把镜像帧的字节吞掉（镜像直接坏掉）；
- 反过来 console 数据也可能被 boot_loader 当成帧头。

加仲裁能解决，但代价大于收益 —— **两个接收器各监听同一根线**，
每个约 15 个 FF，零交互。console 那一份的 `rst` 接 `cpu_rst_eff`，
引导期间整体保持复位，镜像帧一个字节也进不来。

#### 2.2 弹出必须**延迟一拍**

```
rx_pop_req <= perip_ren & mmio_sel & (idx == 2) & rx_avail;   // 寄存一拍
rx_pop      = rx_pop_req;
```

原因：DCache 的读是**两拍契约** —— 请求拍给 `perip_ren` 脉冲，
**下一拍**才采 `perip_rdata`。如果在请求当拍就动 FIFO 头指针，
采样那拍读到的已经是下一个字节，症状是"每读一次丢一个字节"。

#### 2.3 满了就丢，但置溢出位

`rx_cnt == 8` 时新字节**丢弃**，并把 `RXSTAT.bit1` 置 1（读一次清）。

★ 不覆盖已有数据：覆盖会让软件读到"看起来正常、其实是后来那个字节"的错误序列，
比丢字节难查得多。

#### 2.4 代价

| 项 | 数量 |
|---|---|
| console `uart_rx` | ~15 FF |
| RX FIFO（8×8 位 + 指针 + 计数 + 溢出位） | ~36 FF |
| LED 寄存器 | 7 FF |

---

### 3. 软件：`sim/gen_console_demo.py`

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

#### 3.1 生成器自带一个两遍汇编

`puts` 的返回判断和 handler 结束都要**前向引用**。第一版用"同地址覆盖"硬凑，
把自己绕晕了（生成出来还留着旧指令）；改成"先记录待回填的跳转、最后统一解算"
反而只有 20 行。

#### 3.2 踩过的两个坑（都够隐蔽）

1. **把字符串放在 IROM，然后用 `lw` 去读** —— 本核的 IROM 和 DRAM 是
   **两套独立地址空间**（IROM 只能取指、DRAM 只能读写）。`lw 0x200` 读到的是
   DRAM 里的 0，于是 `puts` 一个字节都不打（横幅完全消失，但程序不报错）。
   正确做法：启动时用立即数把字符串写进 DRAM（`sim/gen_console_demo.py` 里
   `for k, w in enumerate(pack_string(BANNER))` 那一段）。
2. **`puts` 只打了一个字就返回** —— 本字内右移 4 次后没有回到"取下一个字"，
   实测横幅只有 `BigB`。修法是加一个 4 字节计数器，用完 `jal` 回 `puts` 开头。

---

### 4. 验证

#### 4.1 `sim/tb_console.sv`（6 条判据全过）

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

#### 4.2 全量回归

```
[REGRESSION] ALL PASS (28 runs)
```

7 个基准程序拍数仍是一个没变（35/42/46/54/77/110/97）——
本轮 RTL 只动了板级（MMIO/GPIO），没碰 CPU 数据通路。

---

### 5. 为什么**没有**做"load-use 0 拍前递"

这是本轮开工时的第一项计划，做到一半发现**需求本身与本微架构矛盾**，如实记录：

#### 5.1 现在的时序

设 load 指令在 `EXU@0 → M1@1 → M2@2`，消费者在 `IDU`：

| 周期 | load 在 | 消费者在 | 消费者能否拿到数据 |
|---|---|---|---|
| 0 | EXU | IDU | ✗ 地址都还没算出来 |
| 1 | M1 | IDU（停） | ✗ DCache 请求这一拍才发出去 |
| 2 | M2 | IDU（停） | ✓ `3'b101` 前递 M2 真值（`rdata_ex_pipe`） |

所以消费者在 IDU **停 2 拍**（`exu_load_use | mem_load_use`），第 3 拍进 EXU。
这就是现在的行为，`Data_hazard.sv:129` 的 `load_use_stall = exu_load_use | mem_load_use`。

#### 5.2 关键事实：DCache 是 **M2 打的**

```
// rtl/LSU.sv:199
assign addr = {Ex_result_addr_reg_pipe[31:18], 2'b00, Ex_result_addr_reg_pipe[15:0]};
                          ^^^^^ M2 的寄存器
```
`cpu_en/cpu_addr` 全部取自 **M2**，所以 DCache 的数据属于 **M2 那条指令**。
`LSU_Rdata`（M1 级的 `rdata_ex`）因此和 M1 的地址是**错位的**，
它接到 `Control.MEM_Rdata` 却**没有任何读者**（综合报告里那条
`Port MEM_Rdata[31] ... has no load` 就是它）。

#### 5.3 结论

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

### 6. ★ v12-BUG-1（已定位并修复）：更年轻的 `mret` 吞掉更老分支的误预测

#### 6.1 现象

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

#### 6.2 分离：普通代码没问题，问题只在中断上下文

新建了 `sim/gen_brsel_progs.py` + `sim/tb_mini.sv`（最小观察台：只有 CPU + IROM +
DRAM 模型，跑一个 hex 后 dump 寄存器）：

| 程序 | 模式 | 结果 |
|---|---|---|
| `brsel_a` | 普通代码：`andi` → `bne`（1 条间隔）→ 条件 `addi` | x6 = **10** ✓ |
| `brsel_b` | 同上，中间插 nop | x6 = **10** ✓ |
| `brsel_c` | 条件执行的是一条 `sw` | x6 = **10**、x7 = **9** ✓ |
| `brsel_h` | **同样的动态模式放进定时器中断处理程序** | x6 = **0**（应为 1）✗ |

所以：**不是"not-taken 分支"本身的问题，而是"中断上下文 + 紧跟其后的指令"**。

#### 6.3 用 `+win` 抓流水级，一条一条看

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

#### 6.4 根因

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

#### 6.5 修复

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

#### 6.6 验证

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

#### 6.7 构建 + 上板（含修复）

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

### 7. 构建结果（2026-10-18 18:09）

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

### 8. 上板验证（2026-10-18 18:10）

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
