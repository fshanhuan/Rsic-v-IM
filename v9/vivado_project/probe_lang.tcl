# =============================================================================
# probe_lang.tcl — 探 target_language 到底接受什么值
# =============================================================================
set OUT "E:/FPGA/v9_vivado_ila/probe_lang.txt"
set fh [open $OUT w]
proc t {label script} {
    global fh
    if {[catch {uplevel 1 $script} r]} { puts $fh "FAIL  $label  -> $r" } else { puts $fh "ok    $label  => $r" }
}

create_project -force probe_lang E:/FPGA/v9_vivado_ila/probe_lang -part xc7z020clg484-1

t "list_property_value target_language" {list_property_value target_language [current_project]}
t "get target_language (default)"       {get_property target_language [current_project]}
t "set target_language Verilog"         {set_property target_language Verilog [current_project]}
t "set target_language Mixed"           {set_property target_language Mixed [current_project]}
t "set target_language VHDL"            {set_property target_language VHDL [current_project]}
t "set default_lib work"                {set_property default_lib work [current_project]}

# is_global_include / file_type 在普通文件上是否合法
add_files -norecurse "E:/FPGA/v9_vivado_ila/src/myCPU.sv"
t "file_type SystemVerilog"             {set_property file_type SystemVerilog [get_files "E:/FPGA/v9_vivado_ila/src/myCPU.sv"]}
t "is_global_include on .sv"            {set_property is_global_include 1 [get_files "E:/FPGA/v9_vivado_ila/src/myCPU.sv"]}
add_files -norecurse "E:/FPGA/v9_vivado_ila/gui_build/post_route_ila.dcp"
t "is_global_include on .dcp"           {set_property is_global_include 1 [get_files "E:/FPGA/v9_vivado_ila/gui_build/post_route_ila.dcp"]}
add_files -norecurse "E:/FPGA/v9_vivado_ila/gui_build/v9_ila.bit"
t "is_global_include on .bit"           {set_property is_global_include 1 [get_files "E:/FPGA/v9_vivado_ila/gui_build/v9_ila.bit"]}
t "add rpt to utils_1"                  {add_files -fileset utils_1 -norecurse [glob "E:/FPGA/v9_vivado_ila/gui_build/*.rpt"]}
t "create_run synth_1"                  {if {[llength [get_runs -quiet synth_1]]==0} {create_run -flow "Vivado Synthesis 2018" synth_1}; get_runs synth_1}
t "set part on run"                     {set_property part xc7z020clg484-1 [get_runs synth_1]}

close $fh
puts "WROTE $OUT"
set r [open $OUT r]; while {[gets $r l] >= 0} { puts $l }; close $r
