# =============================================================================
# build_project_ila.tcl — 生成「GUI 里全流程可见」的 v9 ILA 工程（工程模式）
# -----------------------------------------------------------------------------
# 和前两版的根本区别：
#   * 第 1 版 v9_vivado    ：非工程模式，顶层做引脚截断。已删。
#   * 第 2 版 v9_ila_gui   ：工程只是"壳"，设计靠 create_debug_core 在内存里
#                            做完再挂检查点上去 → 磁盘上没有 .runs/.srcs，
#                            GUI 里 Design Runs 全灰、点不动。
#   * 本版 v9_ila          ：ILA 是**标准 IP 例化**，synth_1 / impl_1 都是
#                            真实的 run，工程模式下把流程完整跑一遍。
#
# 用法（约 20~40 分钟，建议后台跑）：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado_ila/build_project_ila.tcl' `
#       -log 'E:/FPGA/v9_vivado_ila/build_project_ila.log'
#
# 开关：
#   DO_SYNTH = 1  重建工程并重跑综合；= 0 保留已有工程和 synth_1，直接进实现
#   DO_IMPL  = 1  一路跑到 bitstream；= 0 只到综合（调 RTL 时用，省时间）
# =============================================================================

set WORK  "E:/FPGA/v9_vivado_ila"
set PROJ  "E:/FPGA/v9_vivado_ila/v9_ila"
set SRC   "$WORK/src"
set WSRC  "E:/share doc/v9"

set PART       "xc7z020clg484-1"
set TOP        "board_top_gui"
set ILA_DEPTH  2048
set ILA_PROBES {1 32 1 5 32 32 32 32 32 32 32 32 1}

set DO_SYNTH 1       ;# 0 = 保留已完成的 synth_1，直接进实现
set DO_IMPL  1       ;# 0 = 只建工程 + 综合；1 = 一路跑到 bitstream

# =============================================================================
# 0) 目录准备
#    DO_SYNTH=1 时整工程重建（干净）；DO_SYNTH=0 时保留已有工程和
#    synth_1 结果，只重跑实现 —— 调实现阶段时用这个，省一次综合。
# =============================================================================
if {$DO_SYNTH} { file delete -force $PROJ }
file mkdir "$WORK/project_src"

# prog.hex 放到工程目录里，让 IROM_INIT 用相对路径（工程自包含、可搬走）
file copy -force "$WORK/prog.hex" "$WORK/project_src/prog.hex"

# src/board_top_ila.sv 每次都从权威源码目录同步过来
# （E:\share doc\v9\board\board_top_ila.sv 是唯一权威版本，改了必须同步）
file copy -force "$WSRC/board/board_top_ila.sv" "$SRC/board_top_ila.sv"

# =============================================================================
# 1) 建工程
# =============================================================================
create_project -force v9_ila $PROJ -part $PART
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# =============================================================================
# 2) 加 RTL
#    刻意逐个列出，不把 src 整个目录丢进去，免得杂文件混进来。
# =============================================================================
set RTL_SRC [list \
    "$SRC/myCPU.sv" "$SRC/IFU.sv" "$SRC/ICache.sv" \
    "$SRC/Branch_Predictor.sv" "$SRC/IDU.sv" "$SRC/Reg_Stack.sv" \
    "$SRC/RegisterFile.sv" "$SRC/CSR.sv" "$SRC/EXU.sv" \
    "$SRC/ALU.sv" "$SRC/LSU.sv" "$SRC/DCache.sv" \
    "$SRC/WBU.sv" "$SRC/Data_hazard.sv" "$SRC/Control.sv" \
    "$SRC/add.sv" "$SRC/sext.sv" "$SRC/Reg.sv" \
    "$SRC/MDU_pipelined.sv" "$SRC/sync_mem.sv" \
    "$SRC/reset_sync.sv" "$SRC/board_top.sv" \
    "$SRC/board_top_ila.sv" \
    "$WORK/project_src/board_top_gui.sv" \
]
foreach f $RTL_SRC { if {![file exists $f]} { error "缺 RTL 源文件: $f" } }

add_files -norecurse $RTL_SRC
add_files -norecurse [list "$WORK/project_src/prog.hex"]

# include 路径：para.sv 在 src 下，用 `include "para.sv"` 引用
set_property include_dirs [list $SRC "$WORK/project_src"] [current_fileset]
catch { set_property file_type {Memory Initialization Files} [get_files "$WORK/project_src/prog.hex"] }

# .sv 必须逐个标成 SystemVerilog（工程默认按 Verilog 解析 .sv，接口会解析错）
foreach f [get_files -of [get_filesets sources_1]] {
    if {[string equal -nocase [file extension $f] ".sv"]} {
        set_property file_type SystemVerilog $f
    }
}

set_property top $TOP [current_fileset]

# =============================================================================
# 3) 加约束
# =============================================================================
add_files -fileset constrs_1 -norecurse "$WORK/v9_board_ila.xdc"

# =============================================================================
# 4) 例化并配置 ILA IP
#    ★ 顺序很重要：先 C_NUM_OF_PROBES，再逐个 C_PROBEn_WIDTH。
#    ★ create_ip 默认不加 -force，重复建同名 IP 会报错，所以先判断一下。
# =============================================================================
if {[llength [get_ips -quiet u_ila_0]] == 0} {
    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name u_ila_0
}
set ip [get_ips u_ila_0]

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES       13 \
    CONFIG.C_DATA_DEPTH          $ILA_DEPTH \
    CONFIG.C_INPUT_PIPE_STAGES   1 \
    CONFIG.C_EN_STRG_QUAL        1 \
    CONFIG.C_ADV_TRIGGER         false \
    CONFIG.ALL_PROBE_SAME_MU_CNT 2 \
] $ip

set i 0
foreach w $ILA_PROBES {
    set_property CONFIG.C_PROBE${i}_WIDTH $w $ip
    incr i
}
puts "==> ILA IP 配置完成：13 个 probe，宽度 {$ILA_PROBES}，深度 $ILA_DEPTH"

generate_target all $ip
puts "==> ILA IP 输出已生成"

# 例化模板留一份，方便对照端口名
set veo [glob -nocomplain "$PROJ/v9_ila.gen/sources_1/ip/u_ila_0/u_ila_0.veo"]
if {[llength $veo]} { file copy -force [lindex $veo 0] "$WORK/project_src/u_ila_0.veo.template" }

update_compile_order -fileset sources_1

# 打一份源文件清单，方便 GUI 里核对
puts "---- 工程源文件清单 ----"
foreach f [get_files -of [get_filesets sources_1]] { puts "  SRC  [file tail $f]" }
foreach f [get_files -of [get_filesets constrs_1]] { puts "  XDC  [file tail $f]" }
puts "  TOP  = [get_property top [current_fileset]]"
puts "  PART = [get_property part [current_project]]"

catch { set_property target_simulator XSim [current_project] }

# =============================================================================
# 5) 跑流程：synth_1 → impl_1
# =============================================================================
if {$DO_SYNTH} {
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
} else {
    puts "==> DO_SYNTH=0，复用已有 synth_1"
}

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "综合失败：PROGRESS=[get_property PROGRESS [get_runs synth_1]]  STATUS=[get_property STATUS [get_runs synth_1]]"
}
puts "==> 综合完成"

open_run synth_1 -name synth_1
report_utilization -file "$WORK/project_src/util_post_synth.rpt"
report_debug_core  -file "$WORK/project_src/debug_core_post_synth.rpt"
# ILA 有没有真的挂进设计，在综合这一步就能确认
puts "RESULT synth_debug_cores = [get_debug_cores -quiet]"
close_design

if {$DO_IMPL} {
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1

    if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
        error "实现失败：PROGRESS=[get_property PROGRESS [get_runs impl_1]]  STATUS=[get_property STATUS [get_runs impl_1]]"
    }
    puts "==> 实现 + bitstream 完成"

    open_run impl_1
    report_utilization        -file "$WORK/project_src/util_post_route.rpt"
    report_timing_summary     -file "$WORK/project_src/timing_post_route.rpt"
    report_timing -sort_by group -max_paths 20 -path_type summary \
                  -file "$WORK/project_src/timing_worst_paths.rpt"
    report_drc                -file "$WORK/project_src/drc.rpt"
    report_clock_utilization  -file "$WORK/project_src/clock_util.rpt"
    report_debug_core         -file "$WORK/project_src/debug_core_post_route.rpt"

    puts "RESULT debug_cores = [get_debug_cores -quiet]"

    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    set whs [get_property SLACK [get_timing_paths -delay_type min]]
    puts "RESULT WNS = $wns ns"
    puts "RESULT WHS = $whs ns"

    # 50MHz 时钟自己的 WNS —— 本次验证最关心的数
    set p [get_timing_paths -delay_type max -from [get_clocks clk_sys_unbuf] -max_paths 1]
    if {[llength $p]} { puts "RESULT 50MHz WNS = [get_property SLACK $p] ns" }

    # 是否存在建立时间违例路径
    set tp [get_timing_paths -delay_type max -max_paths 1 -slack_lesser_than 0]
    puts "RESULT setup_failing_paths_exist = [expr {[llength $tp] > 0}]"

    report_timing_summary -no_header -no_detailed_paths \
                          -file "$WORK/project_src/ts_brief.rpt"
    close_design
}

puts "================================================================"
puts "RESULT xpr   = $PROJ/v9_ila.xpr"
puts "RESULT bit   = $PROJ/v9_ila.runs/impl_1/board_top_gui.bit"
puts "RESULT ltx   = $PROJ/v9_ila.runs/impl_1/board_top_gui.ltx"
puts "RESULT files = [llength [get_files]]"
puts "RESULT runs  = [get_runs]"
puts "RESULT build OK"
puts "================================================================"

close_project
