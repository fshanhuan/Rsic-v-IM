# =============================================================================
# BigBird v9 — 时序收敛扫描（Vivado 参考脚本）
# -----------------------------------------------------------------------------
# 用途：对同一份 RTL 依次尝试多个时钟周期，报告 WNS/TNS 与资源占用，
#       用于确定「这颗 CPU 在你的板卡/器件上能跑到多少 MHz」。
# 用法：vivado -mode batch -source syn/timing_sweep.tcl
#       请按实际修改 part 与源文件目录。
# =============================================================================
set part_name   "xc7a35tcpg236-1"     ;# 例：Basys3 的器件
set src_dir     "./"
set periods     {20.0 15.0 12.5 10.0 8.0}  ;# 50/66/80/100/125 MHz

create_project -force timing_sweep ./timing_sweep -part $part_name
add_files [glob -nocomplain $src_dir/*.sv $src_dir/*.v]
add_files -fileset constrs_1 ./syn/v9.xdc

foreach p $periods {
    puts "================ clock period = $p ns ================"
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {} -objects [get_runs synth_1]
    create_clock -period $p -name sys_clk [get_ports fpga_clk] -force
    reset_run impl_1
    launch_runs impl_1 -to_step route_design -jobs 4
    wait_on_run impl_1
    open_run impl_1
    report_timing_summary -file ./timing_sweep/report_${p}ns.rpt
    report_utilization   -file ./timing_sweep/util_${p}ns.rpt
    puts "WNS = [get_property SLACK [get_timing_paths -delay_type max]]"
}
