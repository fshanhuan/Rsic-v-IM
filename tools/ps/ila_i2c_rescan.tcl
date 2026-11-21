# =============================================================================
# ila_i2c_rescan.tcl —— 用"重扫"制造一段长时间的总线活动，同时抓波形
# -----------------------------------------------------------------------------
# 为什么要这样：adv7511_init 每 200 ms 才动 1 ms 左右，328 µs 的窗口撞上的概率只有
# ~0.16%。而 vio_rescan 会立刻让 i2c_probe 扫完 16 个地址（约 1.5 ms 连续活动），
# 所以：先武装 ILA（触发条件 = SCL 被拉低），再打重扫脉冲，必然抓到。
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
set CSV  "$WORK/_diag/ila_i2c_rescan.csv"
proc P {s} { puts "\[ILA2\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] { catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } } }
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
catch { refresh_hw_device -update_hw_probes true $dev }

set i2c ""
foreach i [get_hw_ilas -quiet] {
    if {[llength [get_hw_probes -of_objects $i]] == 8} { set i2c $i }
}
if {$i2c eq ""} { P "RESULT no_i2c_ila" ; exit 1 }

set tp ""
foreach q [get_hw_probes -of_objects $i2c] {
    if {[get_property NAME $q] eq "hdmi_scl_rd_1"} { set tp $q }
}
P "trigger probe: [get_property NAME $tp]"
set_property COMPARE_VALUE.0 "eq1'b0" $tp
catch { set_property CONTROL.TRIGGER_POSITION 32 $i2c }

# 1) 武装
catch { run_hw_ila $i2c }
P "armed"

# 2) 打重扫脉冲（VIO probe_out0 = vio_rescan）
set v [lindex [get_hw_vios -quiet] 0]
set pr ""
foreach q [get_hw_probes -of_objects $v] {
    if {[get_property NAME $q] eq "vio_rescan"} { set pr $q }
}
if {$pr ne ""} {
    set_property OUTPUT_VALUE 1 $pr ; commit_hw_vio $v
    after 30
    set_property OUTPUT_VALUE 0 $pr ; commit_hw_vio $v
    P "rescan pulsed"
} else {
    P "WARN: no vio_rescan probe"
}

after 800
catch { wait_on_hw_ila $i2c }
set data [upload_hw_ila_data $i2c]
if {[llength $data] == 0} { P "RESULT upload_failed" ; exit 1 }
catch { write_hw_ila_data -csv_file $CSV $data }
P "csv: $CSV"
P "RESULT ila_i2c_rescan_grabbed"
disconnect_hw_server
exit 0
