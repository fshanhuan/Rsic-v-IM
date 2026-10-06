#!/usr/bin/env bash
# =============================================================================
# verify_all.sh — 验收总脚本（修复前/后都用它，输出可直接对比）
#   0) 严格网络检查    .verify/netcheck.sh                 期望全 OK（无隐式网络）
#   1) 官方回归        v9/sim/run_all.sh                    期望 15 项通过
#   2) 板级自检        v9/board/tb_board_top.sv             期望 PASS 33/33
#   3) 差分测试        自建夹具 vs 独立参考模型              期望全过
#   4) 交叉验证        同一批程序喂给工程自带 tb_iverilog    期望全过
#   5) 综合脚本一致性  syn/synth_core.ys 清单 elaboration    期望全 OK
#   另有需 Windows 侧 ModelSim 的第五道门禁（第二仿真器）：
#       bash .verify/difftest/run_modelsim.sh 40
# 用法: bash verify_all.sh [随机用例数]        默认 40
# =============================================================================
set -uo pipefail

PREFIX="$HOME/ivlocal"
export PATH="$PREFIX/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

SRC="/mnt/c/Users/14000/Desktop/share/share/v9_上板改造_交付版"
NRAND="${1:-40}"
WORK="$HOME/accept"

rm -rf "$WORK"; mkdir -p "$WORK"
cp -r "$SRC/v9" "$WORK/v9"
cd "$WORK/v9" || exit 1
mkdir -p sim/build wave

RC0=1; RC1=1; RC2=1; RC3=1; RC4=1; RC5=1

echo "############################################################"
echo "# 0) 严格网络检查（隐式网络 / 先用后声明）"
echo "############################################################"
bash "$SRC/.verify/netcheck.sh" > "$WORK/0_netcheck.log" 2>&1; RC0=$?
grep -E '\[(OK|BAD)\]|隐式网络检查: ' "$WORK/0_netcheck.log"

echo
echo "############################################################"
echo "# 1) 官方回归 run_all.sh"
echo "############################################################"
bash sim/run_all.sh > "$WORK/1_runall.log" 2>&1; RC1=$?
grep -E 'SELFCHECK|run_all\.sh: ' "$WORK/1_runall.log" | tail -12

echo
echo "############################################################"
echo "# 2) 板级自检 tb_board_top"
echo "############################################################"
iverilog -g2012 -o sim/build/tb_board.vvp \
    board/sync_mem.sv board/reset_sync.sv board/board_top.sv \
    myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv \
    RegisterFile.sv CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv LSU.sv \
    DCache.sv WBU.sv Data_hazard.sv Control.sv add.sv sext.sv Reg.sv \
    board/tb_board_top.sv > "$WORK/2_board_compile.log" 2>&1
if [ $? -eq 0 ]; then
    vvp sim/build/tb_board.vvp +prog=sim/prog.hex > "$WORK/2_board.log" 2>&1; RC2=$?
    grep -E 'BOARD-SELFCHECK|total cycles|ICache hit|x[0-9]+ = .*FAIL' "$WORK/2_board.log" | tail -10
else
    echo "板级测试台编译失败"; tail -5 "$WORK/2_board_compile.log"
fi

echo
echo "############################################################"
echo "# 3) 差分测试（独立参考模型，随机 $NRAND 例）"
echo "############################################################"
bash "$SRC/.verify/difftest/run.sh" "$NRAND" > "$WORK/3_diff.log" 2>&1; RC3=$?
grep -E '^差分测试结果|^失败用例|compile|编译' "$WORK/3_diff.log" | tail -5

echo
echo "############################################################"
echo "# 4) 交叉验证（工程自带 tb_iverilog.sv）"
echo "############################################################"
bash "$SRC/.verify/difftest/crosscheck.sh" > "$WORK/4_cross.log" 2>&1; RC4=$?
grep -E '^(PASS|FAIL) |交叉验证不一致处数' "$WORK/4_cross.log" | tail -12

echo
echo "############################################################"
echo "# 5) 综合脚本一致性 syn/synth_core.ys"
echo "############################################################"
bash "$SRC/.verify/syncheck.sh" > "$WORK/5_syncheck.log" 2>&1; RC5=$?
grep -E '\[(OK|BAD)\]|综合脚本一致性: ' "$WORK/5_syncheck.log"

echo
echo "############################################################"
echo "# 汇总"
echo "############################################################"
printf '  0) 隐式网络检查通过     : %s (rc=%d)\n' "$([ $RC0 -eq 0 ] && echo PASS || echo FAIL)" "$RC0"
printf '  1) 官方回归 7/7         : %s (rc=%d)\n' "$([ $RC1 -eq 0 ] && echo PASS || echo FAIL)" "$RC1"
printf '  2) 板级自检 PASS        : %s (rc=%d)\n' "$([ $RC2 -eq 0 ] && echo PASS || echo FAIL)" "$RC2"
printf '  3) 差分测试全过         : %s (rc=%d)\n' "$([ $RC3 -eq 0 ] && echo PASS || echo FAIL)" "$RC3"
printf '  4) 交叉验证一致         : %s (rc=%d)\n' "$([ $RC4 -eq 0 ] && echo PASS || echo FAIL)" "$RC4"
printf '  5) 综合脚本清单一致     : %s (rc=%d)\n' "$([ $RC5 -eq 0 ] && echo PASS || echo FAIL)" "$RC5"
echo "  日志目录: $WORK"
# 只在全部通过时返回 0
[ $RC0 -eq 0 ] && [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && [ $RC3 -eq 0 ] && [ $RC4 -eq 0 ] && [ $RC5 -eq 0 ]
