# teach/ — 讲解专用 RTL（不影响原工程）

> 目的：**不改原工程源码**，单独复制一份 RTL，只做"降低讲解难度 / 修掉波形怪异点"的简化，
> 保证整体架构正确、能跑过验证，然后为它生成一套干净的讲解波形。

原工程（`../*.sv`）一个字没动；本目录是独立副本，可随时删除。

---

## 1. 一条命令

```bash
cd "<v9>"
bash teach/run.sh build     # 只编译
bash teach/run.sh teach     # 编译 + 跑 10 个讲解程序 → teach/wave/*.vcd
bash teach/run.sh regress   # 编译 + 跑 7 个回归程序，检查自检 PASS
bash teach/run.sh all       # 全部
bash teach/view.sh teach_alu   # GTKWave 打开讲解波形
```

产物：

| 路径 | 内容 |
| --- | --- |
| `teach/wave/*.vcd` | 讲解波形（verilator 产出） |
| `teach/wave/*.gtkw` | 对应 GTKWave 会话（含新增观测信号） |
| `teach/log/*.log` | 每个程序的完整日志（含自检结论） |
| `teach/obj_dir/` | verilator 编译产物（实际在 /tmp/v9teach，不占工程） |

> 因为源码路径含空格，verilator 的 `--Mdir` 用不了，所以 `run.sh` 先整体复制到
> `/tmp/v9teach` 再编译，运行完把波形/日志拷回来。

---

## 2. 简化/修复清单

改动**只集中在 `teach/rtl/EXU.sv` 一个文件**，共两处。

### 改动① 数据寄存器也遵循 `EXU_inst_clear`（让 EX 结果与 valid 同拍）

**原版**：

```verilog
// 数据寄存器：不看 clr
else if (valid_last & ready_next & ~mdu_stall & ~bp_pend)  ...锁存...
// valid_next：看 clr
else if (ready_last & valid_last & EXU_inst_clr) valid_next <= 0;
```

于是 `clr=1` 那拍"**数据照锁、valid 被压 0**"，波形上 **`EX 结果` 比 `EX valid` 早一拍**。

**讲解版**：

```verilog
else if (valid_last & ready_next & ~mdu_stall & ~bp_pend & ~EXU_inst_clr)
```

`clr=1` 那拍数据也不锁 → 数据和 valid 落在同一沿。因为 `clr` 那拍 `valid=0`，数据本来没用，所以结果等价。

效果（teach_alu）：

| 版本 | cyc14 | cyc15 | cyc16 |
| --- | --- | --- | --- |
| 原版 | clr=1，锁数据 | `EX结果=5`，valid=0 | valid=1 |
| 讲解版 | clr=1，不锁 | — | **`EX结果=5`，valid=1（同拍）** |

### 改动② 修掉 MDU 的"重复发射"

**现象（原版）**：同一条 M 指令被 MDU 发射两次，div 的 34 拍迭代跑两趟。

| 波形 | M 指令执行次数 | `mdu_start` 次数（原版） | `mdu_busy`（原版） |
| --- | --- | --- | --- |
| teach_mul | 3 | **4** | 8 |
| teach_div | 1 | **2** | **68**（≈34×2） |
| prog_mul | 8 | **9** | 18 |
| prog_div | 4 | **6** | 204 |
| prog_div_pair | 3 | **5** | 170 |

**根因**：清 `mdu_issued` 的条件比"数据寄存器锁存条件"宽松：

```verilog
// 原版：结果窗口那拍就满足，但此刻 EX 里还是同一条 M 指令
if (valid_last & ready_next & ~mdu_stall) begin
    mdu_issued <= 0; mdu_res_vld <= 0;
end
```

结果窗口一到（`mdu_res_vld=1` → `mdu_stall=0`）就清了标志，同一条 M 指令又被 `mdu_start` 发一次。

**讲解版**：把清标志的条件与**数据寄存器锁存条件**完全对齐——只有"数据真的被换掉"才清：

```verilog
if (valid_last & ready_next & ~mdu_stall & ~bp_pend & ~EXU_inst_clr & (pc != pc_out)) begin
    mdu_issued <= 0; mdu_res_vld <= 0;
end
```

**修复后**：一条 M 指令正好一次 `mdu_start`。

| 波形 | M 指令次数 | `mdu_start` | `mdu_busy` |
| --- | --- | --- | --- |
| teach_mul | 3 | **3** | 6 |
| teach_div | 1 | **1** | **34**（一趟） |
| prog_mul | 8 | **8** | 16 |
| prog_div | 4 | **4** | 136 |
| prog_div_pair | 3 | **3** | 102 |
| teach_loop_mul | 循环 4 次 | 4 | 8 |
| teach_loop_div | 循环 3 次 | 3 | 102 |

> 代价：mul 密集的程序会**慢一点**（`prog_mul 85→100`），因为 MDU 不再"提前抢跑"。
> 换来的是"一条指令一次发射"的干净波形 + div 少跑一趟。

### 已有观测信号（无需改 RTL，`.gtkw` 里已加）

| 讲解用途 | 信号 |
| --- | --- |
| **IF 交付有效**（每指令 1 拍，与 `IF 指令` 显示真指令完全对齐） | `u_cpu.IFU_Inst0.advance_en` |
| EX 为什么 valid 被压 | `u_cpu.EXU_inst_clear` |
| MEM 第三级 valid（送 WBU 的 `valid_wb`） | `u_cpu.LSU_valid_wb` |

有了 `advance_en`，IF 阶段就**不用再解释 valid 为什么时高时低**：`advance_en=1` 那一拍就是"取到并交付了一条真指令"。

---

## 3. 验证结果

`bash teach/run.sh all`：

```
[teach]   10/10 PASS   （板级自检：write-once / fetch-align）
[regress]  7/7 PASS    （寄存器/内存期望值逐条比对）
```

与原版 RTL（`../wave/*.vcd`）逐项对比：

| 项 | 结论 |
| --- | --- |
| 通用寄存器 x0–x31 | **17/17 程序全部一致** |
| CSR（mepc/mcause/mstatus/mtvec） | **全部一致** |
| 自检结论 | 全部 PASS |
| 总周期数 | 见下表（div 变快、mul 略慢） |

周期数对比（原版 → 讲解版）：

| 程序 | 原版 | 讲解版 | | 程序 | 原版 | 讲解版 |
| --- | --- | --- | --- | --- | --- | --- |
| teach_alu | 39 | 39 | | prog | 81 | 82 |
| teach_loaduse | 45 | 45 | | prog_mul | 85 | 100 |
| teach_branch | 54 | 54 | | prog_div | 248 | **200** |
| teach_mul | 42 | 45 | | prog_load_lane | 214 | 214 |
| teach_div | 95 | **63** | | prog_load_use | 241 | 241 |
| teach_mem | 39 | 39 | | prog_loop | 287 | 287 |
| teach_loop_alu | 85 | 85 | | prog_div_pair | 354 | **271** |

**结论**：功能层面完全等价（寄存器/CSR 一致、自检全过）；时序上 div 更快更干净，mul 略慢。

---

## 4. 和原工程的差异一览

| 文件 | 差异 |
| --- | --- |
| `rtl/EXU.sv` | 改动① + 改动②（唯一有差异的 RTL 文件） |
| `tb/tb_iverilog.sv` | 仅两处适配 verilator：<br>(a) 注释里的 "Verilator" 字样改成"仿真器"（verilator 会把它当 pragma 报错）；<br>(b) `force u_cpu.WBU_inst0.stall` 用 `` `ifdef VERILATOR `` 分支包起来（verilator 不支持 force，且它对悬空 input 本就按 0 处理）。 |
| 其余 `rtl/*.sv` | 与原工程**逐字节相同** |

---

## 5. `teach_mix` —— 一条**无冲突**主线

`teach_mix` 把几种机制串成一条主线，**且刻意做成没有任何依赖冲突**：

```
addi → load → addi（不读 load 的结果）→ mul → branch(taken)
```

**程序**（`teach/gen_mix_prog.py` 生成 `teach/teach_mix.hex`）—— 整段 7 条，**没有准备段**：

| 地址 | 指令 | 作用 |
| --- | --- | --- |
| **0x00** | **`addi sp,zero,3`** | **① addi**（sp = 3） |
| **0x04** | **`lw gp,0(zero)`** | **② load**（gp = mem[0] = 0） |
| **0x08** | **`addi tp,zero,7`** | **③ addi ← 不读 ② 的结果，故无 load-use** |
| **0x0c** | **`mul t0,tp,sp`** | **④ mul**（7×3 = 21，EX→EX 前递） |
| **0x10** | **`bne t0,zero,8`** | **⑤ branch**（21≠0 → 跳，跳过 0x14） |
| 0x14 | `addi a0,zero,0xBAD` | 错误路径，应被冲刷 |
| 0x18 | `ecall` | 结束 |

> ③ 若写成 `addi tp,gp,7`（读 load 的 gp）就会触发 load-use 气泡 ——
> 那种情况由 `teach_loaduse`（图 02）单独演示，本图专门展示"无冲突"版本。

实测结果：`x2=3 x3=0 x4=7 x5=21`，
**`x10=0`（错误路径的 `addi a0` 确实没执行）**。全程 **46 拍**，
**`CTRL_load_use_stall` 全程为 0**。

**出图**：

```bash
python3 teach/gen_mix_prog.py          # 生成 hex
bash teach/run.sh teach                # 出 teach/wave/teach_mix.vcd
python3 teach/gen_gtkw.py              # 刷新 .gtkw 会话
python3 teach/render_mix_figs.py       # → figures/讲解/09*.svg + .png
```

**行表自己定义，按【模块边界】命名**（31 行）：

> 命名约定：`<模块>_<信号>` = 该模块的输出/内部寄存器；
> 缩进的 `<下游>_ready` = 下游回给上游的握手输入。**每对 valid↔ready 排在一起。**

| 行 | 信号 | 用途 |
| --- | --- | --- |
| `IFU_pc` / `IFU_inst` / `IFU_valid` | 同名探针 | 取指单元的输出 |
| `IFU_advance_en →IDU` | `IFU_advance_en` | 交付脉冲（一指令一格） |
| `  IDU_ready (IDU→IFU)` | `IDU_ready` | 下游收不收（= ID1/ID2 写使能） |
| `IDU_pc` | `IDU_pc` | ID2 的 PC（送 EXU） |
| `IDU_ID1_valid` / `IDU_ID2_valid →EXU` | 同名探针 | ID 内部两级各自的 valid |
| `  EXU_ready (EXU→IDU)` | `EXU_ready` | 下游收不收 |
| `EXU_pc` / `EXU_result` / `EXU_valid →LSU` / `EXU_inst_clr` | 同名探针 | 执行单元的输出 |
| `  LSU_ready (LSU→EXU)` | `LSU_ready` | 下游收不收 |
| `LSU_M1_valid` / `M2` / `M3 →WBU` | 同名探针 | LSU 内部三级各自的 valid |
| `  WBU_ready (WBU→LSU)` | `WBU_ready` | 恒 1 |
| `WBU_valid` / `WBU_pc` / `WBU_rd` / `WBU_rd_value` | 同名探针 | 写回单元的输出 |
| `CTRL IFU_stall (总)` + 4 个来源 | `CTRL_*` | 这一拍为什么停 |
| `CTRL dnpc_flag` / `dnpc` / `mispredict` | `CTRL_*` | 重定向 |

> 这些名字就是 `teach/tb/tb_iverilog.sv` 里探针的**真实名字**，
> 所以 GTKWave 里看到的名字和图上的行名**完全一致**。

三张图：`09_主线总览`（cyc12~52）、`09a_载入与无冲突流水`（18~33）、
`09b_mul与分支重定向`（28~47）。

关键拍（实测）：

| 拍 | 事件 |
| --- | --- |
| 15 | ① `addi` 进 EX，x2=3 |
| 20 | ② `lw` 进 EX |
| 22–23 | DCache 未命中回填（`CTRL_dcache_hold`，**不是冲突**） |
| 26 | ③ `addi` 进 EX —— **紧接 ② 之后，没有多停一拍** |
| 30–32 | ④ `mul` 在 EX 占 3 拍（`CTRL_mdu_busy` 拉 2 拍） |
| **37** | **⑤ `dnpc=0x18`、`mispredict=1` → 冲刷 0x14** |
| 46 | `0x18` 的 `ecall` 进 EX |

> `09b` 里能看到一个 **已知限制**：`ecall` 那一拍 `dnpc_flag` 也拉高了（目标是 `mtvec=0`），
> 但这一拍 IFU 的 `ready=0`，重定向被丢掉、PC 没动（`Control.sv` 里有注释记录）。
> 测试台靠 `ecall` 后 DRAIN 8 拍收尾，不影响 `mepc/mcause` 的校验。
> 同理，⑤ 的错路径 `addi a0` 只流到 IF/ID 就被冲掉，**从没进过 EX**。

---

## 6. 还能继续做（未做）

1. **ICache 那个 `1-0-1` 毛刺**：判定排比地址排晚一拍，导致新地址第 2 拍"判上一条请求"。
   彻底修要加一级 `align_addr_r`，代价是冷行取指 3 拍 → 4 拍，波形更慢，**不划算**，建议维持现状并用 `advance_en` 讲解。
2. **把讲解图重出**：目前 `figures/讲解/*` 还是原版（iverilog）的图。
   讲解版波形在 `teach/wave/`，可用 `sim/render_window.py` 重出一套干净的图。
