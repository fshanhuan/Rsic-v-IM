# =============================================================================
# link_dcp_project.tcl — 兜底方案：把已有 checkpoint 链接进一个新工程
# -----------------------------------------------------------------------------
# 目的：让 GUI 一定能"看到东西"。把已经跑出来的
#   reports/post_synth.dcp、reports/post_route.dcp、reports/v9_ila.bit
# 作为 design source 链接进工程，这样在 Vivado 里：
#   - Sources 窗口能看到这两个 checkpoint；
#   - 双击 post_route.dcp 就能打开**已实现的设计**（看布局、看时序、看原理图）；
#   - reports/ 里的报告可以直接打开；
#   - Hardware Manager 可以烧 v9_ila.bit。
#
# 注意：这些是**链接**（不复制），源文件仍在 reports\ 下，别删。
#
# 用法：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado_ila/link_dcp_project.tcl' -log link.log -journal link.jou
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set PROJ "$WORK/v9_ila_checkpoints"

create_project -force v9_ila_checkpoints $PROJ -part xc7z020clg484-1
set_property target_language SystemVerilog [current_project]

# 链接 checkpoint（post-route 是含 ILA 的最终实现）
set dcps [list "$WORK/reports/post_synth.dcp" "$WORK/reports/post_route.dcp"]
foreach d $dcps {
    if {![file exists $d]} { error "missing checkpoint: $d" }
}
add_files -norecurse $dcps

# 也把 RTL 与约束链接进来，方便看源码和改
add_files -norecurse [glob "$WORK/src/*.sv"]
add_files -fileset constrs_1 -norecurse "$WORK/v9_board_ila.xdc"
set_property include_dirs [list "$WORK/src"] [current_fileset]
set_property top board_top_ila [current_fileset]
update_compile_order -fileset sources_1

puts "==> project created: $PROJ/v9_ila_checkpoints.xpr"
puts "==> linked: $dcps"
puts "==> bitstream (for Hardware Manager): $WORK/reports/v9_ila.bit"
close_project
