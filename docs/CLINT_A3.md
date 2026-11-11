# A3 CLINT：把 `mtime/mtimecmp` 变成有唯一计数源的标准定时器

> 一句话：`mtime/mtimecmp` 从**非标准 CSR**（`0x7C0/0x7C1`）迁到**内存映射 CLINT**
> （`0x1000_0030/0x38`），但**只保留一个计数器**——CSR 变成门面。
> 状态：RTL 完成，`sim/tb_clint.sv` 5/5 通过，LED = 0x7F（七项检查全过）。

---

## 1. 改造前

```verilog
// rtl/CSR.sv（改造前）
logic [31:0] mtime_reg, mtime_divcnt;
always_ff ... mtime_reg <= mtime_reg + 1;      // 计数器住在 CSR 里
assign mtip = (mtime_reg >= mtimecmp_reg);
```

`mtime` 在 CSR `0x7C0`、`mtimecmp` 在 `0x7C1` —— 都是**自定义** CSR，
而 RISC-V 标准把它们放在**内存映射的 CLINT**。两者不兼容，意味着：
外部工具/RTOS 按标准写法访问 CLINT 会落空。

---

## 2. 改造后的结构

```
                    ┌──────────────────────────────────────┐
  csrw 0x7C0 ──────►│ CSR（门面）                          │
  csrr 0x7C0 ◄──────│  读=转发 / 写=一根 we 脉冲           │
                    └───────────┬──────────────────────────┘
                                │ mtime_we / mtimecmp_we / wdata
                    ┌───────────▼──────────────────────────┐
   sw 0x1000_0030 ─►│ rtl/clint.sv（唯一计数源）            │
   lw 0x1000_0030 ◄─│   mtime 分频递增 + mtimecmp           │
                    │   写优先级：CSR > 总线 > 自增         │
                    └───────────┬──────────────────────────┘
                                │ mtime / mtimecmp
                                ▼
                          mtip（CSR 里比较）
```

**为什么必须单一计数源**：两套计数器哪怕分频完全一样，也会因为复位相位、
写入时刻不同而漂移。软件一旦混用两条路径（shell 用 CSR 算 uptime、驱动用
MMIO 设超时），时间就对不上，而且极难查。

---

## 3. ★ 为什么把 CLINT 放在**核内**（`myCPU`），而不是板级 `board_top`

这是个刻意的取舍：

| 方案 | 端口数 | 既有 TB 影响 |
|---|---|---|
| 放 `board_top` | myCPU 需要 6 根端口（2 读 + 4 写），且 7 个 TB 都要接 `mtime_in/mtimecmp_in`，否则悬空变 z —— `tb_sys` 的 "mtime is software-writable" 直接 FAIL | **要改 7 个 TB** |
| **放核内（选了）** | 板级只需要 3 写 + 2 读，且**只是 MMIO 路径** | **不用改任何 TB** |

关键点：`mm_*` 悬空时写使能是 `x`，Verilog 的 `if (x)` 取 **false**，
于是自动落到"自增"分支 —— 既有 TB 完全无感。这是"把可悬空的输入放在优先级
最低的分支"这一条设计经验的直接应用。

---

## 4. 寄存器

| 地址 | 名字 | 访问 | 说明 |
|---|---|---|---|
| `0x1000_0030` | `MTIME` | RW | mtime 低 32 位（500 kHz，每 tick 2 µs） |
| `0x1000_0034` | `MTIMEH` | RO | 恒 0（本设计 mtime 只有 32 位，编造高位会让软件算错墙钟） |
| `0x1000_0038` | `MTIMECMP` | RW | 比较值；`mtime >= mtimecmp` 时 MTIP 挂起 |
| `0x1000_003C` | `MTIMECMPH` | RO | 恒 0（写忽略） |

写优先级（同拍只可能有一个来源）：

```
① CSR 写（csrw mtime / mtimecmp）   ← 软件兼容路径
② 总线写（sw 0x1000_0030 / 0x38）   ← SoC 标准路径
③ 自增（仅 mtime，按 `MTIME_DIV_DEFAULT 分频 = 100 → 500 kHz）
```

不变量：`mtimecmp` 复位为**全 1**（上电后不会凭空冒出 MTIP）；写 `mtime` 时
**顺带清零分频计数器**（否则刚写完 0 又立刻 +1，读回比写入值大 1）。

---

## 5. 验证：`sim/tb_clint.sv` + `sw/clinttest.c`

七项检查，结果位图写进 LED：

| bit | 判据 | 证明什么 |
|---|---|---|
| 0 | `csrw mtime,0` 后 `lw 0x30` == 0 | CSR 写 → 总线读 |
| 1 | 隔一段空转再读，值变大 | 真的在计数 |
| 2 | `csrw mtime,0xABCD0000` 后 `lw 0x30` == 同值 | 同一份状态 |
| 3 | `sw 0x30,0` 后轮询 `csrr mtime` 掉到 0 附近 | 反方向同一份状态 |
| 4 | `csrw mtimecmp,0x12345678` 后 `lw 0x38` == 同值 | mtimecmp 同一份状态 |
| 5 | `mie.MTIE` + `mtimecmp` 到期 → 中断来一次 | MTI 通路仍然可用 |
| 6 | `0x34`/`0x3C` 读到 0 | 高半字不编造 |

```
[CLINT-TEST] led=0x7f nrecv=2 mtime=00000084 mtimecmp=ffffffff
[CLINT-TEST]   [PASS] all 7 CLINT checks (CSR <-> MMIO single source)
[CLINT-TEST]   [PASS] csrw mtime -> lw 0x30 same value
[CLINT-TEST]   [PASS] sw 0x30 -> csrr mtime same value
[CLINT-TEST]   [PASS] timer interrupt fired once (MTI)
[CLINT-TEST] PASS  (5/5)
```

### 踩过的坑（值得记下来）

第一版 bit3 写成"`sw 0x30,0x13570000` 之后**立刻** `csrr mtime` 比较"，
结果 FAIL。原因**不是**两套计数器，而是**流水线顺序**：

> store 要到 M 级才发到总线，而紧跟的 CSR 读在 ID 级就取样了 ——
> 那一拍读到的是写之前的值。

改成"写 0，然后轮询 CSR 直到它掉到 0 附近"就稳了（先前 mtime 是 `0xABCD_xxxx`，
只有写真的落到同一个计数器上，它才会掉下来）。这类"软件可见顺序 vs 流水线
阶段"的坑，以后测 MMIO 都要注意。

---

## 6. 改动文件

| 文件 | 改动 |
|---|---|
| `rtl/clint.sv` | **新增**：mtime/mtimecmp 唯一计数源（分频 + 双写口 + 优先级） |
| `rtl/CSR.sv` | 删掉内部计数器；改为门面（`mtime_in/mtimecmp_in` 读、`mtime_we_o/mtimecmp_we_o/clint_wdata_o` 写）；`mtip` 改用输入比较 |
| `rtl/Reg_Stack.sv` | 5 根端口穿透 |
| `rtl/IDU.sv` | 5 根端口穿透 |
| `rtl/myCPU.sv` | 例化 `clint`；新增 3 写 + 2 读的**总线侧**端口 |
| `rtl/soc_map.sv` | 新增 `0x30/0x34/0x38/0x3C` 寄存器号（4 位 idx） |
| `board/board_top.sv` | MMIO 译码出 `mm_mtime_we` / `mm_mtimecmp_we`；读 mux 加四路 |
| `sw/clinttest.c` | **新增**：七项判据 |
| `sim/tb_clint.sv` | **新增**：判据 TB |
| `_diag/regress.ps1`、`sim/run_mem.ps1`、两个 `build_project_*.tcl` | 文件表加 `clint.sv`；新增 `tb_clint` 用例 |

---

## 7. 还没做的

| 项 | 说明 |
|---|---|
| 64 位 mtime | 现在 32 位（500 kHz 下约 2.4 小时回绕）。ATOMIC 的 `MTIMEH` 恒 0，标准写法读高半再读低半会拿到 0 + 低半，软件仍能算对单次差 |
| `msip`（软件中断 IPI） | 单核不需要 |
| 定时器进 PLIC | 刻意**不接**：MTI（`mcause=0x80000007`）才是标准路径，再塞进 PLIC 会重复上报 |
