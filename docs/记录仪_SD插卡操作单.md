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

```
[PASS] preflight : debug APB reachable
[PASS] sd_bit : card identified, LBA0 read
[PASS] write  : CSV written and read back byte-identical (diff=0)
[PASS] verify-1024 : card bytes match the CSV and a third-party FAT driver reads them
RESULT PASS (card validated end to end)
```

`diff=0` 和最后一行 `RESULT PASS` 就是"卡上文件和导出逐字节一致"的凭据。

---

## 四、卡住了怎么办（三种典型情况）

### 情况 A：第一步就 `[FAIL] preflight : debug APB dead`

板子的 PS 调试口卡死了，软件复位救不回来。

**做法**：拔 DC，等 5 秒，插上（**卡要在这次上电时就位**），再跑一次。

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
