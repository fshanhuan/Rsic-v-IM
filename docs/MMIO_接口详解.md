# MMIO 接口详解（总线侧 6 + 译码 2 + 寄存器 7 + 外设侧 5）

> ★ MMIO **不是独立模块** —— 它是 `board/board_top.sv:409-559` 里的一段地址译码 + 寄存器组，
> 直接挂在 CPU 的 `perip_*` 总线上。所以"接口"要分三层看：总线侧（跟 DCache 说话）、
> 译码（选谁）、外设侧（跟引脚说话）。
> 基址 `0x1000_0000`，选它的原因：DCache 的 `UNCACHE_MASK = 0x0FFF_FFFF`，
> 地址 ≥ `0x1000_0000` 的访问**自动**走不可缓存通路（不填缓存行、读直通外设）。
>
> **配套波形**：[`MMIO_全部端口.png`](../figures/存储器/wavedrom/MMIO_全部端口.png)
> （图 W4，第 33–47 拍）：34 拍读 TXSTAT 得 0 → 38 拍写 TXDATA → 39 拍 `busy=1` 且 `uart_tx`
> 出起始位、同拍再读 TXSTAT 得 1 → 45 拍写 LED=0x2A。

## 1. 总线侧（6 根，来自 myCPU 顶层端口）

| 信号 | 位宽/方向 | 作用 | 细节 / 坑 |
|---|---|---|---|
| `perip_addr[31:0]` | 32 入 | 字节地址 | = DCache 的 `mem_addr`（= `cpu_addr_r`）。译码只看 `[31:16]`、`[15]`、`[4:2]` |
| `perip_ren` | 1 入 | 读使能（单拍） | = DCache 的 `mem_en`（`myCPU.sv:909`）。`perip_en = perip_ren`（`board_top.sv:222`） |
| `perip_wen` | 1 入 | 写使能（单拍） | = DCache 的 `mem_wen`（`store_req_r`） |
| `perip_mask[1:0]` | 2 入 | 写宽度 | **MMIO 完全忽略它**（只有 DRAM 用）。`sb` 写 TXDATA 也会整字节生效 |
| `perip_wdata[31:0]` | 32 入 | 写数据 | TXDATA 取 `[7:0]`、LED 取 `[6:0]`、BOOTREQ 取 `[0]` |
| `perip_rdata[31:0]` | 32 出 | 读数据 | **组合 mux**（`:546-559`），优先级 **MMIO → IROM 数据窗口 → DRAM**；MMIO 未命中的寄存器号/未列出的 idx 返回 `0` |

## 2. 译码（2 根）

| 信号 | 位宽 | 表达式 | 说明 |
|---|---|---|---|
| `mmio_sel` | 1 | `(perip_addr[31:16] == 16'h1000) & (perip_addr[15] == 1'b0)`（`:441`） | 窗口实际是 `0x1000_0000 – 0x1000_7FFF` |
| `mmio_idx[2:0]` | 3 | `perip_addr[4:2]`（`:442`） | 寄存器号；**只译码这 3 位** → 见坑 5 的别名问题 |

## 3. 寄存器映射（`mmio_idx` = 字地址，7 个）

| 地址 | idx | 读/写 | 名字 | 读回什么 / 写做什么 | 实现 |
|---|---|---|---|---|---|
| `+0x00` | 0 | WO | **TXDATA** | 写：`perip_wdata[7:0]` → `uart_tx.send` 单拍脉冲；读回 `0` | `:446-456` |
| `+0x04` | 1 | RO | **TXSTAT** | 读：`{31'b0, uart_busy}`，bit0=1 表示上一帧还没发完 | `:549` |
| `+0x08` | 2 | RO | **RXDATA** | 读：`{24'b0, rx_fifo[rx_rp]}` —— **只看队头，不弹**（幂等） | `:550` |
| `+0x0c` | 3 | RO | **RXSTAT** | 读：`{30'b0, rx_ovf, rx_avail}`；bit0=FIFO 非空，bit1=溢出过。**读一次清溢出位** | `:529, :551` |
| `+0x10` | 4 | RW | **LED** | 写：`led_reg <= perip_wdata[6:0]` → 引脚 `led[6:0]`；读回 `0`；复位值 0 | `:533-539` |
| `+0x14` | 5 | WO | **BOOTREQ** | 写 bit0=1 → 重新武装 `boot_loader`（软件"按一下复位键"），**仅 `IROM_BOOT=1` 时存在** | `:266-278` |
| `+0x18` | 6 | WO | **RXPOP** | 写 1（且 FIFO 非空）→ 弹一个字节；配合 RXDATA 的 peek 用 | `:497-498` |

标准用法：

```c
while (!(RXSTAT & 1));      // 等字节
c = RXDATA;                 // 看（不弹）
RXPOP = 1;                  // 弹
```

## 4. 外设侧（5 根）

| 信号 | 位宽/方向 | 谁产生 / 谁消费 | 说明 |
|---|---|---|---|
| `uart_tx` | 1 出 | `uart_tx_inst`（`CLK_FREQ=50e6`, `BAUD=115200`） | 空闲为 1；一帧 10 bit ≈ **87 µs**，`busy` 期间来的新字节**直接丢弃**（没有发送 FIFO） |
| `uart_rx` | 1 入 | 两个 `uart_rx` 实例同时监听：`uart_rx_inst`（boot_loader）与 `uart_rx_con_inst`（console） | 为什么两个：`valid` 是单拍脉冲、两者没有握手，共用会互相偷字节（`:431-434`） |
| `led[6:0]` | 7 出 | `led_reg` 直接出引脚（LED1~LED7） | 板上真实引脚，不需要并进 `debug_dead` |
| `uart_busy` | 1 内部 | `uart_tx_inst.busy` → TXSTAT.bit0 | |
| `rx_avail` / `rx_ovf` | 1+1 内部 | 8 深 FIFO（`rx_cnt != 0` / 满时置位） | 满时**丢弃新字节并置 ovf**，不覆盖已有数据（`:525-527`） |

## 5. 五个坑

1. **RXDATA 必须幂等**。v13.5 之前是"读即弹"，实测一次 `lw 0x1000_0008` 会让 `perip_ren` 出现**两个**脉冲（DCache 的 uncacheable 读被重发），于是每读一个字节吃掉两个（命令 `l 3f` 变成 `l3`）。现在拆成 peek + RXPOP，`RXDATA` **永远不许**再带副作用（`:481-496`）。
2. **MMIO 读必须"读到 T+1 拍还成立"**。DCache 在 `mem_en` 的**下一拍**才采 `perip_rdata`（同步 BRAM 的契约），而 MMIO 是组合 mux —— 寄存器值必须稳定两拍。**RXSTAT.bit1 的"读清"就踩在这条线上**：清零发生在读请求那一拍的时钟沿（`:529`），而采样在下一拍，按代码推演**溢出位会读回 0**（*未实测*，要证实得用 `sim/tb_console.sv` 灌满 FIFO 再读一次）。
3. **TXDATA 忙时丢弃**：没有发送 FIFO，也没有背压，软件必须自己轮询 TXSTAT。高速打印时丢字符是预期行为。
4. **`perip_mask` 被忽略**：注释说"顺带挡掉字节/半字写"（`:444-445`），但代码是 `perip_wen & mmio_sel & (mmio_idx == 3'd0)`（`:453`）**没有 mask 项** —— `sb` 写 TXDATA 照样发一帧。注释与代码不一致，用整字写就没歧义。
5. **地址别名**：`mmio_idx` 只看 `[4:2]`，所以 `0x1000_0020`、`0x1000_0100` 都等于 `0x1000_0000`（TXDATA）。软件只用 `0x1000_0000 / 04 / 08 / 0c / 10 / 14 / 18` 这 7 个地址即可，别依赖"其他地址会访问不到"。

## 6. 和 DCache 的关系

- 地址 ≥ `0x1000_0000` ⇒ DCache 判为 **uncacheable**：命中恒 0、不回填、读直通外设（`DCache.sv:114-116, 120-121`）；
- 代价是每次 MMIO 访问都要走一遍 `hold`（2 拍），且 `miss` 端口会跟着拉高（该端口无读者，见 `DCache_接口详解.md` §5）；
- store 到 MMIO 是写直达，`hold` 恒 0（store 永不等数据）。
