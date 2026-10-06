#!/usr/bin/env bash
# =============================================================================
# run_modelsim.sh — 第二仿真器交叉验证
#
#   把**同一套差分测试**同时喂给 iverilog 与 ModelSim SE，做三方比对：
#       (a) iverilog  的 dump  vs  独立参考模型
#       (b) ModelSim  的 dump  vs  独立参考模型
#       (c) iverilog  的 dump  vs  ModelSim 的 dump   （逐字节）
#
#   为什么值得单独跑一遍：
#     1) 排除"差分测试的结果只是 iverilog 特有语义解释"的可能 —— (c) 直接对比
#        两个仿真器的 32 个 GPR + 全部非零内存字，任何一条差异都是仿真器语义分歧。
#     2) ModelSim 的**编译期检查远比 iverilog 严格**。首次接入时它当场报出 5 处
#        "先用后声明"（vlog-2730，硬错误、不可压制）—— 按 Verilog 隐式网络规则，
#        这些标识符会被当成 1 位 wire，其中一个是 32 位的 mdu_res（乘除法结果总线）。
#        iverilog 对这些全部静默放过（见 .verify/README.md）。
#
#   用法:  bash run_modelsim.sh [随机用例数=20]
#   环境:  WSL；Windows 侧安装 ModelSim SE（默认 E:\FPGA\ModelSim_10.5se）
#          可用 MSIM_DIR / MSIM_WORK 覆盖安装目录与工作目录。
#   注意:  ModelSim 是 Windows 程序，工作目录必须在 Windows 可访问的分区，
#          且**不能含非 ASCII 字符**（10.5 对中文路径支持不好）。
# =============================================================================
set -uo pipefail

PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
MSIM_DIR="${MSIM_DIR:-/mnt/e/FPGA/ModelSim_10.5se/win64}"
WORK="${MSIM_WORK:-/mnt/c/Users/14000/AppData/Local/Temp/msim_dt}"
NRAND="${1:-20}"

VLIB="$MSIM_DIR/vlib.exe"; VLOG="$MSIM_DIR/vlog.exe"; VSIM="$MSIM_DIR/vsim.exe"
for t in "$VLIB" "$VLOG" "$VSIM"; do
    if [ ! -x "$t" ]; then
        echo "!! 找不到 ModelSim 可执行文件: $t"
        echo "!! 请用 MSIM_DIR=<安装目录>/win64 指定"
        exit 1
    fi
done

RTL="rtl/myCPU.sv rtl/IFU.sv rtl/ICache.sv rtl/Branch_Predictor.sv rtl/IDU.sv
     rtl/Reg_Stack.sv rtl/RegisterFile.sv rtl/CSR.sv rtl/EXU.sv rtl/ALU.sv
     rtl/MDU_pipelined.sv rtl/LSU.sv rtl/DCache.sv rtl/WBU.sv
     rtl/Data_hazard.sv rtl/Control.sv rtl/add.sv rtl/sext.sv rtl/Reg.sv"

echo "############################################################"
echo "# 0) 准备工作区: $WORK"
echo "############################################################"
rm -rf "$WORK"
mkdir -p "$WORK/rtl" "$WORK/logs" "$WORK/tests"
cp "$SRC/v9/"*.sv                          "$WORK/rtl/" || exit 1
cp "$SRC/v9/experimental/MDU_pipelined.sv" "$WORK/rtl/" || exit 1
cp "$SRC/.verify/difftest/tb_difftest.sv"  "$WORK/"     || exit 1
cp "$SRC/.verify/difftest/rv32.py" "$SRC/.verify/difftest/gen.py" \
   "$SRC/.verify/difftest/compare.py"      "$WORK/"     || exit 1
cd "$WORK" || exit 1
python3 gen.py tests "$NRAND" > logs/gen.log 2>&1 || { echo "用例生成失败"; tail -5 logs/gen.log; exit 1; }
NTEST=$(grep -c . tests/manifest.txt)
echo "用例数: $NTEST  (定向 20 + 随机 $NRAND)"

# ---------------------------------------------------------------- ModelSim 编译
echo
echo "############################################################"
echo "# 1) ModelSim 编译（严格检查 —— 期望 0 个硬错误）"
echo "############################################################"
rm -rf work
"$VLIB" work                                  > logs/vlib.log    2>&1
"$VLOG" -sv -work work $RTL tb_difftest.sv    > logs/vlog_tb.log 2>&1
VLOG_RC=$?
# vlog 把错误分两类：** Error: ... 是硬错误（阻断编译）；** Error (suppressible): ... 可压制
HARD=$(grep -c '^\*\* Error: '               logs/vlog_tb.log)
SOFT=$(grep -c '^\*\* Error (suppressible)'  logs/vlog_tb.log)
WARN=$(grep -c '^\*\* Warning'               logs/vlog_tb.log)
echo "vlog rc=$VLOG_RC   硬错误=$HARD   可压制=$SOFT   警告=$WARN"
if [ "$HARD" -gt 0 ]; then
    echo "--- 硬错误明细 ---"
    grep '^\*\* Error: ' logs/vlog_tb.log | head -20
    echo
    echo "!! ModelSim 编译未通过：先修掉上面这些（多为\"先用后声明\"触发的隐式网络），"
    echo "!! 详见 .verify/README.md 的说明。"
    exit 1
fi
echo "ModelSim 编译通过。"

# ---------------------------------------------------------------- iverilog 编译
HAVE_IV=1
if command -v iverilog >/dev/null 2>&1; then
    echo
    echo "############################################################"
    echo "# 2) iverilog 编译（同一份 RTL，用于逐字节对比）"
    echo "############################################################"
    if iverilog -g2012 -I rtl -o tb_iv.vvp $RTL tb_difftest.sv > logs/vlog_iv.log 2>&1; then
        echo "iverilog 编译 OK"
    else
        echo "iverilog 编译失败:"; tail -20 logs/vlog_iv.log; HAVE_IV=0
    fi
else
    echo; echo "(本机无 iverilog，跳过逐字节对比，只做 ModelSim vs 参考模型)"
    HAVE_IV=0
fi

# ---------------------------------------------------------------- 逐用例运行
norm() {  # 把 ModelSim 的 "# " transcript 前缀和行尾空白去掉，统一成两仿真器可比格式
    sed -e 's/^# //' -e 's/[[:space:]]*$//' "$1"
}

echo
echo "############################################################"
echo "# 3) 逐用例运行（每个用例跑两个仿真器）"
echo "############################################################"
P_MS=0;  F_MS=0;  BAD_MS=""
P_IV=0;  F_IV=0;  BAD_IV=""
NDIFF=0; BAD_DIFF=""
NCYC=0;  BAD_CYC=""
NRUN=0

# 注意: 仿真器会从 stdin 读命令，务必 `< /dev/null`，
#       否则会把 manifest.txt 剩下的用例名吃掉（循环只跑第一个用例）。
while read -r name; do
    [ -z "$name" ] && continue
    NRUN=$((NRUN + 1))

    # --- ModelSim ---
    "$VSIM" -c -do "run -all; quit -f" work.tb_difftest \
        +prog="tests/$name.hex" +max=20000 +post=60 > "logs/msim_$name.raw" 2>&1 < /dev/null
    norm "logs/msim_$name.raw" > "logs/msim_$name.log"
    if python3 compare.py "logs/msim_$name.log" "tests/$name.exp" "$name" \
            > "logs/cmp_msim_$name.txt" 2>&1; then
        P_MS=$((P_MS + 1))
    else
        F_MS=$((F_MS + 1)); BAD_MS="$BAD_MS $name"
    fi

    # --- iverilog ---
    if [ "$HAVE_IV" = 1 ]; then
        vvp tb_iv.vvp +prog="tests/$name.hex" +max=20000 +post=60 > "logs/iv_$name.raw" 2>&1 < /dev/null
        norm "logs/iv_$name.raw" > "logs/iv_$name.log"
        if python3 compare.py "logs/iv_$name.log" "tests/$name.exp" "$name" \
                > "logs/cmp_iv_$name.txt" 2>&1; then
            P_IV=$((P_IV + 1))
        else
            F_IV=$((F_IV + 1)); BAD_IV="$BAD_IV $name"
        fi

        # --- 两仿真器逐字节对比（只比状态：GPR / MEMW / MAGIC_CYC / TOTAL_CYC）---
        grep -E '^(GPR|MEMW|MAGIC_CYC|TOTAL_CYC) ' "logs/iv_$name.log"   > "logs/d_iv_$name.txt"
        grep -E '^(GPR|MEMW|MAGIC_CYC|TOTAL_CYC) ' "logs/msim_$name.log" > "logs/d_ms_$name.txt"
        if ! diff -q "logs/d_iv_$name.txt" "logs/d_ms_$name.txt" >/dev/null 2>&1; then
            # 周期数不同（但状态一致）单列出来：说明两仿真器对同一 RTL 的调度有差异
            if diff -q <(grep -E '^(GPR|MEMW) ' "logs/d_iv_$name.txt") \
                       <(grep -E '^(GPR|MEMW) ' "logs/d_ms_$name.txt") >/dev/null 2>&1; then
                NCYC=$((NCYC + 1)); BAD_CYC="$BAD_CYC $name"
            else
                NDIFF=$((NDIFF + 1)); BAD_DIFF="$BAD_DIFF $name"
            fi
        fi
    fi

    printf '.'
done < tests/manifest.txt
echo

# ---------------------------------------------------------------- 汇总
echo
echo "############################################################"
echo "# 汇总"
echo "############################################################"
printf '  (a) ModelSim  vs 参考模型 : PASS=%d FAIL=%d\n' "$P_MS" "$F_MS"
[ -n "$BAD_MS" ]   && echo "      失败:$BAD_MS"
if [ "$HAVE_IV" = 1 ]; then
    printf '  (b) iverilog  vs 参考模型 : PASS=%d FAIL=%d\n' "$P_IV" "$F_IV"
    [ -n "$BAD_IV" ] && echo "      失败:$BAD_IV"
    printf '  (c) 两仿真器逐字节一致    : %d/%d 用例一致，%d 个状态不一致\n' \
           "$((NRUN - NDIFF - NCYC))" "$NRUN" "$NDIFF"
    [ -n "$BAD_DIFF" ] && echo "      状态分歧:$BAD_DIFF"
    if [ "$NCYC" -gt 0 ]; then
        printf '      (其中 %d 个用例仅周期数不同、状态完全一致):%s\n' "$NCYC" "$BAD_CYC"
    fi
fi
echo "  日志目录: $WORK/logs"
echo "############################################################"

[ "$F_MS" -eq 0 ] && { [ "$HAVE_IV" = 0 ] || { [ "$F_IV" -eq 0 ] && [ "$NDIFF" -eq 0 ]; }; }
