# CHECKPOINT v14 —— 分支预测加宽 / IROM 双读口 / 轻量 shell

> 本轮（v13.5 → v14）围绕四个目标：**修缺陷**、**load-use**、**分支预测是否值得做**、
> **双口存储器**、**轻量 shell**。下面每一条都带实测数字与"改了什么/为什么"，
> 以及**没做成的部分和原因**（这一节比成功部分更重要）。
> 全部 RTL 改动都过了 `_diag/check_compile.sh`（Verilator lint + iverilog 精化）
> 与 `_diag/regress.ps1` 全量回归。

---

## 1. 分支预测：**值得做，但只做到 256 行**（实测扫描，不是拍脑袋）

`_diag/bp_sweep.sh` 把 `rtl/para.sv` 的 `BP_INDEX_BITS` / `BP_HIST_BITS` 逐个替换，
只跑 CoreMark 1 次迭代，其余 RTL 一个字不动。结果（总拍数 / 误预测次数 / 误预测率）：

| BTB/PHT 行数 | GHR 位宽 | 总拍数 | 误预测 | 分支总数 | 误预测率 | 相对 64 行 |
|---|---|---|---|---|---|---|
| 64 | 6 | 482 990 | 10 680 | 73 707 | 14.5% | — |
| 256 | 6 | 471 384 | 8 376 | 73 685 | 11.4% | −2.4% 拍 |
| **256** | **8** | **468 266** | **7 753** | **73 694** | **10.5%** | **−3.05% 拍** ← 采用 |
| 1024 | 8 | 462 715 | 6 618 | 73 710 | 9.0% | −4.2% 拍 |
| 1024 | 10 | 461 825 | 6 466 | 73 675 | 8.8% | −4.4% 拍 |

**结论：停在 256 行。** 64→256 拿到 3.05%；256→1024 只多 1.4%，却要 ~900 个 LUT
和"1024 选 1"的取指读 mux（RAS/时序风险都不划算）；历史 8→10 只多 0.2%（已饱和）。
剩下 10.5% 的误预测主要是**冷启动（compulsory）**与 gshare 的容量冲突，堆尺寸治不好。

### 改了什么

1. `rtl/para.sv`：`BP_INDEX_BITS 6 → 8`、`BP_HIST_BITS 6 → 8`（附上整张扫描表）。
2. `rtl/Branch_Predictor.sv`：
   - 表项从 **unpacked 数组**改成**打包向量**。这不是风格问题：Verilator 对
     "for 循环里给数组做非阻塞赋值"有展开上限（`%Error-BLKLOOPINIT`），
     LINES=64 能过、256 直接报错 —— 与 v11 给 DCache 的 `valid` 换打包向量同一个坑。
   - PHT 的 2 位饱和计数器拆成 **`pht_hi` / `pht_lo` 两根 1 位向量**：
     iverilog **不支持**对二维打包数组连续索引（`pht[idx][1]` 报
     "Array index expressions must be constant"），而全量回归跑在 iverilog 上。
     加减法按位写（`+1: lo'=~lo|hi, hi'=hi|lo`；`-1: lo'=hi&~lo, hi'=hi&lo`），
     与原 `±1` 逐状态等价（64/6 配置复现同一组 10 680 次误预测即为证）。
   - 四个表加 `(* ram_style = "distributed" *)`：它们是"同步写 + **组合读**"，
     BRAM 做不到组合读，必须落 LUTRAM（256×57 ≈ 230 个 LUT6）。不加就会退化成
     ~14.6 k 个触发器。

---

## 2. 双口存储器：**IROM 第二读口 + 数据窗口 0x0002_0000**（"lw 读不到 IROM"已解）

### 硬件

- 新增 `board/sync_mem_dp.sv`：**2 读口 + 1 写口**，两个读口 + 写口写在**同一个
  `always_ff`** 里 —— Vivado 只有这样才能推成 True Dual Port RAM（拆成两个
  always_ff 会被推成两块 RAM，占用翻倍）。
- `board/board_top.sv`：IROM 换成 `sync_mem_dp`，端口 A = 取指（只读），
  端口 B = **CPU 数据读** 或 **引导器写**（二者互斥：引导期间 CPU 被 `cpu_rst_eff`
  按住，不可能同时来）。数据窗口译码：

  ```
  perip_addr[31:16] == 0x0002  →  IROM 字 [perip_addr[15:2]]（64KB 全量可见，只读）
  ```

  优先级：MMIO(0x1000_xxxx) > IROM 窗口(0x2_xxxx) > DRAM(0x0~0x1_FFFF)。
  DRAM 的写使能额外门掉窗口（写它静默丢弃）——**代码区只读**是刻意的不变量。
- **BRAM 数量不变**：BRAM36 本来就是两个独立端口，64KB 仍是 15 个 tile。

### 为什么缓存是安全的

窗口地址 < 0x1000_0000，DCache 会把它当可缓存地址。这没问题：IROM 对 CPU 永远只读，
唯一的写者（`boot_loader`）只在 `boot_busy=1` 时写，而那时 CPU 与 DCache 一起被复位
清空 —— 缓存行不可能是陈旧的。

### 验收

- 新增 `sw/dptest.c` + `sw/build_dptest.sh`（**两遍编译**）：从窗口前 64 个字算 djb2
  校验和，与链接后算出的期望值比对。期望值必须是**可写变量**（落 `.data` / DRAM），
  不能是立即数 —— 立即数会进 `.text`，而 `.text` 正是被校验的对象（自我指涉）。
  脚本末尾会断言"两遍 `.text` 逐字节相同"。
- Verilator 实测（`bash sw/run_coremark.sh +irom=sw/build/dptest_irom.hex +dram=...`）：

  ```
  DPTEST / D1=0 / CK=0x5e2e3bbd / D2=0 / W0=0x00011197 / D3=0 / D4=0 / DPTEST-PASS
  ```

  `W0 = 0x00011197` 就是 IROM 的第 0 个字（复位向量那条指令），
  D3（连读两次相等）与 D4（lbu×4 拼回 lw）同时验证了**幂等**与**字节通路**。
- `sim/tb_cm.sv` 的存储器模型同步加了窗口（模型必须与 `board_top` 译码一致，
  否则"仿真通过、上板不通"），并且 `[HITBAD]/[MBAD]` 自检对窗口地址改为回查 `irom[]`。

---

## 3. 轻量 shell：`sw/monitor.c` → 命令表驱动的 v14 shell

| 命令 | 说明 |
|---|---|
| `h` / `help` | 帮助（由命令表自动生成，不再手写两遍） |
| `d` / `dump <a> [n]` | dump（默认 8 字，上限 256，每行 8 个） |
| `p` / `peek <a>` | 读一字 |
| `w` / `poke <a> <v>` | 写一字（外设寄存器同路） |
| `c` / `csr` | dump 关键 CSR |
| `l` / `led <v>` | 写 LED（低 7 位） |
| `f` / `fill <a> <n> <v>` | 填 n 个字 |
| `m` / `cmp <a> <b> <n>` | 比较两块内存，打印首个不同 |
| `k` / `cksum <a> [n]` | djb2 校验和；**`k 20000` 就是"读自己的代码"** |
| `u` / `uptime` | 开机时长（`mtime`@500kHz → s.mmm） |
| `i` / `info` | 硬件/镜像信息（含 `BTB/PHT 256  GHR 8  RAS 8`） |
| `e` / `echo <text>` | 回显（链路测试） |
| `b` / `boot` | 重新进入引导器 |

行编辑：退格、`^U` 删整行、`^C` 取消、`↑/↓` 历史（4 条，相同命令不重复存）、
CR 后紧跟的 LF 被吞掉（宿主发 CRLF 时不再多一个空提示符）。
数字：缺省**十六进制**（与旧脚本兼容），`0x` 十六进制、`0d` 十进制。
体积：text 11 308 B（IROM 64 KB 用 17%）。

★ 不变量没变：`RXDATA` 是幂等 peek，弹出必须写 `0x1000_0018`；`TXDATA` 忙要等
`TXSTAT.bit0`；MMIO 不可缓存。

### 回归证据（`sim/tb_monitor.sv`，真实 `board_top`）

```
=== BigBird RV32 shell (v14) ===
 mtime=1750  DRAM=0x10000  IROM-win=0x20000
 h = help
> l 3f
 LED <- 0x0000003f
> p 10000
 [00010000] = 0x2d657220
  [PASS] M1 banner printed / M2 'l 3f' replied / M3 'p 10000' replied
[MONITOR-SELFCHECK] status=PASS (3 checks)
```

---

## 4. 缺陷（P4）：**已修**（v14 第二轮）—— 靠一个"请求身份证"信号

### 机制（实测，`sim/tb_monitor.sv +poptrace`）

探针加了 `en/adv/mrr/idx/a` 之后的原始波形是：

```
[RD] c=7770850000 ren=1 rp=0 cnt=5 rd=6c en=1 adv=0 mrr=0 idx=2 a=10000008
[RD] c=7770890000 ren=1 rp=0 cnt=5 rd=6c en=0 adv=1 mrr=0 idx=2 a=10000000
```

第一眼像"同一地址读两次"，其实 `a`（DCache 的 `cpu_addr` 输入）是**下一条请求**的地址，
而板级 `perip_addr`（= DCache 的 `mem_addr` = **寄存后的** `cpu_addr_r`）仍是本次
RXDATA 读的地址。真正的问题是 `rtl/myCPU.sv:868-878` 这组接线决定的窗口：

```
cpu_en = LSU_mem_ren_pipe | lsu_bus_wen      ← 本拍（M2 电平）
cache_rd_req = cpu_en_r & ~cpu_wen_r & ~line_resident & ~mem_req_r   ← 上一拍
```

`mem_req_r` 在**数据返回那一拍**就被清，而 `cpu_en_r` 要等这条 load 离开 M2 才掉 ——
中间那一拍 `cache_rd_req` 又为 1 ⇒ **同一条已服务完的请求**又对总线打了一次读。
第二条脉冲那拍的 `en=0/adv=1` 就是"load 正在离开 M2"。

### 修法：LSU 给出请求身份证 `req_seq`

只比地址**修不了**（`while (!(RXSTAT & 1));` 这种同地址轮询会读到旧值），必须有一个
"这是一条新请求"的 token：

- `rtl/LSU.sv`：新增输出 `req_seq`，**每推进一条 M2 指令翻转一位**
  （翻转条件与流水线推进条件逐字一致：`ready_next & ~lsu_freeze`；冻结期间不翻转）。
- `rtl/DCache.sv`：`req_seq_r` 与 `cpu_addr_r` **同沿**采样；`unc_busy` 粘滞位记录
  "本请求已发过 uncacheable 读"，**只允许在 `req_seq_r != 发读时的 seq` 时清除**；
  粘滞期间 `resp_for_now` 由它撑起（否则 `mem_req_r` 已清、重发被禁 ⇒ 自锁）。
- `rtl/myCPU.sv`：`lsu_req_seq` 连线一根。

区分能力：
- 同一条请求还在（冻结 / 数据刚回）→ seq 不变 → 不重发 ✅
- 同地址的下一条请求到了 → seq 变了 → 照常发 ✅

### 验收（全部实测）

| 判据 | 修前 | 修后 |
|---|---|---|
| `tb_monitor [COUNT]` | `RXDATA reads=26  rx_pop=13`（2:1） | **`reads=13  rx_pop=13`（1:1）** |
| `tb_monitor` 四项判据 | 3/4 | **4/4 PASS**（含 `M4 IROM window readable`） |
| CoreMark（1 次迭代） | 415 905 拍 / 120.22 iter/s | **完全不变**（415 905 / 120.22） |
| 全量回归 | 38/38 | 见 §7 |

★ 上一轮按 `§9.4` 草案加的 `unc_busy`（只用 `cpu_adv` 清）实测无效，已回滚；
这一轮的版本**多了请求身份证**，才真正生效。上一轮的 `+poptrace` 探针保留在 TB 里。

---

## 5. load-use：**2 拍是这个微架构的下界**（含三条改法的代价）

一次 load-use（load 在 EXU、消费者在 IDU）当前停 **2 拍**（`load_use=50 339` 拍 /
25 000 次事件）。原因是访存流水 `EXU → M1 → M2(发总线) → M3`：

- 消费者在 IDU 的第 1 拍：load 在 EXU，**地址都还没算出来** → 必停 1 拍；
- 第 2 拍：load 在 M1（DCache 的同步读还没返回）→ 再停 1 拍；
- 第 3 拍：load 在 M2，`cpu_rdata` 当拍有效 → 前递，放行。

三条能再省 1 拍的路，代价都量过：

| 改法 | 收益上限 | 代价 | 判断 |
|---|---|---|---|
| M1 命中就前递（地址提前一拍查数组） | ~+3.5%（只覆盖 70% 命中） | DCache 数据阵列再加一套 **256:1 读 mux ≈ 1 700 LUT**，还要挡"同拍 store 合并 / 回填"两种冲突 | ❌ 不划算 |
| 把总线请求从 M2 挪到 EXU（地址当拍就有） | ~+5% | 动 LSU/DCache 的核心时序契约（P4 就出在这条路上），关键路径 ALU→DCache→BRAM | ❌ 风险 > 收益 |
| 软件侧调度（编译器 -O2 已经不差） | 0 | 无 | —— |

**结论（v14 当时）：RTL 侧到此为止。** 但第 4 轮把这条路走通了 —— 见 §5b。

### 5b. v15：**问题解决了**（DCache 加第二个读口，load-use 2 拍 → 1 拍）

上一节的判断里有一条是错的：我把"M1 命中前递"的代价估成"多一套 256:1 读 mux"就够了，
其实真正要做的是**给 DCache 加一个只读探测口**，把 M1 那一段的有效地址（`Ex_result_addr_reg`）
也拿去查数组 —— 命中时数据**当拍**就有，消费者不必等到 M2。

```
DCache 新增：m1_addr / m1_en  →  m1_hit / m1_rdata
  m1_hit = m1_en & ~MMIO & valid[m1_idx] & (tag[m1_idx]==m1_tag) & ~(同 index 的 store 合并)
LSU 新增：  LSU_Rdata_m1 = lane_extract(m1_rdata, funct3_reg, addr_reg[1:0])
            m1_load_ok   = mem_ren_reg & valid_reg & m1_hit
Data_hazard：mem_hit 允许"是 load 但 m1_load_ok=1"；mem_load_use 增加 & ~MEM_m1_ok
myCPU：     MEM_forward_val = m1_load_ok ? LSU_Rdata_m1 : （jump/csr ? rd_value : Ex_result）
```

★ 唯一需要护栏的 hazard：**同拍有一次 store 合并打到同一 index** 时数组还是旧值
（合并本拍末才生效）⇒ `m1_hit` 直接置 0，退回 M2 路径（多停 1 拍，功能正确）。
回填（fill）不需要护栏：回填只发生在行不驻留时，那时 `m1_hit` 本来就为 0。

★ 这条通路**只可能变快、不可能改错语义**：store / 空拍 / 未命中 / MMIO 一律 `m1_load_ok=0`，
行为与 v14 逐拍相同。

#### 实测（1 次迭代，`+perf`）

| 指标 | v14 | **v15** | 变化 |
|---|---|---|---|
| 总拍数 | 468 263 | **440 656** | −5.9% |
| `load_use` 停拍 | 50 339 | **22 681** | **−55%** |
| `ifu_stall` | 71 147 | 43 505 | −39% |
| CoreMark 拍/迭代 | 415 905 | **388 944** | −6.5% |
| iter/s（仿真口径） | 120.22 | **128.55** | **+6.9%** |
| ⇒ CoreMark/MHz | 2.408 | **2.571** | — |

功能验收：全量回归 **38/38 PASS**（含 `prog_load_use`、`prog_load_lane`、
`tb_dcache_unit`）、`dptest` `DPTEST-PASS`（D1..D4 全 0，含 `lbu×4` 与 `lw` 的一致性）、
CoreMark CRCs 仍为官方值 `e714/1fd7/8e3a`。

#### 代价（实测，`_diag/build_boot_v15.log`）

| 资源 | v14 | v15 | 变化 |
|---|---|---|---|
| WNS / WHS | 1.187 / 0.007 | **0.645 / 0.015** | 时序余量少了 0.54 ns（**仍为正**，50 MHz 成立） |
| Slice LUTs | — | 36 990（69.5%） | 两个新读口（256:1 的 tag/data mux） |
| Slice Registers | — | 34 047（32.0%） | 不变（没有新增状态） |
| Block RAM Tile | 66.5 | **66.5** | 不变 |
| LUT as Memory | 856 | 976 | +120（预测器表的组合读） |

⇒ 用 **0.54 ns 的时序余量** 换 **6.9% 的性能**，资源上只多两个多路选择器，**划算**。

#### 上板（v15 bitstream，ITER=1400 ⇒ 10.87 s）

```
Total ticks      : 543407157     ← 388 148 拍/迭代（v14 是 415 256）
Total time (secs): 10.868143
Iterations/Sec   : 128.816853    ← 128.82 iter/s = 2.576 CoreMark/MHz
Iterations       : 1400
[0]crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a
Correct operation validated.
```

仿真 388 944 拍/迭代 vs 上板 388 148（差 0.2%，仍是"1 次迭代含预测器冷启动"）。
★ 报分镜像的迭代次数再改一次：**1300 → 1400**（核又快 7%，1300 次只剩 ~10.1 s，
贴着 10 s 的线，不安全）。

---

## 6. CoreMark：**120.41 iter/s @ 50 MHz ⇒ 2.41 CoreMark/MHz**（v13.5 是 116.80 / 2.34）

### 上板（正式报分，ITER=1300 ⇒ 10.80 s ≥ 10 s）

```
Total ticks      : 539832473
Total time (secs): 10.796649
Iterations/Sec   : 120.407725
Iterations       : 1300
[0]crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a
Correct operation validated.
CoreMark 1.0 : 120.407725 / GCC13.2.0 -O2 -march=rv32im -mabi=ilp32 / STACK
```

★ **报分镜像的迭代次数要从 1200 改成 1300**：核快了 2.9% 之后 1200 次只跑 **9.97 s**，
CoreMark 会直接判 `ERROR! Must execute for at least 10 secs` —— 上一轮的 1200 次
在 v14 上**不再合法**（实测确实被拒）。现在 `sw/build/cm_*.hex` 就是 ITER=1300。

### 上板 vs 仿真（拍/迭代）

| 口径 | 拍/迭代 | 说明 |
|---|---|---|
| 仿真 1 次迭代（`+perf`） | 415 905 | **含预测器冷启动**（256 项 BTB/PHT 要现学） |
| 上板 1300 次平均 | 415 256 | 冷启动被摊薄 ⇒ 稳态值 |

两者差 0.16%，方向与"1 次迭代含 warmup"完全一致（v13 同样差 0.04%，只是当时
预测器只有 64 项、学得快）。**不是时钟或 mtime 口径的问题**：`mtime` 每 100 拍 +1
再 ×100，`mcycle` 与 TB 的 `cyc` 逐拍对得上。

### 停顿普查（`+perf`，1 次迭代：468 263 拍 / 353 912 条 ⇒ **CPI 1.323**，原 1.364）

| 类别 | 拍数 | 占比 | 变化 |
|---|---|---|---|
| 退休（有效） | 353 912 | 75.6% | ↑ |
| load-use 重放 | 50 339 | 10.75% | 不变（架构下界，见 §5） |
| 分支误预测重填 | ≈38 657 | 8.26% | ↓（原 11.0%） |
| MDU 迭代 | 20 868 | 4.46% | 不变 |
| DCache hold | 4 547 | 0.97% | 不变（缺失率 29.6% 仍几乎不要钱） |

---

## 7. 验证状态

### 7.0 一键验收（v15 新增，每次改 RTL 后跑这两条就够）

```powershell
# 仿真侧（约 1 分钟）：Verilator 全 RTL 跑 IROM 数据窗口自检
wsl bash -c "cd /mnt/e/FPGA/v9_vivado_ila && bash sw/run_dptest.sh"
#   → D1..D4 全 0 + 「[DPTEST] PASS」

# 板上侧（约 90 秒）：编程 + 灌 monitor + 4 项自检
powershell -NoProfile -ExecutionPolicy Bypass -File _diag\board_smoke.ps1
#   → S1 横幅 / S2 code-win / S3 cksum 与主机一致 / S4 echo
#   → 「[SMOKE] PASS (4 checks)」
#   -SkipProgram        只跑 S3/S4（monitor 已在跑时用）
#   -WithCoreMark       追加 S5：CoreMark 合法性 + iter/s（约 +60 秒）
```

`board_smoke.ps1` 的 S3 是**主机侧对拍**：脚本自己用 python 算 monitor IROM 前 64 字的
djb2，再与板上 `k 20000` 的返回值比 —— 一边是 hex 文件、一边是硅片，逐位相同才算过。

- `_diag/check_compile.sh`：Verilator lint（top=`board_top`）0 error、iverilog 精化 0 error。
- `_diag/regress.ps1`：**38/38 全部 PASS**（含 `tb_dcache_unit` —— 它在本轮 P4 修复后
  一度 FAIL，因为新端口 `req_seq` 没被驱动；TB 里按 `cpu_en` 上升沿翻转后通过，
  并给出"同地址两次 MMIO 读看到不同副作用值"的判据）。
- `tb_monitor`：**4/4 PASS**，且 `[COUNT] RXDATA reads=13 == rx_pop pulses=13`（修前 26/13）。
- `dptest`（Verilator）：`DPTEST-PASS`（D1..D4 全 0）。
- CoreMark：修复前后**逐位不变**（415 905 拍/迭代、120.22 iter/s），CRCs 官方值。
- 构建：**OK**（`_diag/build_boot_v14b.log`，2026-10-19 21:31，含 P4 修复）
  - **WNS = 1.187 ns / WHS = 0.007 ns**（比 P4 修复前的 0.912 更好：uncacheable
    那条路径少了一次"重发判定"的组合锥）。
  - Block RAM Tile 66.5（与 v13 相同）、`LUT as Memory 856`（预测器表在 LUTRAM）。
  - 备份：`_bak/board_top_gui_boot_v14p4.bit` / `.ltx`（★ 不放 `v9_boot/`）。
- **上板（含 P4 修复的 v14 bitstream）：已验**

  | 项 | 板上实测 |
  |---|---|
  | 启动横幅 | `=== BigBird RV32 shell (v14) ===` + `mtime=1750` |
  | IROM 数据窗口 | `code-win OK  w0=00011197`（与仿真/主机三口径逐位相同） |
  | `k 20000` | `cksum 0xf7b9ad39`（= 主机侧 `monitor_irom.hex` 前 64 字的 djb2） |
  | `echo P4-OK-12345` | `P4-OK-12345`（逐字符回显，一字节一次总线读） |
  | CoreMark（ITER=1300） | 539 832 473 ticks / 10.796649 s / **120.407725 iter/s**，`Correct operation validated` —— **与 P4 修复前逐位相同**（修复只去掉多余 MMIO 读，不改性能） |
  ★ `k 20000` 的**主机侧对拍**是最硬的一条证据：板上 `lw` 读 IROM 出来的
  64 个字，与工程里那份 hex 的 djb2 校验和**逐位相同** —— 双读口 + BRAM 推断
  在真芯片上完全正确，不只是仿真。

- **v15（load-use 2 拍 → 1 拍）**：构建 WNS **0.645** / WHS 0.015，BRAM 66.5（不变）、
  LUT 36 990（69.5%）；上板 543 407 157 ticks / 1400 次 / 10.868 s /
  **128.816853 iter/s**，CRCs 官方值 + `Correct operation validated`。详见 §5b。
  备份 `_bak/board_top_gui_boot_v15.bit` / `.ltx`。

## 8. v16：shell 的 `load` / `run`（软件写代码区并执行）—— **不需要统一地址空间**

原先估价 1.5~2 天（把 IROM+DRAM 合成 192KB、改 `link.ld`/引导协议/全部 TB）。
实际只要**一个观察**：IROM 的第二个端口本来就是**读写**的（引导器用它写代码区）。
让 CPU 对窗口 `0x2_xxxx` 的 store 也落到这个端口之后 —— 软件就能写代码区，
而取指读的是**同一个数组**，于是写完直接 `jalr` 过去就能执行。

### 改动（3 处，都很小）

| 位置 | 改动 |
|---|---|
| `board/board_top.sv` | IROM 端口 B 的 `b_wen/b_wdata/b_mask` 从"只接引导器"改成 `boot_busy ? 引导器 : CPU store`（两个 generate 分支都改，仿真/上板行为一致）；DRAM 写仍被窗口挡掉 |
| `sw/monitor.c` | 新命令 `L <addr>`（收十六进制流，每 8 位一个字，写窗口）与 `r <addr>`（跳到取指地址执行）；地址必须 ≥ 0x3000（monitor 自己占 0x0~0x2FFF） |
| `sim/tb_monitor.sv` | 新增 M5（`loaded 16 bytes`）与 M6（`returned to shell`）两条判据 |

`L` 的解析**不依赖换行**：连续十六进制数字流，每 8 位切一个字，CR/LF/空格忽略。
这是被 RX FIFO（8 深）教出来的 —— 宿主的换行会被挤掉，按行解析会把两行粘成 16 位。

### 验收（`sim/tb_monitor.sv`，真实 `board_top`，6/6 PASS）

```
> L 3000
hex8, '.'=end
....                                   ← 每写一个字回一个点
 loaded 16 bytes @irom 0x00003000  (run 0x00003000)
> p 23000
 [00023000] = 0x10000537                ← 字**真的**写进 IROM 了（lui a0,0x10000）
> r 3000
 jump to irom 0x00003000, running...
* returned to shell                     ← 星号是**应用自己**写的；然后返回了 shell
[MONITOR-SELFCHECK] status=PASS (6 checks)
```

M6 的判据就是 `"* returned"` 这 10 个字节 —— 星号只能由应用的三条指令
（`lui/addi/sw`）写出来，所以它同时证明"代码写进去了、跳过去执行了、UART 通了、
还能返回"。

**上板同样通过**（v16 bitstream + `_diag/load_app.ps1`）：

```
[load] 4 words (16 bytes) @irom 0x3000
[load] reply: ....  done  loaded 16 bytes @irom 0x00003000  (run 0x00003000) >
[run ] reply: r 3000  jump to irom 0x00003000, running... * returned to shell >
```

### 两个必须记住的坑（都实测踩过）

1. **安全下界不能硬编码**：最初写 0x3000，但 monitor 加了 load/run 两条命令后
   `.text` 涨到 13 836 B（`_etext` = 0x2C0C），再涨一点就会自己踩自己。
   现在 `link.ld` 里加了 `_etext` 符号，monitor 用
   `IROM_APP_MIN = align4k(_etext)`；`L`/`r` 用同一个下界。
   ★ 边界：monitor 再长到跨过 4KB 边界时，`IROM_APP_MIN` 会自动上移，
   而 `sim/tb_monitor.sv` 里的 0x3000 需要跟着改（TB 用固定地址）。
2. **跳过去之前要等 UART 真的空**：`putc_` 只在写之前查 busy，最后一个 `\n` 还在
   移位寄存器里（115200 下 87 µs）；应用第一件事往往就是写 TXDATA，而 `uart_tx`
   忙时**丢弃** ⇒ 实测"应用跑了、它的第一个字符却不见了"。
   修法：`c_run` 在 `fn()` 之前 `while (UART_TXSTAT & 1);`。

### 构建（v16）

| 项 | 值 |
|---|---|
| WNS / WHS | **0.048 / 0.015 ns** ← 时序余量已经几乎为零 ⚠️ |
| Slice LUTs | 36 150（67.95%） |
| Slice Registers | 34 058（32.0%） |
| Block RAM Tile | 66.5（不变） |

⚠️ **WNS 0.048 ns 是个警告**：v15 是 0.645，v16 只多了一个写使能 mux，却吃掉 0.6 ns
（大概率是布线/布局噪声，但也说明这条路径已经很紧）。下一次改 RTL 之前应该先跑
`report_timing` 看关键路径，别再往这条路上加逻辑；真要提速就得重新排布
`perip_addr/perip_wen`（它们扇出到 MMIO 译码、DRAM、IROM 端口 B 三处）。

### ★ 更正：`fence.i` **没有缺陷**（上一版文档里的"会让 CPU 停住"是误判）

上一版这里写着"插了 fence.i 之后 CPU 不响应"，**结论是错的**。真相是测试台的问题：
`sim/tb_monitor.sv` 在 shell 还在打印（"loaded ..."/"> "）的时候就把下一条命令发完了，
而 RX FIFO 只有 **8 深** —— 行尾的 CR 被挤掉，命令永远等不到回车，看上去就是"CPU 停住"。
把 TB 的间隔从 2 ms 拉到 12 ms 之后，**带 fence.i 的版本 6/6 全过**。

而且 `fence.i` 本身也单独验证过（新增 `sw/fenceitest.c`）：

```
bash sw/build_simple.sh sw/fenceitest.c fenceitest
bash sw/run_coremark.sh +irom=sw/build/fenceitest_irom.hex +dram=sw/build/fenceitest_dram.hex
  → F1 / F2 / F3 / F4 / FENCEITEST-PASS
```

三种场景：裸 `fence.i`；`store` 之后紧跟 `fence.i`；循环里连续四条 `fence.i`。
三种都正常退休并继续执行 ⇒ 这条指令在当前实现里是可用的。
（`tb_sys fencei` 只测"能退休、不崩"，`fenceitest` 补的是"之后还能继续取指执行"。）

★ 现在的 `L`/`r` **都带 fence.i**（"写完代码区再跳"和"热补丁"都靠它）。
★ 真正的教训不是 fence.i，而是**测试台的时序也是被测系统的一部分**：
8 深 FIFO + 阻塞式打印，命令之间的静默期必须大于一行的打印时间。

（`_diag/load_app.ps1` 一行一个 `Write` 发送，正好绕开了这个问题 —— 它把整段
hex 一次写出去，`c_load` 的解析又**不依赖换行**，所以不会被 FIFO 挤压影响。）

## 9. v17：**C 应用也能 load-and-run**（`D` 命令 + `link_app.ld`）

v16 只能跑"裸机器码"（纯指令、没有常量）。要跑 C 程序，缺的是两样东西：
**字符串/常量放哪** 和 **怎么把数据段灌进去**。

### 改动

| 位置 | 内容 |
|---|---|
| `sw/monitor.c` | 新命令 `D <addr>`：与 `L` 同一套"连续十六进制流"解析，但**直接写目标地址**（DRAM/MMIO），用于灌 `.rodata/.data`；上限 8KB；拒绝写 IROM 窗口（那是 `L` 的活） |
| `sw/app/link_app.ld` | 应用布局：`.text` 从 **`IROM_APP_MIN`**（当前 0x4000，48KB）起；`.rodata/.data/.bss` 放 DRAM 0x1_0000；**没有 crt0**（入口就是 `main`，由 shell `jalr` 调用、沿用 shell 的栈、`return` 回 shell） |
| `sw/app/hello_app.c` | 演示应用：打印 `.rodata` 里的字符串 + 累加 `.data` 变量，自己清 `.bss` |
| `sw/build_app.sh` | 编应用：`--split 0xC000`（= 0x10000-0x4000）+ `--trim`，并打印 `APP_ENTRY=0x........` |
| `_diag/load_app.ps1` | 新增 `-HexFile/-DramHex/-DramAddr/-Entry`：一条命令完成 "L 代码 → D 数据 → r 入口" |

★ 为什么 `.rodata` 必须放 DRAM：本核 `lw` 走数据口，地址 0x4000 会被译到 **DRAM**
（不是 IROM 窗口 0x2_xxxx）。放 IROM 的只有**取指**读的那些字节。
★ `.bss` 由应用自己清（`__bss_start/__bss_end` 来自 `link_app.ld`）—— shell 不知道
它多大，也不该替应用清。

### 验收（上板实测）

```
[load] 95 words (380 bytes) @irom 0x4000   →  loaded 380 bytes @irom 0x00004000
[data] 9 words @dram 0x10000               →  stored 36 bytes @0x00010000
[run ] entry 0x4034
[run ] reply: r 4034  jump to irom 0x00004034, running...
              HELLO-APP from IROM 0x4000 acc=15  returned to shell >
```

`HELLO-APP from IROM 0x4000` 来自 **DRAM 的 .rodata**，`acc=15` 说明 `.bss` 清过、
`.data` 可写 —— 代码/常量/数据三段全都走了这条新通路，而且返回了 shell。

### 又一次被 `IROM_APP_MIN` 救了

加了 `D` 命令之后 monitor 的 `.text` 涨过 12KB，`IROM_APP_MIN` 自动从 0x3000 跳到
**0x4000**；第一次 `L 3000` 直接被拒：
` refuse: below shell text end; use >= 0x00004000` —— 这正是硬编码下界会踩的坑，
而现在是机器替我们算的。应用与 TB 都跟着改成 0x4000。

## 10. 下一轮清单

1. 时序收紧：**WNS 只剩 0.048 ns**，下一次改 RTL 前先 `report_timing`，
   别再往 `perip_addr/perip_wen` 的扇出锥上加逻辑。
2. `_diag/app_build_run.ps1`：把 `build_app.sh` + `load_app.ps1` 串成一条命令
   （含 `IROM_APP_MIN` 检查：从 shell 的 `i` 命令读，或直接试 `L` 看是否被拒）。
3. `--trim` 精简引导镜像；`board_smoke.ps1` 增加 `-WithFenceI`（已有）与
   `-WithHelloApp`（把 C 应用也纳入一键验收）。
