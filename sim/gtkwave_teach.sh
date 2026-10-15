#!/usr/bin/env bash
# =============================================================================
# gtkwave_teach.sh — 用 GTKWave 打开「上台讲解」波形（自动带好信号和分组）
# -----------------------------------------------------------------------------
# 用法：
#   bash sim/gtkwave_teach.sh              # 默认打开 teach_alu
#   bash sim/gtkwave_teach.sh teach_div    # 打开某个讲解波形（可带/不带 .gtkw）
#   bash sim/gtkwave_teach.sh tb_iverilog_prog
#
# 说明：
#   - .gtkw 会话文件与 .vcd 都在 v9/wave/ 下，这里先 cd 到 wave/ 再启动，
#     因为 GTKWave 的 [dumpfile] 相对路径是相对**当前目录**解析的。
#   - 会话里已经按 CLK / IF / ID / EX / MEM / WB / CTRL / REGS / CSR 分好组，
#     总线默认十六进制显示（@23），单比特为波形（@28）。
# =============================================================================
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
WAVE="$DIR/../wave"
NAME="${1:-teach_alu}"
NAME="${NAME%.gtkw}"

if [ ! -f "$WAVE/$NAME.gtkw" ]; then
    echo "找不到 $WAVE/$NAME.gtkw"
    echo "可用的讲解波形："
    for f in "$WAVE"/teach_*.gtkw "$WAVE"/tb_iverilog_prog.gtkw; do
        [ -e "$f" ] || continue
        echo "  $(basename "$f" .gtkw)"
    done
    exit 1
fi

cd "$WAVE"
echo "GTKWave: $WAVE/$NAME.gtkw"
exec gtkwave "$NAME.gtkw"
