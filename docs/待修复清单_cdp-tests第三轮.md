# 待修复清单 —— 官方 `cdp-tests` 第三轮验证发现的问题

> **状态：H1 / H2 / H3 三项已全部应用并验证通过。**
> 验证结果：官方差分 **39/39 PASS**（上游 `cdp-tests` 克隆下来共 39 条、无 `intr` 二进制；
> 原文的"47 条 + `intr`/`intr_timer`"属于另一个套件版本 —— 见文末《验证结果》）。
> 分步证据：修复前 **0/39**（`addi` 第一条即 desync）→ 只修 H3+H1 **32/39**
> → 再修 H2 **39/39**，且中途失败集恰好是 `lb lbu lh lhu lw sb sh`，与本文件预测**逐条吻合**。
>
> 实现落点：`rtl/EXU.sv`（新增 `up_stall` 接收门控，见 `syn/修复史_全量.md §EXU-11`）、
> `rtl/DCache.sv`（读窗口整字 mask，`§DCACHE-6`）、工程顶层新增 `rtl/MDU_pipelined.sv`（`§MDU-4`）。
>
> **下面各节的"要改的地方"保留原文（含当时的行号）作为修复依据的留档**；
> 行号已随注释迭代漂移（例如 H1 说的"第 175~177 行"现在是 `rtl/EXU.sv:202`），
> 实际以 RTL 中的 `H1` / `H2` / `H3` 注释与上表锚点为准。
>
> 关键结论（仍然成立）：官方仓库自带的差分测试此前 **从未真正在 v9 上跑过**；
> 前两轮文档里的「103/103 / 239/239」都只是 v9 自带 `sim/` 测试台的数字。

---

## 0. 怎么跑官方差分（复现环境）

- 仿真器：Verilator 5.020 + make（本机 `verilator` 已装）。
- 测试台：`BigBird-CPU-Lab-main/cdp-tests`（`Makefile` + `golden_model` + `bin/*.bin`）。
- **重要**：Verilator 的 `obj_dir` 不能在含空格的路径下构建，先把工程拷到无空格目录，
  例如 `cp -r "…/v9" /home/<user>/work/v9`，再在 `cdp-tests` 里：

```bash
make build CPU_DIR=../v9
for t in $(ls bin/*.bin | xargs -n1 basename | sed 's/\.bin//' | grep -v intr); do
    make run TEST=$t CPU_DIR=../v9
done
INTR_TEST=1 make run TEST=intr       CPU_DIR=../v9
INTR_TEST=1 make run TEST=intr_timer CPU_DIR=../v9
```

差分模型每收到一次「RTL 提交」就执行一条参考指令，因此要求**一条指令恰好提交一次**。

---

## 1) H1（P0，会算错结果）：前端 hold 时 EXU 重复接收同一条指令

### 现象
- 官方差分 `addi` **第 1 条就失败**：`addi x1,x0,0`(pc=4) 的
  `debug_wb_have_inst` 连续高两拍，参考模型多走一条，之后全 desync。
- `jal` 用例：`0x3c` 的 `addi x1,x1,1` 被执行两次（2 → 3），
  `0x40` 算出 4，预期 3。

### 根因
`IDU` 在 `IFU_stall`（load-use | MDU 忙 | `icache_hold` | `dcache_hold`）期间会
**保持**送给 EXU 的 `valid_next`（内部 `valid_d`）不变；而 `EXU` 只按
`ready_last & valid_last` 接收（`ready_last` 只看下游 LSU），于是同一条指令被
连续接收两拍、执行两次。第二次的源操作数已是第一次写回后的值 → 结果错。
这是旧设计一直存在、但因为没有 Cache 而被掩盖的握手漏洞。

### 要改的地方

**文件 `v9/rtl/EXU.sv`**

1) 端口列表，第 70 行附近，把

```verilog
    input  logic bp_pend
);
```

改成

```verilog
    input  logic bp_pend,
    // 上游 IDU 正在冻结（stall）：IDU 会保持送出的 valid 不变，
    // EXU 在此期间不得再接收，否则同一条指令被连续接收两拍、执行两次。
    input  logic up_stall
);
```

2) `valid_next` 赋值，第 175~177 行附近，把

```verilog
        else if(ready_last & valid_last & EXU_inst_clr )
            valid_next <= 1'b0;
        else if(ready_last & valid_last)
            valid_next <= 1'b1;
```

改成

```verilog
        else if(ready_last & valid_last & EXU_inst_clr )
            valid_next <= 1'b0;
        else if(ready_last & valid_last & ~up_stall)
            valid_next <= 1'b1;
```

3) 数据寄存器更新条件，第 239 行：

```verilog
        else if(valid_last & ready_next & ~mdu_stall & ~bp_pend)
```
→
```verilog
        else if(valid_last & ready_next & ~mdu_stall & ~bp_pend & ~up_stall)
```

4) 控制寄存器更新条件，第 280 行：

```verilog
    else if(valid_last & ready_next & ~mdu_stall & ~bp_pend) begin
```
→
```verilog
    else if(valid_last & ready_next & ~mdu_stall & ~bp_pend & ~up_stall) begin
```

**文件 `v9/rtl/myCPU.sv`**，EXU 例化，第 498 行附近，把

```verilog
      .bp_pend (bp_hold_exu)
  );
```
改成
```verilog
      .bp_pend (bp_hold_exu),
      // H1：IDU 冻结期间 EXU 不接收新指令
      .up_stall(IFU_stall)
  );
```

> ⚠️ **不要把 `.valid_last(IDU_valid)`（第 490 行）改成
> `.valid_last(IDU_valid & ~IFU_stall)`。** 这个“不加端口”的写法实测
> **只有 40/47**：`valid_last` 在 EXU 内部还参与 `EXU_inst_clr` 的清空路径，
> 掩掉它会连清空一起掐掉，留下陈旧控制寄存器（重定向/异常判定出错），
> 失败用例 `lb lbu lh lhu lw sh start`。

### 为什么必须是「独立的接收门控」而不是别的
- `EXU_inst_clear` 的语义是「把这条指令作废」，与「这一拍先别收」不同；
  把 stall 并进去会废掉不该废的指令（即现有 B4 修复要避免的 `mem_stall` 期间
  作废分支/跳转），且挡不住「stall 结束后再收一次」。
- 从 IDU 侧改会把 `IDU_valid` 拉低，而 `Control` 的 load-use 判定依赖
  `IDU_valid`，会产生振荡/漏判；实测直接让 IDU 在取指 hold 期间不冻结，
  取指 pc/inst 配对被打乱（`rd` 直接错）。

---

## 2) H2（P1，接口契约）：CPU 与课程原始 SoC 的读数据口径不一致

### 现象
修好 H1 后仍差 7 条：`lb lbu lh lhu lw sb sh`。
例如 `lb x14,2(x1)`（字内偏移 2，内存字节 `0xf0`）读出 0，应为 `0xfffffff0`。

### 根因
上板改造后 CPU 的契约是「存储器返回**原始整字**，CPU 按 `addr[1:0]` 自己抽取」
（见 `rtl/LSU.sv`/`rtl/WBU.sv` 的 B1 修复、`board/sync_mem.sv` 读口）。
而课程原始 SoC 的 `mySoC/dram_driver.sv` 会**按 `perip_mask` 在存储器侧先抽取**，
于是发生二次抽取。

### 要改的地方

**文件 `v9/rtl/DCache.sv`**，第 208 行，把

```verilog
    assign mem_mask  = store2_mask;
```
改成
```verilog
    // 读请求窗口向存储器声明「整字访问」，让老师 SoC 的 dram_driver 返回原始整字，
    // CPU 再按 addr[1:0] 抽取；写口仍用真实字节 mask。
    // 课程 DRAM 是组合读（dram_driver 每拍按当前 mask 重新抽取），
    // 所以整字 mask 要一直保持到数据被采走那一拍（mem_req_r=1）。
    assign mem_mask  = mem_wen ? store2_mask
                              : ((mem_en | mem_req_r) ? 2'b10 : store2_mask);
```

> 板级 `board/sync_mem.sv` 读口不看 mask，此改动对板级无影响。
> 若坚持「SoC 抽取」的旧契约，则要改回 `LSU`/`WBU` 的抽取逻辑，并让
> `sync_mem` 读口也抽取——改动更大且与 Cache「整行回填」语义冲突，不建议。

---

## 3) H3（P1，打包）：官方评测 Makefile 找不到 `MDU_pipelined`

### 现象
官方 `cdp-tests/Makefile` 的源码列表是 `$(wildcard $(CPU_DIR)/*.sv)`，只通配 v9
**顶层**；而 `rtl/EXU.sv` 例化的是 `experimental/MDU_pipelined.sv`，verilator 直接报：

```
%Error: Cannot find file containing module: 'MDU_pipelined'
```

即：功能全对也**编译不过**。

### 要改的地方

把 `experimental/MDU_pipelined.sv` 复制到 v9 顶层（与未被例化的 `rtl/MDU.sv` 并存无害）：

```bash
cp v9/experimental/MDU_pipelined.sv v9/rtl/MDU_pipelined.sv
```

---

## 验证结果（实测）

**环境**：WSL2 Ubuntu 24.04 + Verilator **5.020**（本机 `apt-get download verilator` 解包到 `~/opt`，
无需 sudo）+ 上游 [`hongpengWu/BigBird-CPU-Lab`](https://github.com/hongpengWu/BigBird-CPU-Lab) 的 `cdp-tests`。
工程拷到无空格路径 `~/work/v9_canon`（`share doc` 含空格，Verilator 的 `obj_dir` 建不起来）。

| 配置 | 官方差分结果 |
| --- | --- |
| 修复前（原始 v9） | **0 / 39** —— `addi` 第一条就 desync（连编译都过不了，见 H3） |
| 只修 H3 + H1 | **32 / 39** —— 失败集恰好 `lb lbu lh lhu lw sb sh`（= H2 预测） |
| H3 + H1 + H2（最终） | **39 / 39 PASS** |

其它回归（最终配置）：

| 验证 | 结果 |
| --- | --- |
| v9 自带 iverilog 整机回归（7 程序） | **7 / 7 PASS**（`prog` 36/36，其余 35/35） |
| `sim/tb_dcache_unit.sv`（DCache 模块级） | **PASS**（H2 改的正是 DCache 的 mask，必测） |
| Vivado 2025.2 全流程重建（synth + impl + bitstream） | **0 errors / 0 critical warnings**；`WNS = 3.445 ns`、`WHS = 0.032 ns`、失败建立路径 **0** —— 50 MHz（周期 20 ns）下时序仍闭合。bitstream `4045689` 字节。日志 `build_project_ila.log` |
| 板级行为 | H2 对已上板 bitstream **无影响**（`board/sync_mem.sv` 读口不看 mask，已逐行核对） |

### 关于"47 条"与 `intr`（已查清）

原文写"官方差分 47 条 + `intr` / `intr_timer` 2 条"；v9 自己的 `README.md` 也写
"全量回归：47 条（**39 条 RV32I + 8 条 RV32M**）"。本次把上游套件逐项查了一遍：

| 查什么 | 结果 |
| --- | --- |
| `cdp-tests/bin/*.bin` | **39 个** —— 恰好是 RV32I 那一档 |
| 全仓库找 `*mul*` / `*div*` 文件 | **0 个** |
| `git branch -a` / `git tag` | 只有 `main`，无其它分支/标签 |
| `Makefile` 里的 `INTR_TEST` 开关 | **不存在** |
| 上游 `README.md` 的自我定位 | "面向初学者的 **RV32I** 处理器教学工程"、"完整单周期 **RV32I** 主线" |

**结论**：上游 `BigBird-CPU-Lab` **本来就是纯 RV32I** —— 既没有 RV32M 用例，也没有中断用例。
所以那 8 条 RV32M + 2 条中断用例来自**本地对套件的扩展**，不在本工作区里。因此：

* **39/39 = 目前可获取到的套件 100% 通过**，这是可复现的硬结论；
* **"47/47" 与 "intr 2/2" 在本工作区无法复现**：需要先拿到那 10 个用例的二进制
  （或生成脚本）。在那之前，这两个数字不应被引用为"已验证"。
* 原文"修复前第一条即失败 → 只修 H1 为 **40/47**"与本次的 **32/39** 比例一致（≈82%），
  差别只是套件条目数 —— 两者互相印证，并不矛盾。

> 补一句：本轮的 39 条里**没有一条**覆盖 RV32M 乘除，而 v9 恰恰把原本的组合 MDU 换成了
> `MDU_pipelined`（见 §EXU-8）。所以乘除路径靠的是 v9 自带的
> `prog_mul` / `prog_div` / `prog_div_pair`（iverilog 回归里已 PASS），
> 而不是官方差分。**想让乘除也进官方差分，需要补那 8 条 RV32M 用例。**

---

## 其它说明 / 遗留

1. ~~本轮所有验证都是**仿真级**。真实综合/时序（Fmax、BRAM 推断）本机无
   yosys/Vivado，仍未做。~~
   **已补**：H1/H2 应用后用 Vivado 2025.2 跑了工程模式全流程（synth + impl + 时序），
   入口 `E:\FPGA\v9_vivado_ila\build_project_ila.tcl`（`DO_SYNTH=1 / DO_IMPL=1`），
   日志 `build_project_ila.log`，时序报告 `project_src\timing_post_route.rpt`。
2. 板级 `board/tb_board_top.sv` 在本地解包的 iverilog 12.0 上 vvp 阶段报
   `syntax error`（同一工具链跑 `sim/` 正常），**本次未复跑**（没碰它）。
   注意：H1 改了 `EXU` 的端口列表（新增 `up_stall`），目前全工程只有 `rtl/myCPU.sv`
   例化 `EXU`（已同步接好）；若将来有别的台子直接例化 `EXU`，需补 `.up_stall`。
3. Verilator/obj_dir 路径不能含空格（`share doc` 有空格），务必先拷到无空格目录 ——
   本次验证就是在 `~/work/v9_canon` 下跑的。
