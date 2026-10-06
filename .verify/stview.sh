#!/usr/bin/env bash
# 用工程自带 tb_iverilog 的事件日志定位某个 store 的 wdata
# 用法: bash stview.sh <prog名> [grep模式]
set -uo pipefail
PREFIX="$HOME/ivlocal"; export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
cd "$HOME/difftest" || exit 1
PROG="${1:-rnd003}"
PAT="${2:-002128}"
vvp tb_proj.vvp +prog="tests/${PROG}_ecall.hex" +prog_id=3 +vcd=logs/cc.vcd \
    > "logs/st_${PROG}.log" 2>&1
echo "=== 含 $PAT 的 ST/WB/MEMW 事件 ==="
grep -nE "\[ST \]|\[WB \]|MEMW" "logs/st_${PROG}.log" | grep -E "$PAT" || echo "（无匹配）"
echo "=== 全部 ST 事件 ==="
grep -E "^\[ST \]" "logs/st_${PROG}.log" | head -20
echo "=== 自带测试台的寄存器快照（含 MEASURED）==="
grep -E "^\s+x[0-9]+ =" "logs/st_${PROG}.log" | head -32
