# SD 卡插卡操作单（手机上照着做）
> **状态**：**当前**（2026-11-18）｜手机上看的一页：插卡 → 断电 → 一条命令 → 看判定表


> 目标：让"ADC 样本 → CSV → micro SD 卡"这条链路出真凭据。
> 你需要做的事只有两件：**插卡**、**拔电再上电**。剩下的交给一条命令。

---

## 一、准备（3 步）

| # | 做什么 | 注意 |
|---|---|---|
| 1 | 把 micro SD 卡插进卡槽 | 插到底，听到/感觉到卡住 |
| 2 | **拔掉 DC 电源，等 5 秒，再插上** | 必须真断电。用 `rst` 复位不行（板子的 PS 调试口会卡死） |
| 3 | 确认 JTAG 连着电脑 | 就是平时能烧板子那根 |

> 为什么必须断电：卡只在**上电那一瞬间**决定自己进 SD 模式还是 SPI 模式。
> 热插拔 / 只软复位，卡可能停在一个我们进不去的状态。

---

## 二、跑一条命令

在你平时开 PowerShell 的目录（`E:\FPGA\v9_vivado_ila`）：

```powershell
powershell -NoProfile -File tools\ps\sd_session.ps1
```

它会按顺序做：**先探板子 → 识别卡 → 格式化并写 CSV → 把关键扇区读出来 → 用两套独立方法验字节**。
每一步打印 `[PASS]` 或 `[FAIL]`，最后给一张表。

---

## 三、正常应该看到什么

> **⚠️ 2026-11-19 22:20 重要澄清：`-Mode Full` 写进去的样本是"假 DRP"的方波，不是真 XADC。**
>
> **✅ 23:49 已修好：方案 A 完成。** 新位流 `_baseline_v9/board_top_ps_rec_S5x.bit` 里
> ADC 换成了**真 XADC**（片内温度通道），实测排空 256 个样本：
> 15 个不同码值 / 2529…2543 / 均值 2536.5 → **619.3 mV → 38.9 °C**，
> 期间 `adc_cnt` **+256**（200 kSa/s）。
> 用法：先 `xsdb _diag\prog_s5x.tcl` 烧这个位流，再跑 `-Mode Full`
> （或直接 `_diag\s5x_verify.ps1`）。旧位流保留为 `board_top_ps_rec_S5_fakedrp.bit`。
>
> 下面是当时（修好之前）的记录，留着说明**为什么会有这一步**：
>
> PS 那一版位流（`board_top_ps_rec_S5.bit`）为了不占模拟引脚、不要 DMA，
> **ADC 用的是假 DRP**（`board/board_top_ps_rec.sv` 第 18 行写明"不接 XADC 原语"），
> 码值固定 `2048 ± 32`（`0x07E0 / 0x0820`）。修好前实测确认：
> `drain_20261119_221551.csv` 1024 行只有这两个值，`2016 ×512 + 2080 ×512`。
>
> 真正带**真 XADC** 的是 PL 那版（`board_top_rec.sv`，S2b2 位流），但它把 PS 的
> AXI 从口**钉死**了（`s_axil_*` 全接常数），ARM 读不到。
> 所以修好之前**没有任何一个位流同时具备"真 XADC + PS 可读 AXI"**。
>
> 这件事不影响"SD 写卡链路"的结论（写/读/校验都是真的），但它决定了
> `-Mode Full` 到底证明了什么。要写进 SD 的样本是**真 ADC 数据**，有两条路：

| 方案 | 改什么 | 代价 | 样本 |
|---|---|---|---|
| **A（小）** | 把 `board_top_ps_rec.sv` 里的假 DRP 换成真的 XADC 原语，只开**片内温度通道**（不占任何引脚，端口不变 → 不用重包 IP）| 一次 BD 重建（~40 min）| **真 ADC 转换**，但是温度 |
| **B（大）** | 再给 PS 那版加上 AD11/AD10/AD2 的模拟 inout，同时改 IP 端口表 + BD 连线 + XDC | 重包 IP + BD 重建，1~2 轮 | **真 ADC**，且是外部模拟通道 |

在选之前，先把板上这条链路跑通（`-Mode Card`）不受影响 —— 它写的是程序自己
生成的合成 CSV，和 ADC 无关。

```
[PASS] preflight : debug APB reachable
[PASS] sd_bit : card identified, LBA0 read
[PASS] write  : CSV written and read back byte-identical (diff=0)
[PASS] verify-1024 : card bytes == CSV (djb2 match), CSV extracted to PC and opened twice, third-party FAT driver reads it
RESULT PASS (card validated end to end)
```

`diff=0` 和最后一行 `RESULT PASS` 就是"卡上文件和导出逐字节一致"的凭据。

**"PC 能打开"是单独一条证据**（2026-11-19 补）：`verify` 这一步会把卡字节里
重建出来的文件**落到 PC 上** `sim\build\sd\card_file_1024.csv`，然后**用两种
互不相干的实现各打开一次** —— Python 的 `csv` 模块、PowerShell 的 `Import-Csv`，
两次都报行数与列名。输出里会多这两行：

```
  extracted: sim\build\sd\card_file_1024.csv (9603 bytes, djb2=0x545706DB)
  csv open check: 1001 rows (incl. header), header=['idx', 'adc']
  [pc-open] Import-Csv: 1000 rows, columns=idx,adc
```

验收时直接双击那个 `.csv`（Excel / 记事本都能开）就是最直白的物证。
本机已用主机侧 dump 把这条路跑通：`9603` 字节、`djb2=0x545706DB`、
**1000 行 0 处不符**（按 `idx*7+0x800 & 0xFFF` 复核）。

> 2026-11-19 21:30 补：preflight 那一行也可能长这样 ——
> `[PASS] preflight : debug APB recovered by rst -processor`
> 这是**正常的**（板子上电后调试口偶发卡住，`rst -processor` 能救回来，
> 实测恢复后读写测试 `0xCAFEBABE` 通过）。只有**三种复位都救不回来**才需要断电。

---

## 四、卡住了怎么办（三种典型情况）

### 情况 A：`[FAIL] preflight : debug APB dead`

板子的 PS 调试口卡死了，`rst -dap` / `-system` / `-processor` 三种都试过仍不通。

**做法**：拔 DC，等 5 秒，插上（**卡要在这次上电时就位**），再跑一次。

> 注意区分：如果 preflight 显示 `recovered by ...`，那**不是**情况 A，板子是好的，别去断电。

### 情况 B：`[FAIL] sd_bit : no usable card response (ncr=64 ...)`

命令发出去了，但 64 个时钟里 CMD 线一直是高 = **没有任何东西应答**。

| 可能原因 | 怎么确认 |
|---|---|
| 卡没插到底 / 卡槽接触不良 | 拔出来重插，再断电上电 |
| 断电时卡不在位（卡被"热插"了） | 按顺序再来一次：插卡 → 断电 → 上电 |
| 卡不是 SDHC/SDXC（很老的卡） | 换一张 |
| MIO40..45 通路问题 | 报 `ncr=64` 且 `CLK-follow=1` 时，基本只能靠示波器量卡座 CLK 脚 |

把 `sim\build\sd\session_sd_bit.txt` 发我。

### 情况 C：`[FAIL] write : step=...`

卡被识别了（说明线通了！），但写/格式化某一步失败。这一步的日志在
`sim\build\sd\session_write_syn.txt`，里面 `[3b] speed probe -> ...` 那行尤其重要：

- `speed probe -> 1` = 高速可用
- `speed probe -> 0` = 高速不行已自动降速（只是慢，能继续）
- `speed probe -> -1` = 高速低速都读不出，异常

---

## 五、进阶：用真实样本（PL 记录仪）

`-Mode Card` 用的是**合成样本**（`0x800+7i`），目的是把"卡"和"PL 记录仪"两个变量分开。
卡确认没问题后，再跑真样本：

```powershell
# 先烧带记录仪 MMIO 的位流
D:\vivado\2025.2\Vivado\bin\xsdb.bat _diag\restore_s6.tcl

# 再跑完整模式（会用记录仪 FIFO 的真实样本，并重新验证一遍）
powershell -NoProfile -File tools\ps\sd_session.ps1 -Mode Full
```

---

## 六、只想看主机侧逻辑（不碰板子）

```powershell
powershell -NoProfile -File tools\ps\sd_session.ps1 -Mode Plan   # 只打印计划
powershell -NoProfile -File tools\ps\sd_session.ps1 -Mode Sim    # 位级仿真 + FAT32 规范/第三方复核
```

`-Mode Sim` 应该看到 `21/21` 和 `37/37` 全通过 —— 这一步不需要板子、不需要卡。

---

## 七、出问题要我查，把这些文件发我

| 文件 | 内容 |
|---|---|
| `sim\build\sd\session_sd_bit.txt` | 识别卡那一步的完整日志 |
| `sim\build\sd\session_write_syn.txt` | 写入那一步的完整日志 |
| `sim\build\sd\session_dump_1024.txt` | 读证据扇区那一步的日志 |
| `sim\build\sd\session_verify_1024.txt` | 规范复核的完整输出 |
| `sim\build\sd\sd_dump.bin` | 从板子上 dump 出来的证据扇区（16 KB） |

一句话总结现状也行：**把最后那张表的截图发我**就够判断。
