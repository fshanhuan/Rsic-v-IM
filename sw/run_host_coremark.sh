#!/usr/bin/env bash
# 找主机版 coremark 产物在哪，并跑一遍拿参考 CRC
set -u
SRC="${HOME}/rv32/coremark"
cd "${SRC}" || exit 1

make clean >/dev/null 2>&1
make PORT_DIR=linux 2>&1 | tail -6

echo "== 找产物 =="
find "${SRC}" -maxdepth 3 -type f -perm -u+x -name 'coremark*' 2>/dev/null

BIN="$(find "${SRC}" -maxdepth 3 -type f -perm -u+x -name 'coremark*' 2>/dev/null | head -1)"
if [ -z "${BIN}" ]; then
    echo "!! 还是没有产物"
    ls "${SRC}" | head -20
    exit 1
fi

echo "======== 主机（x86-64）CoreMark：$BIN ========"
"${BIN}" 2>&1 | head -30
