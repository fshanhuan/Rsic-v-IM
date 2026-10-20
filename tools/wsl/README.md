# tools/wsl —— 在 WSL 里跑官方 `cdp-tests` 差分的脚本

**为什么必须进 WSL**：官方差分套件（上游 `BigBird-CPU-Lab/cdp-tests`）需要 **Verilator + make**，
Windows 侧没有；WSL Ubuntu 里 `make` / `g++` / `python3` / `git` 都是现成的。

**为什么解包 `.deb` 而不是 `apt install`**：本机 WSL 用户 `shane` **没有免密 sudo**。
而 Verilator 运行时只需要 `perl` / `libc` / `libstdc++`（都已经在），所以
`apt-get download` + `dpkg-deb -x` 到 `~/opt` 就能正常用，**完全不需要 root**。

---

## 一次性准备（约 3 分钟）

```bash
W=/mnt/e/FPGA/v9_vivado_ila/tools/wsl
wsl -d Ubuntu -e bash $W/get_verilator.sh   # 无 sudo 取 Verilator 5.020 → ~/opt/verilator
wsl -d Ubuntu -e bash $W/setup_env.sh       # 写 ~/opt/env.sh + 编译最小设计做端到端冒烟
wsl -d Ubuntu -e bash $W/fix_vroot.sh       # 补 verilator_bin 软链（.deb 布局适配）
wsl -d Ubuntu -e bash $W/get_suite.sh       # 浅克隆上游 BigBird-CPU-Lab
```

> `.deb` 把二进制放在 `usr/bin`，而 `verilator` 这个 perl 外壳在设了 `VERILATOR_ROOT` 时会去
> `$VERILATOR_ROOT/verilator_bin` 找 —— `fix_vroot.sh` 就是补这个软链。少了它会报
> `exec: .../verilator_bin: not found`（本次真实踩到）。

---

## 跑验证

```bash
wsl -d Ubuntu -e bash /mnt/e/FPGA/v9_vivado_ila/tools/wsl/run_canonical.sh <标签>
```

它会把**正本**（`E:\share doc\v9`）的顶层 RTL 拷到 `~/work/v9_canon`，建工程，跑全部
39 条用例，打印通过/失败汇总；失败用例的完整日志落在 `~/suite_logs/<标签>/`。

---

## 脚本清单

| 脚本 | 作用 |
| --- | --- |
| `get_verilator.sh` | 无 sudo 获取 Verilator 5.020（`.deb` → `~/opt/verilator`） |
| `setup_env.sh` | 生成 `~/opt/env.sh`；编译并运行一个最小设计做端到端冒烟测试 |
| `fix_vroot.sh` | 把 `verilator_bin*` 软链到 `VERILATOR_ROOT`（.deb 布局适配） |
| `get_suite.sh` | 浅克隆上游 `BigBird-CPU-Lab`，列出 `cdp-tests` 结构 |
| `run_canonical.sh` | ★ **主入口**：正本 RTL → `~/work/v9_canon` → 建工程 → 跑 39 条 → 汇总 |
| `find_rv32m.sh` | 取证脚本：证明上游套件是**纯 RV32I**（"47 条"里的 8 条 RV32M 不在上游） |
| `check_inventory.sh` | 数 `bin/*.bin`（39 个），查有没有 `intr` 用例（没有） |
| `diag_addi.sh` | 单条 `addi` 的失败细节 —— H1 desync 的首个直接证据 |
| `probe.sh` / `probe_net.sh` | 环境勘察：工具链、网络、sudo、apt 是否可用 |

---

## 两个必须知道的坑

1. **路径不能含空格**：`E:\share doc\v9` 带空格，Verilator 的 `obj_dir` 在含空格路径下建不起来
   （`--Mdir` 也不行）。所以脚本一律先把 RTL 拷到 `~/work/` 再编译。
2. **`obj_dir` 会被复用**：`run_canonical.sh` 开头先 `make clean`，否则会拿旧的 `obj_dir`
   去跑新 RTL，得到假结果。

---

## 本套脚本验证过的结论（2026-10）

| 配置 | 官方差分 |
| --- | --- |
| 修复前 | **0 / 39**（H3 让工程编译不过；绕过 H3 后 H1 让第一条 `addi` 就 desync） |
| 只修 H3 + H1 | **32 / 39**（失败集恰好 `lb lbu lh lhu lw sb sh`） |
| H3 + H1 + H2 | **39 / 39 PASS** |

详见 [`../../README.md`](../../README.md) §4.2 与
[`../../docs/历史/待修复清单_cdp-tests第三轮.md`](../../docs/历史/待修复清单_cdp-tests第三轮.md)。
