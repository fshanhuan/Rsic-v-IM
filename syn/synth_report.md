# v9 综合资源报告（可复现）

## 复现方式

```bash
# 1) 准备 yosys（无需 root：直接解包 Ubuntu 的 deb）
mkdir -p /tmp/yroot && cd /tmp/yroot
apt-get download yosys yosys-abc
for d in *.deb; do dpkg-deb -x "$d" /tmp/yroot; done
export PATH=/tmp/yroot/usr/bin:$PATH

# 2) 在 v9/ 目录下跑报告
cd v9
yosys -s syn/synth_core.ys
```

> 若本机已有 yosys（`apt install yosys` 或 OSS CAD Suite），直接跑第 2 步即可。
> 换工艺：把 `synth_core.ys` 里的 `synth_xilinx -family xc7` 换成
> `synth_ice40` / `synth_ecp5` / `synth_intel` / `synth_gowin`。

## 整机资源（v9 现状：单拍组合 MDU）

映射目标 `synth_xilinx -family xc7`（Xilinx 7 系列作为代表性 FPGA）：

| 资源 | 数量 |
| --- | --- |
| LUT (LUT1~LUT6 合计) | 8218 |
| MUXF7 / MUXF8 | 1463 |
| 触发器 FF (FDRE+FDSE) | 5589 |
| CARRY4 进位链 | 521 |
| DSP48E1 | 12 |
| RAM 原语 (RAM32M/RAM64X1S) | 128 |

## MDU 改造前后对比（关键结论）

| 实现 | 逻辑单元估算 (LC) | CARRY4 | DSP48E1 | FF |
| --- | --- | --- | --- | --- |
| 原版：单拍组合 `MDU.sv` | 2150 | 419 | 12 | 0 |
| 时序化：`experimental/MDU_pipelined.sv` | 407 | 81 | 12 | 235 |

**结论**：把 MDU 从「单拍纯组合」改为「乘法单拍 + 除法 32 拍迭代」后，
MDU 的逻辑规模降到约 **1/5**，最长进位链降到约 **1/5**，代价是 235 个触发器。
DSP 用量不变（12 个，来自 3 个 32×32 乘法器）。

这是整机时序收敛中**性价比最高的一处改造**，因此被优先列出。

## 关于「时序数字」的说明

Yosys 本身不是静态时序分析工具，无法直接给出 ns 级的 WNS/TNS。
本报告因此给出的是**与工艺无关的结构性指标**（LUT/LC 数、进位链长度、
触发器数），它们可复现、可对比，足以判断一次 RTL 改动是否让关键路径变长。

要拿到真实的 ns 级时序：

- Vivado：用 `syn/v9.xdc` + `syn/timing_sweep.tcl`，会输出 WNS/TNS 与
  每个时钟周期下的资源占用；
- Quartus：用 `syn/v9.sdc`，跑 Timing Analyzer；
- 开源流程：`nextpnr` 自带静态时序分析，可给出真实 Fmax。

## 与差分回归的关系

以上所有数字都是在**功能未回退**的前提下取得的：

- 基线（改造前）：47/47 全绿（39 条 RV32I + 8 条 RV32M）；
- 当前提交状态：**47/47 全绿**；
- 时序化 MDU：模块级独立验证 4968 向量全过（尚未接入整机，见
  `syn/上板改造说明.md` §3 P1）。
