# =============================================================================
# build_ila.tcl — v9 / EES-331 / ILA 版构建脚本（Vivado 2025.2 纯 Tcl）
# -----------------------------------------------------------------------------
# 流程：create_project → 加 RTL/约束 → synth_design → 核实调试网络 →
#       create_debug_core(ILA) → connect_debug_port → opt/place/route →
#       时序与资源报告 →（可选）write_bitstream
#
# 顶层 board_top_ila，器件 xc7z020clg484-1：
#   输入 100MHz(M19) --MMCM--> 50MHz 给 CPU；调试信号全部走 ILA，不占引脚。
#
# 用法：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado_ila/build_ila.tcl' -log build.log -journal build.jou
#
# 只查网络名 / 只综合：把 DO_IMPL 设 0；要出 bitstream：MAKE_BIT 设 1
#   （MAKE_BIT=1 需要先在 v9_board_ila.xdc 里给 debug_dead 指定一个空闲引脚，
#     否则 write_bitstream 会因 DRC UCIO-1/NSTD-1 失败。）
# =============================================================================

set WORK   "E:/FPGA/v9_vivado_ila"
set PROJ   "$WORK/v9_ila"
set OUT    "$WORK/reports"

set PART   "xc7z020clg484-1"
set TOP    "board_top_ila"

# 是否继续做实现（0 = 只综合并核对调试网络，用于快速确认 mark_debug 生效）
set DO_IMPL  1
# 是否生成 bitstream
set MAKE_BIT 0
# ILA 采样深度（每个探针的采样点数）
set ILA_DEPTH 2048

file mkdir $OUT

# ---------------------------------------------------------------- 1) 建工程
create_project -force v9_ila $PROJ -part $PART
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# ---------------------------------------------------------------- 2) 加源文件
# 不含根目录 MDU.sv（EXU 例化的是 MDU_pipelined）；不含 board_top_vivado.sv（上一版外壳）。
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
update_compile_order -fileset sources_1
puts "==> project created: $PROJ (top=$TOP, part=$PART)"

# ---------------------------------------------------------------- 3) 综合
synth_design -top $TOP -part $PART -include_dirs "$WORK/src"
write_checkpoint -force "$OUT/post_synth.dcp"
report_utilization    -file "$OUT/util_post_synth.rpt"
puts "==> synthesis done (checkpoint: $OUT/post_synth.dcp)"

# ------------------------------------------------- 4) 核实 ILA 要抓的网络是否还在
# 这一步是整条 ILA 流程的**关键护栏**：
#   如果 mark_debug/KEEP 没生效、或调试量没有真实负载，这些信号会被综合优化掉，
#   后面 connect_debug_port 就会失败（而且报错信息不直观）。所以先逐个核对。
#
# ★ 网络名必须写成 "名字[*]" 这种**折叠总线**形式：
#   综合后总线会被拆成逐位网络（debug_wb_pc[0] ... debug_wb_pc[31]），
#   用总线名 "u_board_top/u_cpu/debug_wb_pc" 直接 get_nets 是**找不到**的（实测踩过），
#   而 "debug_wb_pc[*]" 会一次返回全部 32 个位网络 —— 正好也是
#   connect_debug_port 需要的形式（多根网络 = 一根总线探针）。
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

set found {}
set missing {}
foreach n $ILA_NETS {
    set hits [get_nets -quiet $n]
    if {[llength $hits] == 0} {
        lappend missing $n
    } else {
        lappend found $n
        puts "ILA_NET_OK  $n  -> [llength $hits] net(s)"
    }
}
puts "ILA_NET_SUMMARY found=[llength $found] missing=[llength $missing]"
if {[llength $missing] > 0} {
    puts "ILA_NET_MISSING: $missing"
    error "debug nets missing (mark_debug/KEEP not effective, or nets optimized away)"
}
if {!$DO_IMPL} {
    puts "==> DO_IMPL=0, stopping after synthesis + net check"
    exit 0
}

# ---------------------------------------------------------------- 5) 插入 ILA
create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH      $ILA_DEPTH [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 1        [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL      1        [get_debug_cores u_ila_0]
# 不要显式开 C_ADV_TRIGGER，见 impl_ila.tcl 里的说明（会触发
# ALL_PROBE_SAME_MU_CNT 取值范围校验失败）。基础触发够用。

# probe0 由 create_debug_core 自动建好；probe1..probe12 必须显式 create_debug_port，
# 否则 get_debug_ports 找不到、set_property 报 [Common 17-55]。
set_property port_width 1 [get_debug_ports u_ila_0/probe0]
set rest_widths {32 1 5 32 32 32 32 32 32 32 32 1}
set i 1
foreach w $rest_widths {
    create_debug_port u_ila_0 probe
    set_property port_width $w [get_debug_ports u_ila_0/probe$i]
    incr i
}
set_property port_width 1 [get_debug_ports u_ila_0/clk]

# 采样时钟：必须用 CPU 真正在跑的 50MHz（MMCM 输出经 BUFG），不能用输入 100MHz。
#   实测该网络名为 sys_clk_50m（BUFG clk_bufg_inst 的输出）。
connect_debug_port u_ila_0/clk [get_nets sys_clk_50m]

set i 0
foreach n $ILA_NETS {
    connect_debug_port u_ila_0/probe$i [get_nets $n]
    puts "ILA_CONNECT  probe$i <- $n ([llength [get_nets $n]] bits)"
    incr i
}
puts "==> ILA connected: [llength $ILA_NETS] probes, depth=$ILA_DEPTH"

implement_debug_core
puts "==> debug core implemented"

# ---------------------------------------------------------------- 6) 实现
opt_design
place_design
phys_opt_design
route_design
puts "==> implementation done"

write_checkpoint -force "$OUT/post_route.dcp"
report_utilization       -file "$OUT/util_post_route.rpt"
report_timing_summary    -file "$OUT/timing_post_route.rpt"
report_timing -sort_by group -max_paths 20 -path_type summary -file "$OUT/timing_worst_paths.rpt"
report_drc               -file "$OUT/drc.rpt"
report_clock_utilization -file "$OUT/clock_util.rpt"
report_debug_core        -file "$OUT/debug_core.rpt"

if {$MAKE_BIT} {
    write_bitstream -force "$OUT/v9_ila.bit"
    puts "==> bitstream written: $OUT/v9_ila.bit"
} else {
    puts "==> MAKE_BIT=0，跳过 write_bitstream"
}

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "================================================================"
puts "RESULT top=$TOP part=$PART ila_depth=$ILA_DEPTH probes=[llength $ILA_NETS]"
puts "RESULT WNS(setup) = $wns ns  (CPU 时钟 50MHz = 20ns)"
puts "RESULT WHS(hold)  = $whs ns"
puts "RESULT Fmax_est   = [format %.2f [expr {1000.0/(20.0-$wns)}]] MHz"
puts "RESULT reports in $OUT"
puts "================================================================"
