#!/usr/bin/env bash
# =============================================================================
# sw/build_hello.sh -- 用 C 工具链编一个最小自检程序（sw/hello.c）
# -----------------------------------------------------------------------------
# 目的：给"工具链 + crt0 + 链接脚本 + IROM/DRAM 双镜像"一条**短**验证路径。
#   CoreMark 有问题时先跑这个：它几百拍就结束，能把"工具链/内存映射"和
#   "某个 benchmark 的算法逻辑"两类问题分开。
#
# 产物（sw/build/）：
#   hello.elf / hello.bin
#   hello_irom.hex（取指镜像）/ hello_dram.hex（数据镜像）
#
# 跑仿真：
#   bash sw/run_coremark.sh +irom=sw/build/hello_irom.hex +dram=sw/build/hello_dram.hex
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

OUT="${PROJ_ROOT}/sw/build"
PORT="${PROJ_ROOT}/sw/coremark_port"     # 复用同一套 crt0/link.ld/libc_mini
mkdir -p "${OUT}"

CFLAGS=(
    $ARCH -O2
    -ffreestanding -fno-builtin -fno-common
    -mno-relax -msmall-data-limit=0
    -Wall
)

echo "== compile hello.c =="
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${PROJ_ROOT}/sw/hello.c" -o "${OUT}/hello.o"
riscv64-unknown-elf-gcc $ARCH -c "${PORT}/crt0.S"      -o "${OUT}/crt0_hello.o"
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${PORT}/libc_mini.c" -o "${OUT}/libc_mini_hello.o"

echo "== link =="
riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${PORT}/link.ld" \
    "${OUT}/crt0_hello.o" "${OUT}/hello.o" "${OUT}/libc_mini_hello.o" \
    -o "${OUT}/hello.elf" -lgcc

riscv64-unknown-elf-size -A "${OUT}/hello.elf" | grep -E '\.text|\.rodata|\.data|\.bss' || true

riscv64-unknown-elf-objcopy -O binary "${OUT}/hello.elf" "${OUT}/hello.bin"
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/hello.bin" \
    --split 0x10000 \
    --irom "${OUT}/hello_irom.hex" --dram "${OUT}/hello_dram.hex" \
    --irom-words 16384 --dram-words 32768
echo "== ok =="
