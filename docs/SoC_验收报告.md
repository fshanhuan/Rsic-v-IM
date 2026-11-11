# SoC 验收报告（A1–A4 + 软件段）

> 一页看完：做了什么、拿什么证明、还差什么。
> 全部数字来自本仓库的回归与 Vivado 报告，可复现命令在文末。

---

## 1. 一句话结论

BigBird RV32 从「CPU + 顶层硬连译码」升级为**带总线、中断控制器、标准定时器、单一地址表**的 SoC，
并且已经能在其上跑**文件系统 + 从文件系统加载执行程序 + 贪吃蛇逻辑**。

---

## 2. 五个阶段的交付与证据

| 阶段 | 交付 | 证据 |
|---|---|---|
| **A1 总线化** | `rtl/soc_map.sv`（地址单一来源）+ `board/soc_bus.sv`（译码/片选/读回选/写分发）；`board_top` 里 4 处散落译码收成 1 处 | `tb_bus` **4/4**：DRAM 读写 / 代码窗口读 / 代码窗口写 / MMIO+UART |
| **A2 中断** | `rtl/plic_lite.sv`（8 源、电平语义、claim 清位）；`CSR.meip` 不再硬连 0；`mmio_idx` 3→4 位 | `tb_irq` **3/3**，`mcause=0x8000_000B` |
| **A3 CLINT** | `rtl/clint.sv`；`mtime/mtimecmp` 从非标准 CSR `0x7C0/0x7C1` 迁到 `0x1000_0030/0x38`，**唯一计数源** | `tb_clint` **5/5**，LED=0x7F：CSR↔MMIO 双向同源 + MTI 中断 |
| **A4 地址表** | `tools/gen_soc_map.py` → `sw/soc_map.h` + `docs/地址表.md`；`--check` 进回归；`monitor.c` 编译期断言 | 回归用例 `soc_map` PASS |
| **软件 S3** | `sw/fstest.c`：ramdisk 文件系统（块 256 B×256、超级块 + 32 项目录 + bump 分配） | `[PROG] PASS`，126 k 拍；进回归 |
| **软件 S4** | `sw/runtest.c`：文件系统 → IROM 窗口 → `fence.i` → 跳转执行 → 返回 | `[PROG] PASS`，2.3 k 拍；进回归 |
| **软件 S5（内核）** | `sw/snake.c`：20×12 网格、吃食长身、自撞/撞墙判定 | `[PROG] PASS`，2.4 k 拍；进回归 |
| **P1（应用与显示）** | `run <file>` 容器 + 入口桩 + ramdisk 位图分配 + 增量重绘 | 板上 `HELLO-APP`/`acc=15`/`returned to shell`；`df` 152→155；单步 2 523 B→30 B（见 `docs/P0P1_完成报告.md`） |
| **P0（可信度）** | RX 中断默认开、容器进仿真回归、首命令、lint 门禁、SVA | `tb_monitor` 9/9（无 X）、`tb_runapp` 5/5、lint 0/0（37 文件无白名单）、SVA 0 违约（见 `docs/P0_完成报告.md`） |
| **#6 AXI4-Lite 总线化** | `board/axil_slave.sv`（从口→简单总线，请求/授权）+ `board/dram_shared.sv`（共享端口 128 KB DRAM，CPU 优先、AXI 借空拍）+ `board_top` 的 `AXIL_EN` 开关 | `tb_axil` **10/10**（含 AW/W 通道分离 T8）、`tb_dram_shared` **6/6**、`tb_axil_dram` **4/4**；OOC 综合 0 error（DRAM 32×RAMB36）（见 `docs/AXI_总线化_6_7.md`） |
| **#7 Zynq PS 接入（硬件）** | PS7 + `axi_protocol_converter`(AXI3→AXI4Lite) + 本 SoC 的 BD；`board/board_top_ps.sv`；真实引脚约束 `_diag/ps_pins.xdc` | BD `validate` 通过、地址 `0x4000_0000`/256 KB；综合+实现+比特流 **DRC 0 Errors**、后布线 **WNS +0.649 ns**、LUT 62.52%、BRAM 48；产物 `ps_bd/soc_ps.bit` / `soc_ps.xsa` |
| **#7 Zynq PS 接入（软件）** | `sw/ps/ps_axil_test.c`（freestanding）+ `start_ps.S` + `link_ps.ld`；`_diag/ps_run.tcl`（fpga -f → ps7_init → dow → con） | ELF 已编出（728 B，entry 0x0）；断电重启后一次通过：`=== PS -> RISC-V AXI test === B) 0x5150c0de C) 0x12345678 RESULT: PASS`（COM13），且调试器 `mrd 0x40010040 = 0x5150C0DE` 独立复核一致 |
| **双核 第1步：PS 装载 RISC-V 镜像** | `board/ps_ctrl.sv`（控制平面 `0x4002_0000`）+ `sw/ps/stub.S`（20 条指令的 stage-0 搬运器）+ `tools/bin2iromhex.py` + `tools/gen_ps_image.py` + `sw/ps/riscv_loader.c` + `IROM_BOOT=2` | 仿真 `tb_ps_ctrl` **14/14**；**板上** loader 打印 `STATUS=b1550009 → loaded 5114 words → HOLD=0 → STATUS=b1550040 (ALIVE=1) RESULT: PASS`，同一时刻 **COM9 上 shell 横幅完整可读**（`code-win OK w0=00012197`）—— 乱码问题消失 |
| **双核 第2步：共享 DRAM 一致性** | `rtl/DCache.sv` 新增 `inval`（整表无效，**四个命中判定都加 ~inval**）+ MMIO `0x1000_001C` bit0 触发 + `sim/tb_dcache_stale.sv` | 先**复现**陈旧读（`S2 x6=0x1111`，而 DRAM 已是 0x2222），再验证修复（`S3 x7=0x2222`）；**4/4**，`hit=1 miss=2`、收尾 1 条有效行 |
| **双核 第3步：双向中断** | `irq_ps` 输出 + PLIC 源 4 + BD 接 `IRQ_F2P` + `sw/ps/ps_irq_test.c`（GIC SPI 61..68）+ `sw/pstest.c` | 仿真 `tb_ps_ctrl` P7/P8/P9；**板上** `SCRATCH=0x600D0001`、`SH_MSG=0xDEADBEEF`、`SH_ACK=0x0000ACED`、`SH_NIRQ=0xB8E`，COM9 打 `PS-OK` |

**全量回归**：

```
[REGRESSION] ALL PASS (53 runs)
```

> 45 项仿真用例 + `tb_runapp`（容器 `run` 端到端）+ `tb_axil`（AXI 桥，10 项）
> + `tb_axil_dram`（AXI↔DRAM↔CPU 端到端，8 检查，已转正）+ `tb_dram_shared`（共享端口 DRAM 仲裁）
> + `tb_ps_ctrl`（PS 装载全流程，14 检查）+ `tb_dcache_stale`（一致性，4 检查）
> + `lint`（Vivado xvlog 门禁，38 文件无白名单）+ `sva`（xsim 断言，0 违约）。
> 明细见 `docs/P0_完成报告.md`、`docs/P0P1_完成报告.md`、`docs/AXI_总线化_6_7.md`（末章"双核协同三步"）。

---

## 3. 时序与资源（Vivado 2025.2，xc7z020clg484-1，50 MHz）

| 资源 | v17 基线 | v18（A1+A2+A3） | **v18 重建（2026-11-11，当前源码）** |
|---|---|---|---|
| WNS | +0.048 ns | +0.250 ns | **+0.646 ns** |
| WHS | +0.015 ns | +0.005 ns | **+0.005 ns** |
| TNS | — | 0.000 | **0.000** |
| Slice LUTs | 36 150（67.95%） | 35 904（67.49%） | **36 241（68.12%）** |
| Slice Registers | 34 058（32.01%） | 33 762（31.73%） | **34 054（32.01%）** |
| Block RAM Tile | 66.5（47.5%） | 66.5（47.50%） | **66.5（47.50%）** |
| DSPs | 4 | 4 | **4** |

> ★ 2026-11-11 用**当前源码**重建（`build_project_boot.tcl`：`RESULT build OK`、
> `RESULT WNS = 0.646 ns`、`WHS = 0.005 ns`、DRC 0 errors，比特流 17:51 重新生成）。
> 必须重建的原因：`board_top.sv` 在 #6 过程中被行级编辑改坏过，之后是从 IP 打包副本
> 恢复的（11 个测试台全过，但没有重新综合过）。重建证明**当前源码能综合、能过时序、
> 能出比特流**。LUT/FF 比原 v18 记录多约 340（+0.6%），来源是 P0-4 把四处
> "先使用后声明"改成显式声明（逻辑不再被隐式 1 bit 网络吞掉）；WNS 反而从
> +0.250 提升到 **+0.646**。
> 报告：`reports/util_v18_final.rpt`（后布线利用率）、`build_v18b.log`（时序）；比特流 `v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.bit`。

**结论**：总线化没有压垮这条只剩 48 ps 的路径，LUT/FF 反而因为去掉了重复译码而减少；
PLIC 与 CLINT 的加法被合并收益抵消还有余。

---

## 4. 上板验证（2026-11-10，v18 比特流）

| 检查 | 结果 |
|---|---|
| 烧录 | `programmed in 52.5s`（`v9_boot/.../board_top_gui_boot.bit`） |
| 引导器灌 64 KB 镜像 | 成功；shell 启动 |
| **总线 + IMEM 读写** | `k 20000` → `cksum 0x65e2cbd9`，主机侧对同一 64 字算 djb2 = **0x65e2cbd9（逐位一致）** |
| **CLINT** | `p 10000030` 两次相差 2,316,153 tick ≈ 4.63 s @500 kHz；`u` → `mtime=58145170 = 116.290 s` |
| **PLIC 寄存器** | `p 10000020` → `0x3`（bit0 残留字节 / bit1 引导期溢出）；`p 10000024` → `0` |
| **A2 外部中断** | `irqtest` → **`OK`**（PLIC→MEIP→陷入→mret 全通） |
| **中断入口/返回** | `irqdiag` → **`ABCDE`**（两次软件中断都正确返回） |
| shell 全部命令 | `i` / `l 3f` / `p 10000` / `k 20000` 均正常 |

### 顺带修掉的两个工具缺陷

1. **`load_uart.ps1` 拒绝空 DRAM 镜像**：`.data/.rodata` 为空时 `_dram.hex` 是空文件 →
   `throw "no words in ..."` → **镜像根本没发出去**。表现是"小程序上板不跑"，
   而 monitor（有 .data）正常。已在 `sw/elf2hex.py` 里补一个字（写个 0，无害），
   从此所有镜像都可加载。
2. **`board_run` 的监听窗口**：一次性打印的程序要用 `-NoGo -ReleaseWaitMs 2000`
   （监听必须先于引导器 5 s 空闲释放打开），否则永远抓不到。

---

## 5. 还没做的（已知缺口，不掩盖）

| 项 | 状态 | 说明 |
|---|---|---|
| **S1 shell 输入中断驱动** | ✅ **已默认启用**（P0-1） | 三个原因都修了：① `getc_nb()` 的轮询回退与 ISR **抢同一个 RX FIFO**（中断模式下 `getc_nb` 只吃环形缓冲）② **陷入处理对中断也做 `mepc += 4`**（跳掉被打断的指令；规范只允许对同步异常/断点这么做）③ **`tb_monitor` 只清了 DRAM 低 16 K 字**，栈顶以上是 X —— ②跳掉 `sw` 后 `lw` 读到未初始化存储，X 流进控制路径，看起来像"停顿网络出现 X"。仿真 `tb_monitor` **9/9**（含 M9 无 X），真片 `rx irq ON / exc n=0`，120 字符长命令逐字节一致。退回轮询：`-DRX_IRQ_DISABLE` |
| S2 串口调试服务（单步/断点/trace） | ⬜ | 未开始 |
| S2 串口调试服务 | ✅ **软件断点**（真片验证） | `bk <addr>` / `bl` / `bd`：把指令换成 `ebreak`，陷入后还原并 `mepc+=4` 跳过。真片实测 `bk 4000` → `d 24000 1` 读到 `00100073` → `bd` 还原。局限：单断点、命中即还原 |
| S5 渲染层（ANSI 增量重绘） | ✅ **已可玩**（P1-3） | `sw/snake_play.c`：边框只画一次，之后每步只发改动格子（`ESC[r;cH`）。实测 **2 523 B/帧 → ≈30 B/步（84×）**；方向键（含 5 ms 字节等待）、`r` 重开 / `q` 退出 |
| 开机后第一条命令可能失效 | ✅ **已修**（P0-3） | 根因：`rx_flush()` 原来在**横幅之后**（横幅 10.6 ms），冲掉的可能是用户输入；移到位（横幅之前、开中断之前）后，3 次引导的第一条命令 3/3 正常 |
| lint / 断言 | ✅ **进门禁**（P0-4/5） | `xvlog --sv` **37 个文件（无任何白名单）0 error / 0 warning**，1~2 s 跑完；`sim/sva_soc.sv` 8 条 SVA 用 xsim 跑，**25 s / 0 违约**。注：之前"xvlog 慢 10 分钟"的真因是 `xsim.dir\\work` 库被历次运行累积污染，清库即恢复（详见 `docs/AXI_总线化_6_7.md`） |

---

## 5. 复现方法

```powershell
# 1) 全量回归（49 项，约 50 分钟；含 lint 与 SVA）
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\regress.ps1

# 1b) 只跑一项（调试用，文件表与回归同源）
powershell -NoProfile -File _diag\sim_one.ps1 -Tb tb_monitor `
    -Plus '+prog=sw/build/monitor_irom.hex','+dram=sw/build/monitor_dram.hex'

# 1c) lint / SVA 单独跑
powershell -NoProfile -File _diag\lint.ps1
powershell -NoProfile -File _diag\sva.ps1

# 2) 编译软件测试（WSL 内，工具链在 ~/rv32/sysroot，见 sw/env.sh）
wsl -e bash -lc "cd /mnt/e/FPGA/v9_vivado_ila && bash sw/build_simple.sh sw/fstest.c fstest"

# 3) 跑单个软件测试
vvp sim/build/tb_prog.vvp +prog=sw/build/fstest_irom.hex +dram=sw/build/fstest_dram.hex

# 4) 综合 + 实现 + 出报告
vivado -mode batch -source _diag/build_v18_quick.tcl
```

---

## 6. 一张图看结构

```
                    ┌──────────────────────────────────────────┐
  取指 ────────────►│  IMEM 64 KB（端口 A）                     │
                    │  └─ 端口 B：代码窗口 0x2_xxxx（读写）      │◄──── CPU 数据口
                    └──────────────────────────────────────────┘
  数据 ────────────►  soc_bus ──┬─► DRAM 128 KB      0x0000_0000
                                ├─► 代码窗口          0x0002_0000
                                └─► MMIO              0x1000_0000
                                       ├ UART TX/RX (0x00…0x18)
                                       ├ LED / BOOTREQ
                                       ├ PLIC-lite     (0x20/0x24/0x28/0x2C)
                                       └ CLINT         (0x30/0x34/0x38/0x3C)
  中断 ────────────►  PLIC.irq → CSR.mip.MEIP → Control.intr_take
  定时 ────────────►  CLINT.mtime/mtimecmp（CSR 0x7C0/0x7C1 只是它的门面）
```

---

## 7. 复现清单（一条命令一条命令地跑）

> 下面所有命令都在仓库根目录 `E:\FPGA\v9_vivado_ila` 下执行；数字是 2026-11-11 的实测。

### 7.1 全量回归（51 项，约 45~60 分钟）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\regress.ps1
```

期望结尾：`[REGRESSION] ALL PASS (53 runs)`。
其中包含 `lint`（37 个设计文件、无白名单、0 error/0 warning）与 `sva`（xsim，0 违约）。

### 7.2 单项调试（与回归同源的文件表）

```powershell
powershell -NoProfile -File _diag\sim_one.ps1 -Tb tb_monitor `
    -Plus '+prog=sw/build/monitor_irom.hex','+dram=sw/build/monitor_dram.hex'
powershell -NoProfile -File _diag\sim_one.ps1 -Tb tb_axil          # AXI 桥 10 项
powershell -NoProfile -File _diag\sim_one.ps1 -Tb tb_dram_shared   # 共享端口 DRAM 6 项
powershell -NoProfile -File _diag\sim_one.ps1 -Tb tb_axil_dram     # 端到端 4 项
```

### 7.3 门禁单独跑

```powershell
powershell -NoProfile -File _diag\lint.ps1    # ~2 s
powershell -NoProfile -File _diag\sva.ps1     # ~25 s
```

> 若某个 `xvlog`/`xelab` 突然变慢：先删 `xsim.dir\work`（库累积污染，见 §AXI 文档）。

### 7.4 软件侧（WSL 内，RISC-V 工具链）

```bash
source sw/env.sh
bash sw/build_simple.sh sw/monitor.c monitor        # shell
bash sw/build_app.sh  sw/app/hello_app.c hello_app  # 可 run 的容器
bash sw/build_coremark.sh                           # CoreMark
```

### 7.5 上板（RISC-V 侧）

```powershell
# 烧 v18 + 灌 shell（会重配 FPGA，约 1 分钟）
powershell -NoProfile -File _diag\board_run.ps1 -Hex sw\build\monitor_irom.hex `
    -DramHex sw\build\monitor_dram.hex -Repeat 2 -NoGo -ReleaseWaitMs 2000 -ListenSec 6
# 之后正常敲命令
powershell -NoProfile -File _diag\mon_cmd.ps1 -Cmd "i" -Seconds 3
```

### 7.6 上板（PS 侧，#7）

前置：板子 JTAG 健康（`xsdb connect` 能看到 `APU / Cortex-A9 / xc7z020`；
若只看到 `DR shift through all zeroes`，说明需要断电重启）。

```powershell
# 编译 PS 裸机程序（用本机现成的 Arm GNU 13.2.1）
powershell -NoProfile -File sw\build_ps_app.ps1

# 烧 PS 设计 + ps7_init + dow -force + con + 调试器读回 + 抓 COM13
powershell -NoProfile -File _diag\ps_run_all.ps1
```

期望 COM13：

```
=== PS -> RISC-V AXI test ===
A) RISC-V DRAM[0x10044] = 0x........   (informational)
B) write/readback 0x10040 = 0x5150c0de   (expect 0x5150c0de)
C) write/readback 0x10048 = 0x12345678   (expect 0x12345678)
RESULT: PASS
```

以及 `ps_run.log` 里的调试器读回 `mrd 0x40010040 = 0x5150c0de`。

### 7.7 综合/实现（Vivado）

```powershell
# v18（RISC-V 板级，IROM_BOOT=1）
vivado -mode batch -source build_project_boot.tcl        # RESULT WNS = 0.646 ns

# PS 设计（PS7 + AXI + 本 SoC），含真实引脚约束
vivado -mode batch -source _diag\build_ps_bd.tcl         # BD + 综合 + 实现
vivado -mode batch -source _diag\ps_constrain.tcl        # 加引脚约束后重跑，出 bit/XSA
```
产物：`v9_boot/v9_ila.runs/impl_1/board_top_gui_boot.bit`、`ps_bd/soc_ps.bit`、`ps_bd/soc_ps.xsa`。

