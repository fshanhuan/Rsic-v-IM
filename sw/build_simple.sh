#!/usr/bin/env bash
# =============================================================================
# sw/build_simple.sh -- 编一个"单文件 C 自检程序"（divtest / memtest / hello ...）
# -----------------------------------------------------------------------------
# 用法： bash sw/build_simple.sh sw/divtest.c div
#   产物： sw/build/<name>_irom.hex / <name>_dram.hex
#   跑仿真：bash sw/run_coremark.sh +irom=sw/build/<name>_irom.hex \
#                                  +dram=sw/build/<name>_dram.hex
#
# 复用同一套 crt0 / link.ld / libc_mini（sw/coremark_port），保证内存布局一致：
#   .text -> IROM(64KB)   .rodata/.data/.bss/栈 -> DRAM 0x1_0000 以上
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

SRC="${1:?用法: build_simple.sh <源文件.c> <名字>}"
NAME="${2:?用法: build_simple.sh <源文件.c> <名字>}"

OUT="${PROJ_ROOT}/sw/build"
PORT="${PROJ_ROOT}/sw/coremark_port"
mkdir -p "${OUT}"

CFLAGS=(
    $ARCH -O2
    -ffreestanding -fno-builtin -fno-common
    -mno-relax -msmall-data-limit=0
    -Wall -Wno-unused-parameter
)

echo "== compile ${SRC} -> ${NAME} =="
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${SRC}" -o "${OUT}/${NAME}.o"
riscv64-unknown-elf-gcc $ARCH -c "${PORT}/crt0.S"      -o "${OUT}/${NAME}_crt0.o"
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${PORT}/libc_mini.c" -o "${OUT}/${NAME}_libc.o"

riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${PORT}/link.ld" \
    "${OUT}/${NAME}_crt0.o" "${OUT}/${NAME}.o" "${OUT}/${NAME}_libc.o" \
    -o "${OUT}/${NAME}.elf" -lgcc

riscv64-unknown-elf-size "${OUT}/${NAME}.elf"
riscv64-unknown-elf-objcopy -O binary "${OUT}/${NAME}.elf" "${OUT}/${NAME}.bin"
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/${NAME}.bin" \
    --split 0x10000 \
    --irom "${OUT}/${NAME}_irom.hex" --dram "${OUT}/${NAME}_dram.hex" \
    --irom-words 16384 --dram-words 32768
