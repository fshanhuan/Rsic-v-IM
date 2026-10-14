# =============================================================================
# make_gui_project.tcl — 用**标准工程流程**重建 ILA 工程（GUI 里能正常查看）
# -----------------------------------------------------------------------------
# 为什么要有这个脚本（上一版的教训）：
#   上一版用 create_project 建了工程之后，我直接用 **synth_design / place_design /
#   route_design 这些"非工程模式"命令**跑完了全流程。结果：
#     - E:\FPGA\v9_vivado_ila\reports\ 里有完整报告和 bit；
#     - 但工程目录下**根本没有 .runs / .srcs**，Design Runs 是空的，
#       在 Vivado GUI 里打开只能看到源文件，双击网表、Open Implemented Design、
#       看时序报告、Program Device 全都做不了 —— 就是"打开是黑的"。
#   本脚本改用**真正的工程流程**（launch_runs / wait_on_run），
#   让 synth_1 / impl_1 在磁盘上真实存在，GUI 才能正常用。
#
# 流程：create_project → 加源文件/约束 → 配置 run
#       → launch_runs synth_1（综合）
#       → 综合后插入 ILA（工程 run 的网表在内存里）
#       → launch_runs impl_1（实现）→ write_bitstream → 报告
#
# 用法：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado_ila/make_gui_project.tcl' -log gui_build.log -journal gui_build.jou
# =============================================================================

set WORK   "E:/FPGA/v9_vivado_ila"
set PROJ   "E:/FPGA/v9_vivado_ila/v9_ila_gui"
set OUT    "$WORK/gui_reports"

set PART   "xc7z020clg484-1"
set TOP    "board_top_ila"
set ILA_DEPTH 2048

file mkdir $OUT

# ---------------------------------------------------------------- 1) 建工程
create_project -force v9_ila_gui $PROJ -part $PART
# 注意：target_language 的**合法取值只有 Verilog / VHDL / Mixed**。
#   写成 SystemVerilog 会直接报
#     ERROR: [Common 17-162] Invalid option value specified for 'value'.
#   然后脚本静默中断（实测踩过）。.sv 的解析版本靠下面逐个文件的 file_type 指定。
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# ---------------------------------------------------------------- 2) 源文件
set RTL_SRC [list \
    "$WORK/src/myCPU.sv" \
    "$WORK/src/IFU.sv" \
    "$WORK/src/ICache.sv" \
    "$WORK/src/Branch_Predictor.sv" \
    "$WORK/src/IDU.sv" \
    "$WORK/src/Reg_Stack.sv" \
    "$WORK/src/RegisterFile.sv" \
    "$WORK/src/CSR.sv" \
    "$WORK/src/EXU.sv" \
    "$WORK/src/ALU.sv" \
    "$WORK/src/LSU.sv" \
    "$WORK/src/DCache.sv" \
    "$WORK/src/WBU.sv" \
    "$WORK/src/Data_hazard.sv" \
    "$WORK/src/Control.sv" \
    "$WORK/src/add.sv" \
    "$WORK/src/sext.sv" \
    "$WORK/src/Reg.sv" \
    "$WORK/src/MDU_pipelined.sv" \
    "$WORK/src/sync_mem.sv" \
    "$WORK/src/reset_sync.sv" \
    "$WORK/src/board_top.sv" \
    "$WORK/src/board_top_ila.sv" \
]
foreach f $RTL_SRC { if {![file exists $f]} { error "missing RTL source: $f" } }
add_files -norecurse $RTL_SRC

set_property include_dirs [list "$WORK/src"] [current_fileset]
add_files -fileset constrs_1 -norecurse "$WORK/v9_board_ila.xdc"
set_property generic "IROM_INIT=$WORK/prog.hex" [current_fileset]
set_property top $TOP [current_fileset]

# 把源文件显式标为 SystemVerilog。
# 为什么需要：工程综合 run 默认按工程属性里的 Verilog 版本解析，而 v9 全工程是
# SystemVerilog（always_ff / always_comb / logic / 自定义属性）。
# 实测 create_project 后直接 launch_runs 时，.sv 的解析版本可能落回 Verilog，
# 所以这里逐个文件设 file_type。
foreach f [get_files -of [get_filesets sources_1]] {
    if {[string equal -nocase [file extension $f] ".sv"]} {
        set_property file_type SystemVerilog $f
    }
}
update_compile_order -fileset sources_1
puts "==> project created: $PROJ (top=$TOP)"
puts "==> .sv files set to SystemVerilog: [llength [get_files -of [get_filesets sources_1] -filter {FILE_TYPE == SystemVerilog}]]"

# ---------------------------------------------------------------- 3) 配置 run
# 让综合 run 使用 SystemVerilog 解析（工程默认是 Verilog，.sv 会被当 Verilog 读，
#   虽然多数语法能过，但 board_top_ila 里的属性/结构体风险高，显式设成 SV 更稳）。
if {[llength [get_runs -quiet synth_1]] == 0} { create_run -flow Vivado Synthesis 2018 synth_1 }
set_property flow       "Vivado Synthesis 2018" [get_runs synth_1]
set_property is_enabled 1                       [get_runs synth_1]
set_property part       $PART                   [get_runs synth_1]
# 注意：run 对象上**没有** top / generic 属性（它们在 fileset 上，前面已经设过）。
#   写成 set_property top ... [get_runs synth_1] 会报
#     ERROR: [Common 17-54] The object 'run' does not have a property 'top'.

# ---------------------------------------------------------------- 4) 综合
puts "==> launching synth_1 ..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set s [get_property STATUS [get_runs synth_1]]
set p [get_property PROGRESS [get_runs synth_1]]
puts "==> synth_1 status=$s progress=$p"
if {$p ne "100%"} { error "synthesis did not finish: $s" }

# ---------------------------------------------------------------- 5) 插入 ILA
open_run synth_1
puts "==> opened synth_1 (in-memory netlist)"

create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH         $ILA_DEPTH [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES  1          [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL       1          [get_debug_cores u_ila_0]
# ALL_PROBE_SAME_MU_CNT 默认 1 会过不了 IP 校验（要求 2~16），必须显式设 2
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

# 网络名必须用折叠总线写法（综合后总线被拆成逐位网络）
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

connect_debug_port u_ila_0/clk [get_nets sys_clk_50m]

set i 0
foreach n $ILA_NETS {
    set hits [get_nets -quiet $n]
    if {[llength $hits] == 0} { error "ILA net missing: $n" }
    connect_debug_port u_ila_0/probe$i $hits
    puts "ILA_CONNECT probe$i <- $n ([llength $hits] bits)"
    incr i
}
implement_debug_core
puts "==> ILA connected + implemented ($i probes, depth=$ILA_DEPTH)"

# ---------------------------------------------------------------------------
# ★ 关键：把"已带 ILA 的设计"落盘，并让 impl_1 用这个检查点。
#
# 为什么不能在 close_design 之后直接 launch_runs impl_1：
#   ILA 是插在**内存里**当前打开的设计上的；一旦 close_design，
#   launch_runs impl_1 会**从磁盘上的 synth_1 检查点重新开始**，
#   那个检查点里没有 ILA → 实现和 bitstream 里都不会有 ILA，
#   而流程照样"成功"，只是上板抓不到任何波形（非常隐蔽的坑）。
#
# 做法：write_checkpoint 落盘 → 把它注册成一个新的 synthesis run
#   （is_synthesis=1，模仿 Synth 3-3 的标准做法）→ 把 impl_1 的
#   parent_run 指到它 → 这样工程流程（impl_1 run）用的就是带 ILA 的网表，
#   同时 GUI 里 Design Runs 完整可见。
# 写完检查点后要 close_design，否则 impl_1 启动会说设计已被占用。
# ---------------------------------------------------------------------------
set ILA_DCP "$OUT/board_top_ila_ila.dcp"
write_checkpoint -force $ILA_DCP
puts "==> checkpoint with ILA written: $ILA_DCP"
close_design

set ILA_RUN "synth_ila"
if {[llength [get_runs -quiet $ILA_RUN]] > 0} { delete_runs $ILA_RUN }
create_run -flow "Vivado Synthesis 2018" -parent_run synth_1 $ILA_RUN
set_property is_synthesis          1      [get_runs $ILA_RUN]
set_property is_enabled            1      [get_runs $ILA_RUN]
set_property part                  $PART  [get_runs $ILA_RUN]
set_property "top"                 $TOP   [get_runs $ILA_RUN]
catch {set_property "STEP.PLACE_DESIGN.ARGS.DIRECTIVE" "Default" [get_runs $ILA_RUN]}

# impl_1 改挂在带 ILA 的 run 下
set_property parent_run $ILA_RUN [get_runs impl_1]
puts "==> impl_1 parent_run = [get_property parent_run [get_runs impl_1]]"

# ---------------------------------------------------------------- 6) 实现
puts "==> launching impl_1 (with ILA) ..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set s [get_property STATUS [get_runs impl_1]]
set p [get_property PROGRESS [get_runs impl_1]]
puts "==> impl_1 status=$s progress=$p"
if {$p ne "100%"} { error "implementation did not finish: $s" }

# ---------------------------------------------------------------- 7) 报告 + ILA 自检
open_run impl_1
file mkdir $OUT
report_utilization       -file "$OUT/util_post_route.rpt"
report_timing_summary    -file "$OUT/timing_post_route.rpt"
report_timing -sort_by group -max_paths 20 -path_type summary -file "$OUT/timing_worst_paths.rpt"
report_drc               -file "$OUT/drc.rpt"
report_clock_utilization -file "$OUT/clock_util.rpt"
report_debug_core        -file "$OUT/debug_core.rpt"

# ★ 自动检测 ILA 到底有没有进到最终实现里 —— 不能只看流程"成功"
set cores [get_debug_cores -quiet]
puts "==> debug cores in impl_1: $cores"
if {[llength $cores] == 0} {
    puts "!! WARNING: impl_1 里没有任何 debug core —— ILA 在检查点交接时丢了。"
    puts "!! 回退方案：用 impl_ila.tcl 在内存里做实现（那条路已验证可用）。"
    set ILA_OK 0
} else {
    set ILA_OK 1
}

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
set bit [glob -nocomplain "$PROJ/v9_ila_gui.runs/impl_1/*.bit"]
puts "================================================================"
puts "RESULT project    = $PROJ/v9_ila_gui.xpr"
puts "RESULT top=$TOP part=$PART  ila_depth=$ILA_DEPTH"
puts "RESULT ILA_IN_IMPL= $ILA_OK   cores=[llength $cores]"
puts "RESULT WNS(setup) = $wns ns"
puts "RESULT WHS(hold)  = $whs ns"
puts "RESULT bitstream  = $bit"
puts "RESULT reports in $OUT"
puts "================================================================"
close_design
