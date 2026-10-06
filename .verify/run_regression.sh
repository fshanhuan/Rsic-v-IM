#!/usr/bin/env bash
# 在 WSL 原生文件系统上跑交付版自带的全量回归
set -uo pipefail
SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
DST="$HOME/v9verify"

PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export IVERILOG="$PREFIX/usr/bin/iverilog"
export VVP="$PREFIX/usr/bin/vvp"

which iverilog vvp
iverilog -V 2>/dev/null | head -1

rm -rf "$DST"
mkdir -p "$DST"
cp -r "$SRC/v9" "$DST/v9"
echo "=== copied: $(find "$DST/v9" -type f | wc -l) files ==="

cd "$DST/v9"
echo "############ RUN run_all.sh ############"
bash sim/run_all.sh
rc=$?
echo "############ run_all.sh exit code = $rc ############"
exit $rc
