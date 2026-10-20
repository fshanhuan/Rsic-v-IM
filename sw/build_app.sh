#!/usr/bin/env bash
# =============================================================================
# sw/build_app.sh -- 编一个"从 shell 加载并运行"的 C 应用
# -----------------------------------------------------------------------------
# 用法： bash sw/build_app.sh sw/app/hello_app.c hello_app
# 产物（sw/build/）：
#   <name>.elf / <name>.bin
#   <name>_irom.hex   —— 代码段（**从 0x3000 起**，喂给 shell 的 `L 3000`）
#   <name>_dram.hex   —— .rodata/.data（**从 0x10000 起**，喂给 `D 10000`）
#   并在最后一行打印入口地址：APP_ENTRY=0x........（喂给 `r <addr>`）
#
# ★ 两个与 build_simple.sh 不同的地方：
#   1. 用 sw/app/link_app.ld（.text 0x3000、没有 crt0 —— 应用被 shell jalr 调用）；
#   2. elf2hex 的 --split 是 0xD000 = 0x10000 - 0x3000（bin 的偏移量口径）。
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

SRC="${1:?用法: build_app.sh <源文件.c> <名字>}"
NAME="${2:?用法: build_app.sh <源文件.c> <名字>}"
OUT="${PROJ_ROOT}/sw/build"
LD="${PROJ_ROOT}/sw/app/link_app.ld"
mkdir -p "${OUT}"

APP_BASE=0x4000
SPLIT=$((0x10000 - 0x4000))          # 0xC000

CFLAGS=(
    $ARCH -O2
    -ffreestanding -fno-builtin -fno-common -fno-stack-protector
    -mno-relax -msmall-data-limit=0
    -Wall -Wno-unused-parameter
)

echo "== compile app ${SRC} -> ${NAME} =="
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${SRC}" -o "${OUT}/${NAME}.o"
riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${LD}" \
    "${OUT}/${NAME}.o" -o "${OUT}/${NAME}.elf" -lgcc

ENTRY=$(riscv64-unknown-elf-nm "${OUT}/${NAME}.elf" | awk '$3=="main"{print $1}')
if [ -z "${ENTRY}" ]; then
    echo "!! 找不到 main 符号"; exit 1
fi

riscv64-unknown-elf-size -A "${OUT}/${NAME}.elf" | grep -E '^\.text|^\.rodata|^\.data|^\.bss' || true
riscv64-unknown-elf-objcopy -O binary "${OUT}/${NAME}.elf" "${OUT}/${NAME}.bin"
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/${NAME}.bin" \
    --split $((SPLIT)) \
    --irom "${OUT}/${NAME}_irom.hex" --dram "${OUT}/${NAME}_dram.hex" \
    --trim \
    --irom-words 12288 --dram-words 16384

echo "== done =="
ls -l "${OUT}/${NAME}_irom.hex" "${OUT}/${NAME}_dram.hex"
echo "APP_ENTRY=0x0${ENTRY}"
