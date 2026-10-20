# CPU 优化评审 · 性价比与主流差距（v9 基线评审）

> **对象**：BigBird v9 —— RV32IM 六级流水线 + I/D-Cache + gshare 分支预测器
> **平台**：Xilinx xc7z020clg484-1（Zynq-7020），Vivado 2025.2，板级 50 MHz
> **日期**：2026-10-16
> **性质**：只读分析 + 独立实验验证。**未改动任何 RTL / 约束 / 工程文件**
> **验证状态**：关键数字均有两个以上独立来源交叉验证（Vivado 报告 / Quartus 报告 / iverilog 实跑 / 板载 ILA CSV）

> ### ⚠ 本文是"评审"，不是"实施记录"
> 本文写于 2026-10-16，当时**没有改任何 RTL**。之后按本文 §4 的建议动手做了 5 项，
> 实施记录（含每项的 file:line 改动、实测前后对照、踩到的 6 个真 bug）在
> **`docs/历史/IMPLEMENTATION_v10.md`**。
>
> ### ⚠ 证据路径已变（2026-10-20 整理）
> 文中引用的 `project_src/*.rpt`（含 `:行号`）是 Vivado 的生成目录，**整理时已清理**，
> 可用 `build_project_ila.tcl` 重建；**v17 现存的实现报告**见 `_bak/impl_reports/`
> （`timing_post_route.boot.rpt` / `util_post_route.boot.rpt` / `timing_worst_paths.boot.rpt`）。
> 本文的数字本身是当时实测的，仍可用；只有"去哪看原始 rpt"这一句失效。
>
> 一句话对照：整机 7 个程序周期 84/88/253/215/242/288/330 → **36/42/94/55/83/110/97**
> （几何平均 **2.80×**），异常专项 `tb_exc` 从 0 项过变成 **20/20 全过**。
> 下面 §0 的"三件最该做的事"里，第 1/2/3 项与"两件几乎免费的小事"里的 IROM 门控
> 都已落地；本文其余章节保持原样（作为决策依据留档，不回改）。

---

## 0. 摘要（TL;DR）

**v9 的功能正确性做得很扎实**（官方差分 `cdp-tests` 39/39、板上 ILA 逐拍验证、7 个程序 iverilog 246/246）。
但实测暴露出**两个结构性天花板**，而且**都不在它一直优化的方向上**：

| 天花板 | 实测结论 | 根因性质 |
| --- | --- | --- |
| **性能** | **取指前端每 3 拍才交付 1 条指令**（0.33 IPC 上限）；整机 IPC 0.15~0.24 | **架构性**：前端与 PC 强耦合，没有取指缓冲 |
| **频率** | 关键路径 15.9 ns 里 **逻辑仅 3.4 ns、布线 12.5 ns**；芯片只占 38% | **物理性**：布局未约束 ⇒ **零 RTL 改动可提频** |

**三件最该做的事**：

| 优先级 | 动作 | 收益 | 代价 | 风险 |
| --- | --- | --- | --- | --- |
| **1** | **布局约束 + 实现策略** | **Fmax 61 → 80~100 MHz** | 0 行 RTL，0.5 天 | **零** |
| **2** | **前端解耦（取指队列 / 2 字取指）** | 取指 3→2 拍，**~1.2~1.3×** | +70~120 LUT / +70~110 FF，20~40 h | 高 |
| **3** | **MDU：乘法器合一 + 除法 Radix-4** | 除法 **34→18 拍**（除法密集 ~1.6×） | 只改 1 文件，1 天 | 低 |

**两件几乎免费的小事**：IROM 读使能门控（省 2/3 的 ROM 翻转）、PHT 初始化改 taken + `jal` 旁路 PHT（估 4~6%）。

---

## 1. 实测基线

### 1.1 时序（`project_src/timing_post_route.rpt:392-483`）

| 项 | 值 |
| --- | --- |
| WNS / WHS | **+3.445 ns / +0.032 ns**，失败端点 **0**（`All user specified timing constraints are met.`） |
| 时钟 / Fmax | 20 ns（50 MHz）/ **Fmax ≈ 61 MHz**（Quartus 侧独立实测 78.2 MHz，`syn/quartus_modelsim_实测.md:256-276`） |
| 关键路径 | **15.897 ns** = 逻辑 **3.365 ns (21.2%)** + 布线 **12.532 ns (78.8%)** |
| 逻辑级数 | 15 级（`LUT6×6 LUT5×3 LUT3×2 LUT2×1 CARRY4×3`） |
| 时钟偏斜 | DCD 6.054 / SCD 6.592 ⇒ **−0.052 ns** |

**关键路径唯一**：`timing_worst_paths.rpt` 里 **20 条失败端点全部同源**，就是同一条链。

```
EXU_Inst0/add2_reg_reg[3]/C            ← 源（扇出 128，net 1.574 ns）
  → Control_inst0（前递 mux）
  → ALU_i0/add_inst0（32 位加法器算分支目标，3×CARRY4，1.06 ns）
  → Ex_result[9]（net 1.385 ns）
  → Control_inst0/bp_misp_det        ★ 32 位目标比较器（3×CARRY4，0.743 ns）
  → bp_hold_exu + EXU_inst_clear（+LUT5+LUT6，1.05 ns）
  → dnpc_flag（扇出 36，0.928 ns）
  → IDU_Inst0/flush
  → IDU_Inst0/inst_d[11]_i_1（LUT2）
  → IDU_Inst0/inst0（★ 扇出 278，走线 2.118 ns）
  → IDU_Inst0/pi_d_reg[4]/R            ← 终点
```

**两个关键发现**：

1. **`Control` 自身只有 3 级 LUT。** 深度来自两端：上游是**两条 32 位进位链串在一个周期里**
   （ALU 加法器 + 误预测目标比较器）；下游是 `flush`(fo=36) / `inst0`(**fo=278**) 的高扇出广播网。
2. **这条链一次都没经过 `inst_d` 的译码逻辑本身** —— 命中的是 `pi_d`/`pi_s1`（预测元数据）和 `pc_d` 的 flush 端口。
   ⇒ **`IDU` 拉成两级流水想给译码留的余量，在这条真正的最差路径上一分钱都没用上。**

> 补充：全设计最差的 **hold** 路径也在前端 —— `ICache_inst/align_tag_r_reg[22] → tag_reg_0_63_22_22`，**+0.045 ns**
> （`docs/vivado/vivado_50mhz_实测.md:156-157`）。即 **tag LUT-RAM + 比较就是压住 Fmax 的那一处**。

### 1.2 资源（`project_src/util_post_route.rpt`）

| 资源 | 整机（含 ILA） | CPU 本体（`syn/synth_report.md`，yosys） | 结论 |
| --- | --- | --- | --- |
| LUT | **13006 (24.5%)**（逻辑 12232 / 存储器 774） | 8218 | **ILA / dbg_hub 吃掉 ~4788 LUT ≈ 37%** |
| FF | **14765 (13.9%)** | 5589 | **ILA 吃掉 ~9176 FF ≈ 62%** |
| BRAM | **38.5 (27.5%)** | IROM 4 + DRAM 16 | **ILA 捕获缓冲吃掉 ~24 块 ≈ 63%** |
| DSP48E1 | 12 (5.45%) | 12 | **全部来自 MDU 的 3 个并行 32×32 乘法器**（4 DSP/乘法器） |
| F7 / F8 Muxes | 1651 / 638 | — | 主要来自前递 mux 网络 |
| LUT as Memory | 774 | — | `RAM64X1S×56 + RAM64X1D×22` |

> ⚠️ **两列来自不同工具**（Vivado post-route vs yosys `synth_xilinx`），口径略有差异，但量级可靠：
> **debug 基础设施占了本工程约 2/3 的 FF 与 3/5 的 BRAM。**

### 1.3 整机性能（作者权威日志 `teach/log/*.log`，逐项计算）

| 程序 | 周期 | 有效写回 | **IPC** | stall 占比 | ICache 访问 | 2×访问 |
| --- | --- | --- | --- | --- | --- | --- |
| prog | 82 | 12(+2) | ~0.17 | 44% | 65 | 130 |
| prog_div | 200 | 10 | **0.05** | **81%** | 186 | 372 |
| prog_div_pair | 271 | 31 | 0.114 | 63% | 236 | 472 |
| prog_load_lane | 214 | 40 | 0.187 | 41% | 170 | 340 |
| prog_load_use | 241 | 44 | 0.183 | 41% | 192 | 384 |
| prog_loop | 287 | 58 | 0.202 | 38% | 210 | 420 |
| teach_loop_alu | 85 | 16 | 0.188 | 39% | 60 | 120 |
| teach_loop_loaduse | 108 | 21 | 0.194 | 42% | 78 | 156 |

**恒等式**：`总周期 ≥ 2 × ICache 访问次数`（8 个程序全部成立）。
这是"每 2~3 拍才能取一条指令"的直接体现（长程序收敛到 3，短程序因冷启动更大）。

> `docs/模块阅读文档.md:75` 声称"稳态 1 IPC"（`docs/模块阅读文档.md:75`）—— **实测未达到**。

---

## 2. ★ 停顿来源分解（本轮新增的决定性实验）

两个自研测试台（`_diag/`，**未改动任何 RTL**）：

### 2.1 前端孤立测量（`_diag/tb_fe_real.sv`，用**真** `rtl/ICache.sv`）

```
SUMMARY prog=prog_seq.hex     cyc_window=396 delivered=132 hold_cycles=264
        addr_align_bubbles=132 ctrl_stall_cycles=0 icache_hits=134 icache_misses=132
SUMMARY prog=prog_loop_fe.hex （同上，逐字一致）
SUMMARY prog=prog_branch_fe.hex（同上）
SUMMARY prog=prog_jal_fe.hex  （同上）
```

**`132 条 / 396 拍 = 每 3 拍 1 条指令`**，四种负载（顺序/循环/分支/jal）**逐字一致**；
`hold_cycles=264`（**66% 的周期是自伤停顿**），其中 `addr_align_bubbles=132` —— **正好等于交付条数**。

> ⚠️ 注意 `icache_hits=134 / misses=132` 里的高 miss 率是**人造负载的假象**（该 harness 的程序区被 NOP 填满，
> 每个新地址都是强制 miss）。真实程序的 miss 率是 10~20%（`prog_loop` 33/209）。
> **但 3 拍节拍与 miss 率无关**：它是地址稳定性气泡造成的。

### 2.2 全 CPU 停顿归因（`_diag/tb_stall_sources.sv`）

```
myCPU.sv:175   assign IFU_stall = IFU_stall_ctrl | icache_hold | dcache_hold;
Control.sv:297 assign IFU_stall_ctrl = load_use_stall | mdu_busy;
```

| 程序 | 总周期 | IFU_stall | **ICache hold** | DCache hold | **load_use** | **mdu_busy** |
| --- | --- | --- | --- | --- | --- | --- |
| prog | 82 | 36 (44%) | **~27 (33%)** | 2 (1%) | **7 (3.4%)** | 16 (8%) |
| prog_loop | 287 | 110 (38%) | **110 (38%)** | 0 | **0** | **0** |
| prog_load_lane | 214 | 87 (41%) | **86 (40%)** | 2 (0.4%) | **0** | **0** |
| prog_div | 200 | 162 (81%) | ~34 (17%) | 0 | 0 | **~162 (81%)** |

> `prog_loop`（110/110）与 `prog_load_lane`（86/87）两行是**精确相等**的硬数据 —— 这两个程序里停顿**只有一个来源**。
> 带 `~` 的按精确比例与权威日志反推。

**这张表直接给出优先级**：

1. **ICache hold = 前端停顿的全部** ⇒ 唯一的前端杠杆；
2. **load_use 在循环里 = 0**（`prog_load_lane` 45 条 load，load_use 却是 0，因为消费者隔得足够远）；
3. **mdu_busy = 除法程序停顿的全部**（81%）。

### 2.3 DCache 命中路径（`_diag/tb_load_latency.sv`）

```
=== 第 1 次 load 0x40（冷启动，预期 miss）===
  cyc=8   M2=1 addr=00000040 | DCache: en=1 hit=0 miss=0 hold=1   ← miss
  cyc=10  M2=1 addr=00000040 | DCache: en=1 hit=0 miss=1 hold=0   ← 回填，撤销 hold
  >>> 冷启动：hold 拍数 = 2，数据到达拍 = 6

=== 第 2 次 load 0x40（同一行已驻留，预期命中）===
  cyc=22  M2=1 addr=00000040 | DCache: en=1 hit=1 miss=0 hold=0   ← ★ 命中，hold=0
  >>> 命中路径：hold 拍数 = 0，数据到达拍 = 3
```

**DCache 命中路径 0 停顿，miss 才停 2 拍。**

---

## 3. 根因分析

### 3.1 ★ 为什么每 3 拍才能取一条指令（前端——**第一大瓶颈**）

`ICache.sv` 的**行大小 = 1 个 32 位字**（`para.sv:151-154`、`ICache.sv:19,57`），配合同步 BRAM
（请求 1 拍、数据下一拍，`board/sync_mem.sv:89-92`），**再加上一处结构性的相位错配**：

| 拍 | `cpu_addr` | `cpu_addr_r` | `mem_rdata` 属于 | `addr_same_r` | `fetch_align` | 能否接收 |
| --- | --- | --- | --- | --- | --- | --- |
| T | A | A | — | — | 0 | ✗ |
| T+1 | A+4 | A | **A**（1 拍前） | **0** | **0** | ✗ ← **废拍** |
| T+2 | A+4 | A+4 | A+4 | 1 | 1 | ✓ 命中 |
| T+3 | A+8 | A+4 | A+4 | **0** | **0** | ✗ ← **又一个废拍** |

**根因（`ICache.sv:94` + `:128` + `:134`）**：

```systemverilog
// :94   接受条件绑在「活的」地址上
assign addr_same_r = (cpu_addr == cpu_addr_r) & cpu_en_r;
assign fetch_align = resp_valid_r & addr_same_r;      // :97

// :128  请求侧寄存器
cpu_index_r <= index;      // 描述 T-1 的请求
// :134  比较侧又寄存一拍  ★ 关键
align_index_r <= cpu_index_r;   // 描述 T-2 的请求
```

`align_*_r` 描述的是**两拍前**的取指，而 `mem_rdata` 来自**一拍前**的取指（`myCPU.sv:302-304` 把
`inst_valid` 接 `fetch_align`、`mem_stall` 接 `hold`）。**两者只有在 PC 不动的那一拍才一致** ——
这正是 `addr_same_r` 强行把 PC 冻住一拍的原因。

**⇒ 每个新 PC 都必然废掉一拍，而且因为 `IFU.sv:71` 的 `advance_en = valid & ready & inst_valid`
只在接收时才推进 PC，这个废拍永远藏不掉。净效果 = 每 3 拍 1 条指令。**

**关键负结果 —— 显而易见的"修法"全部失败（子代理实跑验证）**：

| 尝试 | 结果 |
| --- | --- |
| `-DICACHE_OPT`：去掉 `addr_same_r` | 2 拍/条，但**自检 FAIL**（`prog` 10 处不符、`prog_loop` 4 处）—— 回填时写错行 |
| 变体 FIX：`align_*_r <= index/tag_in` | 2 拍/条，**FAIL**（`prog` 10 处）—— PC 不能前进时同一响应被连续交付两次 |
| 变体 O2：基于边沿的 accept | **活锁** —— `icache_hit=0 icache_miss=0`，因为 accept 依赖 `hold`（`:107`），而 `hold` 又依赖 `fetch_align` |

**⇒ 真正的修法是"把响应存起来"（取指队列），不是"改宽比较器"。**
这条结论很重要：**不要让任何人"顺手把地址稳定性检查删掉"**（会静默算错）。

### 3.2 为什么除法让整机停 34 拍

`MDU_pipelined.sv:148-158` 是**每拍 1 位的恢复余数法**，`DIV_BITS=32` ⇒ 32 拍迭代 + 装载拍 + `div_hold` 结果窗口 = **34 拍**。
`busy` 经 `EXU.sv:183 mdu_busy = mdu_stall` 传播后**同时冻结三处**：

- `Control.sv:297` → 冻 PC + 冻 IDU（前端）
- `LSU.sv:152` → 冻 LSU 三级流水
- `EXU.sv:195` → 冻 EXU 自己的 valid/data 寄存器

而且 `Control.sv:125,130` 还用 `~mdu_busy` 屏蔽分支判定、`Control.sv:270` 屏蔽中断接收。**整机吞吐 1/34。**

### 3.3 分支误预测：惩罚 4 拍，且预测器常常学不会

- **惩罚 = 4 拍**（`_fw/penalty.py` 实测）：重定向后 PC 要 2 拍才到 `dnpc`，目标指令再 1 拍才被交付 = **3 拍前端空**，
  加约 1 拍流水排空。对比：**正确预测的 taken 分支仍要 1 拍气泡**（任何 PC 不连续都要一次 PWRITE→PREAD 交替）。
- **预测器常常不收敛**：`prog_loop` 实测 **9 次误预测 / 10 条控制流指令**（9 次 `[RDR] … mispredict=1`，
  VCD 里每个稳态循环迭代都有 `dnpc_flag` 脉冲）。

> ⚠️ **口径陷阱**：日志里 `BPU : pred=10 hit=9 miss=1` **不是分支准确率**！
> `Branch_Predictor.sv:126-128` 的 `hit_cnt` 统计的是"预测与**解析结果**一致"，而
> `bp_pred_cnt/bp_hit_cnt/bp_miss_cnt` 在 `myCPU.sv:187` **根本没被读出**。
> 用这个计数器评估预测器会严重高估。

- **成因**：PHT 初值 `2'b01` 弱不跳转（`Branch_Predictor.sv:102`），而 `update_en` 只在 EX 发生
  ⇒ 3 拍节拍下**第一次执行每条 taken 控制流必然误预测**；`jal` 也被同一个共享饱和计数器门控（`:84`）。
- **代价**：`prog_loop` 里约 36 / 288 拍 ≈ **12%**。

---

## 4. 优化清单（按性价比排序）

| # | 优化项 | 依据 | 收益 | 代价 / 风险 | 工时 | **性价比** |
| --- | --- | --- | --- | --- | --- | --- |
| **1** | **布局约束 + 实现策略** | 逻辑 3.4 ns / 布线 12.5 ns；占空比 38%；`build_project_ila.tcl:188,207` 用**默认策略**（无 `-directive`）；路由器中间值曾自报 WNS=**3.930**（优于收敛后的 3.445） | **Fmax 61 → 80~100 MHz** | **0 行 RTL，零功能风险** | 0.5 天 | ★★★★★ |
| **2** | **前端解耦：取指队列 / 2 字取指** | §2.1：**每 3 拍 1 条**；§2.2：ICache hold = 停顿全部（33~40%） | 取指 **3→2 拍**，**~1.2~1.3×**（`prog_loop` 287→~190~210 拍） | +70~120 LUT / +70~110 FF；**高风险**（重写 IFU-1/ICACHE-1 握手不变量） | 20~40 h | ★★★★☆ |
| **3** | **MDU：乘法器合一 + 除法 Radix-4** | 12 DSP 全在 MDU（4/乘法器×3）；除法 34 拍，实测占除法程序 **81%** 停顿 | **~1.6×**（除法密集）+ **−8 DSP** | 只改 1 个文件，低风险 | 1 天 | ★★★★☆ |
| **4** | **剥离 ILA（交付版）** | LUT 4788(37%) / FF 9176(62%) / BRAM ~24(63%)；ILA 版比引脚版低 **4.8 MHz**（`vivado_50mhz_实测.md:149-154`） | 面积 + 提频 | 构建开关，零风险 | 0.5 天 | ★★★★☆ |
| **5** | **PHT 初始化改 taken + `jal` 旁路 PHT** | PHT 初值弱不跳转（`Branch_Predictor.sv:102`），`jal` 被共享计数器门控（`:84`）⇒ 首次执行必误预测 | 估 **4~6%**（`prog_loop` 12% 误预测代价的一部分） | +10~20 LUT，低中风险 | 2~4 h | ★★★★☆ |
| **6** | **IROM 读使能门控（省电 + 修计数器）** | `ICache.sv:80,130` 的 `mem_en` 上电后**恒为 1**，`myCPU.sv:741` 直连 ⇒ 16KB ROM **100% 周期被读**，而只有 ~33% 在做有效工作。`myCPU.sv:31-32` **明确禁止** DCache 这么做（DCache 已正确门控）——同一规则从未施加到 ICache | 0 周期；省 ~2/3 ROM 翻转；计数器变可信 | **+2 LUT，低风险** | 1~2 h | ★★★★☆ |
| **7** | **DCache `data` 数组修成 RAM** | **已独立验证**：`synth_1/runme.log` 报 `WARNING [Synth 8-4767] Trying to implement RAM 'data_reg' in registers ... [DCache.sv:252]`，原因 *"multiple writes via different ports in same process"*（回填 `:245` + store 合并 `:249-261`）；对照 ICache 同结构成功推断为 `RAM64X1S` | **−2048 FF / −1.5~2.5k LUT** | 中风险（数组失去复位初值，靠 `valid[]` 门控） | 6 h | ★★★☆☆ |
| **8** | **寄存器堆推断成 LUTRAM** | distributed-RAM 最终报告里**只有** ICache `tag/data` + DCache `tag`，**RF 缺席** ⇒ 停在触发器（整数组复位循环 `RegisterFile.sv:27-29` 阻断了 LUTRAM 映射） | −1024 FF / −600~1100 LUT | 中高风险（4 态仿真丢 x0 初值） | 5 h | ★★★☆☆ |
| **9** | **ICache tag 24→20 位 / 寄存 tag 阵列** | tag 宽度按 32 位地址算（`para.sv:154`），但 IROM 只有 4096 字（13 位地址）；且**全设计最差 hold 路径就在这里**（+0.045 ns） | 0 周期；买 hold 余量 | −4 LUT-RAM，低风险 | 2~3 h | ★★★☆☆ |
| **10** | **load-use 的 M2 前递** | §2.2：load_use 只占 3.4%（`prog`），循环里为 **0** | 有限（~1.03×） | 中风险 | 1 天 | ★★☆☆☆ |
| **11** | **关键路径改造（P1/P2/P3）** | 32 位目标比较器（3×CARRY4）；`flush`/`inst0` 高扇出（2.118 ns） | 80~85 MHz | 高风险 | 10~14 h | ★★☆☆☆ |
| **12** | **RAS（返回地址栈）** | 完全缺失（`Branch_Predictor.sv:32-58` 无相关端口）；返回靠 BTB tag+target | **当前程序为 0**（`BPU pred=0` for mul/div/load）；仅调用密集代码有价值 | +120~200 LUT / +270 FF，低中风险 | 6~10 h | ★★☆☆☆ |
| **13** | **异常体系补全** | `TRAP_ENABLE=0`（`Control.sv:18`，`myCPU.sv:361` 未覆盖）⇒ **整块同步异常是死逻辑**；且 `trap_redirect` 未进 `intr_safe`（`Control.sv:268-271`），中断与同步异常可同拍抢写 `mepc` | 功能债，非性能 | 高风险 | 2~3 天 | ★★☆☆☆ |

### 明确**不建议**做的事

| 项 | 为什么不做 |
| --- | --- |
| ~~DCache 同拍命中判定~~ | §2.3 实测证明命中已是 **0 停顿**，收益为 0 |
| ~~"顺手删掉 ICache 的 `addr_same_r`"~~ | **实测会静默算错**（§3.1 三种变体全失败：10 处不符 / 活锁）。必须走队列方案 |
| **4 字行 / 预取（先于队列做）** | miss 已经只 +1 拍、miss 率 10~20% ⇒ **≤5% 周期**；前端瓶颈是"两拍一个响应"，不是 miss 率 |
| MDU 面积优化 | DSP 只用 **5.45%**（12/220），不紧张；单乘法器会变慢 1~2 ns ⇒ **除非 LUT 紧张** |
| `IDU` 两级流水合成一级 | 关键路径不经过译码逻辑，但 `RegisterFile.sv:36-38` 是**组合读**，去掉一级会让"组合读 → 前递 mux → ALU"变长 ⇒ **可能反而恶化时序** |
| 删 `IFU` 的 `valid` 触发器 | 0 收益，但 `syn/修复史_全量.md` §IFU-1 记录它是为修 `mem_stall_r` 相位错误而加的 ⇒ **风险 >> 收益** |
| 硬冲 100 MHz | 布线占 78.8%，高扇出远距离布线**不会因逻辑变浅而消失**；**先拿第 1 项那 20~40 MHz 更划算** |
| 缩小 64 行 Cache 几何 | 问题在**实现方式**（DCache data 停在 FF），不在容量 |
| 把 DCache 数组塞进 Block RAM | 64×32 用 LUTRAM 更省，而 **BRAM 是本设计最紧的资源**（ILA 已吃掉 63%） |
| 重新启用 `MDU.sv`（组合版） | 2150 LC / 419 CARRY4 vs 时序版 407 / 81 ⇒ **严格更差** |

---

## 5. 与主流设计的差距

| 维度 | **v9** | PicoRV32 | VexRiscv | SweRV EH1 | Rocket | CVA6/Ariane | BOOM |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **取指** | 1 字，**1 条 / 3 拍** | 1 字，无 cache | 1/拍 + fetch buffer | 1~2 字，1/拍 | 16B 行，1/拍 | 32b，1/拍 | 2 路，4/拍 |
| 发射宽度 | 单发射顺序 | 单发射 | 单发射 | **双发射** | 单发射 | 单发射 | 超标量乱序 |
| 流水级数 | 8 物理 / 5 功能 | ~3~5 | 5 | 9 | 5 | 6 | 10+ |
| 分支预测 | gshare 64 PHT + 64 BTB，6 位 GHR | **无** | 静态/BTB | BHT+BTB+**RAS** | BTB+BHT | TAGE+BTB+**RAS** | TAGE+**RAS** |
| **RAS** | **无** ❌ | 无 | 无 | 有 | 有 | 有 | 有 |
| 分支解析级 | **EX**（冲刷 4 拍） | — | ID/EX | ID | ID | ID | ID |
| L1 I/D | 64 行 DM，**行=1 字**（256 B） | 无 | 2~4KB，4 字行 | 16KB 4 路 | 4~16KB 4 路 | 16~32KB 4 路 | 16~64KB 8 路 |
| **预取 / 取指缓冲** | **完全没有** | 无 | fetch buffer | IBUF+预取 | IBUF | 队列+预取 | 缓冲+预取 |
| miss 处理 | **阻塞、单笔在飞、+1 拍** | — | 阻塞 | 阻塞 | 阻塞 | **非阻塞（MSHR）** | 非阻塞（MSHR） |
| **写缓冲** | **无**（写直达直压总线） | — | — | 有 | 有 | 有 | 有 |
| **除法** | **34 拍，冻死整机** | — | 迭代反压 | 迭代反压 | 33 拍流水 | Radix-4 迭代 | 流水 |
| **异常/特权** | **TRAP_ENABLE=0（默认关）** ⚠️ | 无 | 无/部分 | 完整 | M/S/U | M/S/U | 完整 |
| 验证 | 39/39 cdp-tests + 板上 ILA | — | — | UVM | — | 形式化 | — |

### 三个真正的"代差"（不是参数差）

1. **完全没有取指解耦手段。** 主流核全部在"同步 BRAM"与"PC 产生"之间插**取指缓冲 / 预取队列**。
   v9 的 `IFU` **只在接收时才推进 PC**（`IFU.sv:71`），而 `ICache` 又把在飞请求绑在**活的 PC** 上（`ICache.sv:94`）
   ⇒ **没有任何地方能停住一个已取到的字**。这是 3 拍节拍的根因，也是整机 33~40% 周期的来源。
   **v9 缺的不是预测器，是取指缓冲。**
2. **投机恢复比主流慢。** Rocket/CVA6/SweRV 都在 **ID** 解析分支，v9 在 **EX**（`Control.sv:125,196`），
  且解析结果还要穿过长组合链才变成 flush ⇒ 惩罚 4 拍。
3. **物理实现没被当作设计的一部分。** 38% 占空比、78.8% 布线占比、20 条最差路径全同源 ——
   这是"逻辑写对了、布局没管"的典型形态。**这一条 v9 完全可以靠 0 行 RTL 补上。**

### v9 反而做得好的地方

- **握手契约统一且被文档化**：`valid_last/ready_last/valid_next/ready_next` 一套命名贯穿全设计，
  `★ 不变量` 标记 **129 处**，踩坑史 **228 KB** 归档 —— 这个纪律性强于绝大多数课程设计。
- **有真实的动态预测器 + 真实的 I-Cache**（PicoRV32 类没有），且命中路径的面积比 CVA6/BOOM 的 tag bank 更省。
- **板上 ILA 逐拍取证**（B9 的 `ecall` 重定向定位）—— 很多项目都没做到这个颗粒度。
- **官方差分真的跑通了**（H1/H2/H3，0/39 → 39/39），而不是只跑自带测试台。

---

## 6. 更正记录（相对分析过程中的中间结论）

| 中间结论 | 更正后 | 依据 |
| --- | --- | --- |
| "前端每 **2 拍** 1 条指令" | ❌ **每 3 拍 1 条**（`delivered=132 / 396`），0.33 IPC 上限 | `_diag/tb_fe_real.sv`，四种负载逐字一致 |
| "每条 load 固定 3 拍，命中也要走完整 miss 流程" | ❌ **命中 0 停顿**，miss 才 2 拍 | `_diag/tb_load_latency.sv` |
| "做 DCache 同拍命中判定可省 2 拍/load" | ❌ **作废**，收益为 0 | 同上 |
| "ICache 加宽是低风险 1.5 天改动" | ⚠️ **必须配取指队列**；单纯改宽/去门控**会算错**（3 种变体全失败） | `_fw/FRONTEND_REPORT.md` §2/I-1 实跑 |
| "load_use 是主要停顿之一" | ⚠️ **循环里为 0**，只在 `prog` 里占 3.4% | §2.2 逐拍分解 |
| "分支误预测惩罚 2 拍" | ⚠️ **4 拍**（3 拍前端空 + ~1 拍排空） | `_fw/penalty.py` |
| "BPU `hit=9 miss=1` 说明预测器很准" | ❌ 该计数器**不是准确率**，它统计"预测与解析一致"；实测 **9 误预测 / 10 条控制流** | `sim/build/prog.log` + VCD |
| "除法收益 ~1.35×" | ✅ **加强**为 **~1.6×**（mdu_busy 实测占除法程序 **81%**） | §2.2 |

---

## 7. 建议的实施顺序

| 阶段 | 动作 | 预期 | 风险 |
| --- | --- | --- | --- |
| **P0** | 实现策略（`-directive`）+ Pblock 约束 | **Fmax 61 → 80~100 MHz** | **零** |
| **P0** | ILA 剥离开关（交付版） | −37% LUT / −62% FF / −63% BRAM | 零 |
| **P0** | IROM 读使能门控 + 计数器加 `~stall`（1~2 h） | 省电 + 计数器可信 | 低 |
| **P1** | PHT 初始化改 taken + `jal` 旁路 PHT（2~4 h） | 估 4~6% | 低中 |
| **P1** | MDU 三乘法器合一（2 h） | −8 DSP | 低 |
| **P1** | 除法 Radix-4 | 除法 **34 → 18 拍** | 低 |
| **P2** | **前端解耦：2~4 项取指队列**（20~40 h） | **3→2 拍/条，~1.2~1.3×** | **高**（先补前端断言） |
| **P3** | DCache data → RAM；RF → LUTRAM | −3k FF / −2~3.5k LUT | 中 |
| **P3** | ICache tag 24→20 位 | 买 hold 余量 | 低 |
| **P4** | 异常体系补全（`TRAP_ENABLE` 的 D1/C4） | 功能补完 | 高（**功能债，迟早要还**） |
| 不做 | DCache 同拍命中 / MDU 面积 / IDU 合级 / RAS / 硬冲 100 MHz | — | 见 §4 |

**如果只做一件事**：做 P0 的布局约束 —— 半天工时、零回归风险、换来 **~40% 的频率提升**。
**如果做两件**：再加 P2 的前端解耦（这是唯一的性能大杠杆，但要先补断言、且必须走队列方案）。

> **P2 的前置条件**：`sim/tb_iverilog.sv` 已有 `fetch-align (pc<->inst coherent)` 断言，
> 队列方案必须让它继续 PASS，并**新增**"一次响应只被接收一次"的断言。

---

## 附录 A：证据索引

| 结论 | 证据文件 |
| --- | --- |
| 时序 WNS/WHS、关键路径 15.897 ns、逐级增量 | `project_src/timing_post_route.rpt:392-483` |
| 20 条失败端点全同源 | `project_src/timing_worst_paths.rpt:17-60` |
| LUT/FF/BRAM/DSP、F7/F8、distributed RAM | `project_src/util_post_route.rpt:35-45,106-122` |
| CPU 本体资源（8218 LUT / 5589 FF） | `syn/synth_report.md:21-43` |
| `[Synth 8-4767]` DCache data→FF、`[Synth 8-3936]` LSU 裁剪 | `v9_ila/v9_ila.runs/synth_1/runme.log` |
| ILA 配置（depth 2048、16 探针、~430 bit） | `project_src/debug_core_post_route.rpt` |
| 实现策略为默认（无 `-directive`） | `build_project_ila.tcl:188,207` |
| 路由器中间 WNS=3.930 | `build_project_ila.log`（`Route 35-416`） |
| IPC / stall / Cache 计数（作者权威日志） | `teach/log/*.log`、`sim/build/prog.log` |
| 最差 hold 路径 = ICache tag 阵列（+0.045 ns） | `docs/vivado/vivado_50mhz_实测.md:156-157` |
| 最差逻辑/布线比（0.704 ns 逻辑 vs 13.870 ns 布线） | `docs/vivado/vivado_50mhz_实测.md:145-149` |
| Quartus 侧同路径独立实测（78.2 MHz） | `syn/quartus_modelsim_实测.md:256-276` |
| 板上 ILA 实测 PC 每 3 个采样前进一次 | `ila_20261016_0012.csv` |

## 附录 B：本轮新增文件（**未改动任何 RTL**）

### 我（主分析）新增

| 文件 | 作用 |
| --- | --- |
| `_diag/tb_load_latency.sv` | 隔离 `LSU+DCache+sync_mem`，测命中 / miss 各停几拍 ⇒ **命中 0 拍、miss 2 拍** |
| `_diag/tb_stall_sources.sv` | 全 CPU 运行，逐拍把 `IFU_stall` 拆成 ICache / DCache / load_use / mdu_busy 四来源 |
| `_diag/tb_fe_real.sv` | 用**真** `rtl/ICache.sv` 复现前端节拍（去掉 probe 专用信号）⇒ 独立验证 3 拍/条 |
| `_diag/build/*.vvp` | 上述实验的编译产物 |

### 子代理报告

| 文件 | 内容 |
| --- | --- |
| `_fw/FRONTEND_REPORT.md` | 前端完整分析（418 行）：3 拍节拍、3 个失败的"修法"、预测器实测、O-1~O-7 |
| `docs/EXECUTE_CONTROL_数据通路分析.md` | 执行/控制通路逐级拆解（含 file:line 证据） |
| `reports/mem_mdu_analysis.md` | 访存子系统与 MDU 分析 |
| `_fw/` 其余 | 子代理的实验台：`tb_fe.sv`、`tb_lat.sv`、`tb_bp.sv`、`analyze_cpu.py`、`penalty.py`、`probe/ICache_probe.sv` 等 |

### 复跑命令（本机 iverilog：`D:\eda_tools\iverilog\bin`）

```powershell
# 实验一：DCache 命中 / miss 各停几拍
& 'D:\eda_tools\iverilog\bin\iverilog.exe' -g2012 -I rtl -o _diag\build\tb_load_latency.vvp `
  _diag\tb_load_latency.sv rtl\LSU.sv rtl\DCache.sv rtl\sext.sv board\sync_mem.sv
& 'D:\eda_tools\iverilog\bin\vvp.exe' _diag\build\tb_load_latency.vvp

# 实验二：停顿来源分解
& 'D:\eda_tools\iverilog\bin\iverilog.exe' -g2012 -I rtl -I board -o _diag\build\tb_stall.vvp `
  _diag\tb_stall_sources.sv rtl\myCPU.sv rtl\IFU.sv rtl\IDU.sv rtl\EXU.sv rtl\LSU.sv rtl\WBU.sv `
  rtl\ALU.sv rtl\add.sv rtl\sext.sv rtl\Reg.sv rtl\Reg_Stack.sv rtl\RegisterFile.sv rtl\CSR.sv `
  rtl\Control.sv rtl\Data_hazard.sv rtl\ICache.sv rtl\DCache.sv rtl\Branch_Predictor.sv `
  rtl\MDU_pipelined.sv board\sync_mem.sv
& 'D:\eda_tools\iverilog\bin\vvp.exe' _diag\build\tb_stall.vvp +prog=sim/prog_loop.hex +max=900

# 实验三：前端节拍（3 拍/条）
& 'D:\eda_tools\iverilog\bin\iverilog.exe' -g2012 -I rtl -o _diag\build\fe_real.vvp `
  _diag\tb_fe_real.sv rtl\IFU.sv rtl\ICache.sv
& 'D:\eda_tools\iverilog\bin\vvp.exe' _diag\build\fe_real.vvp +prog=_fw/prog_seq.hex
```

## 附录 C：测量口径与已知限制

1. **仿真周期与频率无关。** 前端实验按 20 ns（50 MHz，与约束一致）；停顿分解按 10 ns（100 MHz）。
   论文/报告引用**周期数**时不受影响；引用绝对时间请按板上 50 MHz 换算。
2. **实验二在 `max_cyc` 截断窗口内统计。** `prog_loop`（110/110）与 `prog_load_lane`（86/87）
   是**精确相等**的硬数据（两个程序停顿只有一个来源）；带 `~` 的按精确比例与权威日志反推。
3. **前端 harness 的 miss 率是人造负载的假象。** `prog_seq.hex` 程序区被 NOP 填满，
   每个新地址都强制 miss（132/266）；真实程序 miss 率 10~20%。**但 3 拍节拍与 miss 率无关。**
4. **`syn/synth_report.md` 的数字来自 yosys，不是 Vivado。** 与 Vivado post-route 口径有差异，
   仅用于"CPU 本体 vs 整机"的量级对比。
5. **本仓库没有 per-module 资源报告**（已查 `util_post_route.rpt`、`util_post_synth.rpt`、
   `board_top_gui_utilization_synth.rpt` 三份，均无层次化表格）。子代理报告里 `Control`/`Data_hazard`
   的 LUT 预算（≈300~420 / ≈60~90）是**按 RTL 逐位推算的估算**，已在原报告标注。
6. **`bash` 在本沙箱不可用**（`E_ACCESSDENIED`），故 `sim/run_all.sh` 无法直接运行；
   子代理改用 `vvp` 直接跑 7 个程序，结果 **246/246 全过**。
7. **时序数字有多个口径**，引用时请注明来源：
   - 本目录 `project_src/timing_post_route.rpt`：**WNS +3.445 ns @ 20 ns ⇒ 61 MHz**
   - 早期引脚版记录 `docs/vivado/vivado_50mhz_实测.md`：WNS +4.162 ns ⇒ 63 MHz
   - Quartus 侧 `syn/quartus_modelsim_实测.md`：78.2 MHz
   三者对应不同顶层/工具/版本，**不是矛盾**。
