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
| [`产品报告_v17.docx`](产品报告_v17.docx) | 18 页产品级报告：规格参数、六项关键技术、CoreMark 实测、资源与时序、三层验证、风险与路线图 | 对外介绍、评审、验收汇报 |
| [`开发记录.md`](开发记录.md) | v14~v17 开发总账：分支预测扫参（64→256）、IROM 双读口与数据窗口、load-use 2 拍→1 拍、MMIO 重复读缺陷（P4）、轻量 shell、load-and-run；**含没做成的部分与原因** | 改 RTL 之前必读；查"为什么这样设计" |
| [`C_工具链与RTOS.md`](C_工具链与RTOS.md) | rv32 gcc 13.2 工具链、CoreMark 移植与报分流程、FreeRTOS 移植、P 系列缺陷修复 | 跑 C 程序 / 复现 CoreMark |
| [`串口与console.md`](串口与console.md) | 串口引导（boot loader）、Zicntr 计数器、UART 收发、RXDATA 幂等 peek + RXPOP 出队、RX FIFO、GPIO；合并了原 `BOOT_UART` / `ZICNTR_UART` / `CONSOLE_GPIO` 三份记录 | 接外设、调 console、做板级集成 |
| [`模块说明.md`](模块说明.md) | 逐模块导读：接口、握手约定（4 条不变量）、流水线各级职责、易踩坑点 | 接手代码、做二次开发 |
| [`CPU优化评审.md`](CPU优化评审.md) | v9 基线的优化评审：还能优化什么、性价比、与主流实现的差距（含实测支撑） | 规划下一轮性能工作 |
| [`数据通路分析.md`](数据通路分析.md) | EXECUTE / CONTROL 数据通路与时序分析，关键路径剖析 | 调时序、改分支/异常逻辑 |
| [`vivado/`](vivado/) | 上板流程与 ILA：交付说明、50 MHz 实测、ILA 使用说明、上板验证判据、工程打开是黑的、ecall 重定向故障 | 建工程、烧板、抓波形 |

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
