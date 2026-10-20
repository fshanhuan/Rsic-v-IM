#!/usr/bin/env bash
# =============================================================================
# sw/run_dptest.sh -- 一条命令跑 dptest（IROM 数据窗口自检，Verilator 全 RTL）
# -----------------------------------------------------------------------------
# 为什么单独一个脚本：dptest 是"lw 读得到自己的代码"这条通路的**严格**验收
# （逐字校验和 + 幂等 + lbu×4 拼回 lw），它的编译/运行参数与 CoreMark 那套不同
# （镜像路径、拍数上限），每次手敲容易漏。
#
# 用法：
#   bash sw/run_dptest.sh              # 先两遍编译镜像，再跑仿真
#   REBUILD=1 bash sw/run_dptest.sh    # 强制重新 verilate
#
# 判据：stdout 里出现 DPTEST-PASS 且 D1..D4 全为 0。
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "${PROJ_ROOT}"

OUT="${PROJ_ROOT}/sw/build"
LOG="${PROJ_ROOT}/sim/build/dptest_run.log"
mkdir -p "${PROJ_ROOT}/sim/build"

echo "== build dptest image (two-pass: checksum self-reference) =="
bash "${PROJ_ROOT}/sw/build_dptest.sh" > /dev/null || { echo "FAIL: build_dptest.sh"; exit 1; }

echo "== run (Verilator) =="
bash "${PROJ_ROOT}/sw/run_coremark.sh" +max=2000000 \
    +irom=sw/build/dptest_irom.hex +dram=sw/build/dptest_dram.hex \
    > "${LOG}" 2>&1
rc=$?

grep -E '^D[1-4]=|^CK=|DPTEST-PASS|DPTEST-FAIL|BAD' "${LOG}" || true

if grep -q 'DPTEST-PASS' "${LOG}" && [ "${rc}" = "0" ]; then
    echo "[DPTEST] PASS  (log: sim/build/dptest_run.log)"
    exit 0
else
    echo "[DPTEST] FAIL  (see ${LOG})"
    exit 1
fi
