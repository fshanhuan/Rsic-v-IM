#!/usr/bin/env bash
# 生成新回归程序的 hex + 期望值片段，并复制到 v9/sim/
set -uo pipefail
PREFIX="$HOME/ivlocal"; export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
cd "$HOME/difftest" || exit 1
cp "$SRC/.verify/difftest/mkcases.py" "$SRC/.verify/difftest/rv32.py" . || exit 1
python3 gen.py tests 0 >/dev/null || exit 1
python3 mkcases.py
echo "=== cases.txt ==="
cat cases.txt
echo "=== 复制 hex 到 v9/sim/ ==="
cp prog_load_lane.hex prog_load_use.hex prog_loop.hex prog_div_pair.hex "$SRC/v9/sim/" && echo "已复制 4 个程序"
