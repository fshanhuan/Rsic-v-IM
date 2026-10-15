# experimental/ — 实验件（不参与 `v9` 默认构建）

## `MDU_pipelined.sv`

RV32M 乘除法的**时序化**实现：

- 乘法：单拍（组合乘法 + 同拍寄存），与 ALU 结果同拍，接入时无需暂停；
- 除法：32 拍迭代状态机（每拍 1 位商），运算期间 `busy=1`。

### 验证状态

**模块级**：4968 条向量全对

- 边界向量 968 条：`{0, 1, 2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFF, 0xFFFF0000,
  0x10000, 0xAAAAAAAA, 0x55555555}` 的两两组合 × 8 条指令；
- 随机向量 4000 条：含定向注入的除零与 `INT_MIN / -1` 溢出。

覆盖全部 8 条指令：`mul / mulh / mulhsu / mulhu / div / divu / rem / remu`，
以及三类边界语义（除零、有符号溢出、符号回正）。

### 整机接入状态

**已接入 `EXU`**（`EXU.sv` 中 `MDU_pipelined MDU_i0 (...)`）。接入时同步改造了
`EXU`（MDU 等结果状态机 `IDLE → WAIT → DONE`）、`LSU`（`mdu_busy` 并入 `lsu_freeze`）
与 `Control` 三处，具体见 [`../syn/上板改造说明.md`](../syn/上板改造说明.md) §3「P1」。

接入后三个程序回归 **103/103 全过**（`sim/run_iverilog.{bat,sh}`）。
原单拍组合的 [`../MDU.sv`](../MDU.sv) 保留在工程里作为对照，**已不参与构建**——
编译时请用 `experimental/MDU_pipelined.sv`。
