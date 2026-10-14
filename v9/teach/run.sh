#!/usr/bin/env bash
# =============================================================================
# teach/run.sh — 用 verilator 跑「讲解版」RTL
# -----------------------------------------------------------------------------
# 用法：
#   bash teach/run.sh build     # 只编译
#   bash teach/run.sh teach     # 编译 + 跑全部讲解程序，出波形 + 日志
#   bash teach/run.sh regress   # 编译 + 跑 7 个回归程序，检查自检 PASS
#   bash teach/run.sh all       # 两者都跑
#
# 产物：
#   teach/wave/<name>.vcd   讲解波形
#   teach/log/<name>.log    每个程序的完整日志（含自检结论）
#
# 说明：源码路径含空格，verilator 的 --Mdir 不能直接用，所以整体复制到
#       /tmp/v9teach（无空格）里编译运行，再把波形/日志拷回来。
# =============================================================================
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="${V9TEACH_BUILD:-/tmp/v9teach}"
OBJ="$BUILD/obj_dir"
mkdir -p "$DIR/wave" "$DIR/log"

sync_src() {
    mkdir -p "$BUILD"
    cp "$DIR"/rtl/*.sv "$BUILD"/
    cp "$DIR"/tb/tb_iverilog.sv "$BUILD"/
    cp "$DIR"/*.hex "$BUILD"/
}

build() {
    sync_src
    echo "[build] verilator 编译讲解版 RTL (在 $BUILD) ..."
    cd "$BUILD"
    verilator --binary --trace --timing \
        -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-WIDTH -Wno-fatal \
        -Wno-CASEINCOMPLETE -Wno-ASSIGNIN -Wno-DECLFILENAME -Wno-WIDTHEXPAND \
        --top-module tb_iverilog -o Vtb --Mdir obj_dir \
        *.sv
    echo "[build] done -> $OBJ/Vtb"
}

run() { # $1=名字 $2=hex文件 $3=prog_id
    local name="$1" hex="$2" pid="$3"
    if ( cd "$BUILD" && "$OBJ/Vtb" +prog="$hex" +prog_id="$pid" \
            +vcd="wave_$name.vcd" +max=4000 ) > "$DIR/log/$name.log" 2>&1; then
        echo "  PASS  $name"
    else
        echo "  FAIL  $name   (见 teach/log/$name.log)"
    fi
}

collect() {
    for f in "$BUILD"/wave_*.vcd; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"; cp "$f" "$DIR/wave/${b#wave_}"
    done
}

TEACH_PROGS="teach_alu teach_loaduse teach_branch teach_mul teach_div teach_mem
             teach_loop_alu teach_loop_loaduse teach_loop_mul teach_loop_div
             teach_mix"
REGRESS="prog:0 prog_mul:1 prog_div:2 prog_load_lane:3 prog_load_use:4 prog_loop:5 prog_div_pair:6"

do_teach() {
    echo "[teach] 讲解程序（prog_id=9，板级自检：write-once / fetch-align）"
    for n in $TEACH_PROGS; do run "$n" "$n.hex" 9; done
    collect
}
do_regress() {
    echo "[regress] 回归程序（prog_id=0..6，自检寄存器/内存期望值）"
    for pair in $REGRESS; do run "${pair%%:*}" "${pair%%:*}.hex" "${pair##*:}"; done
    collect
}

case "${1:-teach}" in
    build)   build ;;
    teach)   build; do_teach ;;
    regress) build; do_regress ;;
    all)     build; do_teach; do_regress ;;
    *) echo "用法: bash teach/run.sh [build|teach|regress|all]"; exit 1 ;;
esac
