#!/usr/bin/env bash
# 交叉验证：项目自带 tb_iverilog.sv 上跑同一批程序，检验错值是否复现
set -uo pipefail
PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
WORK="$HOME/difftest"
cd "$WORK" || exit 1
mkdir -p tests logs

cp "$SRC/v9/sim/tb_iverilog.sv" rtl/ || exit 1
cp "$SRC/.verify/difftest/rv32.py" "$SRC/.verify/difftest/gen.py" "$SRC/.verify/difftest/crosscheck.py" "$WORK/" || exit 1

rm -rf tests
python3 gen.py tests "${NRAND:-5}" >/dev/null || exit 1

echo "=== 用工程自带测试台编译 ==="
iverilog -g2012 -I rtl -o tb_proj.vvp \
    rtl/myCPU.sv rtl/IFU.sv rtl/ICache.sv rtl/Branch_Predictor.sv rtl/IDU.sv \
    rtl/Reg_Stack.sv rtl/RegisterFile.sv rtl/CSR.sv rtl/EXU.sv rtl/ALU.sv \
    rtl/MDU_pipelined.sv rtl/LSU.sv rtl/DCache.sv rtl/WBU.sv \
    rtl/Data_hazard.sv rtl/Control.sv rtl/add.sv rtl/sext.sv rtl/Reg.sv \
    rtl/tb_iverilog.sv 2> logs/cc_compile.log
[ $? -ne 0 ] && { echo "编译失败"; tail -20 logs/cc_compile.log; exit 1; }
echo "编译 OK"

echo "=== 交叉验证（自带测试台，+prog_id=3 只报实测） ==="
python3 crosscheck.py lane_min loaduse div_min storeload loop mulchain
