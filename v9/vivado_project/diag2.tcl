# =============================================================================
# diag2.tcl — 安全诊断（每条都防呆，一条失败不影响后面的）
# =============================================================================
set OUT "E:/FPGA/v9_vivado_ila/diag2.txt"
set fh [open $OUT w]

proc safe {label script} {
    global fh
    if {[catch {uplevel 1 $script} r]} {
        puts $fh "$label = <ERR> $r"
    } else {
        puts $fh "$label = $r"
    }
}

open_project E:/FPGA/v9_vivado_ila/v9_ila/v9_ila.xpr

safe "TOP"        {get_property top [current_fileset]}
safe "PART"       {get_property part [current_project]}
safe "PROJ_DIR"   {get_property DIRECTORY [current_project]}
safe "FILESETS"   {get_filesets}
safe "SOURCES"    {llength [get_files -of [get_filesets sources_1]]}
safe "CONSTRS"    {llength [get_files -of [get_filesets constrs_1]]}
safe "RUNS"       {get_runs}
safe "RUNS_N"     {llength [get_runs]}
safe "DIR_IN_SRC" {llength [get_property directory [get_filesets sources_1]]}

puts $fh ""
puts $fh "--- get_files sources_1 ---"
if {[catch {foreach f [get_files -of [get_filesets sources_1]] { puts $fh "  $f" }} e]} { puts $fh "  <ERR> $e" }
puts $fh "--- get_files constrs_1 ---"
if {[catch {foreach f [get_files -of [get_filesets constrs_1]] { puts $fh "  $f" }} e]} { puts $fh "  <ERR> $e" }

close_project
close $fh
puts "WROTE $OUT"
set r [open $OUT r]; while {[gets $r l] >= 0} { puts $l }; close $r
