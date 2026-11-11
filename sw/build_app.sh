#!/usr/bin/env bash
# =============================================================================
# sw/build_app.sh -- 编一个"从 shell 加载并运行"的 C 应用（P1-1）
# -----------------------------------------------------------------------------
# 用法： bash sw/build_app.sh sw/app/hello_app.c hello_app
# 产物（sw/build/）：
#   <name>.elf / <name>.bin
#   <name>_irom.hex   代码段（从 0x6000 起）
#   <name>_dram.hex   .rodata/.data（从 0xA000 起）
#   <name>.app        ★ 容器：头(32B) + 代码 + 数据，`run <name>` 一把装完
#   <name>_app.hex    ★ 容器的 'L' 可吃版本（宿主脚本用）
#
# 和 build_simple.sh 的区别：
#   1. 用 sw/app/link_app.ld：.text 0x6000、数据 0xA000、应用有自己的 4 KB 栈；
#   2. 带入口桩 sw/app/start.S（保存/恢复 shell 的 gp/ra/sp、设自己的 gp/sp、清 .bss）；
#   3. elf2hex 的 --split = 0x4000（0xA000 - 0x6000），最后再打容器。
#
# 上板流程（一条命令）：
#   _diag/put_app.ps1 -Name hello_app      # 灌容器 + sa 存进文件系统
#   然后在 shell 里：  run hello_app
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

SRC="${1:?用法: build_app.sh <源文件.c> <名字>}"
NAME="${2:?用法: build_app.sh <源文件.c> <名字>}"
SW_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${PROJ_ROOT}/sw/build"
LD="${SW_DIR}/app/link_app.ld"
START="${SW_DIR}/app/start.S"
mkdir -p "${OUT}"

APP_BASE=0xA000                       # 数据区基址
APP_TEXT=0x6000                       # 代码基址（shell text 已到 0x4CF4，留 4KB 余量）
SPLIT=$((APP_BASE - APP_TEXT))        # 0x4000

CFLAGS=(
    $ARCH -O2
    -ffreestanding -fno-builtin -fno-common -fno-stack-protector
    -mno-relax -msmall-data-limit=0
    -Wall -Wno-unused-parameter
)

echo "== compile app ${SRC} -> ${NAME} =="
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${SRC}"    -o "${OUT}/${NAME}.o"
riscv64-unknown-elf-gcc $ARCH          -c "${START}"  -o "${OUT}/${NAME}_start.o"
riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${LD}" \
    "${OUT}/${NAME}_start.o" "${OUT}/${NAME}.o" -o "${OUT}/${NAME}.elf" -lgcc

# 入口必须是桩（_start），否则说明 .text.start 没排在最前
ENTRY=$(riscv64-unknown-elf-nm "${OUT}/${NAME}.elf" | awk '$3=="_start"{print $1}')
if [ -z "${ENTRY}" ]; then
    echo "!! 找不到 _start 符号"; exit 1
fi
if [ "${ENTRY}" != "00006000" ]; then
    echo "!! _start 不在 0x6000（实际 0x${ENTRY}）：.text.start 没有被排到最前"; exit 1
fi

riscv64-unknown-elf-size -A "${OUT}/${NAME}.elf" | grep -E '^\.text|^\.rodata|^\.data|^\.bss' || true
riscv64-unknown-elf-objcopy -O binary "${OUT}/${NAME}.elf" "${OUT}/${NAME}.bin"
python3 "${SW_DIR}/elf2hex.py" "${OUT}/${NAME}.bin" \
    --split $((SPLIT)) \
    --irom "${OUT}/${NAME}_irom.hex" --dram "${OUT}/${NAME}_dram.hex" \
    --trim \
    --irom-words 12288 --dram-words 5120

python3 "${SW_DIR}/mkapp.py" \
    --irom "${OUT}/${NAME}_irom.hex" --dram "${OUT}/${NAME}_dram.hex" \
    --irom-base ${APP_TEXT} --dram-base ${APP_BASE} --entry ${APP_TEXT} \
    --out "${OUT}/${NAME}.app" --hex "${OUT}/${NAME}_app.hex"

echo "== done =="
ls -l "${OUT}/${NAME}.app" "${OUT}/${NAME}_app.hex"
echo "APP_ENTRY=${APP_TEXT}"
echo "APP_DATA=${APP_BASE}"
