#!/usr/bin/env bash
# =============================================================================
# sw/run_coremark.sh -- Verilator 编译 + 跑 CoreMark（仿真口径）
# -----------------------------------------------------------------------------
# 用法：
#   bash sw/run_coremark.sh                 # 默认 15 亿拍上限
#   bash sw/run_coremark.sh +max=200000000  # 自定义上限（plusargs 直接透传）
#   REBUILD=1 bash sw/run_coremark.sh       # 强制重新 verilate
#
# stdout = 程序串口输出（CoreMark 报告）；stderr = 仿真进度。
#
# ★ 踩坑：Verilator 的 --Mdir 会 `make -C <Mdir>`，所以命令行里给的源文件路径
#   **必须是绝对路径**，否则 make 在 obj 目录里找不到 sim/cm_main.cpp。
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

cd "${PROJ_ROOT}"

OBJ_DIR="${PROJ_ROOT}/sim/build/obj_cm"
EXE="cm_sim"

mkdir -p "${OBJ_DIR}"

# 自动判新旧：RTL/tb/main.cpp 任何一个比可执行文件新就重编。
#   ★ 这条很重要：改完 RTL 忘了 REBUILD=1 会**静默**跑旧模型（v13 查 DCache 缺陷时
#     就踩过：修完还在看旧结果，差点否掉正确修复）。
NEED=0
if [ ! -x "${OBJ_DIR}/${EXE}" ]; then
    NEED=1
elif [ -n "$(find "${PROJ_ROOT}/rtl" "${PROJ_ROOT}/board/sync_mem.sv" \
                "${PROJ_ROOT}/sim/tb_cm.sv" "${PROJ_ROOT}/sim/cm_main.cpp" \
                -newer "${OBJ_DIR}/${EXE}" -print -quit 2>/dev/null)" ]; then
    NEED=1
fi

if [ "${REBUILD:-0}" = "1" ] || [ "${NEED}" = "1" ]; then
    echo "== verilate (首次约 1~2 分钟) =="
    SRCS=()
    for f in "${PROJ_ROOT}"/rtl/*.sv; do
        case "$(basename "$f")" in
            para.sv|ICache.sv) continue ;;   # para.sv 是 include；ICache 已不使用
        esac
        SRCS+=("$f")
    done
    verilator --cc --exe --build -O3 -j 4 \
        -I"${PROJ_ROOT}/rtl" \
        --top-module tb_cm \
        --Mdir "${OBJ_DIR}" \
        -o "${EXE}" \
        -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
        --x-assign fast --x-initial fast \
        -CFLAGS "-O3 -march=native" \
        "${SRCS[@]}" \
        "${PROJ_ROOT}/board/sync_mem.sv" \
        "${PROJ_ROOT}/sim/tb_cm.sv" \
        "${PROJ_ROOT}/sim/cm_main.cpp" \
        2>&1 | tail -n 25
else
    echo "== 复用已编译的 ${OBJ_DIR}/${EXE}（REBUILD=1 可强制重编） =="
fi

echo "== run =="
"${OBJ_DIR}/${EXE}" "$@"
