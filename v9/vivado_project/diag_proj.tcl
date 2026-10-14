# =============================================================================
# diag_proj.tcl — 诊断工程在 GUI 里能看到什么
# =============================================================================
set OUT "E:/FPGA/v9_vivado_ila/diag.txt"
open_project E:/FPGA/v9_vivado_ila/v9_ila/v9_ila.xpr

set fh [open $OUT w]
puts $fh "TOP            = [get_property top [current_fileset]]"
puts $fh "PART           = [get_property part [current_project]]"
puts $fh "FLOW           = [get_property flow [current_project]]"
puts $fh "SIM_TOP        = [get_property top [get_filesets sim_1]]"
puts $fh ""
puts $fh "FILESETS:"
foreach fs [get_filesets] { puts $fh "  $fs" }
puts $fh ""
puts $fh "SOURCE FILES ([llength [get_files -of [get_filesets sources_1]]]):"
foreach f [get_files -of [get_filesets sources_1]] { puts $fh "  $f" }
puts $fh ""
puts $fh "CONSTR FILES ([llength [get_files -of [get_filesets constrs_1]]]):"
foreach f [get_files -of [get_filesets constrs_1]] { puts $fh "  $f" }
puts $fh ""
puts $fh "RUNS ([llength [get_runs]]):"
foreach r [get_runs] {
    puts $fh "  $r  status=[get_property STATUS $r]  progress=[get_property PROGRESS $r]  steps=[get_property STEPS $r]"
}
puts $fh ""
puts $fh "DESIGN MODE / open design:"
puts $fh "  current_design = [expr {[catch {current_design} d] ? \"<none: $d>\" : $d}]"
close_project
close $fh
puts "WROTE $OUT"
set r [open $OUT r]; while {[gets $r l] >= 0} { puts $l }; close $r
