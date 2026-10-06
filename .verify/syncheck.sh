#!/usr/bin/env bash
# 按 syn/synth_core.ys 的文件清单编译，复现"缺模块"
set -uo pipefail
PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
W="$HOME/syncheck"
rm -rf "$W"; mkdir -p "$W"; cd "$W"
cp "$SRC/v9/"*.sv .
# 清单逐字取自 syn/synth_core.ys:7-10（注意：MDU.sv，且不含 board/*.sv、不含 experimental/）
iverilog -g2012 -I. -o out.vvp \
    myCPU.sv ALU.sv add.sv Branch_Predictor.sv Control.sv CSR.sv \
    Data_hazard.sv DCache.sv EXU.sv ICache.sv IDU.sv IFU.sv LSU.sv MDU.sv \
    RegisterFile.sv Reg_Stack.sv Reg.sv sext.sv WBU.sv 2>&1 | grep -Ei 'error|missing' | head -10
echo "rc=${PIPESTATUS[0]}"
echo "--- 清单里是否提到 board / MDU_pipelined ---"
grep -n -E 'board|MDU_pipelined' "$SRC/v9/syn/synth_core.ys" || echo "（未出现：board/*.sv 与 experimental/MDU_pipelined.sv 都不在清单里）"
