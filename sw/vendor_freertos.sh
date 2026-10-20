#!/usr/bin/env bash
# =============================================================================
# sw/vendor_freertos.sh -- 把 FreeRTOS-Kernel 需要的那部分 vendor 进仓库
# -----------------------------------------------------------------------------
# 只拷内核运行必需的文件（不是整个 FreeRTOS 发行包）：
#   tasks.c / queue.c / list.c / timers.c + include/*.h
#   portable/GCC/RISC-V/*          （上下文切换 + 陷入处理，M 模式）
#   portable/MemMang/heap_4.c      （堆，供 pvPortMalloc 用）
#
# 内核版本写在 sw/freertos/VERSION.txt，便于复现。
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

SRC="${HOME}/rv32/FreeRTOS-Kernel"
DST="${PROJ_ROOT}/sw/freertos"

if [ ! -d "${SRC}" ]; then
    echo "!! 内核不在 ${SRC}" >&2
    echo "   git clone --depth 1 -b V11.1.0 https://github.com/FreeRTOS/FreeRTOS-Kernel.git ~/rv32/FreeRTOS-Kernel" >&2
    exit 1
fi

mkdir -p "${DST}/kernel" "${DST}/include" "${DST}/port" "${DST}/memmang"

for f in tasks.c queue.c list.c timers.c; do
    cp -f "${SRC}/${f}" "${DST}/kernel/"
done
cp -f "${SRC}"/include/*.h "${DST}/include/"
cp -f "${SRC}/portable/GCC/RISC-V/"*.c   "${DST}/port/" 2>/dev/null || true
cp -f "${SRC}/portable/GCC/RISC-V/"*.S   "${DST}/port/" 2>/dev/null || true
cp -f "${SRC}/portable/GCC/RISC-V/"*.h   "${DST}/port/" 2>/dev/null || true
cp -f "${SRC}/portable/GCC/RISC-V/"*.txt "${DST}/port/" 2>/dev/null || true
cp -f "${SRC}/portable/MemMang/heap_4.c" "${DST}/memmang/"

# 版本信息
{
    echo "FreeRTOS-Kernel vendored from ${SRC}"
    echo "tag/branch: $(git -C "${SRC}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "commit    : $(git -C "${SRC}" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "date      : $(git -C "${SRC}" log -1 --format=%ad 2>/dev/null || echo unknown)"
} > "${DST}/VERSION.txt"

echo "== vendored =="
ls -l "${DST}/kernel" "${DST}/port" "${DST}/memmang" | sed 's/^/   /'
cat "${DST}/VERSION.txt"
