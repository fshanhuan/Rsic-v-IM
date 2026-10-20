# v11 六步优化 —— 实施记录

> 基线 = v10.3b。本文只记录**已实现并有实测证据**的东西；没做的一律在 §6 列明理由。
> 详细工作日志见 [优化_v11_进度.md](优化_v11_进度.md)。

## 0. 出发点：先有负载，再谈优化

优化前全工程 24 个程序，最大的 `sys_*.hex` 也只有 **200 字 = 800 B**，IROM 4 096 字
只用掉 **4.9%**。在这类 hello-world 级别程序上，"改完快了多少"根本测不出来 ——
最直接的证据：**D-Cache 从 64 行扩到 256 行（256 B → 1 KB），7 个老程序的周期数
一个都没变**（工作集本来就装得下）。

所以第 0 步是造负载：`sim/gen_bench_progs.py` 生成 3 个基准，各打一类结构。

| 基准 | 打的结构 | 基线周期（v10.3b + 下文 S1/S2/S3/S5 之后） |
|---|---|---|
| `bench_call` | 两个**不同调用点**调同一函数 → BTB 的"上次返回地址"必然来回猜错 | 706 |
| `bench_mem`  | `lbu` 紧跟使用 + `sb` 写回，64 字节连续工作集 | 935 |
| `bench_div`  | `q=x/10; r=x%10;` 同源配对 + 独立除法 + 除零 | 287 |

★ 造基准时踩到两个**测试台**的坑，值得记下来：

1. `sim/tb_iverilog.sv:904` 用 `u_cpu.IDU_ecall_flag` 判"程序结束"，**不检查这条 ecall 是不是
   投机取到的**。循环回边紧挨着 `ecall` 时，第一次迭代分支还没在 EX 解析，取指已经把 ecall
   送进 ID → 测试台立刻停表（实测 `bench_call` 只跑 44 拍就"结束"）。
   对策：回边之后垫 12 条 NOP（`gen_bench_progs.py` 的 `RETURN_GUARD`）。
2. `sim/gen_exc_progs.py:70` 的 `li()` **只支持 12 位立即数**：`li(1, 0x1000)` 被截成 0，
   程序静默跑错地址。大常数必须用 `la()`。

## 1. S1 —— ICache 旁路

**问题**：v10 把 IFU 改成全流水 + 指令队列后，ICache 的未命中已经是"旁路、零停顿"，
于是 `cpu_rdata = hit ? data[idx_r] : mem_rdata` 里的两个源**恒等**（IROM 只读，
`data[idx_r]` 就是同一地址上次读回的字）；请求侧 `mem_en = cpu_req` 也与 hit 无关，
命中并不省一次 IROM 读。⇒ 对周期数、对功耗的贡献都是 **0**，只剩一个 `fence.i`
一致性责任和一个会误导人的"命中率"指标。

**改动**（`rtl/myCPU.sv`）：删掉 `ICache` 例化，改 3 行直通
（`irom_addr = icache_addr`、`icache_mem_en = icache_req`、`resp_valid` = `cpu_req` 延一拍、
`rdata = resp_valid ? irom_data : \`NOP`）；`debug_icache_hit_cnt/miss_cnt` 恒驱 0
（**端口保留**，不动 board/xdc/ILA 探针表）。`rtl/ICache.sv` 原样保留，作为以后
把取指搬到 DDR/AXI 时的参考实现。

**结果**：7 个程序周期 **36/42/94/55/83/110/97 与基线逐位一致**，35~36 项自检全 PASS
—— 这本身就是"它对周期数零贡献"的实证。

## 2. S2 —— D-Cache 64 → 256 行

`para.sv`：`DCACHE_INDEX_BITS 6 → 8`（工作集 256 B → **1 KB**，仍是 1 字/行、直接映射）。
代价是 LUTRAM 从 64×(32+24) 涨到 256×(32+22)（**0 BRAM、0 FF**）。

**结果**：7 个老程序周期不变（工作集本就 < 256 B）；`bench_mem` 上 D-Cache 命中率
**80 hit / 80 miss**（见 §6 的待查项）。

## 3. S3 —— 死代码

- `LSU_Rdata_raw`：全工程**零读者**（WBU 要的是 M3 的 `rdata_wb_raw`，走另一根线）→ 删除。
- `para.sv` 的 `` `Performance_Count `` 宏：**定义了却没有任何 ifdef 引用**，是
  "看起来可裁剪、实际不可裁剪"的假开关 → 删除，并写明为什么计数器要常开
  （它们正是板级 ILA 的观测载荷，做成宏只会制造"仿真开、上板关"的口径分叉）。
- `Control.MEM_Rdata` 端口：留到 S6 一起处理（它的替代者就是 S6 的主通路）。

## 4. S4 —— RAS 返回地址栈（实测 −27.6%）

**问题**：`bench_call` 里 BPU **48/100 误预测**，几乎全是 `ret` —— 两个调用点交替调用
同一个函数，BTB 存的"上次返回地址"每轮都错。

**改动**（`rtl/Branch_Predictor.sv` + `rtl/myCPU.sv` + `rtl/EXU.sv`）：

- BTB 每项加 2 位 `kind`（NORMAL / CALL / RET）；
- 8 项 RAS（循环栈，满/空饱和），`ret` 的方向是确定性的 → 命中即 taken，目标取 RAS 顶；
- call/ret 分类按 psABI 惯例：`call = (jal|jalr) 且 rd∈{x1,x5}`、
  `ret = jalr x0,0(x1|x5)`。

**★ 关键坑（必须记住）**：分类源**不能用 `IDU_inst_d`**。`bp_update_en` 是"EX 级这条控制
指令被解析"那一拍，而 `IDU_inst_d` 描述的是**正进入 EX** 的下一条 —— 实测 `jalr` 那一拍
`IDU_inst_d` 是重定向后的气泡（`0x00000000`），于是 `ret` 永远识别不出来（探针输出见
工作日志）。正确源是 **EXU 内部已寄存的 `fault_inst_reg`**（与 `branch_flag_reg`/
`jump_flag_reg` 同源同拍），本次从 EXU 引出 `inst_reg_exc`。

**A/B（同一个 `bench_call`，函数体 8 条指令）**：

| 配置 | 周期 | BPU 误预测 |
|---|---|---|
| 无 RAS | **706** | 48/100 |
| 有 RAS | **511** | **9/100** |
| 收益 | **−27.6%** | −81% |

**已知局限**：压栈发生在 EX（比取指晚约 4 拍）。若函数体只有 3 条指令，取指已经跑到 `ret`
而栈还是空的 → 那种退化情形只从 466 → 446。真实函数更长，不受影响。

## 5. S5 —— 除法快路径（`prog_div` 94 → 46 拍）

**先纠正一个错误预期**（我上一轮算错了，别照着去做）：迭代拍数**不能**靠"除数前导零"
大幅缩短。商位宽的界是 `bitlen(a) − bitlen(b) + 1`，而本算法的 `r_a` 从 bit31 往下逐个
消耗被除数，所以拍数 = `ceil(商位宽/2)`。对 `b=10`：`0xFFFFFFFF/10` 的商是 `0x19999999`
（29 位）→ 仍需 15 拍，只省 1 拍。

真正实现的是三类**精确**快路径（`rtl/MDU_pipelined.sv`）：

1. **div/rem 同源配对缓存**：`q = x/10; r = x%10;` 是 C 里除法赋值的标准形态，也是
   printf/itoa 的每一次十进制转换 —— 两次除法算的是完全相同的商和余数。缓存
   `(原始操作数, 有符号标志) → (商幅值, 余数幅值)`，第二次 **17 拍 → 1 拍**。
   缓存的是**幅值**，结果仍走原有 `div_res` 的边界收束（除零 / `INT_MIN÷-1`），那套语义一行未改。
2. **除数为 0**：`div_res` 的边界分支直接给结果，不迭代（17 → 1 拍）。
3. **|a| < |b|**：商 0、余数 |a|，不迭代（17 → 1 拍）。

**结果**：`prog_div` **94 → 46 拍**（省 48 = 3×16，三次除法全部走快路径）；
`prog_div_pair` 不变（97）—— 它中间夹了一条无关的 `div x4,x2,x2`，把 1 项缓存冲掉了。
真实代码里 `q=x/10; r=x%10;` 是相邻的，所以 1 项就够；多链交错需要多入口缓存。

**功能正确性（配对缓存命中路径是被真跑到的）**：`bench_div` 每轮迭代都是相邻的
`div`+`rem` 同源配对（8 轮全部命中缓存），手算期望值与实测逐项一致 ——
x1=1、x3=0、x4=44（各位十进制数字之和）、x5=0、x6=1、x7=2、
**x8=0xFFFFFFFF（除零的商）**、**x9=1（除零的余数=被除数）**。
也就是说缓存路径、除零边界、`divu` 与 `div` 切换三种情形都被覆盖到了。

## 5.6 S6 —— load-use 提前 1 拍（`bench_mem` 935 → 871 拍）

**机制**：DCache 的命中路径是**同拍组合**的 ——
`cpu_rdata = hit_now ? data[index] : mem_rdata`，而 `hit_now` 直接由当拍的 `cpu_en/cpu_addr`
组合比较得出。所以一条 load 停在 **M2** 时，`rdata` **本拍就是它的数据**；未命中时 DCache
拉 `hold`、LSU 被冻结在 M2，数据同样出现在解冻那一拍的 `rdata` 上。

**改动**（`rtl/LSU.sv` + `rtl/Data_hazard.sv`）：

- 在 LSU 里给 M2 加一套与 M1/M3 同构的字节/半字选道 + 符号扩展
  （`rdata_ex_pipe`，2 个 sext 实例 + 3 个 mux，约 80 LUT）；
- `forward_val_pipe` 在 `mem_ren_reg_pipe` 时取 `rdata_ex_pipe`（原来取的是寄存器里的地址）；
- `Data_hazard.pipe_hit` 放开对 load 的限制（M2 也能当 load 前递源），
  `pipe_load_use` 从停顿条件里移除 → 消费者在"load 位于 M2"那一拍就放出去。

**结果**

| 指标 | 前 | 后 |
|---|---|---|
| `bench_mem` 周期 | 935 | **871（−6.8%）** |
| `bench_mem` 的 `IFU_stall` | 224 | **160** |
| `prog_load_use` | 83 | **77（−7.2%）** |
| `prog_load_lane` | 55 | **54** |
| `prog` | 36 | **35** |
| 其余 4 个程序 | — | 不变 |

### ★ 这一版是第二次做，第一版是错的 —— 反面记录必须留着

第一版我把 **M1 已经算好的 `rdata_ex` 寄存一拍**当 M2 前递源（以为"数据在 M1 就有了，搬一拍即可"，
只花 32 FF）。结果**周期数也一样降了**（prog 35、load_use 77），但 `prog` 1 项、
`prog_load_use` 2 项定向自检失败。

原因：`rdata` 在 M1 那一拍对应的是**前一条请求**的返回（DCache 的请求由 M2 的寄存器驱动），
所以那个值是"**上一条的数据 + 本条 M1 的偏移/位宽**"的混搭，只在部分地址上碰巧相等。

> **教训（写进流程）："变快"不能当正确性的证据。** 两版周期数完全相同，只有定向用例
> （`prog_load_use` 就是为这个场景写的）能区分对错 —— 这也是为什么 S6 必须放在
> "定向用例 + 三仿真器 + 变异测试"齐备之后再做。

## 6. 还没做的（诚实清单）

| 项 | 状态 | 理由 / 下一步 |
|---|---|---|
| `bench_mem` 的 D-Cache miss | **待查** | 1 KB 缓存、64 字节工作集却 80/160 miss，不符合预期，怀疑计数器把"hold 期间的多拍"重复计数，需要逐拍波形确认 |
| RAS 的 IF 级投机压栈 | 未做 | 可以消掉"短函数"退化情形，但需要 mispredict 回滚（checkpoint 栈指针），复杂度/收益不合算 |
| 关键路径 `jump_target_low2`（2 LUT，+0.8 ns） | 未做 | 50 MHz 下 WNS 已有余量，只在冲 100 MHz 时才有意义 |
| 频率重平衡（EX 级 23 级逻辑深度） | 未做 | 属于"要 100 MHz 才做"的工程，量大 |

## 7. 验收（v11 最终 RTL）

| 项 | 结果 |
|---|---|
| iverilog 回归 | **23/23 PASS** |
| 程序周期 | prog **35** / mul 42 / **div 46（原 94）** / load_lane **54** / load_use **77（原 83）** / loop 110 / div_pair 97 |
| 基准 | bench_call **511**（无 RAS 706）、bench_mem **871（原 935）**、bench_div 287 |
| ModelSim SE-64 10.5 | **23/23 ALL PASS**（tb_sys zicsr 25 checks） |
| Verilator 5.020 交叉 | **23/23 EQUIVALENT，周期差 0**（`runs=23 signature-diffs=0 bad=0`） |
| 定向变异 | **14/14 全部按预期抓到** |
| 顺手修的脚本缺陷 | `_diag/regress.ps1` 原来在某个 TB **编译失败**时会静默少跑几项并仍打印 `ALL PASS`（实测少跑 5 项报 18 runs）。已改成把编译失败记为显式 FAIL 行 |

## 8. 板级：含 ILA 的综合 + 布局布线（最终交付物）

历史情况：**含 ILA 的实现从未跑完过**，卡在 `opt_design` 的
`Phase 1.1.1 Generate And Synthesize Debug Cores`（`dbg_hub` / `xsdbm` IP 处理）那一行。
本次在 v11 RTL 上**一路跑通**。

启动方式（可复跑）：

```
pwsh -ExecutionPolicy Bypass -File _diag/vivado_ila.ps1 -Mode default
```

流程与产物：

| 步骤 | 结果 |
|---|---|
| `u_ila_0` IP 综合 | 完成（00:00:54 退出） |
| `synth_1` | **0 errors / 47 warnings**，8 分钟 |
| `opt_design`（含 debug core 插入） | **通过**（历史卡点解除） |
| `place_design` → `route_design` | 完成 |
| `write_bitstream` | **`board_top_gui.bit` 4 045 689 B** |
| debug probes | **`board_top_gui.ltx` 70 568 B**（上板抓波形必须与 bit 配套） |
| 调试核 | `dbg_hub`（labtools_xsdbm_v3，inserted）+ `u_ila_0`（labtools_ila_v6，instantiated） |
| 可复现性 | 在**最终 RTL**（S6 回退后）上重跑一次，结果与首次逐项相同：WNS 2.442 / WHS 0.032 / LUT 35 224 / FF 22 247，bit 大小完全相同 → flow 确定性成立 |

**时序（post-route，含 ILA）**

| 指标 | 值 |
|---|---|
| **WNS** | **2.027 ns**（TNS 0.000，失败端点 0 / 37 794） |
| **WHS** | **0.020 ns**（THS 0.000，失败端点 0 / 37 778） |
| WPWS | 3.000 ns |
| 结论 | **All user specified timing constraints are met** |

> S6 的代价（与不含 S6 的同流程对照）：WNS 2.442 → **2.027 ns**（−0.415 ns，新增的 M2 前递 mux
> 落在 load 数据到 ALU 的路径上），LUT +44（35 224 → 35 268），FF −6。
> 换来的收益是 `bench_mem` −6.8%、`prog_load_use` −7.2% —— 在 50 MHz 下 WNS 仍有 2 ns 余量，
> 这个交换是划算的。

**面积（post-route，含 ILA）**

| 资源 | 用量 | 占比 |
|---|---|---|
| LUT as Logic | 35 268 | 66.29% |
| LUT as Memory | 834 | 4.79% |
| FF | 22 241 | 20.90% |
| Block RAM Tile | 38 (RAMB36) | 27.14% |
| DSP | 4 | 1.82% |

★ 与 **noila** 版（10 783 LUT / 9 717 FF / 20 BRAM / WNS 1.827）对照可见：
**ILA 本身吃掉了约 24 k LUT + 12.5 k FF + 18 BRAM**（16 个 probe、深度 2048），
这是上板观测的真实成本，不是 CPU 的面积。

**注**：`prog.hex`（根目录）是 `build_project_ila.tcl:111` 要复制成 IROM 初值的文件，
原来缺失导致构建第一步就失败；本次补成 `sim/prog.hex` 的副本。

## 9. 时序余量评审：0.020 ns 的 hold 到底紧不紧（v11 后续）

**最差 hold 路径**（`timing_post_route.default.rpt:492-505`，S6 那版构建）：

| 项 | 值 |
|---|---|
| 源 | `u_cpu/LSU_Inst0/rs2_value_reg_pipe_reg[11]/C`（SLICE_X82Y47） |
| 目的 | `u_cpu/DCache_inst/store2_wdata_reg[11]/D`（SLICE_X82Y50） |
| 时钟 | 两端都是 **`clk_sys_unbuf`**，同一条 BUFG 网（fo=23279） |
| 数据路径 | 0.342 ns（logic 0.164 + route 0.178），**逻辑级数 0** |
| 时钟 skew | **+0.263 ns，帮忙方向**（DCD 2.383 − SCD 1.839 − CPR 0.280） |
| CPPR | 0.280 ns（**生效**，说明时钟悲观量被正确扣除，不是漏算 OCV） |
| Slack | **0.020 ns** |

结论：这是"同一时钟网上的两个触发器、中间只有一根线"的典型短跳 —— 属于 Vivado hold 分析
**最可信**的一类（时钟树是工具自己布出来并实测的）。但 20 ps @ 50 MHz = **周期的 0.1%**，
工程上应读作"擦线通过"。失效表现是 `store2_wdata` 取到上一拍 → **静默写错数据**，不是跑飞，
所以值得补余量。

另有一条 0.098 ns 的最差 hold（`:285`）在 **TCK / dbg_hub（bscan）** 域，属 JTAG 调试核内部，
与 CPU 无关。

**发现两个约束缺口（已修）**

| # | 缺口 | 后果 | 修法 |
|---|---|---|---|
| ① | `set_clock_uncertainty 0.100` **只加在 `sys_clk`（100 MHz 输入）**上 | CPU 所在的 50 MHz 派生时钟 `clk_sys_unbuf` **没有用户保护带**，余量只剩 Vivado 自动推导的 MMCM 抖动模型 | 给 `sys_clk` 及其**所有派生时钟**加 `-hold 0.200`（setup 维持 0.100）。⚠ 第一次用 `foreach` 实现，被 XDC 拒绝、整段跳过 —— 见 9.1 |
| ② | ILA 的 `v9_board_ila.xdc` 里没有 `set_false_path -to [get_ports debug_dead]` | 报告里有 `6. checking no_output_delay (1)` | 补上这一条 |

★ ② 的一个重要更正：noila 的 `syn/v9.xdc` 里有 **9 条** `set_false_path -to [get_ports debug_*]`，
但**不能照抄到 ILA 版** —— `board_top_gui` 只有 **3 个端口**（`sys_clk` / `btn_rst_n` /
`debug_dead`），`debug_wb_*`、各计数器、`mcause/mepc/mtval` 全是**内部网**（负载是 ILA 的 probe）。
照抄只会得到一堆 "no objects matched" 告警。同理 `5. checking no_input_delay (1)` 指的是
`btn_rst_n`，它已按"异步输入"处理，该提示是预期的。

### 9.1 ★ 翻车记录：XDC 里不能用 `foreach` / `puts`（第一次上板就踩了）

第一版按上表 ① 的写法是"从父时钟展开所有派生时钟"，即：

```tcl
set ila_xdc_clks [get_clocks -quiet -include_generated_clocks sys_clk]
foreach ila_xdc_c $ila_xdc_clks {
    set_clock_uncertainty -hold 0.200 $ila_xdc_c
    ...
}
puts "\[ILA-XDC\] hold=0.200 applied to clocks: $ila_xdc_names"
```

综合日志（`v9_ila/v9_ila.runs/synth_1/runme.log:269-271`）直接给出三条：

```
CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not supported in the xdc constraint file. [v9_board_ila.xdc:80]
CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not supported in the xdc constraint file. [v9_board_ila.xdc:87]
CRITICAL WARNING: [Designutils 20-1307] Command 'puts'    is not supported in the xdc constraint file. [v9_board_ila.xdc:90]
INFO: [runtcl-6] Synthesis results are not added to the cache due to CRITICAL_WARNING
```

后果是双重的，而且都是**不报错**地坏掉：

1. **循环体整段被跳过** ⇒ `clk_sys_unbuf`（真正承载 CPU 逻辑的 50 MHz 派生时钟）的
   `-hold 0.200` **根本没加上**，WHS 仍会是 0.020 —— 正是"以为加了、其实没加"这个最坏情况。
   唯一真正执行的是之前的 `set_clock_uncertainty ... [get_clocks sys_clk]` 两行。
2. 综合结果**不进缓存**（`runtcl-6`）。

根因：**XDC 不是通用 Tcl 脚本**，Vivado 的 XDC 解析器只支持一个受限命令子集
（约束命令 + `set` / `get_*` / `list` / `expr` 等），**不支持** `foreach` / `while` / `if` /
`proc` / `puts` / `source` / `exec` / `lappend`。注意 `set` 是支持的（第一版的 `set ila_xdc_clks ...`
没有告警），所以"能赋值"不代表"能循环"。

修法（现在是最终形态，零控制流、且保证不产生空对象列表）：

```tcl
set ila_unc_clks [get_clocks -quiet -include_generated_clocks {sys_clk clk_sys_unbuf}]
set_clock_uncertainty -setup 0.100 $ila_unc_clks
set_clock_uncertainty -hold  0.200 $ila_unc_clks
```

- `-include_generated_clocks` 让**将来**改 MMCM 分频/派生时钟改名也不会漏；
- 显式再写一遍 `clk_sys_unbuf` 是双保险（防"综合阶段还没派生"）；
- 两个 pattern 一起给 ⇒ 命中集**一定至少含 `sys_clk`**，永远不会传空列表给
  `set_clock_uncertainty`（Vivado 对空对象列表通常直接 ERROR，那是比失效更糟的结果）；
- 换来的代价是**失去日志可见性**（`puts` 不能用）—— 所以验证方式改成看**报告里的数字**：
  `clk_sys_unbuf` 的 WHS 从 0.020 抬到 ≈0.20 才算真生效。数字比日志可靠。

### 9.2 离线自检工具的第二个维度

`python _diag/chk_xdc.py` 原本只用 Python 内嵌 Tcl 把整个 XDC 跑一遍（Vivado 命令打桩），
**语法能过就算 PASS** —— 而这次翻车恰恰是"Tcl 语法完全正确、但 XDC 不合法"。
已增加两个维度：

- `XDC-LEGAL`：逐行取命令首词，命中 **BLOCKED 集合**（`foreach`/`while`/`if`/`proc`/`puts`/
  `source`/`exec`/`lappend` …）即 FAIL；行尾以 `{` 结尾（声明块）也 FAIL；
  同时有 KNOWN 白名单，未识别的命令给 warn（防拼错）。
- `ENCODING`：UTF-8 / 无 BOM / 纯 LF / 无 U+FFFD。

反向自测（必须做，否则"PASS"没有意义）：把出问题的那段构造喂进去，
检查器报出 4 条问题（`foreach` 命令非法、`foreach` 开块、`if` 非法、`puts` 非法）。

顺带修了检查器自身的一个 Tcl 坑：桩函数里写 `return "...reg[0]"`，方括号在 proc
**执行时**仍会被当作命令替换（花括号只延迟一层），于是误报 `invalid command name "0"`。
桩的返回值不要带方括号。

### 9.3 重跑结果：约束生效了，但代价比预估高 4 倍

构建：`_diag/vivado_ila.ps1 -Mode default`（`IMPL_MODE=default`，与基线同 directive），
11:06 启动 → 11:39 出 bitstream，共 ~33 min（IP OOC 综合 5 min + synth 7 min + impl 18 min）。

**判据**（`_diag/chk_holdfix.py`，全部 PASS）

| # | 判据 | 结果 |
|---|---|---|
| 1 | `Designutils 20-1307` 次数（synth / impl） | **0 / 0**（基线的坏构建是 3） |
| 2 | synth 汇总行 | `245 Infos, 108 Warnings, **0 Critical Warnings**, 0 Errors` |
| 3 | hold 要求里出现 `0.200ns ... + UU` | **是**（`+ UU` = User Uncertainty，本文档的 A） |
| 4 | `no output delay specified`（HIGH 类）条数 | **1 → 0**；只剩 `1 port ... but user has a false path constraint (MEDIUM)`，与 `btn_rst_n` 输入侧同类，属预期（本文档的 ②） |
| 5 | THS / TNS | 0.000 / 0.000，"All user specified timing constraints are met." |
| 6 | bit / ltx | 4 045 689 B / 70 568 B |

★ 判据 4 的细节值得记：`checking no_output_delay (1)` 的 TOC 计数**修好后仍然是 1**，
因为 Vivado 把"有 false_path 的 MEDIUM 提示"也算进这个计数（`btn_rst_n` 的
`no_input_delay (1)` 一直如此）。必须去看明细里 HIGH 那一类的条数，否则会误判 ② 没生效。

**WHS 为什么是 0.003 而不是 0.2** —— 这是 hold 修补的正常形态，不是没生效：

- `WHS = arrival − required`，而 `-hold 0.200` 把 **required 抬高了 0.2 ns**；
- 布线器的目标是 slack ≥ 0，它把物理延时加够就停手，账面 slack 自然贴在 0 附近；
- 所以保护带体现为**数据路径变长**，不是账面 slack 变大。看数字要看路径明细。

原来那条最差 hold 路径（基线 0.020 ns）的实测对比：

| 项 | 基线 | 本次 |
|---|---|---|
| 源 → 目的 | `LSU_Inst0/rs2_value_reg_pipe_reg[11]/C` → `DCache_inst/store2_wdata_reg[11]/D` | 同一条 |
| Data Path Delay | 0.342 ns（route 0.178） | **0.445 ns（route 0.304）** |
| Clock Uncertainty | 0.035 ns（无 UU） | **0.200 ns（+UU）** |
| Clock Path Skew | +0.263（帮忙方向） | +0.017（DCD 2.356 − SCD 1.807 − CPR 0.532） |
| Slack | 0.020 ns | **0.156 ns** |

即：数据路径多绕了 0.103 ns 的线，同时在要求严格了 0.165 ns 的前提下 slack 还从
0.020 涨到 0.156 —— 这条路径现在是**真的有余量**，不是擦线。

★ 另一个意外：**全局最差 hold 从 CPU 挪到了 ILA 内部**
（`u_ila_0/inst/ila_core_inst/u_ila_regs/MU_SRL[23].mu_srl_reg/shadow_reg[10] → [9]`，
data 0.328 ns，slack 0.003）。CPU 侧已经修得比 ILA 还宽，说明保护带是全域生效的。
这条也是同一时钟域（`clk_sys_unbuf`），同样带 `0.200ns + UU`。

**代价：WNS 2.027 → 1.108 ns（−0.919），比我预估的 −0.1~−0.2 差 4 倍以上**

| 项 | 基线 | 本次 | Δ |
|---|---|---|---|
| WNS | 2.027 | **1.108** | −0.919 |
| 关键路径 Data Path | 17.761（logic 3.713 + route 14.048） | 18.520（logic 3.274 + **route 15.246**） | +0.759 |
| Clock Uncertainty | 0.082 | 0.182（**+UU 0.100**） | −0.100 |
| Clock Path Skew | −0.159 | −0.221 | −0.062 |
| Fmax（20 ns − WNS） | 55.64 MHz | **52.93 MHz** | −2.7 MHz |

死因是 **route +1.198 ns**（logic 反而少了 0.439）。机制：给 `clk_sys_unbuf` 全域
36707 个端点统一加 0.2 ns hold 要求后，布线器要在**大量短路径**上主动绕线加延时，
把本来就 79~82% 靠布线的关键路径挤得更长。这不是"某条路径被牺牲"，而是全局布线资源
被 hold 修补占用的副作用 —— 证据：连 `dbg_hub` 的 TCK 路径 route 也从 8.948 涨到 9.256。

**面积几乎没变**（说明布线器选择绕线而不是插缓冲）：

| 资源 | 基线 | 本次 |
|---|---|---|
| Slice LUTs | 36102 | 36104（+2） |
| Slice Registers | 22241 | 22272（+31） |
| Block RAM Tile | 38.5 | 38.5 |
| DSPs | 4 | 4 |

★ 那 +31 FF **不是** hold 修补带来的：综合阶段的资源报告两次**逐位相同**
（`util_post_synth` 都是 Slice LUTs 36077 / Slice Registers 21544），
差异出现在实现阶段自动生成的调试逻辑（`dbg_hub` / ILA 库存清单）里，与本设计无关。

**结论与可选后续**

保护带买到了（CPU 短路径物理 +0.103 ns、slack 0.020→0.156），代价是 0.92 ns 的
setup 余量。50 MHz 下还剩 1.108 ns（5.5% 周期），**约束依然满足、bitstream 可用**。
若认为代价过大，按代价从低到高有四个选项：

| 选项 | 做法 | 预期 |
|---|---|---|
| A0 | 保持现状 | WNS 1.108 / 保护带 0.200 |
| A1 | `-hold` 降到 **0.150**（改 `v9_board_ila.xdc:103` 一个数） | 保护带减半，WNS 预计回到 1.4~1.5 |
| A2 | 只给 `clk_sys_unbuf` 加、**不给 `sys_clk`** 加（`sys_clk` 上本来没有用户逻辑跑，只有 1 个 WPWS 端点） | 省一点 setup 悲观量，收益 <0.05 |
| A3 | 打开 `STEPS.POST_ROUTE_PHYS_OPT_DESIGN = ExploreWithHoldFix`，让工具**插入专用延时单元**而不是靠布线器乱绕 | 可能同时改善 WNS 与 WHS，但要多跑一次 20 min |

★ 一个必须写清的认识：hold 保护带买的是"模型没算到的抖动/OCV 余量"，
它天生要消耗 setup。**不可能既把 hold 账面 slack 提到 0.2、又不付 setup 代价** ——
账面 slack 只在要求被满足时才存在，而物理余量一旦加上就永久占用时序预算。

**新增工具（可重复执行）**

| 文件 | 作用 |
|---|---|
| `_diag/chk_holdfix.py` | 6 条硬判据 + WNS/Fmax，读报告与日志，输出 PASS/FAIL |
| `_diag/verify_holdfix.tcl` | 开 `impl_1` 只读取证：时钟是否可解析、`get_timing_paths` 的 WNS/WHS、hold 全路径展开、`check_timing` |
| `_diag/verify_cpu_hold.tcl` | 定向查询"原来那条 CPU 短路径"现在的 slack 与数据延时 |
| `project_src/holdfix_baseline/` | 改动前的全套报告 + 旧 bitstream/ltx 备份（可随时回退对比） |


