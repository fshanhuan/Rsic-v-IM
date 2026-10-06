#!/usr/bin/env bash
# =============================================================================
# run_all.sh — v9 全量回归：三个整机程序 + D-Cache 单元测试 + 严格模式
# -----------------------------------------------------------------------------
# 用法：  cd v9 && bash sim/run_all.sh
#
# 覆盖（共 6 项）：
#   1) prog      35/35   综合演示（前递 / load-use / 分支 / jal / ecall）
#   2) prog_mul  34/34   连续 8 条 mul
#   3) prog_div  34/34   连续 4 条 div（MDU 多拍冻结流水）
#   4) prog      严格模式（+no_wbu_force +raw_rf，不用测试台任何兜底）
#   5) prog_mul  严格模式
#   6) prog_div  严格模式
#   7) DCache 模块级单元测试（同步回填 / 二次命中 / MMIO 不缓存 / 外设副作用）
#
# 退出码：全过 0；任一失败非 0（可直接被 CI 使用）。
#
# 环境：需要 iverilog + vvp 在 PATH 上（Ubuntu: apt-get install -y iverilog）。
#       本机 Windows 无 bash 时请用 sim/run_iverilog.bat。
# =============================================================================
set -e
set -o pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
V9="$(cd "$DIR/.." && pwd)"

# iverilog 找不到时的 Windows 回退路径（可用环境变量覆盖）
if [ -z "${IVERILOG:-}" ]; then
    if command -v iverilog >/dev/null 2>&1; then
        IVERILOG="$(command -v iverilog)"
    else
        IVERILOG="D:/eda_tools/iverilog/bin/iverilog.exe"
    fi
fi
if [ -z "${VVP:-}" ]; then
    if command -v vvp >/dev/null 2>&1; then
        VVP="$(command -v vvp)"
    else
        VVP="D:/eda_tools/iverilog/bin/vvp.exe"
    fi
fi
export IVERILOG VVP

PASS=0
FAIL=0

run() {                                    # run <标签> <prog> [extra plusargs]
    local label="$1" prog="$2" extra="${3:-}"
    printf '\n=== [%s] %s ===\n' "$label" "$prog"
    if EXTRA_PLUSARGS="$extra" bash "$DIR/run_iverilog.sh" "$prog"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "!!! FAILED: $label"
    fi
}

run "整机回归"   prog
run "整机回归"   prog_mul
run "整机回归"   prog_div
run "严格模式"   prog     "+no_wbu_force +raw_rf"
run "严格模式"   prog_mul "+no_wbu_force +raw_rf"
run "严格模式"   prog_div "+no_wbu_force +raw_rf"

# ---- v9 修复回归：这几条专测上板改造暴露出的缺陷，原来的 3 个程序完全没覆盖 ----
#   3 prog_load_lane ：lb/lh/lbu/lhu 的地址偏移选道（原来永远读偏移 0）
#   4 prog_load_use  ：load-use 冒险 + 非访存指令后的 load 取数（原来取到陈旧值/0）
#   5 prog_loop      ：后向分支循环（原来误预测被取指 hold 吞掉，循环跑 2 圈就掉出）
#   6 prog_div_pair  ：背靠背 div/rem（原来多拍结果与 rd 错位一条指令）
run "回归(偏移)"  prog_load_lane
run "回归(取数)"  prog_load_use
run "回归(分支)"  prog_loop
run "回归(除法)"  prog_div_pair
run "严格模式"   prog_load_lane "+no_wbu_force +raw_rf"
run "严格模式"   prog_load_use  "+no_wbu_force +raw_rf"
run "严格模式"   prog_loop      "+no_wbu_force +raw_rf"
run "严格模式"   prog_div_pair  "+no_wbu_force +raw_rf"

printf '\n=== [D-Cache 单元测试] tb_dcache_unit ===\n'
mkdir -p "$V9/sim/build"
if (cd "$V9" && "$IVERILOG" -g2012 -o sim/build/tb_dcache_unit.vvp \
        DCache.sv sim/tb_dcache_unit.sv && \
    "$VVP" sim/build/tb_dcache_unit.vvp | tee sim/build/dcache_unit.log); then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "!!! FAILED: D-Cache 单元测试"
fi

printf '\n=====================================================================\n'
printf 'run_all.sh: %d 项通过, %d 项失败\n' "$PASS" "$FAIL"
printf '=====================================================================\n'
[ "$FAIL" -eq 0 ]
