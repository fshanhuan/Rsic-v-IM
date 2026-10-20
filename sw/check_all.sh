#!/usr/bin/env bash
# =============================================================================
# sw/check_all.sh -- 一次性跑完所有 C 自检程序并汇总结果
# -----------------------------------------------------------------------------
# 覆盖：hello（工具链/内存布局）、memtest（数据通路）、divtest（乘除/移位）、
#       multest（32 位乘法），全部跑在 Verilator 模型上（与板级 RTL 同源）。
# 用法： bash sw/check_all.sh
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "${PROJ_ROOT}"

OUT="${PROJ_ROOT}/sw/build"
declare -A NAMES=( [hello]=hello [memtest]=mt [divtest]=div [multest]=mul )
RC_ALL=0

for key in hello memtest divtest multest; do
    a="${NAMES[$key]}"
    printf '\n===== %s =====\n' "${key}"
    bash "${PROJ_ROOT}/sw/run_coremark.sh" \
        +irom="sw/build/${a}_irom.hex" +dram="sw/build/${a}_dram.hex" +max=8000000 \
        > "${OUT}/chk_${a}.log" 2>&1
    rc=$?
    grep -E '^(HELLO|OK|MEMTEST|DIVTEST|MULTEST|T[1-5]=|D[1-4]=|M[1-3]=|DATA=|BSS=)' \
        "${OUT}/chk_${a}.log" | sed 's/^/   /'
    grep -E 'PASS|FAIL' "${OUT}/chk_${a}.log" | sed 's/^/   /'
    [ "${rc}" -ne 0 ] && RC_ALL=1 && echo "   !! 退出码 ${rc}"
done

echo
if [ "${RC_ALL}" -eq 0 ]; then echo "[CHECK] 全部程序跑完"; else echo "[CHECK] 有程序异常退出"; fi
