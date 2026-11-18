# 提交对比报告：`f41acf4` → `f1e8eed`
> **状态**：**当前**（2026-11-18）｜两版 git 提交的逐项对比：规模、改动面、能力增量、证据强度、体积来源

> 仓库：`git@github.com:fshanhuan/Rsic-v-IM`　分支：`main`
> 上一版 `f41acf4`（2026-11-11 21:39）→ 这一版 `f1e8eed`（2026-11-18 14:40）
> 所有数字都由 §12 的命令直接从 git 对象算出，不含估计值。

---

## §1 一句话结论

上一版是 **"v18 SoC + Zynq PS 接入"**（处理器、总线、双核协同）；
这一版在**不删任何一个文件、不改任何已验证时序**的前提下，长出整条 **记录仪 + HDMI 产品线**：16 个新 PL 外设、52 个 PS 裸机源文件、12 个新测试台、10 份新文档、一套 SD 卡写入软件栈。

```
140 个文件新增 / 34 个文件修改 / 0 个文件删除
+29 948 行 / −110 行
```

**"0 删除"是这版最重要的性质**：升级不会丢任何东西，上一版能跑的仿真、脚本、文档全部原地保留。

---

## §2 两个版本各自的坐标

| 项 | 上一版 `f41acf4` | 这一版 `f1e8eed` | 变化 |
|---|---|---|---|
| 提交时间 | 2026-11-11 21:39:36 | 2026-11-18 14:40:05 | 7 天 |
| 提交说明 | feat(v18+PS): 总线化 A1-A4、软件段、AXI 桥、Zynq PS 接入与双核协同三步 | feat(rec): 记录仪 + HDMI 产品线（S0–S8）、SD 写入链路与文档重整 | — |
| 跟踪文件数 | 569 | 709 | **+140** |
| 仓库体积（跟踪内容） | 11.06 MB | 25.08 MB | **+14.0 MB** |
| 产品定位 | 处理器 + 上板工程 + v17 报告 | 多一条**数字记录仪/示波器**产品线 | 分支式扩展 |

---

## §3 改动面总表

| 类别 | 文件数 | 行数 |
|---|---:|---|
| 新增（A） | 140 | **+29 291 / −0** |
| 修改（M） | 34 | **+657 / −110** |
| 删除（D） | **0** | 0 |
| 合计 | **174** | **+29 948 / −110** |

修改的 34 个文件按性质分两类：

| 性质 | 文件数 | 具体 |
|---|---:|---|
| **动了逻辑** | **8** | `rtl/soc_map.sv`、`rtl/DCache.sv`、`board/board_top.sv`、`board/soc_bus.sv`、`board/axil_slave.sv`、`sw/soc_map.h`、`sim/tb_axil.sv`、`sim/tb_monitor.sv` |
| 文档/证据类 | 26 | 22 个 `docs/*.md` + `syn/修复史_全量.md` + 根 `README.md` + 2 个重跑的 `.vcd`；其中 **18 份文档只是 H1 后插一行「状态」（各 +2 行）** |

---

## §4 按目录的增量

| 目录 | 旧文件 | 新文件 | 新增行 | 删除行 | 体积变化 | 这一版加了什么 |
|---|---:|---:|---:|---:|---:|---|
| `sw/` | 131 | 183 | +13 128 | 0 | +429 KB | PS 裸机：SD 位翻转、FAT32、记录仪、SDHCI 移植、移植垫片 |
| `docs/` | 47 | 61 | +7 842 | −68 | **+9.2 MB** | 4 份记录仪文档 + v18 手册 + 双核方案 + 存储器汇报 + 3 个生成脚本 + 4 份 docx/pdf |
| `tools/` | 38 | 63 | +3 538 | 0 | +129 KB | xsdb 自动化、PC 侧验证、ILA 图像重建、位级 SD 仿真 |
| `board/` | 15 | 31 | +3 027 | −16 | +132 KB | 16 个记录仪外设 + 顶层 `board_top_ps_rec` |
| `sim/` | 128 | 140 | +2 245 | 0 | +88 KB | 12 个新测试台（含 474 行的 `tb_recorder`） |
| `rtl/` | 24 | 24 | +114 | −25 | +7 KB | 只改索引宽度 + `DCache` 一行修正，**核心逻辑未动** |
| `syn/` | 9 | 9 | +53 | 0 | +3 KB | 综合修复史新增条目 |
| `wave/` | 10 | 24 | 二进制 | 0 | +3.3 MB | 14 个新 VCD + 2 个重跑覆盖 |
| `figures/` | 8 | 15 | 二进制 | 0 | +782 KB | 7 张新图（含 3 张 HDMI 像素域证据） |
| 根 `README.md` | 1 | 1 | +1 | −1 | — | 产品级汇总改指 v18 手册 |
| `msim/`/`teach/`/`experimental`/`reports` | — | 不变 | 0 | 0 | 0 | **完全未动** |

---

## §5 能力增量：新长出来的子系统

### 5.1 PL 侧（16 个新模块，2 901 行）

| 子系统 | 模块 | 行数 | 作用 |
|---|---|---:|---|
| 采集 | `xadc_sampler.sv` | 203 | XADC 连续采样，出样本流 |
| 采集 | `trigger_unit.sv` | 108 | 边沿/电平触发，稳定帧 |
| 采集 | `meas_unit.sv` | 89 | 周期内 min/max/VPP/均值 |
| 采集 | `async_fifo.sv` | 118 | 跨时钟域缓冲（50 MHz ↔ 40 MHz 像素域） |
| 显示 | `scope_display.sv` | 312 | 波形列缓冲 → 800×600 像素域 |
| 显示 | `hdmi_timing.sv` | 147 | 1056 / 628 / 480000 / 663168 时序发生器 |
| 显示 | `hdmi_meas.sv` | 106 | 测量值叠加定位 |
| 显示 | `font5x7.sv` | 79 | 5×7 字模（`tools/gen_font5x7.py` 生成） |
| I2C | `i2c_master.sv` | 235 | 两路位级 I2C 主控 |
| I2C | `i2c_probe.sv` | 279 | 上电扫描 0x00–0x7F，出地址位图 |
| I2C | `adv7511_init.sv` | 280 | ADV7511 寄存器序列（HDMI 编码器） |
| I2C | `i2c_mmio.sv` | 127 | 两路控制器挂到 MMIO |
| 寄存器 | `rec_mmio.sv` | 340 | 记录仪全部寄存器（`idx ≥ 16`） |
| 模拟 | `dac0832.sv` | 62 | 8 位 DAC 直通（自环用） |
| 顶层 | `board_top_ps_rec.sv` | 270 | 记录仪产品顶层（PS + 记录仪 + 可选 ILA） |
| 上报 | `uart_report.sv` | 146 | 串口报表输出 |

> `board/` 全目录新增 3 027 行 = 这 2 901 行 + 3 个被修改文件的 126 行。

### 5.2 PS 侧（52 个新文件，13 092 行）

| 分组 | 文件数 | 行数 | 内容 |
|---|---:|---:|---|
| **SD 卡写入链路** | 14 | 1 861 | `sd_bit_bus.c`(459) / `sd_crc.c`(53) / `sd_wr.c`(153) / `sd_record.c`(215) / `sd_dump.c`(149) / `sd_fat_sd.c`(163) / `sd_fat_sd_syn.c`(17) / `sd_bit.c`(78) / `fat32.c`(302) + 5 个头文件 |
| **Xilinx SDHCI 移植** | 9 | **7 319** | `sdps/xsdps*.c/h` —— **已放弃的路径**（CMD0 永不完成），整份保留备查 |
| 链接 / 启动 / 构建 | 3 | 226 | `start_ps_sd.S`、`link_ps_sd.ld`、`build_ps_sd.ps1` |
| 历史探针 | 5 | 1 330 | `sd_probe.c`、`sd_raw.c`、`sd_spi.c`、`sd_cd.c`、`mio_test.c` |
| 应用 / 自检程序 | 7 | 1 764 | `recorder.c`、`adctest.c`、`trigtest.c`、`i2ctool.c`、`fat32_test.c`、`sd_wr_test.c`、`uart_beacon.c` |
| 移植垫片 | 14 | 592 | `sw/ps/port/xil_*.h`（13 个）+ `xil_shim.c` |

### 5.3 测试台（12 个新，2 157 行）

| 测试台 | 行数 | 测什么 |
|---|---:|---|
| `tb_recorder.sv` | 474 | 记录仪整链（采集→列缓冲→显示）逐拍 |
| `tb_i2c.sv` | 251 | I2C 位级时序 + ACK |
| `tb_adv7511_init.sv` | 238 | ADV7511 寄存器序列 |
| `tb_xadc_sampler.sv` | 195 | 采样节拍 |
| `tb_hdmi_timing.sv` | 173 | 1056/628/480000/663168 |
| `tb_trigger_unit.sv` | 149 | 触发电平/边沿 |
| `tb_scope_display.sv` | 148 | 列→像素映射 |
| `tb_boot_image.sv` | 119 | 镜像加载 |
| `tb_async_fifo.sv` | 108 | 跨时钟域不丢样本 |
| `tb_hdmi_meas.sv` | 118 | 叠加窗口 |
| `tb_meas_unit.sv` | 99 | min/max/VPP/均值 |
| `tb_font5x7.sv` | 85 | 25 个字符逐位对字模 |

### 5.4 工具链（25 个新，3 538 行）

| 分组 | 内容 |
|---|---|
| **xsdb 自动化**（8） | `arm_exec.tcl`、`arm_drain.tcl`、`arm_mailbox.tcl`、`arm_slcr_up.tcl`、`jtag_probe.tcl`、`s5_demo.ps1`、`sd_session.ps1`（一键四模式）、`sd_wr_test.ps1` |
| **PC 侧验证**（6） | `sd_bit_sim_test.c`（位级 SD 卡仿真，驱动**真实的** `sd_bit_bus.c`）、`fat32_host_test.c`、`fat32_verify.py`、`fat32_verify_dump.py`、`fat32_probe_pyfatfs.py`（第三方 FAT 驱动交叉验证）、`build_and_run.ps1` |
| **ILA 证据重建**（3） | `ila_frame_assemble.py`、`ila_pixels_to_png.py`、`ila_text_decode.py` |
| **其他**（8） | `check_board_pins.py`、`gen_font5x7.py`、`mk_boot_image.py`、`arm_a32_disasm.py`、`build_sim.ps1`、`host/sim/xil_io.h`、`host/sim/sleep.h`、`sd_spi_demo.ps1` |

---

## §6 对既有代码的修改（8 个文件，这是最该关心的部分）

| 文件 | +/− | 改了什么 | 对已验证行为的影响 |
|---|---:|---|---|
| `rtl/soc_map.sv` | +89/−23 | MMIO 索引 **4 位 → 6 位**；新增 16–63 号寄存器定义（I2C/HDMI/XADC/列缓冲/DAC/记录仪） | **零**。0x00–0x3C 的 16 个编号、语义、读写时序全部不变，只是比较位宽变宽；0x40 以上不再别名到 0x00 |
| `board/soc_bus.sv` | +7/−3 | `mmio_idx` 从 `addr[5:2]` 改为 `addr[7:2]`，位宽 4→6 | **零**，同上 |
| `board/board_top.sv` | +54/−6 | 新增参数 `DRAM_INIT`（默认 `""`）、`EXT_MMIO`（默认 `0`）+ 4 个 `ext_*` 端口 | **零**。两个默认值都取"保持 v18 行为"：`DRAM_INIT=""` 不加载镜像，`EXT_MMIO=0` 时 `ext_we` 恒 0、`ext_rdata` 不进 mux |
| `board/axil_slave.sv` | +65/−7 | 等授权 / 等返回加硬超时 `GNT_TMO=64`，超时回 **SLVERR** 放行 | 只影响 `AXIL_EN=1` 的 PS 工程；记录仪位流 `AXIL_EN=0`，端口全钉死。出发点是真实事故：PS 发起的事务若从端永不授权，会把 PS 互连锁死（实测 JTAG 都 halt 不进 A9，只能断电） |
| `rtl/DCache.sv` | +25/−2 | 不可缓存路径的返回判定加一项 `cpu_addr == rd_addr_r` | 修**错值**：连续读两个不同 MMIO 寄存器时，第二个读到第一个的值（实测 `lw 0x94` 读回 0x84 的 bank 值 → 每列取 0 样本 → 一帧一个样本都不弹）。改后重跑全量回归 55/55 |
| `sw/soc_map.h` | +36 | 与新编号同步（生成头文件） | — |
| `sim/tb_axil.sv` | +60 | 新增超时用例 | 纯增量 |
| `sim/tb_monitor.sv` | +28 | 新增监视项 | 纯增量 |

### 文档类改动明细（26 个，不改逻辑）

| 文件 | +/− | 内容 |
|---|---:|---|
| `docs/README.md` | +161/−64 | **重写**：时间线 → 文档地图、状态约定、命名规则、报表产物清单 |
| `syn/修复史_全量.md` | +53 | 新增条目 |
| `docs/DRAM_接口详解.md` | +3/−1 | 补索引宽度说明 |
| `docs/MMIO_接口详解.md` | +3/−1 | 补索引宽度说明 |
| `docs/历史/产品说明_v9_客户版.md` | +2/−2 | 措辞修正 |
| 其余 **18 份** `docs/*.md` | 各 +2 | 统一插入「> **状态**：…」一行 |
| 根 `README.md` | +1/−1 | 产品级汇总从 v17 报告改指 v18 手册 |
| `wave/tb_iverilog.vcd`、`wave/tb_iverilog_prog.vcd` | 二进制 | 重跑覆盖 |

---

## §7 文档对比

| | 上一版 | 这一版 |
|---|---:|---:|
| `docs/` 文件数 | 47 | 61 |
| 其中新增 | — | 10 个 `.md` + 4 个二进制（`docx`/`pdf`） |
| 新增正文字数 | — | ≈ 6 700 行（另有 3 个生成脚本 1 121 行） |

### 新增的 10 份文档

| 文档 | 行数 | 定位 |
|---|---:|---|
| `docs/记录仪_HDMI_方案.md` | 3 938 | **设计主干**，§1–§46：架构、时序、MMIO 表、每个坑的前因后果 |
| `docs/产品手册_v18.md` | 738 | v18 产品手册（规格/性能/资源/验证/路线图） |
| `docs/记录仪_验收报告.md` | 548 | **一页纸验收**：S0–S8 每阶段做了什么、证据在哪、还缺什么 |
| `docs/记录仪_上板操作手册.md` | 397 | 上板全流程 + 38 条坑 |
| `docs/双核应用方案.md` | 388 | CPU ↔ ARM 双核协同 |
| `docs/存储器汇报.md` | 355 | 存储器专题（讲义底稿） |
| `docs/记录仪_SD插卡操作单.md` | 118 | 手机上照着做的一页 |
| `docs/report_src/make_product_doc.py` | 639 | v18 手册生成（md → docx → pdf） |
| `docs/report_src/make_product_figs_v18.py` | 365 | v18 配图生成 |
| `docs/report_src/add_status_headers.py` | 117 | 幂等插入「状态」行（上面 18 个文件的 +2 就是它做的） |

### 新增的 4 份二进制（8.8 MB，占总体积增长的 63%）

| 文件 | 大小 |
|---|---:|
| `docs/产品手册_v18.pdf` | 5.53 MB |
| `docs/存储器专题_研讨.docx` | 1.28 MB |
| `docs/存储器专题_研讨.pdf` | 1.19 MB |
| `docs/产品手册_v18.docx` | 0.84 MB |

---

## §8 证据资产

| 类型 | 数量 | 说明 |
|---|---:|---|
| 波形 `wave/*.vcd` | 14 新 + 2 覆盖 | 乘除/访存/循环等指令级回归波形 |
| 图片 `figures/*.png` | 7 | 其中 3 张是 **HDMI 像素域证据**（`hdmi_frame.png` 整帧重建、`hdmi_trace.png` 波形亮线、`hdmi_line300.png` 网格行）；4 张是 v18 架构/资源/启动/双核框图 |
| 位流 | **0（有意）** | `.gitignore` 排除 `*.bit`；22 个位流放在本地 `_baseline_v9/` |

---

## §9 能力对照：哪些数字是这一版挣来的

| 阶段 | 内容 | 上一版 | 这一版 | 证据类型 |
|---|---|---|---|---|
| S0 | MMIO 扩容 | 16 个寄存器 | **64 个**（`EXT_MMIO` 转发） | 上板回归 55/55 |
| S1a | I2C 主控 | 无 | 双路；**音频总线 2 个真实 ACK** | 上板实测 |
| S1b | HDMI 时序 | 无 | 1056 / 628 / 480000 / 663168 | 仿真（数字域） |
| S2 | XADC 采样 | 无 | ≈195 Sa/s，45.4 °C | 上板实测 |
| S3 | 波形显示 | 无 | 150 列 → 800×600 帧 | 仿真 + ILA 抓取重建 |
| S4 | 采集吞吐 | 无 | 3 130 Sa/s | 上板实测 |
| S5 | 排空 + CSV | 无 | 2 048 样本，`BEEF0005`，Δadc_cnt=2047，200 kSa/s | 上板实测 |
| S6 | 文本叠加 | 无 | `VPP 0.00` / `MEAN 0.00`，25 字符全对 | 仿真逐字比对 |
| S7 | 双速切换 | 无 | 400 kSa/s vs 200 kSa/s | 上板实测 |
| S8 | 文档 | v17 报告 | 4 份记录仪文档 + 索引重写 | — |

### 这一版**没有**拿到的证据（4 条，必须明说）

| 缺口 | 现状 | 卡在哪 |
|---|---|---|
| SD 卡**实际写入** | 软件栈全绿（板上假卡 33/33、位级仿真 21/21、PC 侧 37/37、4 张镜像过第三方 FAT 驱动），真卡 `waitbits=0xffffffff` | **没插 micro SD 卡**；且 PS 调试口被锁在 `0xF0000021`，需断电重上电 |
| HDMI **可见画面** | 像素域数据已重建（800×600 整帧） | 没有显示器接在板上 |
| HDMI **I2C ACK** | HDMI 总线 `f_h=0x0000`（扫不到地址） | 同上，编码器在无显示器时行为待查 |
| 模拟**自环** | XADC 数字通路已验 | 缺 DAC → 1:4.3 分压（100 Ω/330 Ω）→ AD11 的一根线 |

---

## §10 体积增长来源（+14.0 MB）

| 来源 | 增量 | 占比 |
|---|---:|---:|
| `docs/` 4 份二进制文档 | +8.8 MB | 63% |
| `wave/` 波形 | +3.3 MB | 24% |
| `figures/` 图片 | +0.8 MB | 6% |
| `sw/` 源码 | +0.43 MB | 3% |
| `board/`、`tools/`、`sim/`、`rtl/` 等 | +0.6 MB | 4% |

25 MB 对 GitHub 完全无压力（单文件上限 100 MB，建议仓库 < 1 GB）。**继续守住"`.bit` 不进仓库"这条**——22 个位流有 1.4 GB，进来一次就再也不好删了。

---

## §11 留在本地、没进 git 的（约 1.4 GB）

| 路径 | 内容 | 为什么排除 |
|---|---|---|
| `_baseline_v9/` | 22 个 `.bit` + 19 个 `.ltx` | 位流是构建产物；版本证据靠文档里的 WNS/DRC 数字 |
| `_diag/` | xsdb / dump 脚本、探针日志 | 机器相关、噪音大 |
| `v9_rec/`、`ps_bd_rec/`、`v9_ila/`、`v9_boot/`、`ps_bd/` | Vivado 工程（584 MB+） | 可由 `.tcl` 重建 |
| `sim/build/`、`sw/build/` | 编译产物 | — |

> **副作用**：文档里出现的 `_diag/…`、`_baseline_v9/…` 链接在 GitHub 上点不开。这是仓库既有约定（`.gitignore` 明确排除），`docs/README.md` §1 已注明。

---

## §12 怎么自己复核（每条数字的命令）

```powershell
cd _gh/Rsic-v-IM

# 规模
git diff --shortstat f41acf4 f1e8eed                       # 174 files, +29948, -110
git diff --name-status f41acf4 f1e8eed | Group-Object { $_.Substring(0,1) }   # A=140 M=34 D=0
git ls-tree -r --name-only f41acf4 | Measure-Object -Line  # 569
git ls-tree -r --name-only f1e8eed | Measure-Object -Line  # 709

# 逐目录、逐文件
git -c core.quotepath=false diff --numstat f41acf4 f1e8eed

# 只看动了逻辑的 8 个文件
git -c core.quotepath=false diff --stat f41acf4 f1e8eed -- rtl board sim/tb_axil.sv sim/tb_monitor.sv sw/soc_map.h

# 删除清单（应为空）
git diff --name-status --diff-filter=D f41acf4 f1e8eed

# 体积（字节，应得 26298650）
(git ls-tree -r -l f1e8eed) -replace '^\S+\s+\S+\s+\S+\s+(\d+)\s.*','$1' | Measure-Object -Sum
```

---

## §13 结论

| 问题 | 答案 |
|---|---|
| 升级会丢东西吗 | **不会**。0 个删除；26 个文档/证据类改动里，18 份只是加一行状态 |
| 旧项目还能跑吗 | 能。`board_top` 的两个新参数默认值就是 v18 行为，`AXIL_EN=0` 时 `axil_slave` 新逻辑不参与 |
| 这版最大的实质改动是什么 | `DCache.sv` 那一行的**错值修正**（多 1 个条件），加上 MMIO 索引 4→6 位 |
| 这一版能对外汇报到什么程度 | S0/S1b/S2(XADC)/S3/S4/S5(排空+CSV)/S6/S7 可以说"已实现、有实测数字"；**"可见 HDMI 画面""SD 卡实际写入""HDMI I2C ACK""模拟自环"这四项不能说** |
| 下一步最该补的是什么 | 插卡 + 断电重上电，把 S5 的 SD 写入从"软件全绿"变成"卡上留文件" |
