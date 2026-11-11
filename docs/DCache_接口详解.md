# DCache 接口详解（25 个端口）

> 对象：`rtl/DCache.sv`（实例 `DCache_inst`）。行号以 v17 工作区为准。
> 存储组织：256 行 × 1 字 = 1 KB，直接映射；`INDEX_BITS=8`、`TAG_BITS=22`
> （`para.sv:260`），`index = addr[9:2]`、`tag = addr[31:10]`
> （`DCache.sv:105-106`）；`UNCACHE_MASK = 0x0FFF_FFFF`，即 `addr & ~0x0FFF_FFFF != 0`
> 一律当 **MMIO / 不可缓存**（`DCache.sv:114-116`）。

整张端口表共 **12 入 + 13 出**。按"谁跟谁说话"分成五组。

---

## 1. 时钟与复位（2）

| 信号 | 方向 | 作用 | 细节 / 坑 |
|---|---|---|---|
| `clk` | 入 1 | 50 MHz `clk_sys` | 所有寄存器上升沿更新；数组读是**组合**的，不占拍 |
| `reset` | 入 1 | 同步复位，高有效 | 只清 `valid` 向量、请求侧寄存器、计数器（`:362-380`）；**不清 `data[]`** —— 复位后数组里是 `x`，靠 `valid=0` 挡住，所以仿真里未驻留行的数据看起来是斜纹 `x` |

## 2. CPU 请求侧（7，来自 LSU 的 M2 拍）

| 信号 | 方向 | 作用 | 细节 / 坑 |
|---|---|---|---|
| `cpu_en` | 入 1 | 本拍 M2 有一条访存 | = `LSU_mem_ren_pipe \| lsu_bus_wen`（`myCPU.sv:883`）。**电平**：`hold` 期间会保持多拍，不能当"来了一次访问"的脉冲用 |
| `cpu_wen` | 入 1 | 1 = store，0 = load | 与 `cpu_en` 一起构成四种组合：无访问 / load / store |
| `cpu_addr[31:0]` | 入 32 | 字节地址 | `index=addr[9:2]`、`tag=addr[31:10]`；`addr≥0x1000_0000` → MMIO，命中恒 0、不填行、直通外设 |
| `cpu_wdata[31:0]` | 入 32 | store 载荷（原始整字） | 按 `cpu_mask` + `addr[1:0]` 合并进缓存行（`:443-455`），同时寄存一份给写脉冲（`:413`） |
| `cpu_mask[1:0]` | 入 2 | 宽度：`00`=byte / `01`=half / `10`=word | 直接取 `funct3[1:0]`；`funct3=011/111`（非法宽度）在这一层看不出来 |
| `cpu_adv` | 入 1 | 本拍这次访存**确实推进** | = `WBU_ready & ~dcache_hold & ~EXU_mdu_busy`（`myCPU.sv:879`）。**只给 `store_fire` 用**（`:238`）：store 是电平，缺它会在流水线冻结期间重复写同一地址（实测连写 4 拍）。不参与读/命中判定 |
| `req_seq` | 入 1 | 请求身份证，每推进一条 M2 指令翻转 | `LSU.sv:234-237`。DCache 与 `cpu_addr_r` 同沿寄存（`:396`），只用于 MMIO "读只发一次"的判重（`:145-152`）——只比地址区分不了"同一条还在"和"同地址的下一条来了" |

## 3. 存储器侧（1 入 + 5 出）

| 信号 | 方向 | 作用 | 细节 / 坑 |
|---|---|---|---|
| `mem_rdata[31:0]` | 入 32 | perip 总线回来的**原始整字**（DRAM / IROM 数据窗口 / MMIO 三选一） | 只有 `mem_data_vld=1`（= `~cache_rd_req & mem_req_r`，`:155`）那一拍才属于本次读；其余时间是上一次读的残留，**不是** 0 |
| `mem_addr[31:0]` | 出 32 | 送总线的地址 | = `cpu_addr_r`（寄存后的地址，`:339`）；读、写共用同一份，避免与写脉冲错拍 |
| `mem_en` | 出 1 | **单拍**读请求 = `cache_rd_req`（`:151,157`） | 一次 miss 只发一拍；`mem_req_r` 记住"已经发过"，返回那一拍用 `~mem_en & mem_req_r` 标出 |
| `mem_wen` | 出 1 | **单拍**写脉冲 = `store_req_r`（`:340`） | 比 store 请求晚一拍（`store_req_r <= store_fire`，`:408`）；一拍一次，绝不重复 |
| `mem_wdata[31:0]` | 出 32 | 写数据 = `store2_wdata` | `store_fire` 那拍采的副本（`:413`）——写脉冲那拍 `cpu_wdata` 已经是下一条指令的了 |
| `mem_mask[1:0]` | 出 2 | 写：真实字节掩码；读：**强制 `2'b10`** 整字 | `:352-353`。理由：契约是"存储器给整字、CPU 自己按 `addr[1:0]` 抽取"，否则 lb/lh 会被抽两次（§DCACHE-6） |

## 4. M1 命中探测口（2 入 + 2 出，v15）

| 信号 | 方向 | 作用 | 细节 / 坑 |
|---|---|---|---|
| `m1_en` | 入 1 | M1 级这条是 load | = `LSU_mem_ren`（`myCPU.sv:891`） |
| `m1_addr[31:0]` | 入 32 | M1 级有效地址 | = `Ex_result_fwd_reg`（`myCPU.sv:890`）。比主通路早一级：主通路在 M2 才发总线 |
| `m1_hit` | 出 1 | 行已驻留 → 本拍就能给数据 | `m1_en & ~MMIO & ~(同拍 store 合并撞同一 index) & valid & tag 匹配`（`:330-331`）。命中后消费者少停 1 拍（`LSU.sv:221` → `myCPU.sv:408`） |
| `m1_rdata[31:0]` | 出 32 | `data[m1_idx]` | **无条件**输出（`:332`）；`m1_hit=0` 时它是"别的行的数据"，不能当 load 结果用 |

## 5. CPU 输出 + 观测（2 功能 + 4 观测）

| 信号 | 方向 | 作用 | 细节 / 坑 |
|---|---|---|---|
| `cpu_rdata[31:0]` | 出 32 | 给 LSU 的 load 结果（原始整字） | `hit_now ? data[index] : mem_rdata`（`:202`）。命中取缓存行、与总线无关；未命中直通 `mem_rdata`；**空拍是总线残留，不能采** |
| `hold` | 出 1 | 本拍数据不可用 → 冻结访存流水 | `(cpu_en & ~cpu_wen) & ~(hit_now \| resp_for_now)`（`:209`）。store **恒 0**（写直达不等数据）。进 LSU 的 `lsu_freeze`（`LSU.sv:188`）、`IFU_stall`（`myCPU.sv:222`）、`lsu_adv`（`:879`）三处 |
| `hit` | 出 1 | 本拍 load 命中 | `= hit_now`（`:198`）。**RTL 里没有任何读者**，综合会删；板上探不到 |
| `miss` | 出 1 | 本拍 miss | `= resp_for_now & ~hit_now`（`:199`）。**无读者**；而且不含 `~uncacheable`，MMIO 读也会拉高（`miss_cnt` 不会，见下） |
| `hit_cnt[31:0]` | 出 32 | 命中次数 | = load 命中 + store 命中（`:426-427`）。上板接 ILA **probe7** |
| `miss_cnt[31:0]` | 出 32 | 缺失次数 | 只数**可缓存 load** 未命中（`:428` 带 `~uncacheable`）。上板接 ILA **probe8** |

---

## 6. 一次访问的通行顺序（每格 1 拍 = 20 ns）

**load 命中**（1 拍）

```
T   cpu_en=1 cpu_wen=0 : hit_now=1 → cpu_rdata=data[index]、hold=0、hit_cnt+1
    总线零动作（mem_en/mem_wen 全 0）
```

**load 未命中**（3 拍，停 2 拍）

```
T    cpu_en=1 cpu_wen=0，行不驻留 → hold=1（LSU 冻结）
T+1  mem_en=1 单拍、mem_addr=addr   → hold=1
T+2  mem_rdata 到位、mem_data_vld=1 → cpu_rdata=mem_rdata、回填 valid/tag/data、hold=0、miss_cnt+1
```

**store**（2 拍，**从不 hold**）

```
T    cpu_en=1 cpu_wen=1 cpu_adv=1 → store_fire：命中则同拍把载荷合并进缓存行（下一拍起 load 就能看到）
T+1  mem_wen=1 单拍、mem_addr/mem_wdata/mem_mask 用寄存副本
```

未命中时 store **不分配**（写直达），所以"store 后紧跟同地址 load"仍会 miss 一次。

---

## 7. 三个容易踩的点

1. **`hit` / `miss` 是死端口**。RTL 里引出后没人读（`myCPU.sv:285-286, 901-902`），综合会删。看命中率请用 `hit_cnt`/`miss_cnt`（板上唯一能看到的两个），且**计数器比事件晚一拍**。
2. **`hit_cnt/(hit_cnt+miss_cnt)` 会偏高**。store 未命中两边都不计（写直达不分配），分母里没有它。
3. **`cpu_rdata` 空拍是垃圾**。`cpu_en=0` 的拍它跟着 `mem_rdata` 走，是总线残留值；LSU 只在 `hold` 撤销那一拍采它。

## 8. 在板上的可见性

- ILA 16 根探针里只涉及 **probe7 = `debug_dcache_hit_cnt`**、**probe8 = `debug_dcache_miss_cnt`**（`project_src/board_top_gui.sv:84-85`）；
- `hold` 的实时状态可以从 `debug_status[1]` 看（`myCPU.sv:366`），但不在探针表里；
- 其余端口（`hit`/`miss`/`m1_*`/`cpu_rdata`/`mem_*`）**板上不可见**，要看得靠仿真波形（`figures/存储器/wavedrom/`）。
