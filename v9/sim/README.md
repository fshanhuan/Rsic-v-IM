# sim/ — 波形生成（可复现）

`cdp-tests` 的回归波形会把 CPU 内部信号与 `debug_wb_*` 端口别名掉，
在波形窗口里看不到 PC、各阶段 valid、暂停与重定向等关键信号。
本目录提供一个**自包含、带探针**的测试台，专门用来出可读的时序图。

## 一条命令出图

```bash
cd v9/sim
./run_wave.sh              # 默认跑 prog.hex
./run_wave.sh prog_mul     # 跑连续 mul 程序
./run_wave.sh prog_div     # 跑连续 div 程序
```

产物：

| 文件 | 说明 |
| --- | --- |
| `v9/figures/v9_prog_wave.svg` / `.png` | 综合演示：前递、load-use 暂停、分支、跳转、ecall |
| `v9/figures/v9_prog_mul_wave.svg` / `.png` | 连续 8 条 `mul`：单拍 MDU，全程 `stall=0` |
| `v9/figures/v9_prog_div_wave.svg` / `.png` | 连续 4 条 `div`：当前同样是单拍（长组合链换来的） |

> 脚本会把源码复制到 `/tmp` 下的**无空格**构建目录再编译 ——
> GNU Make 无法在含空格路径下构建 Verilator 产物（本仓库根路径含空格）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `tb_wave.sv` | 自包含测试台：指令 ROM + 数据 RAM + myCPU，并把内部信号引到顶层探针 |
| `prog.hex` | 演示程序（lui/addi/add/mul/sw/lw/beq/jal/ori/ecall） |
| `prog_mul.hex` | 连续 `mul` 程序，用于观察乘法零停顿 |
| `prog_div.hex` | 连续 `div` 程序，用于对照「单拍除法」的长组合链代价 |
| `mkwave.py` | 读取 VCD，按时钟下降沿采样并渲染成 SVG（带 RV32I/M 指令译码） |
| `vcd2svg.py` | VCD 解析与 SVG 绘制基础库 |
| `run_wave.sh` | 端到端脚本：编译 → 仿真 → 渲染 |

## 波形怎么读

- **采样点**：每个时钟**下降沿**采样一次，与 `cdp-tests` 测试台读
  `debug_wb_*` 的时刻一致；横轴数字就是「第几拍」。
- **总线**：绿色为十六进制数值；`IF 指令` 一行是紫色，显示**已译码的汇编**。
- **寄存器**：底部 `reg x1..x8` 直接观察寄存器堆的写入过程。

## 依赖

- `verilator`（需支持 `--binary --trace --timing`，5.x 即可）
- `python3`（渲染脚本只用标准库）
- `cairosvg`（可选，用于同时导出 PNG；没有则只出 SVG）
