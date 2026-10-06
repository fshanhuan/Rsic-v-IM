# sim/iverilog — 不依赖 verilator 的回归测试台

`cdp-tests` 的差分框架需要 verilator + make + WSL，本机（Windows，无 WSL 发行版、
无 make、无 verilator）跑不了。本目录新增一个**自包含、只用 iverilog/vvp** 的
回归测试台，作为「上板改造」前的功能基线。

## 一条命令

**全量回归（推荐，CI 用的就是它）**：

```bash
cd v9
bash sim/run_all.sh    # 15 项：7 个程序 × 正常/严格模式 + D-Cache 单元测试
```

跑单个程序：

```bat
cd v9
sim\run_iverilog.bat                    :: prog            （综合演示）
sim\run_iverilog.bat prog_mul           :: 连续 8 条 mul
sim\run_iverilog.bat prog_div           :: 连续 4 条 div
sim\run_iverilog.bat prog_load_lane     :: 字节/半字 load 的偏移选道
sim\run_iverilog.bat prog_load_use      :: load 取数 / load→store 数据相关
sim\run_iverilog.bat prog_loop          :: 后向分支循环
sim\run_iverilog.bat prog_div_pair      :: 背靠背 div/rem
sim\run_iverilog.bat prog wave          :: 跑完直接开 GTKWave
```

> `prog_load_lane` / `prog_load_use` / `prog_loop` / `prog_div_pair` 是第二轮独立验证
> 发现缺陷后补的回归（原来的 3 个程序完全没有访存宽度、后向分支和多拍除法相邻的覆盖）。

等价的裸命令（便于接 CI / 手工调参）：

```bat
cd v9
iverilog -g2012 -o sim\build\tb_iverilog.vvp ^
    myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv ^
    RegisterFile.sv CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv LSU.sv DCache.sv WBU.sv ^
    Data_hazard.sv Control.sv add.sv sext.sv Reg.sv sim\tb_iverilog.sv
mkdir wave
vvp sim\build\tb_iverilog.vvp +prog=sim/prog.hex +prog_id=0 +vcd=wave/tb_iverilog_prog.vcd
```

| 产物 | 说明 |
| --- | --- |
| `sim/build/tb_iverilog.vvp` | 编译产物 |
| `sim/build/<prog>.log` | 完整日志：写回事件、寄存器快照、自检结论 |
| `wave/tb_iverilog_<prog>.vcd` | 波形（含 32 个通用寄存器 + mepc/mcause/mstatus/mtvec） |

退出码：寄存器/内存自检全通过 → `0`；不匹配或超时 → `$fatal` → `1`。

## plusarg

| plusarg | 作用 |
| --- | --- |
| `+prog=<path>` | 选择程序 hex（默认 `sim/prog.hex`），相对 v9 根目录 |
| `+prog_id=<n>` | 期望值表：`0`=prog `1`=prog_mul `2`=prog_div `3`=prog_load_lane `4`=prog_load_use `5`=prog_loop `6`=prog_div_pair，其它=只报实测 |
| `+vcd=<path>` | 波形路径（默认 `wave/tb_iverilog.vcd`） |
| `+max=<n>` | 最大拍数（默认 400，防跑飞）；超时按 FAIL 处理 |
| `+drain=<n>` | ecall 之后再多跑几拍等流水线排空（默认 8） |
| `+no_wbu_force` | 关掉 `WBU.stall` 的 force（RTL 修好后可用） |
| `+raw_rf` | 关掉寄存器堆上电清零（观察原始 x 传播） |

## 测试台做了什么

- **自包含 SoC**：IROM（`$readmemh` 载入文本 hex）+ DRAM/外设，语义照抄
  `cdp-tests/mySoC/miniRV_SoC.v` + `dram_driver.sv`（组合读、按 mask 抽取/合并写）。
- **时序**：时钟 10ns（100MHz），复位 8 拍后释放；在**时钟下降沿**采样，
  与 cdp-tests 读 `debug_wb_*` 的时刻一致。
- **写回事件逐拍打印**：`[WB] cyc=.. pc=.. inst=.. <助记符> ena=.. reg=.. val=..`，
  并**对同一事件去重**（流水线因 load-use 暂停冻结时写回口会保持多拍）。
- **store / 重定向追踪**：`[ST]`、`[RDR]`（dnpc、mispredict、ecall/mret/intr）。
- **结束条件**：ecall 进入译码级（`u_cpu.IDU_ecall_flag`）后再跑 `+drain` 拍取快照
  —— 不能用固定拍数，因为 ecall 会把 PC 重定向到 `mtvec`（复位值 0）导致程序重跑。
- **自检**：打印 x0~x31 快照，与内置期望值逐条比对（`[PASS]`/`[FAIL]`），
  外加 prog 的 `dram[0x1000]`；再打印 ICache/DCache/BPU 计数器。
- **波形**：`$dumpvars(0, tb_iverilog)` + **逐个显式** `$dumpvars` 导出 32 个通用
  寄存器（iverilog 不会自动导出存储器数组），CSR 的 mepc/mcause/mstatus/mtvec 是
  普通 reg，已被自动导出。

## 环境约束（踩过的坑）

1. **非 ASCII 路径**：iverilog 的 `$readmemh` / `$dumpfile` / `-o` 都不接受
   `D:\数微挑战\...` 这类路径（会写成 `\377` 或 `Code generator failure: -1`）。
   脚本一律先 `cd` 到 `v9\` 根目录、只用相对路径。
2. **没有 `$fread`**：`cdp-tests/vsrc/ram.v` 用 `$fread` 读 `.bin`，iverilog 不支持，
   因此这里改用文本 hex（`sim/prog*.hex`）+ `$readmemh`。
3. **存储器数组不自动导出**：必须逐个元素 `$dumpvars`。
4. **`.bat` 必须是纯 ASCII**：cmd.exe 用 OEM 代码页（本机 936）逐行解析批处理，
   UTF-8 中文注释会被当成乱码命令执行。中文说明放在本文件里。
5. `-Wall` 的 `$readmemh` 警告 *Not enough words in the file* 是正常的
   （hex 文件比 ROM 数组短）；ROM 在 `$readmemh` 前已按 `ram.v` 的约定零填充。
6. 编译期的以下提示都**无害**（`-Wall` 可见）：
   - `sorry: Case unique/unique0 qualities are ignored.`（ALU.sv:27 / experimental/MDU_pipelined.sv:76,175）
   - `sorry: constant selects in always_* processes are not currently supported`
     （CSR.sv:113 / ALU.sv:25 / experimental/MDU_pipelined.sv:55,74 / DCache.sv:75，只是敏感表取整个向量）
   - `warning: A for statement must use the index (i) ...`
     （ICache.sv:62 / DCache.sv:96 / Branch_Predictor.sv:93，综合建议，仿真正确）

## iverilog 暴露出的两个 RTL 隐患

> **已修复**：上板改造时这两处已直接改在 RTL 里（`myCPU.sv` 的 WBU 例化补上
> `.stall(1'b0)`、`RegisterFile.sv` 增加复位清零）；测试台里的 `force`/上电清零
> 现在只是兜底，用 `+no_wbu_force +raw_rf` 关掉后同样 **103/103 全过**。
> 下面保留当时的定位记录，便于回溯。

两个问题在 Verilator 流程里**都是隐形的**（Verilator 是 2 态：未初始化存储器 = 0，
未连接输入 = 0），但 iverilog 是 4 态、未连接输入 = z，于是直接暴露：

| # | 位置 | 现象 | 最小改动建议 |
| --- | --- | --- | --- |
| 1 | `myCPU.sv:537` WBU 例化漏接 `.stall` | 输入浮空为 `z`，`if (!stall)` 变成 `x`，寄存器永不更新 → **一条写回都出不来**。`iverilog -Wall` 直接报 `dangling input port 14 (stall) floating` | 例化处补 `.stall(1'b0)` |
| 2 | `RegisterFile.sv:20-22` 寄存器堆无复位 | `rf[0]`（即 x0）保持 `x`，任何以 x0 为源操作数的指令都算出 `x`，污染整条数据通路。FPGA 上依赖 BRAM 上电为 0 才“碰巧正确” | `always_ff` 里加 `if (reset) for (i=0;i<32;i=i+1) rf[i] <= 0;`（或单独把 `rf[0]` 常零化） |

测试台用 `force`（问题 1）和上电清零（问题 2）在**不改 RTL** 的前提下绕过它们，
并各自打印一行 `[TB] workaround: ...` 提醒；`+no_wbu_force` / `+raw_rf` 可以关掉
绕过，观察原始行为。

## 文件

| 文件 | 作用 |
| --- | --- |
| `tb_iverilog.sv` | 自包含测试台（IROM + DRAM + myCPU + 事件日志 + 自检 + 波形） |
| `run_all.sh` | **全量回归**：3 程序 × 正常/严格模式 + D-Cache 单元测试（CI 入口） |
| `run_iverilog.bat` | Windows 一条命令脚本（编译 → 仿真 → VCD/日志，含 GTKWave 开关） |
| `run_iverilog.sh` | 与 `run_wave.sh` 同风格的 bash 版（Linux/macOS/CI 可用；未装 iverilog 时回退到 Windows 路径） |
| `tb_dcache_unit.sv` | D-Cache 模块级单元测试 |
| `vcd2svg.py` / `mkwave.py` | VCD → 时序图（SVG） |
