# =============================================================================
# ila_after_wake.tcl —— 先做手工"唤醒"（VIO 拉低两根线），再用 ILA 抓下一次尝试
# -----------------------------------------------------------------------------
# 已知：正常尝试的波形已经抓到 —— 地址 0x72 发送正确、100 kHz、第 9 拍从机**没有**
#       拉低 SDA（NACK）。
# 要回答：手工唤醒之后，第 9 拍会不会出现真正的 ACK？出现就说明"唤醒"是真的，
#       不出现就说明 init_done=1 是假的。
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
set CSV  "$WORK/_diag/ila_after_wake.csv"
proc P {s} { puts "\[AW\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] { catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } } }
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
catch { refresh_hw_device -update_hw_probes true $dev }

set v [lindex [get_hw_vios -quiet] 0]
foreach q [get_hw_probes -of_objects $v] { set N([get_property NAME $q]) $q }
set i2c ""
foreach i [get_hw_ilas -quiet] { if {[llength [get_hw_probes -of_objects $i]] == 8} { set i2c $i } }

# 1) 武装 ILA：busy 上升沿（下一次 FSM 尝试）
foreach q [get_hw_probes -of_objects $i2c] {
    if {[get_property NAME $q] eq "init_busy_1"} { set_property COMPARE_VALUE.0 "eq1'b1" $q }
}
catch { set_property CONTROL.TRIGGER_POSITION 64 $i2c }
catch { run_hw_ila $i2c }
P "armed"

# 2) 手工唤醒：两根按住 100 ms → 放开 SCL → 放开 SDA → 9 个 2 ms 慢时钟
proc wr {n val} { global N ; if {[info exists N($n)]} { set_property OUTPUT_VALUE $val $N($n) } }
wr vio_pull_scl 1 ; wr vio_pull_sda 1 ; commit_hw_vio $v
after 100
wr vio_pull_scl 0 ; commit_hw_vio $v
after 20
wr vio_pull_sda 0 ; commit_hw_vio $v
after 20
for {set i 0} {$i < 9} {incr i} {
    wr vio_pull_scl 1 ; commit_hw_vio $v ; after 2
    wr vio_pull_scl 0 ; commit_hw_vio $v ; after 2
}
wr vio_pull_scl 0 ; wr vio_pull_sda 0 ; commit_hw_vio $v
P "wake done"

# 3) 等 ILA 触发 + 上传
set ok 1
if {[catch { wait_on_hw_ila -timeout 3000 $i2c } e]} { set ok 0 ; P "wait: $e" }
P "triggered=$ok"
if {$ok} {
    set data [upload_hw_ila_data $i2c]
    catch { write_hw_ila_data -csv_file -force $CSV $data }
    P "csv: $CSV"
}
refresh_hw_vio $v
P [format "done=%d ack_err=%d" [get_property INPUT_VALUE $N(init_done)] [get_property INPUT_VALUE $N(init_ack_err)]]
P "RESULT after_wake_captured"
disconnect_hw_server
exit 0
