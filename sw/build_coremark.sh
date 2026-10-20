#!/usr/bin/env bash
# =============================================================================
# sw/build_coremark.sh -- 交叉编译 CoreMark 并生成仿真用的 irom/dram 镜像
# -----------------------------------------------------------------------------
# 用法：
#   bash sw/build_coremark.sh            # 默认 ITERATIONS=1
#   ITER=40 bash sw/build_coremark.sh    # 指定迭代次数（>=10 s 目标时间用）
#   OPT=-Os bash sw/build_coremark.sh    # 换优化档做 A/B
#
# 产物（sw/build/）：
#   coremark.elf / coremark.bin / coremark.map
#   cm_irom.hex   取指镜像（.text，64 KB 空间）
#   cm_dram.hex   数据镜像（.rodata+.data，从 0x10000 起，加载到 DRAM 字 0）
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

ITER="${ITER:-1}"
OPT="${OPT:--O2}"
# CORE_DEBUG=1 打开 CoreMark 自带的中间量打印（List find / 矩阵值 / 各算法 CRC），
# 用于和 x86 主机版逐行对拍。默认关，因为它会强制 ITERATIONS=1 且输出极多。
DBG="${CORE_DEBUG:-0}"
OUT="${PROJ_ROOT}/sw/build"
PORT="${PROJ_ROOT}/sw/coremark_port"
CM="${PROJ_ROOT}/sw/coremark"

mkdir -p "${OUT}"

# CoreMark 要求这几个宏：FLAGS_STR 会原样打进报告，方便复现
DEFS=(
    -DITERATIONS="${ITER}"
    -DCORE_DEBUG="${DBG}"
    -DFLAGS_STR="\"${OPT} -march=rv32im -mabi=ilp32\""
)

CFLAGS=(
    $ARCH
    "${OPT}"
    -ffreestanding -fno-builtin -fno-common -fno-stack-protector
    -fno-asynchronous-unwind-tables -fno-unwind-tables
    -mno-relax -msmall-data-limit=0
    -ffunction-sections -fdata-sections
    # ★ 必须有：CoreMark 的 mergesort 在**空链表**时执行 `tail->next = NULL`
    #   （core_list_join.c:583，tail==NULL），这是 UB；gcc 13 -O2 会把它优化成
    #   `sw zero,0(zero); ebreak`（= __builtin_trap），运行到就陷入 0xd24。
    #   关掉"空指针解引用必 UB"这条假设，编译器就老老实实生成那次无害的写地址 0。
    -fno-delete-null-pointer-checks
    # ★ CoreMark 在**同一块 byte 数组**上既当 list_head 又当 list_data 用（指针双关），
    #   属于 strict-aliasing 违规。不开这条，gcc 13 在 rv32 上的代码生成会与 x86
    #   不同，表现为 crclist 与官方值不符（而内存/算术语义完全正确）。
    -Wall -Wno-unused-parameter
    -I"${PORT}" -I"${CM}"
    "${DEFS[@]}"
)


SRCS_CM=(
    "${CM}/core_main.c" "${CM}/core_list_join.c" "${CM}/core_matrix.c"
    "${CM}/core_state.c" "${CM}/core_util.c"
)
SRCS_PORT=(
    "${PORT}/core_portme.c" "${PORT}/ee_printf.c" "${PORT}/cvt.c"
    "${PORT}/libc_mini.c"   "${PORT}/crt0.S"
)

echo "== compile (ITERATIONS=${ITER}, ${OPT}) =="
OBJS=()
i=0
for f in "${SRCS_CM[@]}" "${SRCS_PORT[@]}"; do
    o="${OUT}/obj_${i}.o"
    riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "$f" -o "$o"
    OBJS+=("$o")
    i=$((i + 1))
done

echo "== link =="
riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${PORT}/link.ld" \
    "${OBJS[@]}" -o "${OUT}/coremark.elf" -lgcc \
    -Wl,-Map="${OUT}/coremark.map"

echo "== sections =="
riscv64-unknown-elf-size -A "${OUT}/coremark.elf" | grep -E '\.text|\.rodata|\.data|\.bss|Total' || true
riscv64-unknown-elf-size "${OUT}/coremark.elf"

echo "== elf -> bin -> hex =="
riscv64-unknown-elf-objcopy -O binary "${OUT}/coremark.elf" "${OUT}/coremark.bin"
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/coremark.bin" \
    --split 0x10000 \
    --irom "${OUT}/cm_irom.hex" --dram "${OUT}/cm_dram.hex" \
    --irom-words 16384 --dram-words 65536

echo "== done =="
ls -l "${OUT}/cm_irom.hex" "${OUT}/cm_dram.hex"
