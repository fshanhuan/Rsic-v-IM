#!/usr/bin/env bash
# =============================================================================
# netcheck.sh — 严格网络检查（隐式网络 / implicit net）
#
#   做法：把交付目录里的每个 .sv 复制一份，在最顶上插入 `default_nettype none，
#         然后用 iverilog 编译。任何"没有显式声明就被使用"的标识符都会变成硬错误。
#
#   为什么需要这道检查：
#     Verilog 对未声明的标识符会**自动创建一个 1 位隐式 wire**。这有两种后果：
#       (1) "先用后声明" —— 随后同一作用域里的显式声明变成"重复声明"。商用工具
#           （ModelSim vlog-2730）直接硬报错；iverilog 静默放过。第三轮就靠这条
#           抓出 5 处，其中 EXU.sv 的 mdu_res 是 **32 位**乘除法结果，却被先当成
#           1 位网使用（见 验证报告_独立复核.md §10）。
#       (2) "从未声明" —— 被 assign 驱动是合法 Verilog，所以连 ModelSim 都不会报
#           （Control.sv 的 bp_mispredict_raw 就是这种，实测被 ModelSim 放过）。
#     `default_nettype none 把这两类**全都**变成硬错误，且 iverilog 也支持，
#     因此可以进 CI，而不必依赖商用工具。
#
#   用法: bash .verify/netcheck.sh
#   退出码: 0 = 全部干净；非 0 = 有隐式网络（详见输出）
# =============================================================================
set -uo pipefail

PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
WORK="$HOME/netcheck"
LOG="$WORK/logs"

CORE="rtl/myCPU.sv rtl/IFU.sv rtl/ICache.sv rtl/Branch_Predictor.sv rtl/IDU.sv
      rtl/Reg_Stack.sv rtl/RegisterFile.sv rtl/CSR.sv rtl/EXU.sv rtl/ALU.sv
      experimental/MDU_pipelined.sv rtl/LSU.sv rtl/DCache.sv rtl/WBU.sv
      rtl/Data_hazard.sv rtl/Control.sv rtl/add.sv rtl/sext.sv rtl/Reg.sv"

rm -rf "$WORK"; mkdir -p "$WORK/rtl" "$WORK/board" "$WORK/sim" "$WORK/experimental" "$LOG"
cp "$SRC/v9/"*.sv                        "$WORK/rtl/"          2>/dev/null
cp "$SRC/v9/experimental/"*.sv           "$WORK/experimental/" 2>/dev/null
cp "$SRC/v9/board/"*.sv                  "$WORK/board/"        2>/dev/null
cp "$SRC/v9/sim/"*.sv                    "$WORK/sim/"          2>/dev/null
cp "$SRC/.verify/difftest/tb_difftest.sv" "$WORK/sim/"         2>/dev/null

# 给每个 .sv 顶上插入指令（注意：ModelSim 默认逐文件编译，所以必须每个文件都加）
cd "$WORK" || exit 1
for f in $(find . -name '*.sv'); do
    { printf '`default_nettype none\n'; cat "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
done

FAIL=0
check() {   # check <名字> <文件列表...>
    local name="$1"; shift
    # -I rtl：所有模块都 `include "para.sv"（宏定义），必须给出包含路径
    if iverilog -g2012 -I rtl -o /dev/null "$@" > "$LOG/$name.log" 2>&1 \
       && ! grep -qiE 'error|not found' "$LOG/$name.log"; then
        printf '  [OK]   %s\n' "$name"
    else
        FAIL=1
        printf '  [BAD]  %s  （%d 条错误/缺失）\n' "$name" "$(grep -ciE 'error|not found' "$LOG/$name.log")"
        grep -iE 'error|not found' "$LOG/$name.log" | head -12 | sed 's/^/         /'
    fi
}

echo "############################################################"
echo "# 严格网络检查：每个 .sv 顶部加 \`default_nettype none"
echo "############################################################"
check "核心 RTL + 官方回归测试台" $CORE sim/tb_iverilog.sv
check "核心 RTL + 差分测试台"     $CORE sim/tb_difftest.sv
check "板级顶层 + 板级自检台" \
      board/reset_sync.sv board/sync_mem.sv board/board_top.sv \
      $CORE board/tb_board_top.sv
check "D-Cache 单元测试台" rtl/DCache.sv rtl/LSU.sv rtl/sext.sv rtl/Reg.sv sim/tb_dcache_unit.sv

echo "############################################################"
if [ "$FAIL" -eq 0 ]; then
    echo "隐式网络检查: 全部通过（无未声明的标识符）"
else
    echo "隐式网络检查: 存在隐式网络 —— 见上面 [BAD] 明细与 $LOG/"
fi
echo "日志目录: $LOG"
echo "############################################################"
exit $FAIL
