# =============================================================================
# build_v9.tcl — 在 Vivado 2025.2 下非工程模式(pure Tcl)建 v9 工程并跑完整流程
# -----------------------------------------------------------------------------
# 用法（cmd / PowerShell）：
#   "D:\vivado\2025.2\Vivado\bin\vivado.bat" -mode batch -notrace ^
#       -source E:/FPGA/v9_vivado/build_v9.tcl -log build.log -journal build.jou
#
# 流程：create_project -> 加 RTL/约束 -> synth_design -> opt/place/route ->
#       report_timing_summary / report_utilization -> write_bitstream(可关)
#
# 顶层：board/board_top.sv    器件：xc7z020clg484-1    时钟：50MHz(20ns)
#
# 注意：
#   1) 器件 xc7z020clg484-1 属 Zynq-7000，本工程**不使用 PS**，只用 PL 逻辑；
#   2) 引脚约束尚未填写（见 v9_board.xdc 的 TODO 段），所以：
#      - place_design 可能因 IO 未分配而报错/降级；
#      - 因此默认【不生成 bitstream】。功能与时序都看过后，填好引脚再打开。
# =============================================================================

set WORK   "E:/FPGA/v9_vivado"
set PROJ   "$WORK/v9_board"
set OUT    "$WORK/reports"

set PART   "xc7z020clg484-1"
# 顶层为什么不是 board_top 而是 board_top_vivado：
#   board_top 直接引出 4 个 **32 位** 性能计数器，顶层端口共 201 个，
#   而 xc7z020clg484 封装只有 200 个可用 IO → 实现阶段报
#     ERROR: [Place 30-58] IO placement is infeasible.
#     Number of unplaced IO Ports (201) is greater than number of available pins (200).
#   board_top_vivado 把这 4 个计数器截成低 8 位引出，顶层降到 105 个端口；
#   debug_wb_* 五个关键信号保持全宽。board_top 本身未改动。
set TOP    "board_top_vivado"

# 是否生成 bitstream。引脚未约束 → 默认 0；填好 v9_board.xdc 的 TODO 后改 1。
set MAKE_BIT 0

# IROM 初值文件（绝对路径，避免综合时工作目录不确定导致 $readmemh 找不到）
set IROM_HEX "$WORK/prog.hex"

file mkdir $OUT

# ---------------------------------------------------------------- 1) 建工程
create_project -force v9_board $PROJ -part $PART
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# ---------------------------------------------------------------- 2) 加源文件
# 注意：**不要**加根目录的 MDU.sv！
#   EXU.sv 例化的是 MDU_pipelined（experimental/MDU_pipelined.sv）。
#   若同时加入 MDU.sv，综合会处理一个没人用的重复实现，白烧时间。
set RTL_SRC [list \
    "$WORK/src/myCPU.sv" \
    "$WORK/src/IFU.sv" \
    "$WORK/src/ICache.sv" \
    "$WORK/src/Branch_Predictor.sv" \
    "$WORK/src/IDU.sv" \
    "$WORK/src/Reg_Stack.sv" \
    "$WORK/src/RegisterFile.sv" \
    "$WORK/src/CSR.sv" \
    "$WORK/src/EXU.sv" \
    "$WORK/src/ALU.sv" \
    "$WORK/src/LSU.sv" \
    "$WORK/src/DCache.sv" \
    "$WORK/src/WBU.sv" \
    "$WORK/src/Data_hazard.sv" \
    "$WORK/src/Control.sv" \
    "$WORK/src/add.sv" \
    "$WORK/src/sext.sv" \
    "$WORK/src/Reg.sv" \
    "$WORK/src/MDU_pipelined.sv" \
    "$WORK/src/sync_mem.sv" \
    "$WORK/src/reset_sync.sv" \
    "$WORK/src/board_top.sv" \
    "$WORK/src/board_top_vivado.sv" \
]

foreach f $RTL_SRC {
    if {![file exists $f]} { error "missing RTL source: $f" }
}
add_files -norecurse $RTL_SRC

# para.sv 是 `include 的宏文件，不进文件列表，只加搜索路径
set_property include_dirs [list "$WORK/src"] [current_fileset]
add_files -fileset constrs_1 -norecurse "$WORK/v9_board.xdc"

# IROM 初值：board_top 的参数 IROM_INIT 默认是相对路径 "prog.hex"，
# 综合时工作目录不确定，这里显式覆盖成绝对路径。
set_property generic "IROM_INIT=$IROM_HEX" [current_fileset]
set_property top $TOP [current_fileset]
update_compile_order -fileset sources_1

puts "==> project created: $PROJ"
puts "==> top=$TOP part=$PART IROM_INIT=$IROM_HEX"

# ---------------------------------------------------------------- 3) 综合
synth_design -top $TOP -part $PART -include_dirs "$WORK/src"
write_checkpoint -force "$OUT/post_synth.dcp"
report_utilization        -file "$OUT/util_post_synth.rpt"
report_timing_summary     -file "$OUT/timing_post_synth.rpt" -delay_type max
puts "==> synthesis done"

# ---------------------------------------------------------------- 4) 实现
opt_design
place_design
phys_opt_design
route_design
puts "==> implementation done"

write_checkpoint -force "$OUT/post_route.dcp"
report_utilization     -file "$OUT/util_post_route.rpt"
report_timing_summary  -file "$OUT/timing_post_route.rpt"
report_timing -sort_by group -max_paths 20 -path_type summary \
              -file "$OUT/timing_worst_paths.rpt"
report_clock_utilization -file "$OUT/clock_util.rpt"
report_drc              -file "$OUT/drc.rpt"

if {$MAKE_BIT} {
    write_bitstream -force "$OUT/v9_board.bit"
    puts "==> bitstream written"
} else {
    puts "==> MAKE_BIT=0，跳过 write_bitstream（引脚未约束，见 v9_board.xdc）"
}

# ---------------------------------------------------------------- 5) 汇总
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "================================================================"
puts "RESULT top=$TOP part=$PART"
puts "RESULT WNS(setup) = $wns ns"
puts "RESULT WHS(hold)  = $whs ns"
puts "RESULT reports in $OUT"
puts "================================================================"
