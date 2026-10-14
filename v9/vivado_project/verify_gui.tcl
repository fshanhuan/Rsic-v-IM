# =============================================================================
# verify_gui.tcl — 验证「GUI 打开后能看到什么」（每段都 flush，避免缓冲丢输出）
# =============================================================================
set OUT "E:/FPGA/v9_vivado_ila/verify_gui.txt"
set fh [open $OUT w]
proc p {msg} { global fh; puts $fh $msg; flush $fh }
proc t {label script} {
    if {[catch {uplevel 1 $script} r]} { p "FAIL  $label  -> $r" } else { p "ok    $label  => $r" }
}

t "open_project"  {open_project E:/FPGA/v9_vivado_ila/v9_ila_gui/v9_ila_gui.xpr}
t "top"           {get_property top [current_fileset]}
t "part"          {get_property part [current_project]}
t "runs"          {get_runs}
t "files total"   {llength [get_files]}

p ""
p "===== 工程里登记的文件 ====="
foreach f [lsort [get_files]] {
    if {[catch {get_property file_type $f} ft]} { set ft "?" }
    p "  \[$ft\] $f"
}
flush $fh

p ""
p "===== 后布线 checkpoint 能不能打开、里面有没有 ILA ====="
t "open_checkpoint"   {open_checkpoint E:/FPGA/v9_vivado_ila/gui_build/post_route_ila.dcp}
t "  debug cores"     {get_debug_cores -quiet}
t "  top ports"       {llength [get_ports]}
t "  cells"           {llength [get_cells -hier]}
t "  WNS"             {get_property SLACK [get_timing_paths -delay_type max]}
t "  WHS"             {get_property SLACK [get_timing_paths -delay_type min]}
t "  ILA probe count" {llength [get_debug_ports -quiet u_ila_0/*]}
t "  ILA nets"        {llength [get_nets -quiet -of [get_debug_ports -quiet u_ila_0/probe1]]}

close $fh
puts "WROTE $OUT"
