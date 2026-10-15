# 验证工程在 GUI 里能不能正常"展开"：run 状态、源文件、IP、已实现设计
set PROJ "E:/FPGA/v9_vivado_ila/v9_ila/v9_ila.xpr"

open_project $PROJ
puts "==== 1) 工程基本信息 ===="
puts "  part        = [get_property part [current_project]]"
puts "  top         = [get_property top [current_fileset]]"
puts "  target_lang = [get_property target_language [current_project]]"
puts "  源文件总数  = [llength [get_files]]"

puts "==== 2) Design Runs（GUI 里 Design Runs 窗口的内容） ===="
foreach r [get_runs] {
    puts [format "  %-18s status=%-10s progress=%-6s part=%s" \
        $r [get_property STATUS $r] [get_property PROGRESS $r] [get_property part $r]]
}

puts "==== 3) IP 源（GUI 里 IP SOURCES 的内容） ===="
foreach ip [get_ips] {
    puts "  $ip  ->  [get_property IPDEF $ip]"
    puts "        probes = [get_property CONFIG.C_NUM_OF_PROBES $ip]  depth = [get_property CONFIG.C_DATA_DEPTH $ip]"
}

puts "==== 4) 约束文件 ===="
foreach f [get_files -of [get_filesets constrs_1]] { puts "  $f" }

puts "==== 5) 打开已实现设计（GUI 里 Open Implemented Design） ===="
open_run impl_1
puts "  cells      = [llength [get_cells -hier]]"
puts "  top ports  = [llength [get_ports]] -> [get_ports]"
puts "  debug cores= [get_debug_cores -quiet]"
foreach c [get_debug_cores -quiet] {
    set nports 0
    catch { set nports [llength [get_debug_ports $c]] }
    set isins "?"
    catch { set isins [get_property IS_INSERTED $c] }
    puts "     $c : ports=$nports inserted=$isins"
}

puts "==== 6) 布线后的时序（GUI 里 Report Timing Summary 的数） ===="
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "  WNS = $wns ns"
puts "  WHS = $whs ns"
set clk50 [get_clocks -quiet clk_sys_unbuf]
if {[llength $clk50]} {
    set pr [get_property PERIOD $clk50]
    puts "  clk_sys_unbuf: period=$pr ns  freq=[format %.3f [expr {1000.0/$pr}]] MHz"
    set p50 [get_timing_paths -delay_type max -from $clk50 -max_paths 1]
    if {[llength $p50]} {
        set s50 [get_property SLACK $p50]
        puts "  50MHz WNS = $s50 ns  ->  Fmax = [format %.2f [expr {1000.0/($pr - $s50)}]] MHz"
    }
}
set fail [get_timing_paths -delay_type max -max_paths 1 -slack_lesser_than 0]
puts "  建立时间违例路径存在 = [expr {[llength $fail] > 0}]"

puts "==== 7) ILA 探针是否连着真信号 ===="
foreach p {probe1 probe3 probe11 probe12} {
    set nets [get_nets -quiet -of_objects [get_pins -quiet "u_ila_0/$p*"]]
    puts "  $p : [llength $nets] net(s)"
}
close_project

puts "==== 8) 磁盘上的 run 产物 ===="
foreach f {
    "v9_ila.runs/synth_1/board_top_gui.dcp"
    "v9_ila.runs/synth_1/board_top_gui_utilization_synth.rpt"
    "v9_ila.runs/impl_1/board_top_gui_routed.dcp"
    "v9_ila.runs/impl_1/board_top_gui.bit"
    "v9_ila.runs/impl_1/board_top_gui.ltx"
    "v9_ila.runs/impl_1/board_top_gui_timing_summary_routed.rpt"
    "v9_ila.runs/impl_1/board_top_gui_utilization_placed.rpt"
    "v9_ila.runs/impl_1/board_top_gui_drc_routed.rpt"
} {
    set full "E:/FPGA/v9_vivado_ila/v9_ila/$f"
    if {[file exists $full]} {
        puts "  OK   [file tail $f]  ([expr {[file size $full]/1024}] KB)"
    } else {
        puts "  MISS $f"
    }
}
puts "VERIFY DONE"
