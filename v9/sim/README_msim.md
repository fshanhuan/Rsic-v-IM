# `sim/` 的 ModelSim 回归线（v9）

> 本文件说明**在 ModelSim 下怎么跑 v9**，以及踩过的 5 个坑。
> iverilog 那条线见 [`README_iverilog.md`](./README_iverilog.md)、[`run_all.sh`](./run_all.sh)。

## 1. 一条命令跑全量

```bat
cd /d "E:\share doc\v9"
sim\run_msim.bat
```

或直接调 PowerShell 驱动（内容一样）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\run_msim.ps1
```

跑的是 **7 个程序 × {正常, 严格} = 14 项 + D-Cache 单元测试 = 15 项**，
日志落在 `msim/logs/`，汇总表在 `msim/logs/msim_summary.txt`，全过才返回 0。

| 程序 | 覆盖面 |
| --- | --- |
| `prog` | 算术 / `mul` / load-use / 分支 / `jal` / `ecall`（35 项检查） |
| `prog_mul` | 连续 8 条乘法 |
| `prog_div` | 4 次除法（MDU 多拍冻结流水） |
| `prog_load_lane` | `lb/lh/lbu/lhu` 的字节/半字偏移选道 |
| `prog_load_use` | load 后紧跟消费者的前递 |
| `prog_loop` | 后向分支循环（分支预测 + 误预测恢复） |
| `prog_div_pair` | 背靠背除法（MDU 握手重置） |
| `tb_dcache_unit` | D-Cache：miss→fill、二次命中、写直达、MMIO 不缓存、外设副作用 |

「严格模式」= 额外加 `+no_wbu_force +raw_rf`：不用测试台里任何兜底手段
（不 force `WBU.stall`、不做寄存器堆预清），验证 RTL 自身是否干净。

## 2. 只跑单个程序

GUI（要波形）：

```bat
cd /d "E:\share doc\v9"
vsim -do sim/run_msim.do work.tb_msim +prog=sim/prog.hex +prog_id=0 +max=600
```

批处理：

```bat
vlib work
vlog -sv -suppress 7061 -work work -incr "+incdir+." "+incdir+experimental" myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv RegisterFile.sv CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv LSU.sv DCache.sv WBU.sv Data_hazard.sv Control.sv add.sv sext.sv Reg.sv sim/tb_msim.sv
vsim -c -suppress 7061 -L work work.tb_msim +prog=sim/prog.hex +prog_id=0 +max=600 -do "run -all; quit -f"
```

`sim/run_msim.do` 是一个**薄**脚本（建库 + 编译 + `run -all`），
plusarg 由 vsim 命令行透传，不再覆盖默认值。

## 3. 实测结果（本机 ModelSim SE-64 10.5，2016.02）

```
=== [2/3] 7 programs x {normal, strict} + dcache unit ===
  [OK  ] prog             normal: PASS 35/35   strict: PASS 35/35
  [OK  ] prog_mul         normal: PASS 34/34   strict: PASS 34/34
  [OK  ] prog_div         normal: PASS 34/34   strict: PASS 34/34
  [OK  ] prog_load_lane   normal: PASS 34/34   strict: PASS 34/34
  [OK  ] prog_load_use    normal: PASS 34/34   strict: PASS 34/34
  [OK  ] prog_loop        normal: PASS 34/34   strict: PASS 34/34
  [OK  ] prog_div_pair    normal: PASS 34/34   strict: PASS 34/34
  [OK  ] tb_dcache_unit   PASS

=== [3/3] SUMMARY ===
  checks run : 15
  failures   : 0
  RESULT     : ALL PASS
```

## 4. 五个踩过的坑（都已在脚本里解决）

### 4.1 RTL 编译：`include "para.sv"` 找不到

`experimental/MDU_pipelined.sv` 用 `include "para.sv"`，而 `para.sv` 在上一层目录。
必须给 include 路径：

```
+incdir+.  +incdir+experimental
```

### 4.2 工程根目录含空格 → Tcl 把路径拆成两个参数

根目录是 `E:\share doc\v9`，**带空格**。在 `.do` 里写

```tcl
eval vlog ... "+incdir+$ROOT"      ;# 错！
```

Tcl 会把它拆成 `+incdir+E:/share` 和 `doc/v9` 两个参数，vlog 报：

```
** Error: (vlog-7) Failed to open design unit file "doc/v9" in read mode.
```

→ 一律用**相对路径** `"+incdir+."` / `"+incdir+experimental"`（测试台本来也要求
在 v9 根目录下跑，因为 `$readmemh` 用的是相对路径）。
同理，PowerShell 驱动里传参要用 `@RTL` 数组展开，不要拼字符串。

### 4.3 测试台里两处「为 iverilog 写死」的写法，ModelSim 直接报错

`sim/tb_iverilog.sv` 里有两段是为 iverilog 的短板打的补丁，ModelSim 会拒绝：

| 位置 | 写法 | ModelSim 的反应 |
| --- | --- | --- |
| 初始化段 | 0 时刻对 `...Reg_inst.rf[k]` 做过程赋值（RTL 里 `rf` 由 `always_ff` 驱动） | `** Error (vopt-7061) Variable 'rf' driven in an always_ff block, may not be driven by any other process` → **拒绝构建，vsim 报 vopt-1067/Error loading design** |
| 文末 | 32 行 `$dumpvars(0, ...rf[i])` + `$dumpvars(0, dram[1024])` | `** Error (vsim-PLI-3537) $dumpvars() : Argument 2 is invalid.`（ModelSim 要求第二个参数是**模块实例**，不是变量） |

**处理**：不改 RTL，改为自动生成一个 ModelSim 专用测试台：

```bat
python sim\mk_msim_tb.py          :: 从 tb_iverilog.sv 生成 sim/tb_msim.sv
```

生成脚本只做三件语义无关的改写（判据、期望值表、断言**完全一致**）：

1. 删掉寄存器堆的 0 时刻预清 —— 那是 `RegisterFile.sv` 还没有复位分支时的补丁，
   现在 RTL 自己会复位（`always_ff ... if (reset) for(...) rf[i] <= 0`），
   所以**不需要**它；删掉之后严格模式（`+raw_rf`）也照样全过。
2. 删掉逐元素 `$dumpvars` —— ModelSim 的 `$dumpvars(0, tb)` 已经覆盖整棵层次树，
   32 个寄存器都在波形里。
3. 把结尾的 `$fatal(1, ...)` 换成 `$display("[SELFCHECK] status=FAIL...")` ——
   便于外部脚本判定（vsim 批处理下退出码不可靠，见 4.5）。

### 4.4 单元测试台的 `vlog-7061`

`sim/tb_dcache_unit.sv` 也在 `always_ff` 之外预清了 `dram` / `mem_rdata`，
同样触发 `vlog-7061`。这个文件是 iverilog 专用的，**不改它**，
改用 `vlog -suppress 7061`（注意 `-suppress` 要同时给 **vlog** 和 **vsim**：
只给 vsim 的话编译阶段就失败了）。

### 4.5 vsim 批处理的退出码不可靠，Tcl 的 `redirect` 在 `-c` 下不存在

- `vsim -c` 即使遇到 `$fatal` 也**可能返回 0**，不能拿退出码当判据；
- `redirect` 是 ModelSim **GUI** 的命令，在 `-c` 批处理下会报
  `invalid command name "redirect"`。

所以全量回归由 `sim/run_msim.ps1` 驱动：**逐个程序调用一次 vsim**，
再把日志里的 `[SELFCHECK] status=PASS/FAIL/TIMEOUT` 解析出来做汇总。
`sim/run_msim.do` 只服务「单程序 / GUI 看波形」这一种用法。

## 5. 扩展：加一个新的回归程序

1. 用 `sim/gen_teaching_progs.py` 或手写一个 `sim/prog_xxx.hex`；
2. 在 `sim/tb_iverilog.sv` 的 `load_expectation()` 里加一个 `prog_id` 分支
   （期望寄存器值表 + 可选的 `exp_dram`）；
3. 在 `sim/run_msim.ps1` 的 `$Progs` 表里加一行：
   `@{ n = 'prog_xxx'; id = 7; mx = 1200 }`；
4. iverilog 那条线同步在 `sim/run_iverilog.bat` 的 `PROG_ID` 映射里加一行。

## 6. 与 iverilog 那条线的关系

两条线跑的是**同一个测试台的同一套判据**（`tb_msim.sv` 由 `tb_iverilog.sv` 生成），
所以结果应当一致。差异只在工具能力：

| | iverilog 12.0 | ModelSim SE 10.5 |
| --- | --- | --- |
| 语言 | `-g2012` | `vlog -sv` |
| 寄存器堆预清 | 需要（`tb_iverilog.sv` 保留） | 不需要（RTL 已复位，`tb_msim.sv` 删掉） |
| 存储器波形 | 必须逐元素 `$dumpvars` | `$dumpvars(0, tb)` 自动覆盖 |
| 已知未覆盖 | — | 两者都**没跑** `cdp-tests` 的 47 条全指令表（缺 verilator/make） |
