# =============================================================================
# verify_ila.tcl — 验证 ILA 工程是真的可用交付物
# -----------------------------------------------------------------------------
# 检查：工程能否打开、顶层/器件、源文件数、约束、以及 ILA 是否真的在网表里。
# =============================================================================
set OUT "E:/FPGA/v9_vivado_ila/verify_result.txt"
set fh [open $OUT w]

# ---- 1) 工程本身 ----
open_project E:/FPGA/v9_vivado_ila/v9_ila/v9_ila.xpr
puts $fh "PROJ_TOP     = [get_property top [current_fileset]]"
puts $fh "PROJ_PART    = [get_property part [current_project]]"
puts $fh "SRC_COUNT    = [llength [get_files -of [get_filesets sources_1]]]"
puts $fh "XDC_COUNT    = [llength [get_files -of [get_filesets constrs_1]]]"
puts $fh "GENERIC      = [get_property generic [current_fileset]]"
puts $fh "XDC_FILE     = [file tail [lindex [get_files -of [get_filesets constrs_1]] 0]]"
puts $fh "HAS_OLD_MDU  = [expr {[llength [get_files -quiet *MDU.sv]] > 0}]"
close_project

# ---- 2) 后布线 checkpoints 里的 ILA ----
open_checkpoint E:/FPGA/v9_vivado_ila/reports/post_route.dcp
set cores [get_debug_cores -quiet]
puts $fh ""
puts $fh "DEBUG_CORES  = $cores"
foreach c $cores {
    puts $fh "  core $c"
    set ports [get_debug_ports -quiet $c/*]
    puts $fh "    ports = [llength $ports]"
    foreach p [lsort $ports] {
        puts $fh "      $p width=[get_property port_width $p] nets=[llength [get_nets -quiet -of $p]]"
    }
}
puts $fh ""
puts $fh "TOP_PORTS    = [llength [get_ports]]"
foreach p [lsort [get_ports]] { puts $fh "  PORT $p" }
puts $fh "CELL_COUNT   = [llength [get_cells -hier]]"
puts $fh "NET_COUNT    = [llength [get_nets -hier]]"
close_design

close $fh
puts "WROTE $OUT"

set r [open $OUT r]
while {[gets $r line] >= 0} { puts $line }
close $r
