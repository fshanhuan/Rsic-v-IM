#!/usr/bin/env bash
# =============================================================================
# sw/run_probe.sh -- 同一份 CoreMark 算法代码在 x86 与 rv32 上对拍中间量
# -----------------------------------------------------------------------------
# 输出通道是探针自己写的十六进制打印（不经过 printf），所以两边逐字节可比。
# 比较项：SIZE / PER_ITEM / 前 6 个链表节点的 idx+data16 / 矩阵 N / crclist
#        / crcmatrix / crcstate
#
# 用法：
#   bash sw/run_probe.sh
#   HOST_ONLY=1 bash sw/run_probe.sh     # 只编/跑主机版（快速查探针本身对不对）
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "${PROJ_ROOT}"

OUT="${PROJ_ROOT}/sw/build"
CM="${PROJ_ROOT}/sw/coremark"
PORT="${PROJ_ROOT}/sw/coremark_port"
HPORT="${PROJ_ROOT}/sw/cm_probe_port"
mkdir -p "${OUT}"

echo "======== 1) x86 主机版 ========"
gcc -O2 -DCM_HOST=1 -I "${HPORT}" -I "${CM}" \
    "${PROJ_ROOT}/sw/cm_probe.c" \
    "${CM}/core_list_join.c" "${CM}/core_matrix.c" "${CM}/core_state.c" "${CM}/core_util.c" \
    "${HPORT}/port_stub.c" \
    -o "${OUT}/cm_probe_host" > "${OUT}/probe_host_build.log" 2>&1 || true

if [ -x "${OUT}/cm_probe_host" ]; then
    "${OUT}/cm_probe_host" > "${OUT}/probe_host.log" 2>&1 || true
    echo "  ok -> ${OUT}/probe_host.log"
else
    echo "  !! 编译失败："; head -8 "${OUT}/probe_host_build.log"
    exit 1
fi

if [ "${HOST_ONLY:-0}" = "1" ]; then
    echo "--- host 输出 ---"; cat "${OUT}/probe_host.log"
    exit 0
fi

echo "======== 2) rv32 版 ========"
CFLAGS=(
    $ARCH -O2
    -ffreestanding -fno-builtin -fno-common
    -mno-relax -msmall-data-limit=0
    -fno-delete-null-pointer-checks
    -I "${PORT}" -I "${CM}"
)
OBJS=()
for f in "${PROJ_ROOT}/sw/cm_probe.c" "${CM}/core_list_join.c" "${CM}/core_matrix.c" \
         "${CM}/core_state.c" "${CM}/core_util.c"; do
    o="${OUT}/probe_$(basename "$f" | tr '.' '_').o"
    riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "$f" -o "$o"
    OBJS+=("$o")
done
# 端口：只需要 portable_init/fini + default_num_contexts + seed*_volatile，
#   两边用**同一份** port_stub.c（保证种子/尺寸完全一致）
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -I "${HPORT}" -c "${HPORT}/port_stub.c" -o "${OUT}/probe_port.o"
OBJS+=("${OUT}/probe_port.o")
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${PORT}/libc_mini.c" -o "${OUT}/probe_libc.o"
OBJS+=("${OUT}/probe_libc.o")
riscv64-unknown-elf-gcc $ARCH -c "${PORT}/crt0.S" -o "${OUT}/probe_crt0.o"
riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${PORT}/link.ld" \
    "${OUT}/probe_crt0.o" "${OBJS[@]}" -o "${OUT}/cm_probe_rv.elf" -lgcc
riscv64-unknown-elf-objcopy -O binary "${OUT}/cm_probe_rv.elf" "${OUT}/cm_probe_rv.bin"
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/cm_probe_rv.bin" --split 0x10000 \
    --irom "${OUT}/probe_irom.hex" --dram "${OUT}/probe_dram.hex" \
    --irom-words 16384 --dram-words 32768

bash "${PROJ_ROOT}/sw/run_coremark.sh" \
    +irom=sw/build/probe_irom.hex +dram=sw/build/probe_dram.hex +max=30000000 \
    > "${OUT}/probe_rv_raw.log" 2>&1 || true

grep -E '^(SIZE=|N[0-9] |MATN=|CRC=|CM=)' "${OUT}/probe_rv_raw.log" \
    | head -20 > "${OUT}/probe_rv.log" || true

echo "======== 3) 对拍 ========"
echo "--- x86 ---"; cat "${OUT}/probe_host.log"
echo "--- rv32 ---"; cat "${OUT}/probe_rv.log"
echo "--- diff（空 = 一致）---"
diff "${OUT}/probe_host.log" "${OUT}/probe_rv.log" && echo "完全一致 ✅" || true
