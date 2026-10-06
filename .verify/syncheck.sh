#!/usr/bin/env bash
# =============================================================================
# syncheck.sh — 综合脚本（syn/synth_core.ys）一致性检查
#
#   背景（第二轮修复的缺陷之一）：
#     修复前 synth_core.ys 的 read_verilog 清单读的是**保留对照用的组合版**
#     `MDU.sv`，而 EXU 例化的是时序化版 `experimental/MDU_pipelined.sv`
#     → yosys 的 `hierarchy -check` 直接报
#         Unknown module type: MDU_pipelined
#       脚本根本跑不完（synth_report.md 里那组资源数字不可能是从这份源码集来的）。
#     同时清单里**从未出现** `board/*.sv`，上板件从未被任何综合脚本读过。
#
#   本机没有 yosys，因此用 iverilog 做**等价的 elaboration 检查**：
#     iverilog 的模块解析要求与 yosys `hierarchy -check` 同类（未例化的子模块会报
#     Unknown module type），足以验证"清单是否完整、顶层能否解析"。
#
#   用法:
#     bash syncheck.sh            # 活检查：当前 syn/synth_core.ys 应当通过
#     bash syncheck.sh --legacy   # 复现修复前的缺陷清单（应当失败）
# =============================================================================
set -uo pipefail

PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
YS="$SRC/v9/syn/synth_core.ys"
W="$HOME/syncheck"
MODE="${1:-}"

rm -rf "$W"; mkdir -p "$W"
cp -r "$SRC/v9" "$W/v9"
cd "$W/v9" || exit 1

# ---------------------------------------------------------------- legacy 模式
if [ "$MODE" = "--legacy" ]; then
    echo "############################################################"
    echo "# 复现修复前的缺陷清单（读 MDU.sv、不含 board/*.sv）"
    echo "# 期望：失败 —— 这就是修复前的真实状态"
    echo "############################################################"
    iverilog -g2012 -I. -o /dev/null \
        myCPU.sv ALU.sv add.sv Branch_Predictor.sv Control.sv CSR.sv \
        Data_hazard.sv DCache.sv EXU.sv ICache.sv IDU.sv IFU.sv LSU.sv MDU.sv \
        RegisterFile.sv Reg_Stack.sv Reg.sv sext.sv WBU.sv 2>&1 \
        | grep -Ei 'error|missing' | head -6
    rc=${PIPESTATUS[0]}
    echo "rc=$rc   $([ $rc -ne 0 ] && echo '（符合预期：修复前的清单确实跑不通）' || echo '（!! 意外通过）')"
    exit 0
fi

# ---------------------------------------------------------------- 活检查
echo "############################################################"
echo "# 从当前 syn/synth_core.ys 提取 read_verilog 文件清单"
echo "############################################################"
FILES=$(awk '
    /^[[:space:]]*read_verilog/ { coll = 1 }
    coll {
        l = $0
        cont = (l ~ /\\[[:space:]]*$/)
        sub(/\\[[:space:]]*$/, "", l)
        print l
        if (!cont) coll = 0
    }
' "$YS" | grep -oE '[A-Za-z0-9_/]+\.sv' | sort -u)

echo "$FILES" | sed 's/^/    /'
echo "（共 $(echo "$FILES" | grep -c .) 个文件）"

FAIL=0

echo
echo "############################################################"
echo "# 检查 1/3：清单里必须包含时序化 MDU 与板级件"
echo "############################################################"
if echo "$FILES" | grep -q 'experimental/MDU_pipelined\.sv'; then
    echo "  [OK]   含 experimental/MDU_pipelined.sv（EXU 实际例化的版本）"
else
    FAIL=1; echo "  [BAD]  缺 experimental/MDU_pipelined.sv → hierarchy -check 必报 Unknown module type"
fi
if echo "$FILES" | grep -q '^board/'; then
    echo "  [OK]   含 board/*.sv（上板顶层）"
else
    FAIL=1; echo "  [BAD]  缺 board/*.sv → 上板件不在综合范围内"
fi
# 反向检查：保留对照用的组合版 MDU.sv 不该出现在清单里
if echo "$FILES" | grep -qx 'MDU\.sv'; then
    FAIL=1; echo "  [BAD]  清单里出现了 MDU.sv（保留对照的组合版，不是上板路径）"
else
    echo "  [OK]   未包含 MDU.sv（保留对照的组合版，正确地排除在构建之外）"
fi

echo
echo "############################################################"
echo "# 检查 2/3：iverilog elaboration（等价于 yosys hierarchy -check）"
echo "############################################################"
if iverilog -g2012 -I. -o /dev/null $FILES > "$W/elab.log" 2>&1; then
    echo "  [OK]   elaboration 通过（rc=0）"
else
    FAIL=1
    echo "  [BAD]  elaboration 失败："
    grep -Ei 'error|missing' "$W/elab.log" | head -8 | sed 's/^/         /'
fi

echo
echo "############################################################"
echo "# 检查 3/3：EXU 例化的 MDU 与清单一致"
echo "############################################################"
INST=$(grep -oE '^[[:space:]]*MDU[A-Za-z0-9_]*[[:space:]]+MDU_i0' EXU.sv | awk '{print $1}')
echo "  EXU.sv 例化：$INST"
case "$INST" in
    MDU_pipelined) echo "  [OK]   与清单一致（MDU_pipelined）" ;;
    MDU)           FAIL=1; echo "  [BAD]  EXU 例化的是组合版 MDU，与上板预期不符" ;;
    *)             FAIL=1; echo "  [BAD]  未能从 EXU.sv 解析出 MDU 例化" ;;
esac

echo
echo "############################################################"
[ "$FAIL" -eq 0 ] && echo "综合脚本一致性: 全部通过" || echo "综合脚本一致性: 存在问题（见上）"
echo "（复现修复前状态：bash .verify/syncheck.sh --legacy）"
echo "############################################################"
exit $FAIL
