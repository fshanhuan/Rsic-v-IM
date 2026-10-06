#!/usr/bin/env bash
# =============================================================================
# run_wave.sh — 一条命令生成 v9 的流水线时序波形图（SVG + PNG）
# -----------------------------------------------------------------------------
# 前置条件：verilator（含 --binary/--trace/--timing 支持，5.x 即可）、python3、
#           可选 cairosvg（用于同时导出 PNG；没有也能出 SVG）。
# 用法：  cd v9/sim && ./run_wave.sh [程序名，默认 prog]
# =============================================================================
set -e
PROG="${1:-prog}"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d /tmp/v9wave.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

echo "[1/4] 复制源码到无空格构建目录: $BUILD"
cp "$DIR"/../*.sv "$BUILD"/
mkdir -p "$BUILD/sim"
cp "$DIR"/tb_wave.sv "$DIR"/prog*.hex "$DIR"/mkwave.py "$DIR"/vcd2svg.py "$BUILD/sim"/
sed -i "s/PROG_FILE = \"prog.hex\"/PROG_FILE = \"${PROG}.hex\"/" "$BUILD/sim/tb_wave.sv"

echo "[2/4] 编译仿真（verilator --binary --trace --timing）"
cd "$BUILD/sim"
verilator --binary --trace --timing -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-WIDTH \
    -I.. ../*.sv tb_wave.sv --top-module tb_wave > /dev/null

echo "[3/4] 跑仿真生成 VCD"
./obj_dir/Vtb_wave > /dev/null

echo "[4/4] 渲染波形"
mkdir -p "$DIR/../figures"
OUT="$DIR/../figures/v9_${PROG}_wave.svg"
python3 mkwave.py tb_wave.vcd "$OUT" 40 "BigBird v9 — ${PROG} 流水线时序图"
if python3 -c "import cairosvg" 2>/dev/null; then
    python3 -c "import cairosvg,sys; cairosvg.svg2png(url='$OUT', write_to='$OUT'.replace('.svg','.png'), scale=1.4, background_color='white')"
    echo "     PNG: ${OUT%.svg}.png"
fi
echo "     SVG: $OUT"
