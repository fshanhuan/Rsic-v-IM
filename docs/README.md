# 文档索引

> 工程：**BigBird RV32**（RV32IM + Zicsr + Zicntr，M 模式）· 目标板 EES-331 / `xc7z020clg484-1` · 当前代码 **v17**
>
> 命名约定：**当前有效**的文档放在本目录；**已被取代但保留证据链**的放在 [`历史/`](历史/)；
> 对外报告是 `产品报告_v17.docx`，它由 [`report_src/make_report.py`](report_src/make_report.py) 生成，
> 图由 [`report_src/make_figures.py`](report_src/make_figures.py) 生成——**改内容改脚本，不直接改 docx**。

## 1. 当前文档（按阅读顺序）

| 文件 | 讲什么 | 什么时候看 |
| --- | --- | --- |
| [`../README.md`](../README.md) | 工程首页：v17 现状、资源/性能、五分钟上手、仓库结构 | **第一次打开仓库** |
| [`存储器专题_研讨.docx`](存储器专题_研讨.docx) | 14 页课堂讲义：存储器在芯片里的位置、地址空间与三路译码、用途、I/O 时序六条契约、7 张仿真波形逐拍解读、实测数字、8 道讨论题 | 讲课 / 组内研讨存储器 |
| [`产品报告_v17.docx`](产品报告_v17.docx) | 18 页产品级报告：规格参数、六项关键技术、CoreMark 实测、资源与时序、三层验证、风险与路线图 | 对外介绍、评审、验收汇报 |
| [`开发记录.md`](开发记录.md) | v14~v17 开发总账：分支预测扫参（64→256）、IROM 双读口与数据窗口、load-use 2 拍→1 拍、MMIO 重复读缺陷（P4）、轻量 shell、load-and-run；**含没做成的部分与原因** | 改 RTL 之前必读；查"为什么这样设计" |
| [`C_工具链与RTOS.md`](C_工具链与RTOS.md) | rv32 gcc 13.2 工具链、CoreMark 移植与报分流程、FreeRTOS 移植、P 系列缺陷修复 | 跑 C 程序 / 复现 CoreMark |
| [`串口与console.md`](串口与console.md) | 串口引导（boot loader）、Zicntr 计数器、UART 收发、RXDATA 幂等 peek + RXPOP 出队、RX FIFO、GPIO；合并了原 `BOOT_UART` / `ZICNTR_UART` / `CONSOLE_GPIO` 三份记录 | 接外设、调 console、做板级集成 |
| [`IROM两段式布局_代码清单.md`](IROM两段式布局_代码清单.md) | **汇报用代码清单**：`0x0000` 主镜像 + `0x4000` 起 48 KB 程序区的全部原文——两个 `link.ld`、`_etext`→`IROM_APP_MIN`、`L`/`D`/`r` 三条命令、`board_top` 的 `irom_win_sel` 与第二端口、`build_app.sh` 的 `--split` | 讲"换程序不用重新综合"、答疑 IROM 怎么划分 |
| [`地址表.md`](地址表.md) | **SoC 地址表（自动生成）**：数据口地址空间 + MMIO 16 个寄存器（含 PLIC/CLINT）。来源 `rtl/soc_map.sv`，生成 `tools/gen_soc_map.py`，`--check` 进回归 | 查地址、改外设、核对软件宏 |
| [`SoC_验收报告.md`](SoC_验收报告.md) | **一页看完的验收材料**：A1–A4 + 软件 S3/S4/S5 的交付与判据、时序资源对比（WNS +0.250 ns、BRAM 66.5 不变、LUT −246）、**还没做的**（S1 缺陷 / S2 / S5 渲染 / 上板）、复现命令、结构图 | 汇报、评审、交接 |
| [`ROADMAP_SoC.md`](ROADMAP_SoC.md) | **SoC 化路线图**：A1 总线 ✅ / A2 中断 ✅ / A3 CLINT ⬜ / A4 地址表生成 ⬜ / 软件五步 ⬜；每阶段的状态、判据、改动清单与风险 | 想知道"下一步做什么"、接手这个工程 |
| [`中断_A2.md`](中断_A2.md) | **A2 中断子系统**：`rtl/plic_lite.sv`（8 源、电平语义、固定优先级）+ `CSR.mip.MEIP` 不再硬连 0；4 个 MMIO 寄存器（`0x20~0x2C`）；`sw/irqtest.c` + `sim/tb_irq.sv` 判据 `mcause=0x8000_000B` | 接外设中断、查"丢键/丢字节" |
| [`总线化_A1.md`](总线化_A1.md) | **A1 总线化**：新增 `rtl/soc_map.sv`（地址单一来源）+ `board/soc_bus.sv`（译码/片选/读回选/写分发）；加外设从改 4 处降到 1–2 处；三条不变量（写使能只许一处判断、读回选必须用 `hit_*`、`ren`/`wen` 分开分发）；`sim/tb_bus.sv` 四项判据；顺带发现停机 magic 地址撞 LED | 改板级译码、加外设之前 |
| [`模块速查_v17.md`](模块速查_v17.md) | **按 `.sv` 文件逐个**：逻辑五级↔物理八级映射、每个模块干什么、主要输入输出信号含义、命名约定（`_next`/`_pipe`/`_wb`）、哪些文件参与编译 | **第一次读代码**；查"这个信号是什么" |
| [`DCache_接口详解.md`](DCache_接口详解.md) | `rtl/DCache.sv` **25 个端口逐根**：谁驱动/谁消费/哪一拍有效/坑在哪；一次 load hit/miss、一次 store 的通行顺序；哪些端口板上看不见 | 讲存储器接口、读 W2 波形、改 DCache 之前 |
| [`DRAM_接口详解.md`](DRAM_接口详解.md) | `sync_mem` 实例 `dram_inst` **9 个端口**：读 T/T+1、写单拍脉冲、`mask` 字节合并、128 KB 译码、写使能必须被 MMIO/IROM 窗口挡掉 | 改存储器容量/译码、查"写坏 DRAM"类 bug |
| [`MMIO_接口详解.md`](MMIO_接口详解.md) | MMIO 不是模块而是 `board_top` 里的一段译码：总线侧 6 + 译码 2 + **7 个寄存器**（TXDATA/TXSTAT/RXDATA/RXSTAT/LED/BOOTREQ/RXPOP）+ 外设侧 5 | 接外设、写 console/GPIO、查串口丢字节 |
| [`模块说明.md`](模块说明.md) | 逐模块导读（历史版）：接口、握手约定、各级职责、易踩坑点；叙事更细，但 ICache/load 前递/除法拍数等描述已被 v17 取代 | 想知道"当时怎么定位 bug" |
| [`CPU优化评审.md`](CPU优化评审.md) | v9 基线的优化评审：还能优化什么、性价比、与主流实现的差距（含实测支撑） | 规划下一轮性能工作 |
| [`数据通路分析.md`](数据通路分析.md) | EXECUTE / CONTROL 数据通路与时序分析，关键路径剖析 | 调时序、改分支/异常逻辑 |
| [`vivado/`](vivado/) | 上板流程与 ILA：交付说明、50 MHz 实测、ILA 使用说明、上板验证判据、工程打开是黑的、ecall 重定向故障 | 建工程、烧板、抓波形 |

### 1.1 存储器讲义怎么复现（`存储器专题_研讨.docx`）

| 产物 | 生成脚本 | 说明 |
| --- | --- | --- |
| `docs/存储器专题_研讨.docx` / `.pdf` | [`report_src/make_mem_doc.py`](report_src/make_mem_doc.py) | 正文 + 13 张表 + 8 张图；**改内容改脚本** |
| `figures/存储器/M1、M9` | [`../sim/mem_map_fig.py`](../sim/mem_map_fig.py) | 位置/地址空间示意图、三路译码示意图 |
| `figures/存储器/M2~M8` | [`../sim/mem_wave.py`](../sim/mem_wave.py) | 7 张仿真波形图（读 `sim/build/mem_trace.csv`） |
| `sim/build/mem_trace.csv`、`mem_wave_long.vcd` | [`../sim/tb_mem.sv`](../sim/tb_mem.sv) | 每个下降沿录一次存储器接口；VCD 给 GTKWave 现场拖 |
| 演示程序（34 条指令） | [`../sim/gen_mem_demo.py`](../sim/gen_mem_demo.py) | 覆盖 load miss/hit、store、窗口读写、MMIO、自改写 |
| 数字（取指 620 次逐条核对、UART 434 拍/位…） | [`../sim/analyze_mem.py`](../sim/analyze_mem.py) | `--json` 出 `mem_facts.json` |
| `figures/存储器/wavedrom/`（WaveJSON + SVG + PNG） | [`../sim/wd_mem.py`](../sim/wd_mem.py) → [`../sim/wd_render.py`](../sim/wd_render.py) | IROM **全部端口**（22 格）/ DCache **关键端口** 逐拍图；用 `wavedrom-gui.html` 与 kodbox 插件各自的引擎出图，两套引擎输出逐字节一致 |
| `figures/存储器/wavedrom/` 的 W3/W4（DRAM / MMIO） | [`../sim/gen_dram_mmio_demo.py`](../sim/gen_dram_mmio_demo.py) → [`../sim/wd_io.py`](../sim/wd_io.py) | 换一份演示程序（sw/sb/sh 三种宽度写 + TXSTAT/TXDATA/LED），trace 另存 `mem_trace_io.csv`，不动 W1/W2 那份 |

一键复现：`pwsh sim/run_mem.ps1`（或 `bash sim/run_mem.sh`）。

**WaveDrom 版波形怎么来的**（两个工具都不联网）：

1. `python sim/wd_mem.py` —— 读 `sim/build/mem_trace.csv`，按拍窗把 IROM（`irom_inst`，端口 A/B 共 11 根）与
   DCache（`DCache_inst`，CPU 输入 6 + M1 探测 3 + 存储回值 1 + CPU 输出 2 + 计数器 2 + 存储侧输出 5，共 20 根）翻成 WaveJSON；
   DCache 图**故意不画** 5 根：`reset`/`req_seq` 窗口内恒定，`hit`/`miss` 是 RTL 里没有读者的死端口
   （`myCPU.sv` 引出后无人读，综合会删），`m1_rdata` 在 `m1_hit=0` 时无意义 —— 数据仍在 CSV 里，
   要加回来只需恢复 `dcache_doc` 里对应几行；
   同时自检窗口里确实出现了取指/窗口读/窗口写/load miss/回填/hit（15 条断言）。
2. `python sim/wd_vendor.py` —— 从 `wavedrom-gui.html`、`wavedrom-kodbox-plugin/.../editor.html` 抠出引擎（wavedrom 3.5.0 + 皮肤）。
3. `python sim/wd_render.py` —— 无头 Edge 打开 `sim/wavedrom/render.html?v=gui|plugin#<JSON>`，导出 SVG 与 2× PNG，
   并把同一份 JSON 交给另一个引擎交叉比对。

看图：`figures/存储器/wavedrom/index.html`（两张图 + 「在 wavedrom-gui.html 里打开」按钮，链接走 GUI 的分享 hash）。
手工编辑：GUI 里「导入 → 打开文件」选 `.json`；kodbox 里把 `.wave` 拖进编辑器。

## 2. 归档（`历史/`）

v9~v13 时代的记录，**内容已被上面文档吸收或取代**，仅在追溯"当时怎么定位的"时查阅：

| 文件 | 说明 |
| --- | --- |
| [`历史/CHECKPOINT_v12.md`](历史/CHECKPOINT_v12.md) | v12（串口引导 + console）状态快照 |
| [`历史/CHECKPOINT_v13.md`](历史/CHECKPOINT_v13.md) | v13（CoreMark 首次报分 116.80 iter/s）状态快照 |
| [`历史/IMPLEMENTATION_v10.md`](历史/IMPLEMENTATION_v10.md) | v10：前端解耦 / MDU radix-4 / 异常体系 / 实现策略 |
| [`历史/IMPLEMENTATION_v11.md`](历史/IMPLEMENTATION_v11.md) | v11 六步优化实施记录 |
| [`历史/优化_v11_进度.md`](历史/优化_v11_进度.md) | v11 工作日志 |
| [`历史/验证报告_v10_Verilator交叉仿真.md`](历史/验证报告_v10_Verilator交叉仿真.md) | v10 交叉仿真 / 覆盖率 / 随机差分 / 变异测试 |
| [`历史/待修复清单_cdp-tests第三轮.md`](历史/待修复清单_cdp-tests第三轮.md) | 官方 cdp-tests 第三轮发现的问题清单 |
| [`历史/产品说明_v9_客户版.md`](历史/产品说明_v9_客户版.md) | v9 客户版产品说明；**顶层端口表与时序契约仍适用**，性能/资源数字已被 v17 取代 |

## 3. 数字的权威来源（避免引用过时数据）

| 数字 | 权威来源 |
| --- | --- |
| CoreMark 128.82 iter/s、2.576 CoreMark/MHz | [`开发记录.md`](开发记录.md) §5b + 产品报告 表 17 |
| WNS +0.048 / WHS +0.015 ns、LUT 36 150、BRAM 66.5 | 产品报告 表 20/21；原始报告在 `_bak/impl_reports/` |
| 停顿分解（退休 80.3% / 误预测 8.8% / load-use 5.1% / MDU 4.7% / DCache 1.0%） | 产品报告 表 18（口径说明见该节 ★ 段） |
| 仿真回归 38/38、上板冒烟 6 项 | [`开发记录.md`](开发记录.md) §7 |

> ⚠️ 早期文档（含 `历史/`）里的 WNS、LUT、CoreMark 都是当时版本的实测值，**不要与 v17 混用**。
