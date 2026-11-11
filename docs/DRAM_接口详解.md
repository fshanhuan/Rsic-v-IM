# DRAM 接口详解（9 个端口）

> 对象：`board/sync_mem.sv` 的实例 **`dram_inst`**（`board/board_top.sv:568-586`），
> 参数 `WORDS=32768`、`READ_ONLY=0`、`INIT_FILE=""`。
> `sync_mem` 是**可综合的同步 BRAM 模型**，IROM 与 DRAM 共用同一个模块，靠 `READ_ONLY` 分叉。
> 容量：32768 字 × 4 B = **128 KB**，占数据地址 `0x0000_0000 ~ 0x0001_FFFF`。
> 字地址口径 `addr[16:2]`（`ADDR_BITS = $clog2(32768) = 15`，`sync_mem.sv:43,57-58`），
> 低 2 位是字内字节偏移。
>
> **配套波形**：[`DRAM_全部端口.png`](../figures/存储器/wavedrom/DRAM_全部端口.png)
> （图 W3，第 22–34 拍）：23/25/28 拍是 `sw/sb/sh` 三种宽度写同一个字，30 拍读回
> `0x5555_AA78` 证明三次写合到了同一行 —— 本文 §2 的合并规则就是图上那三格。

## 1. 端口表（9 根）

| 信号 | 位宽/方向 | 作用 | 细节 / 坑 |
|---|---|---|---|
| `clk` | 1 入 | `sys_clk`，50 MHz | 读写都在上升沿 |
| `reset` | 1 入 | 同步复位，高有效 | **board_top 里直接接 `1'b0`**（`:574`）：真实 BRAM 的阵列不会被复位清空，DRAM 上电后由程序自己初始化；接 1'b0 时连 `rdata` 也不清，但 data 侧只在 `mem_data_vld` 那拍采，不受影响 |
| `addr[31:0]` | 32 入 | 字节地址，只用 `[16:2]` | 引导期（`boot_busy=1`）由 loader 用 `boot_addr<<2` 独占（`:575`） |
| `ren` | 1 入 | 单拍读使能 | = `boot_busy ? 0 : perip_en`（`:576`），`perip_en = perip_ren`（`:222`）= DCache 的 `mem_en`。**注意没跟 `~mmio_sel & ~irom_win_sel` 相与**（只有写被门掉）→ 每次读 MMIO / IROM 窗口都顺带读一次 DRAM（白烧一次 BRAM 读功耗，功能无影响，因为 `perip_rdata` 的 mux 优先级在它之前） |
| `rdata[31:0]` | 32 出 | 读数据 | **T 拍给 `addr`+`ren`，T+1 拍才有效**；`ren=0` 时保持上一次的值（BRAM 语义） |
| `wen` | 1 入 | 单拍写脉冲 | = `boot_busy ? (boot_we & boot_mem_sel) : (perip_wen & ~mmio_sel & ~irom_win_sel)`（`:582-583`）。**两个 `~` 必须留着**：否则 `sw 0x1000_0000` 会同时写坏 DRAM[0]（栈/全局区），`sw 0x2_0040` 会同时写坏 DRAM[0x40] |
| `wdata[31:0]` | 32 入 | 写数据（原始整字） | 按 `mask` + `addr[1:0]` 合并（见下） |
| `mask[1:0]` | 2 入 | 写宽度：`00`=byte / `01`=half / `1x`=word | **只有写用**，读口完全不看 mask。DCache 读时给的是 `2'b10` 也是这个原因（契约是"存储器给整字、CPU 自己抽"） |

## 2. 写通道的字节合并（`sync_mem.sv:68-75, 110-126`）

```
mask=2'b00 (sb)：wdata_merge = {24'b0, wdata[7:0]}，落点由 byte_offset=addr[1:0] 选
mask=2'b01 (sh)：wdata_merge = {16'b0, wdata[15:0]}，落点由 addr[1] 选高低半字
mask=2'b1x (sw)：wdata_merge = wdata，整字覆盖（不看 addr[1:0]）
```

非对齐的字访问在 EXU 就被判异常了（`iaddr_misalign`/`daddr_misalign`），到不了这里。

## 3. 时序契约（3 条，全设计都靠它）

```
读：  T    addr + ren=1
      T+1  rdata = mem[addr(T)]        ← DCache 用 mem_data_vld 标这一拍
写：  T    addr + wen=1 + wdata + mask  ← 单拍脉冲，没有 ready/握手
      T    同一沿完成写入
同拍读写同一地址：读口返回**旧值**（DCache 的回填逻辑依赖这一点）
```

`wen` 若多给一拍就是**多写一次**，所以 DCache 把它做成 `store_req_r` 单拍脉冲（`DCache.sv:340,408`）。

## 4. 地址空间关系

| 区间 | 归谁 | 说明 |
|---|---|---|
| `0x0000_0000 – 0x0001_FFFF` | **DRAM**（128 KB） | 但软件约定只把 `.data/.bss/栈` 放 `0x1_0000` 以上；`0x0~0xFFFF` 与取指侧 IROM 同地址，容易看混，故意不用（`board_top.sv:22`） |
| `0x0002_0000 – 0x0002_FFFF` | IROM 数据窗口（端口 B） | 写它**只改 IROM**，DRAM 的 `wen` 被 `~irom_win_sel` 挡掉 |
| `0x1000_0000 – 0x1000_7FFF` | MMIO | DRAM 的 `wen` 被 `~mmio_sel` 挡掉；读仍会顺带读一次 DRAM（见上） |

三者由 `board_top.sv:546-559` 的 mux 拼成 `perip_rdata`，优先级 **MMIO → IROM 窗口 → DRAM**。

## 5. 四个坑

1. **`reset` 接 0**：阵列内容上电未定义。仿真是 `tb` 先把前 4096 字（`INIT_WORDS`）清零再 `$readmemh`；板上靠程序自己初始化。
2. **`ren` 没门译码**：外设/窗口访问会白读一次 DRAM（功耗，不是功能问题）。要省功耗可以加 `& ~mmio_sel & ~irom_win_sel`，但会多一级组合延迟进 BRAM 的 ENARDEN —— 历史上这正是关键路径之一（`IFU.sv:141-144` 有同类记录），所以别随手加。
3. **写必须被两个 `~` 门掉**：漏一个就是"打印一个字符，某个变量莫名变了"那类 bug（`board_top.sv:415-417` 有完整记录）。
4. **`INIT_WORDS` 上限 4096**：`sync_mem` 的清零循环被限制在 4096 字以内（`sync_mem.sv:50`），因为 Quartus 对 `initial` 循环次数有硬上限 5000。别以为"整个 128 KB 都被清零了"。
