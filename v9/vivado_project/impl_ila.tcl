# =============================================================================
# impl_ila.tcl — 从已有的综合 checkpoint 直接做「ILA 插入 + 实现」
# -----------------------------------------------------------------------------
# 为什么单独写一个：综合要 4 分钟，而 RTL 没改、只是要调整 ILA 连接/重新实现时，
# 没必要重跑综合。直接从 reports/post_synth.dcp 起步。
#
# 用法：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado_ila/impl_ila.tcl' -log impl.log -journal impl.jou
# =============================================================================

set WORK "E:/FPGA/v9_vivado_ila"
set OUT  "$WORK/reports"

# 是否生成 bitstream（1 = 出 bit，可以直接上板用 Hardware Manager 抓 ILA）
set MAKE_BIT 1
set ILA_DEPTH 2048

file mkdir $OUT
open_checkpoint "$OUT/post_synth.dcp"
puts "==> post_synth.dcp opened"

# ---- 调试网络（折叠总线写法，见 build_ila.tcl 的说明） ----
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

# ---- 插入 ILA，13 根探针 ----
# ★ 关键坑：create_debug_core 只会创建 clk + probe0 **一个**探针端口，
#   probe1..probe12 必须用 create_debug_port **逐个建出来**，位宽在创建时用 -width 指定。
#   实测若不建就直接 set_property port_width [get_debug_ports u_ila_0/probe1]，
#   会报：
#     WARNING: [Vivado 12-1423] No ChipScope debug ports matched 'u_ila_0/probe1'.
#     ERROR:   [Common 17-55] 'set_property' expects at least one object.
#   然后整个实现流程中止。
create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH         $ILA_DEPTH [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES  1          [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL       1          [get_debug_cores u_ila_0]
# ★ 必须显式给 ALL_PROBE_SAME_MU_CNT 一个合法值：它的默认值是 1，
#   而 IP 校验要求 [2,16]，于是 implement_debug_core 直接失败：
#     ERROR: [IP_Flow 19-3458] Validation failed for parameter
#       'All Probe Same Mu Cnt(ALL_PROBE_SAME_MU_CNT)' for IP 'u_ila_0'.
#       Value '1' is out of the range (2,16)
#   属性名就是 ALL_PROBE_SAME_MU_CNT（用 list_property [get_debug_cores u_ila_0] 查到）。
#   置 2 = 每个探针 2 个比较器（够用：既可比较"等于某值"，也可做边沿/区间触发）。
set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_0]
# ★ 不要再显式开 C_ADV_TRIGGER：实测开了之后 ILA 的
#   "All Probe Same Mu Cnt(ALL_PROBE_SAME_MU_CNT)" 会要求 2~16 的取值，
#   而默认值是 1，于是 IP 参数校验失败：
#     ERROR: [IP_Flow 19-3458] Validation failed for parameter
#       'All Probe Same Mu Cnt(ALL_PROBE_SAME_MU_CNT)' for IP 'u_ila_0'.
#       Value '1' is out of the range (2,16)
#     ERROR: [Chipscope 16-330] Synthesis of Debug Cores has failed
#   基础触发（basic trigger）对"抓写回序列 / 等 have_inst 上升沿"完全够用，
#   而且不用额外配 ALL_PROBE_SAME_MU_CNT，所以这里保持默认（不开高级触发）。

# probe0 由 create_debug_core 自动建好，先定它的位宽
set_property port_width 1 [get_debug_ports u_ila_0/probe0]
# 其余 12 根逐个创建
set rest_widths {32 1 5 32 32 32 32 32 32 32 32 1}
set i 1
foreach w $rest_widths {
    create_debug_port u_ila_0 probe
    set_property port_width $w [get_debug_ports u_ila_0/probe$i]
    incr i
}
set_property port_width 1 [get_debug_ports u_ila_0/clk]

# 采样时钟 = CPU 真正在跑的 50MHz（MMCM 输出经 BUFG）
connect_debug_port u_ila_0/clk [get_nets sys_clk_50m]

set i 0
foreach n $ILA_NETS {
    set hits [get_nets -quiet $n]
    if {[llength $hits] == 0} { error "ILA net missing: $n" }
    connect_debug_port u_ila_0/probe$i $hits
    puts "ILA_CONNECT  probe$i <- $n ([llength $hits] bits)"
    incr i
}
puts "==> ILA connected ($i probes, depth=$ILA_DEPTH)"

implement_debug_core
puts "==> debug core implemented"

# ---- 实现 ----
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
    puts "BITSTREAM: $OUT/v9_ila.bit"
} else {
    puts "==> MAKE_BIT=0, skipped write_bitstream"
}

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "================================================================"
puts "RESULT WNS(setup) = $wns ns   (CPU clock 50MHz = 20ns)"
puts "RESULT WHS(hold)  = $whs ns"
puts "RESULT Fmax_est   = [format %.2f [expr {1000.0/(20.0-$wns)}]] MHz"
puts "================================================================"
