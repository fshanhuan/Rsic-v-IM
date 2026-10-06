#!/usr/bin/env bash
# =============================================================================
# run.sh — 独立差分测试：随机/定向程序在 RTL 与参考模型上跑，逐状态比对
#   用法: bash run.sh [随机用例数] [只跑匹配这个前缀的用例]
# 环境: WSL + 本地解包的 iverilog（$HOME/ivlocal）+ python3
# =============================================================================
set -uo pipefail

PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
WORK="$HOME/difftest"
NRAND="${1:-40}"
FILTER="${2:-}"

rm -rf "$WORK"
mkdir -p "$WORK/rtl" "$WORK/tests" "$WORK/logs"
cp "$SRC/v9/"*.sv "$WORK/rtl/" 2>/dev/null
cp "$SRC/v9/experimental/MDU_pipelined.sv" "$WORK/rtl/"
cp "$SRC/.verify/difftest/tb_difftest.sv" "$WORK/"
cp "$SRC/.verify/difftest/rv32.py" "$SRC/.verify/difftest/gen.py" "$SRC/.verify/difftest/compare.py" "$WORK/"

cd "$WORK" || exit 1

echo "=== 生成测试程序 (随机 $NRAND 个) ==="
python3 gen.py tests "$NRAND" || exit 1

echo "=== 编译 RTL ==="
iverilog -g2012 -I rtl -o tb.vvp \
    rtl/myCPU.sv rtl/IFU.sv rtl/ICache.sv rtl/Branch_Predictor.sv rtl/IDU.sv \
    rtl/Reg_Stack.sv rtl/RegisterFile.sv rtl/CSR.sv rtl/EXU.sv rtl/ALU.sv \
    rtl/MDU_pipelined.sv rtl/LSU.sv rtl/DCache.sv rtl/WBU.sv \
    rtl/Data_hazard.sv rtl/Control.sv rtl/add.sv rtl/sext.sv rtl/Reg.sv \
    tb_difftest.sv 2> logs/compile.log
rc=$?
if [ $rc -ne 0 ]; then
    echo "!!! 编译失败"; tail -30 logs/compile.log; exit 1
fi
echo "编译 OK ($(grep -c . logs/compile.log) 行提示)"

PASS=0; FAIL=0; FAILED=""
while read -r name; do
    [ -z "$name" ] && continue
    if [ -n "$FILTER" ] && [[ "$name" != $FILTER* ]]; then continue; fi
    if vvp tb.vvp +prog="tests/$name.hex" +max=20000 +post=60 > "logs/$name.log" 2>&1; then
        :
    fi
    if python3 compare.py "logs/$name.log" "tests/$name.exp" "$name"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); FAILED="$FAILED $name"
    fi
done < tests/manifest.txt

echo "=============================================================="
echo "差分测试结果: PASS=$PASS  FAIL=$FAIL"
[ -n "$FAILED" ] && echo "失败用例:$FAILED"
echo "日志目录: $WORK/logs"
echo "=============================================================="
[ "$FAIL" -eq 0 ]
