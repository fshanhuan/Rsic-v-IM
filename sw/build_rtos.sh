#!/usr/bin/env bash
# =============================================================================
# sw/build_rtos.sh -- 编译 FreeRTOS demo（本核 rv32im_zicsr）
# -----------------------------------------------------------------------------
# 流程：make_rtos_port.py 生成 CSR 定时器版端口 → 编内核 + 端口 + demo →
#       链接到 sw/coremark_port/link.ld（同一套内存布局）→ 出双镜像 hex。
#
# 产物（sw/build/）：
#   rtos.elf / rtos.bin / rtos_irom.hex / rtos_dram.hex
#
# 跑仿真：
#   bash sw/run_coremark.sh +irom=sw/build/rtos_irom.hex +dram=sw/build/rtos_dram.hex +max=3000000
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

OUT="${PROJ_ROOT}/sw/build"
FROOT="${PROJ_ROOT}/sw/freertos"
FPORT="${PROJ_ROOT}/sw/freertos_port"
LINKPORT="${PROJ_ROOT}/sw/coremark_port"     # crt0.S / link.ld / libc_mini.c 复用
mkdir -p "${OUT}"

echo "== generate port (CSR timer patch) =="
python3 "${PROJ_ROOT}/sw/make_rtos_port.py"

CFLAGS=(
    $ARCH -O2
    -ffreestanding -fno-builtin -fno-common -fno-stack-protector
    -fno-asynchronous-unwind-tables -fno-unwind-tables
    -mno-relax -msmall-data-limit=0
    -ffunction-sections -fdata-sections
    -I"${FROOT}/include" -I"${FPORT}" -I"${FROOT}/port"
    -Wall -Wno-unused-parameter
)

SRCS=(
    "${FROOT}/kernel/tasks.c"
    "${FROOT}/kernel/queue.c"
    "${FROOT}/kernel/list.c"
    "${FROOT}/memmang/heap_4.c"
    "${FPORT}/port.c"
    "${PROJ_ROOT}/sw/rtos_demo.c"
)
ASMS=(
    "${FPORT}/portASM.S"
    "${LINKPORT}/crt0.S"
)

echo "== compile kernel/port/demo =="
OBJS=()
i=0
for f in "${SRCS[@]}"; do
    o="${OUT}/rtos_${i}.o"
    riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "$f" -o "$o"
    OBJS+=("$o")
    i=$((i + 1))
done
for f in "${ASMS[@]}"; do
    o="${OUT}/rtos_${i}.o"
    riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "$f" -o "$o"
    OBJS+=("$o")
    i=$((i + 1))
done
# libc 桩（-nostdlib 下 gcc 会隐式调 memcpy/memset）
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${LINKPORT}/libc_mini.c" -o "${OUT}/rtos_libc.o"
OBJS+=("${OUT}/rtos_libc.o")

echo "== link =="
riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${LINKPORT}/link.ld" \
    "${OBJS[@]}" -o "${OUT}/rtos.elf" -lgcc

riscv64-unknown-elf-size -A "${OUT}/rtos.elf" | grep -E '\.text|\.rodata|\.data|\.bss' || true

riscv64-unknown-elf-objcopy -O binary "${OUT}/rtos.elf" "${OUT}/rtos.bin"
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/rtos.bin" \
    --split 0x10000 \
    --irom "${OUT}/rtos_irom.hex" --dram "${OUT}/rtos_dram.hex" \
    --irom-words 16384 --dram-words 32768
echo "== ok =="
