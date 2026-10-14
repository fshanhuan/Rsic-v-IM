# =============================================================================
# rerun_impl.tcl — 只重跑实现阶段（不重综合），并让新增的复位 false_path 生效
# -----------------------------------------------------------------------------
# 为什么单独写一个：综合要 3.5 分钟且 RTL 没改，改的只是 xdc → 只需要从
# post_synth.dcp 重新 opt/place/route。
#
# 注意：xdc 不会自动重读，必须显式 read_xdc，否则新加的
#   set_false_path -from [get_cells ... reset_sync_inst/sync_ff2_reg ...]
# 不生效 —— 这是 Vivado 的常见坑。
#
# 用法：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado/rerun_impl.tcl' -log ... -journal ...
# =============================================================================

set WORK "E:/FPGA/v9_vivado"
set OUT  "$WORK/reports"
set PERIOD 20.000

file mkdir $OUT

# 从综合后的 checkpoint 起步（保留综合结果，只重做实现）
open_checkpoint "$OUT/post_synth.dcp"

# ---- 关键：重读 xdc，让新增的复位 false_path 生效 ----
read_xdc "$WORK/v9_board.xdc"
puts "==> xdc re-read"

opt_design
place_design
phys_opt_design
route_design
puts "==> implementation done"

write_checkpoint -force "$OUT/post_route.dcp"
report_utilization    -file "$OUT/util_post_route.rpt"
report_timing_summary -file "$OUT/timing_post_route.rpt"
report_timing -sort_by group -max_paths 20 -path_type summary -file "$OUT/timing_worst_paths.rpt"
report_drc            -file "$OUT/drc.rpt"
report_clock_utilization -file "$OUT/clock_util.rpt"

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "================================================================"
puts "RESULT WNS(setup) = $wns ns"
puts "RESULT WHS(hold)  = $whs ns"
puts "RESULT actual_max_path = [format %.3f [expr {$PERIOD - $wns}]] ns (period $PERIOD ns)"
puts "RESULT Fmax_est   = [format %.2f [expr {1000.0/($PERIOD - $wns)}]] MHz"
puts "================================================================"
