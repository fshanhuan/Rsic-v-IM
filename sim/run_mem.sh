#!/usr/bin/env bash
# =============================================================================
# run_mem.sh — 「存储器专题」一键复现（Linux / WSL / Git-Bash）
#   1) 重新生成演示程序  2) 编译 board_top + tb_mem  3) 跑 4700 拍
#   4) 重算数字          5) 重画 8 张图
# 用法： bash sim/run_mem.sh            # 全跑
#        bash sim/run_mem.sh -figs      # 只重画图（沿用已有 CSV）
# 依赖： iverilog 12（-g2012）、python3（matplotlib）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONIOENCODING=utf-8
mkdir -p sim/build

RTL="board/board_top.sv board/sync_mem.sv board/sync_mem_dp.sv board/reset_sync.sv
     board/uart_tx.sv board/uart_rx.sv board/boot_loader.sv
     rtl/add.sv rtl/ALU.sv rtl/Branch_Predictor.sv rtl/Control.sv rtl/CSR.sv
     rtl/Data_hazard.sv rtl/DCache.sv rtl/EXU.sv rtl/ICache.sv rtl/IDU.sv
     rtl/IFU.sv rtl/LSU.sv rtl/MDU_pipelined.sv rtl/myCPU.sv rtl/Reg.sv
     rtl/RegisterFile.sv rtl/Reg_Stack.sv rtl/sext.sv rtl/WBU.sv"

if [ "${1:-}" != "-figs" ]; then
  echo "[1/5] 生成演示程序 sim/mem_demo.hex"
  python3 sim/gen_mem_demo.py | head -3

  echo "[2/5] 编译（iverilog）"
  iverilog -g2012 -I rtl -o sim/build/tb_mem.vvp $RTL sim/tb_mem.sv

  echo "[3/5] 仿真 4700 拍"
  vvp sim/build/tb_mem.vvp +stop=4700 +vcd=tb +wave=sim/build/mem_wave_long.vcd | tail -8
fi

echo "[4/5] 统计数字"
python3 sim/analyze_mem.py --json | tail -3

echo "[5/5] 重画图"
python3 sim/mem_wave.py
python3 sim/mem_map_fig.py

echo "完成。讲义：docs/存储器专题_研讨.docx（重新生成用 python3 docs/report_src/make_mem_doc.py）"
