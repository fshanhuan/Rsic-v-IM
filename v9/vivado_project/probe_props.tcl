# =============================================================================
# probe_props.tcl — 查 debug core 到底暴露了哪些可设属性
# -----------------------------------------------------------------------------
# 背景：implement_debug_core 报
#   ERROR: [IP_Flow 19-3458] Validation failed for parameter
#     'All Probe Same Mu Cnt(ALL_PROBE_SAME_MU_CNT)' ... Value '1' is out of the range (2,16)
# 需要知道这个参数在 Tcl 里的**准确属性名**，才能显式设成合法值。
# =============================================================================
set OUT "E:/FPGA/v9_vivado_ila/probe_props.txt"
open_checkpoint "E:/FPGA/v9_vivado_ila/reports/post_synth.dcp"

create_debug_core u_ila_0 ila

set fh [open $OUT w]
puts $fh "===== list_property [get_debug_cores u_ila_0] ====="
foreach p [lsort [list_property [get_debug_cores u_ila_0]]] { puts $fh $p }

puts $fh ""
puts $fh "===== 当前值（含 MU / TRIGGER / DATA_DEPTH 的） ====="
foreach p [lsort [list_property [get_debug_cores u_ila_0]]] {
    if {[string match -nocase *MU* $p] || [string match -nocase *TRIG* $p] || [string match -nocase *DEPTH* $p]} {
        if {[catch {set v [get_property $p [get_debug_cores u_ila_0]]}]} { set v "<err>" }
        puts $fh "$p = $v"
    }
}
close $fh
puts "WROTE $OUT"
