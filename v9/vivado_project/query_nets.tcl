# =============================================================================
# query_nets.tcl — 查综合后 DCP 里调试网络的**真实名字**
# -----------------------------------------------------------------------------
# 背景：build_ila.tcl 的网络核对按 "u_board_top/u_cpu/debug_wb_pc" 去 get_nets 找不到，
#   但综合日志又说 mark_debug 生效并 keep_hierarchy 了若干实例 —— 说明网络**存在**，
#   只是分层名不同（keep_hierarchy 会保留层级）。与其猜名字，不如直接把网表里
#   所有匹配的 net 全列出来，用真实名字去 connect_debug_port。
#
# 用法：
#   & vivado.bat -mode batch -notrace -source query_nets.tcl -log query.log
# =============================================================================
set DCP "E:/FPGA/v9_vivado_ila/reports/post_synth.dcp"
set OUT "E:/FPGA/v9_vivado_ila/net_names.txt"

open_checkpoint $DCP

set fh [open $OUT w]

puts $fh "===== nets matching *debug* ====="
foreach n [lsort [get_nets -hier -quiet *debug*]] { puts $fh $n }

puts $fh ""
puts $fh "===== nets matching *hit_cnt* / *miss_cnt* ====="
foreach n [lsort [get_nets -hier -quiet *hit_cnt*]]  { puts $fh $n }
foreach n [lsort [get_nets -hier -quiet *miss_cnt*]] { puts $fh $n }

puts $fh ""
puts $fh "===== MARK_DEBUG marked nets ====="
foreach n [lsort [get_nets -hier -quiet -filter {MARK_DEBUG == 1}]] { puts $fh $n }

puts $fh ""
puts $fh "===== user hierarchy cells ====="
foreach c [lsort [get_cells -hier -quiet -filter {IS_PRIMITIVE == 0}]] { puts $fh $c }

puts $fh ""
puts $fh "===== nets matching *clk* (lowercase) ====="
foreach n [lsort [get_nets -hier -quiet *clk*]] { puts $fh $n }

puts $fh ""
puts $fh "===== BUFG / MMCM cells ====="
foreach c [lsort [get_cells -hier -quiet -filter {REF_NAME =~ BUFG*}]] { puts $fh "BUFG  $c" }
foreach c [lsort [get_cells -hier -quiet -filter {REF_NAME =~ MMCM*}]] { puts $fh "MMCM  $c" }

close $fh
puts "WROTE $OUT"
