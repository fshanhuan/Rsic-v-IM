#!/usr/bin/env bash
# 追 store 通路（B5：store 数据来自紧邻 load 时整笔丢失）
# 用法: bash trace_store.sh <prog名> <max拍>
set -uo pipefail
PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
WORK="$HOME/difftest"
cd "$WORK" || exit 1
cp "$SRC/.verify/difftest/tb_trace.sv" "$WORK/" || exit 1
python3 gen.py tests 0 >/dev/null || exit 1

iverilog -g2012 -I rtl -o tb_trace.vvp \
    rtl/myCPU.sv rtl/IFU.sv rtl/ICache.sv rtl/Branch_Predictor.sv rtl/IDU.sv \
    rtl/Reg_Stack.sv rtl/RegisterFile.sv rtl/CSR.sv rtl/EXU.sv rtl/ALU.sv \
    rtl/MDU_pipelined.sv rtl/LSU.sv rtl/DCache.sv rtl/WBU.sv \
    rtl/Data_hazard.sv rtl/Control.sv rtl/add.sv rtl/sext.sv rtl/Reg.sv \
    tb_trace.sv 2>/dev/null || { echo "编译失败"; exit 1; }

PROG="${1:-store_dep_load}"
MAX="${2:-80}"
vvp tb_trace.vvp +prog="tests/${PROG}_ecall.hex" +max="$MAX"
