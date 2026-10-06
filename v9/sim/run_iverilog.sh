#!/usr/bin/env bash
# =============================================================================
# run_iverilog.sh — 与 run_wave.sh 同风格的一条命令脚本：编译 → 仿真 → 出 VCD
# -----------------------------------------------------------------------------
# 用法：  cd v9/sim && ./run_iverilog.sh [程序名，默认 prog]
#            程序名 = prog | prog_mul | prog_div
#                   | prog_load_lane | prog_load_use | prog_loop | prog_div_pair
#                     （后 4 个是 v9 修复缺陷后补的回归）
#
# 产物：  sim/build/tb_iverilog.vvp
#         sim/build/<prog>.log
#         wave/tb_iverilog_<prog>.vcd
#
# 说明：  本机（Windows，无 WSL 发行版 / 无 bash）请直接用同目录的
#         run_iverilog.bat —— 这个 .sh 只是保持与 run_wave.sh 一致的用法，
#         方便在装了 bash 的机器上跑。
#
# 关键环境约束：
#   iverilog 的 $readmemh/$dumpfile 与 -o 都不接受非 ASCII 绝对路径，
#   因此脚本一律先 cd 到 v9/ 根目录、只用相对路径。
# =============================================================================
set -e
set -o pipefail          # 否则 `| tee` 会把 vvp 的失败退出码吃掉，CI 永远绿
PROG="${1:-prog}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# 额外的 vvp plusarg（用于严格模式回归，例如 +no_wbu_force +raw_rf）
EXTRA_PLUSARGS="${EXTRA_PLUSARGS:-}"
# iverilog/vvp 默认按 PATH 查找（已装 iverilog 的 Linux/macOS/CI 直接可用）；
# 找不到时回退到本机 Windows 的安装路径。也可以用环境变量显式指定：
#     IVERILOG=/opt/iverilog/bin/iverilog VVP=/opt/iverilog/bin/vvp ./run_iverilog.sh
if [ -n "${IVERILOG:-}" ] && [ -n "${VVP:-}" ]; then
    :                                    # 用户显式指定，直接用
elif command -v iverilog >/dev/null 2>&1; then
    IVERILOG="$(command -v iverilog)"
    VVP="$(command -v vvp)"
else
    IVERILOG="D:/eda_tools/iverilog/bin/iverilog.exe"
    VVP="D:/eda_tools/iverilog/bin/vvp.exe"
fi

cd "$DIR/.."                       # -> v9/
mkdir -p wave sim/build

case "$PROG" in
    prog)           PROG_ID=0 ;;
    prog_mul)       PROG_ID=1 ;;
    prog_div)       PROG_ID=2 ;;
    # v9 修复回归（专测本次修掉的缺陷）
    prog_load_lane) PROG_ID=3 ;;
    prog_load_use)  PROG_ID=4 ;;
    prog_loop)      PROG_ID=5 ;;
    prog_div_pair)  PROG_ID=6 ;;
    *)              PROG_ID=9 ;;   # 9 = 无期望值，只报实测
esac

echo "[1/3] 编译 (iverilog -g2012)"
"$IVERILOG" -g2012 -o sim/build/tb_iverilog.vvp \
    myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv \
    RegisterFile.sv CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv \
    LSU.sv DCache.sv WBU.sv \
    Data_hazard.sv Control.sv add.sv sext.sv Reg.sv sim/tb_iverilog.sv

echo "[2/3] 仿真 (vvp +prog=sim/${PROG}.hex +prog_id=${PROG_ID} ${EXTRA_PLUSARGS})"
# shellcheck disable=SC2086  # EXTRA_PLUSARGS 故意不引号，让它按词拆分
"$VVP" sim/build/tb_iverilog.vvp \
    "+prog=sim/${PROG}.hex" "+prog_id=${PROG_ID}" ${EXTRA_PLUSARGS} \
    "+vcd=wave/tb_iverilog_${PROG}.vcd" | tee "sim/build/${PROG}.log"

echo "[3/3] 产物"
echo "     VCD: wave/tb_iverilog_${PROG}.vcd"
echo "     LOG: sim/build/${PROG}.log"
