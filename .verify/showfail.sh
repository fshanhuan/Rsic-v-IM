#!/usr/bin/env bash
# 查看剩余失败用例的明细
set -uo pipefail
PREFIX="$HOME/ivlocal"; export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
cd "$HOME/difftest" || exit 1
for n in "$@"; do
    echo "### $n"
    python3 compare.py "logs/$n.log" "tests/$n.exp" "$n" | head -14
    echo "--- 是否超时 ---"
    grep -c "DIFFTEST_NO_MAGIC" "logs/$n.log" || true
done
