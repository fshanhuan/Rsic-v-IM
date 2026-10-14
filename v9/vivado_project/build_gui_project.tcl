# =============================================================================
# build_gui_project.tcl — 一条命令做出「GUI 里能正常查看」的 ILA 工程
# -----------------------------------------------------------------------------
# 【上一版为什么在 GUI 里是黑的】
#   上一版用 create_project 建了工程，却直接用 **synth_design / place_design /
#   route_design 这些"非工程模式"命令**跑完全流程。于是磁盘上：
#     - E:\FPGA\v9_vivado_ila\reports\ 里有完整报告和 bit；
#     - 但工程下**没有 .runs / .srcs**，Design Runs 是空的，
#       GUI 里双击网表、Open Implemented Design、看时序报告全都做不了。
#   本脚本做两件事：
#     ① 在内存里完成「综合检查点 → 插 ILA → 实现 → 出 bit」（这条链路已验证可用）；
#     ② 用 Tcl 把 RTL、约束、run 和**已实现的设计 + bit + 各报告**全部登记进工程，
#        这样 GUI 里双击就能打开已实现设计、看报告、连 Hardware Manager。
#
# 用法：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado_ila/build_gui_project.tcl' -log gui_build.log -journal gui_build.jou
# =============================================================================

set WORK   "E:/FPGA/v9_vivado_ila"
set PROJ   "E:/FPGA/v9_vivado_ila/v9_ila_gui"
set OUT    "$WORK/gui_build"

set PART   "xc7z020clg484-1"
set TOP    "board_top_ila"
set ILA_DEPTH 2048

# 产物已存在时，跳过"内存实现"那 9 分钟，只重建工程。
#   （改工程登记方式时反复重跑很有用；要重新实现就把下面改成 1）
set REBUILD_IMPL 0

file mkdir $OUT

set HAVE_RESULT [expr {[file exists "$OUT/post_route_ila.dcp"] && [file exists "$OUT/v9_ila.bit"]}]

# =============================================================================
# 第 1 步：内存流程 —— 综合检查点 → ILA → 实现 → bit
# =============================================================================
if {$REBUILD_IMPL || !$HAVE_RESULT} {

open_checkpoint "$WORK/reports/post_synth.dcp"
puts "==> post_synth.dcp opened"

set ILA_NETS [list \
    u_board_top/u_cpu/debug_wb_have_inst \
    u_board_top/u_cpu/debug_wb_pc[*] \
    u_board_top/u_cpu/debug_wb_ena \
    u_board_top/u_cpu/debug_wb_reg[*] \
    u_board_top/u_cpu/debug_wb_value[*] \
    u_board_top/u_cpu/debug_icache_hit_cnt[*] \
    u_board_top/u_cpu/debug_icache_miss_cnt[*] \
    u_board_top/u_cpu/debug_dcache_hit_cnt[*] \
    u_board_top/u_cpu/debug_dcache_miss_cnt[*] \
    u_board_top/u_cpu/debug_mcause[*] \
    u_board_top/u_cpu/debug_mepc[*] \
    u_board_top/u_cpu/debug_mtval[*] \
    u_board_top/u_cpu/debug_trap_take \
]

create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH         $ILA_DEPTH [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES  1          [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL       1          [get_debug_cores u_ila_0]
# ALL_PROBE_SAME_MU_CNT 默认 1 过不了 IP 校验（要求 2~16），必须显式设
set_property ALL_PROBE_SAME_MU_CNT 2         [get_debug_cores u_ila_0]

set_property port_width 1 [get_debug_ports u_ila_0/probe0]
set rest_widths {32 1 5 32 32 32 32 32 32 32 32 1}
set i 1
foreach w $rest_widths {
    create_debug_port u_ila_0 probe
    set_property port_width $w [get_debug_ports u_ila_0/probe$i]
    incr i
}
set_property port_width 1 [get_debug_ports u_ila_0/clk]

connect_debug_port u_ila_0/clk [get_nets sys_clk_50m]
set i 0
foreach n $ILA_NETS {
    set hits [get_nets -quiet $n]
    if {[llength $hits] == 0} { error "ILA net missing: $n" }
    connect_debug_port u_ila_0/probe$i $hits
    incr i
}
implement_debug_core
puts "==> ILA inserted ($i probes, depth=$ILA_DEPTH)"

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force "$OUT/post_route_ila.dcp"
write_bitstream   -force "$OUT/v9_ila.bit"

set cores [get_debug_cores -quiet]
if {[llength $cores] == 0} { error "ILA 丢失：实现后没有 debug core" }
puts "==> implementation done, debug cores: $cores"

report_utilization       -file "$OUT/util_post_route.rpt"
report_timing_summary    -file "$OUT/timing_post_route.rpt"
report_timing -sort_by group -max_paths 20 -path_type summary -file "$OUT/timing_worst_paths.rpt"
report_drc               -file "$OUT/drc.rpt"
report_clock_utilization -file "$OUT/clock_util.rpt"
report_debug_core        -file "$OUT/debug_core.rpt"

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "RESULT_WNS=$wns"
puts "RESULT_WHS=$whs"
close_design

} else {
    puts "==> 复用已有实现结果（REBUILD_IMPL=0 且产物存在），跳过内存实现"
    set wns "n/a"
    set whs "n/a"
}

# =============================================================================
# 第 2 步：建工程并把结果登记进去（GUI 可查看）
# =============================================================================
create_project -force v9_ila_gui $PROJ -part $PART
# ★ target_language 的合法取值**只有 VHDL / Verilog 两个**：
#     list_property_value target_language [current_project]  =>  VHDL Verilog
#   写 Mixed 或 SystemVerilog 都会报
#     ERROR: [Common 17-162] Invalid option value specified for 'value'.
#   然后脚本静默中断（实测反复踩到）。.sv 的解析版本靠下面逐个文件的 file_type 指定。
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

set RTL_SRC [list \
    "$WORK/src/myCPU.sv" "$WORK/src/IFU.sv" "$WORK/src/ICache.sv" \
    "$WORK/src/Branch_Predictor.sv" "$WORK/src/IDU.sv" "$WORK/src/Reg_Stack.sv" \
    "$WORK/src/RegisterFile.sv" "$WORK/src/CSR.sv" "$WORK/src/EXU.sv" \
    "$WORK/src/ALU.sv" "$WORK/src/LSU.sv" "$WORK/src/DCache.sv" \
    "$WORK/src/WBU.sv" "$WORK/src/Data_hazard.sv" "$WORK/src/Control.sv" \
    "$WORK/src/add.sv" "$WORK/src/sext.sv" "$WORK/src/Reg.sv" \
    "$WORK/src/MDU_pipelined.sv" "$WORK/src/sync_mem.sv" \
    "$WORK/src/reset_sync.sv" "$WORK/src/board_top.sv" \
    "$WORK/src/board_top_ila.sv" \
]
foreach f $RTL_SRC { if {![file exists $f]} { error "missing RTL source: $f" } }
add_files -norecurse $RTL_SRC
set_property include_dirs [list "$WORK/src"] [current_fileset]
add_files -fileset constrs_1 -norecurse "$WORK/v9_board_ila.xdc"
set_property generic "IROM_INIT=$WORK/prog.hex" [current_fileset]
set_property top $TOP [current_fileset]
# 逐个把 .sv 标成 SystemVerilog（工程默认按 Verilog 解析 .sv，风险高）
foreach f [get_files -of [get_filesets sources_1]] {
    if {[string equal -nocase [file extension $f] ".sv"]} {
        set_property file_type SystemVerilog $f
    }
}
update_compile_order -fileset sources_1

# ---- 把「已实现的设计 + bit」登记进工程，这样 GUI 里能直接双击打开 ----
# 用 is_global_include 让它们作为全局设计源出现在 Sources 窗口
add_files -norecurse [list "$OUT/post_route_ila.dcp"]
set_property is_global_include 1 [get_files "$OUT/post_route_ila.dcp"]
# bit 也挂上（Hardware Manager 里可以直接选它）
add_files -norecurse [list "$OUT/v9_ila.bit"]
set_property is_global_include 1 [get_files "$OUT/v9_ila.bit"]

# ---- 报告也登记进工程（GUI 的 Reports 里可打开） ----
set rpts [glob "$OUT/*.rpt"]
add_files -fileset utils_1 -norecurse $rpts

# ---- 建综合 run 并注册进工程（想从 GUI 重新综合时用） ----
# 注意：run 对象上只有 flow / part / parent_run / steps 等属性；
#   `is_enabled` 不存在（会报 [Common 17-54] The object 'run' does not have a property 'is_enabled'），
#   新建的 run 默认就是 enabled，不用设。
if {[llength [get_runs -quiet synth_1]] == 0} { create_run -flow "Vivado Synthesis 2018" synth_1 }
set_property part $PART [get_runs synth_1]

puts "================================================================"
puts "RESULT project    = $PROJ/v9_ila_gui.xpr"
puts "RESULT post-route = $OUT/post_route_ila.dcp"
puts "RESULT bitstream  = $OUT/v9_ila.bit"
puts "RESULT reports    = $OUT/*.rpt"
puts "RESULT WNS=$wns  WHS=$whs"
if {[info exists cores]} { puts "RESULT debug cores = $cores" }
puts "RESULT files in project: [llength [get_files]]"
puts "================================================================"
close_project
