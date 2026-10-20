#!/usr/bin/env bash
# =============================================================================
# sw/diff_coremark.sh -- 用 CoreMark 自带的 CORE_DEBUG 输出做 x86 / rv32 逐行对拍
# -----------------------------------------------------------------------------
# 为什么要这样：CoreMark 的 CRC 是架构无关的，同一份源码 + 同样种子/尺寸，x86 与
# rv32 必须逐行一致。第一个不同的那一行就是"CPU 从哪一步开始算错"。
#
# 两边都带 -DCORE_DEBUG=1（CoreMark 会打印 List find / 矩阵 / 各算法 CRC，并强制
# ITERATIONS=1），过滤掉计时行后 diff。
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "${PROJ_ROOT}"

OUT="${PROJ_ROOT}/sw/build"
mkdir -p "${OUT}"

echo "======== 1) x86 主机版（CORE_DEBUG=1） ========"
make -C "${HOME}/rv32/coremark" clean >/dev/null 2>&1 || true
make -C "${HOME}/rv32/coremark" PORT_DIR=linux XCFLAGS="-DCORE_DEBUG=1 -O2" \
    > "${OUT}/cmdbg_host_build.log" 2>&1 || true
HOST_BIN="$(find "${HOME}/rv32/coremark" -maxdepth 2 -type f -perm -u+x -name 'coremark*' | head -1)"
if [ -z "${HOST_BIN}" ]; then
    echo "!! x86 版没编出来"; tail -5 "${OUT}/cmdbg_host_build.log"; exit 1
fi
"${HOST_BIN}" > "${OUT}/cmdbg_host.log" 2>&1 || true
echo "  -> ${OUT}/cmdbg_host.log"

echo "======== 2) rv32 版（CORE_DEBUG=1） ========"
CORE_DEBUG=1 bash "${PROJ_ROOT}/sw/build_coremark.sh" > "${OUT}/cmdbg_rv_build.log" 2>&1
bash "${PROJ_ROOT}/sw/run_coremark.sh" +max=40000000 > "${OUT}/cmdbg_rv_raw.log" 2>&1 || true

# 只留 CoreMark 的调试行（这些是纯数据），去掉计时/仿真噪声
#   rv32 日志里混着仿真台的 [sim]/[T]/[MEM] 行，一并滤掉
grep -vE '^\[(sim|T|MEM|TRAP|HITBAD|WB|L|S|F|R)\]|^\[sim\]|== |^\[sim' \
    "${OUT}/cmdbg_rv_raw.log" | sed 's/\r$//' > "${OUT}/cmdbg_rv.log" || true

echo "======== 3) 归一化 + diff ========"
# 计时相关行两边必然不同（架构/主频不同），全部剔除；只比数据
norm() {
    grep -vE 'Total ticks|Total time|Iterations/Sec|Compiler (version|flags)|Memory location|CoreMark 1\.0|CoreMark/MHz' "$1" \
    | grep -vE '^$' | sed 's/[[:space:]]\+$//'
}
norm "${OUT}/cmdbg_host.log" > "${OUT}/cmdbg_host.norm"
norm "${OUT}/cmdbg_rv.log"   > "${OUT}/cmdbg_rv.norm"

echo "--- host 行数: $(wc -l < "${OUT}/cmdbg_host.norm")  rv32 行数: $(wc -l < "${OUT}/cmdbg_rv.norm")"
echo "--- 前 12 行差异 ---"
diff "${OUT}/cmdbg_host.norm" "${OUT}/cmdbg_rv.norm" | head -40 || true
