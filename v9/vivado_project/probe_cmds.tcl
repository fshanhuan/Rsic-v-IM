# =============================================================================
# probe_cmds.tcl — 逐条试命令，找出 [Common 17-162] Invalid option value 是哪一条
# =============================================================================
set OUT "E:/FPGA/v9_vivado_ila/probe_cmds.txt"
set fh [open $OUT w]
proc t {label script} {
    global fh
    if {[catch {uplevel 1 $script} r]} {
        puts $fh "FAIL  $label\n        -> $r"
    } else {
        puts $fh "ok    $label   => $r"
    }
}
set WORK "E:/FPGA/v9_vivado_ila"
set PROJ "$WORK/probe_proj"

t "create_project"              {create_project -force probe_proj $PROJ -part xc7z020clg484-1}
t "target_language SystemVerilog" {set_property target_language SystemVerilog [current_project]}
t "target_language Verilog"     {set_property target_language Verilog [current_project]}
t "default_lib work"            {set_property default_lib work [current_project]}
t "add_files rtl"               {add_files -norecurse [glob "$WORK/src/*.sv"]}
t "include_dirs"                {set_property include_dirs [list "$WORK/src"] [current_fileset]}
t "generic"                     {set_property generic "IROM_INIT=$WORK/prog.hex" [current_fileset]}
t "top"                         {set_property top board_top_ila [current_fileset]}
t "file_type SystemVerilog x1"  {set_property file_type SystemVerilog [lindex [get_files -of [get_filesets sources_1]] 0]}
t "count SV files"              {llength [get_files -of [get_filesets sources_1] -filter {FILE_TYPE == SystemVerilog}]}
t "update_compile_order"        {update_compile_order -fileset sources_1}
t "get_runs synth_1"            {get_runs synth_1}
t "flow prop"                   {set_property flow "Vivado Synthesis 2018" [get_runs synth_1]}
t "top on run"                  {set_property top board_top_ila [get_runs synth_1]}
t "part on run"                 {set_property part xc7z020clg484-1 [get_runs synth_1]}
t "generic on run"              {set_property generic "IROM_INIT=$WORK/prog.hex" [get_runs synth_1]}
t "add dcp"                     {add_files -norecurse [list "$WORK/reports/post_synth.dcp" "$WORK/reports/post_route.dcp"]}
t "add xdc"                     {add_files -fileset constrs_1 -norecurse "$WORK/v9_board_ila.xdc"}

close $fh
puts "WROTE $OUT"
set r [open $OUT r]; while {[gets $r l] >= 0} { puts $l }; close $r
