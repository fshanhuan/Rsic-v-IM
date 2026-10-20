#!/usr/bin/env bash
# 把 CoreMark 源码 vendor 进仓库（去掉 .git / docs / 其他 port），只留跑 rv32 需要的东西。
set -e
source "$(dirname "$0")/env.sh"

SRC="${HOME}/rv32/coremark"
DST="${PROJ_ROOT}/sw/coremark"

if [ ! -d "${SRC}" ]; then
    echo "!! 源码不在 ${SRC}，先 git clone https://github.com/eembc/coremark.git ~/rv32/coremark" >&2
    exit 1
fi

mkdir -p "${DST}"
cp -f "${SRC}"/core_main.c "${SRC}"/core_list_join.c "${SRC}"/core_matrix.c \
      "${SRC}"/core_state.c "${SRC}"/core_util.c "${SRC}"/coremark.h "${DST}/"
cp -f "${SRC}"/LICENSE.md "${SRC}"/README.md "${DST}/" 2>/dev/null || true

mkdir -p "${DST}/barebones"
cp -f "${SRC}"/barebones/*.c "${SRC}"/barebones/*.h "${SRC}"/barebones/*.mak "${DST}/barebones/"

echo "== vendored =="
ls -l "${DST}" "${DST}/barebones"
echo
echo "== git rev =="
git -C "${SRC}" log -1 --format='%H %ad %s' 2>/dev/null || echo "(no git)"
