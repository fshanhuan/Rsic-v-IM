#!/usr/bin/env bash
# 生成参考轨迹 + 用自带测试台跑出 RTL 事件流，然后逐条比对
set -uo pipefail
PREFIX="$HOME/ivlocal"; export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
cd "$HOME/difftest" || exit 1
cp "$SRC/.verify/difftest/reftrace.py" "$SRC/.verify/difftest/rv32.py" . || exit 1
cp "$SRC/v9/sim/tb_iverilog.sv" rtl/ || exit 1

# 用工程自带测试台编译（rtl/ 是 run.sh 刚同步过的当前 RTL）
if [ ! -f tb_proj.vvp ]; then
    iverilog -g2012 -I rtl -o tb_proj.vvp \
        rtl/myCPU.sv rtl/IFU.sv rtl/ICache.sv rtl/Branch_Predictor.sv rtl/IDU.sv \
        rtl/Reg_Stack.sv rtl/RegisterFile.sv rtl/CSR.sv rtl/EXU.sv rtl/ALU.sv \
        rtl/MDU_pipelined.sv rtl/LSU.sv rtl/DCache.sv rtl/WBU.sv \
        rtl/Data_hazard.sv rtl/Control.sv rtl/add.sv rtl/sext.sv rtl/Reg.sv \
        rtl/tb_iverilog.sv 2>/dev/null || { echo "编译失败"; exit 1; }
fi

for n in "$@"; do
    echo "################ $n"
    vvp tb_proj.vvp +prog="tests/${n}_ecall.hex" +prog_id=3 +vcd=logs/cc.vcd \
        > "logs/st_${n}.log" 2>&1
    python3 reftrace.py "$n"
done
