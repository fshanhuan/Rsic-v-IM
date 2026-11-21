# =============================================================================
# ila_read_txn.tcl —— 抓"读寄存器"那一段总线（判断读回 0x00 是真是假）
# -----------------------------------------------------------------------------
# 现在读回 0x00/0x41/0x42/0x16 全是 0x00，而 ok=1。两种可能：
#   (a) 芯片真的返回 0（ID 读 0 不合理）；
#   (b) 读的时候 SDA 一直被拉低 —— 那么 ACK 也全"="有"，读出来的位全 0。
# 用 ILA 看 SCL/SDA 的真实波形就能分开：
#   触发 init_done = 1（读完紧接着开始），窗口 328 µs 足够覆盖一次读事务。
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
set CSV  "$WORK/_diag/ila_read.csv"
proc P {s} { puts "\[IR\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] { catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } } }
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
catch { refresh_hw_device -update_hw_probes true $dev }

set i2c ""
foreach i [get_hw_ilas -quiet] { if {[llength [get_hw_probes -of_objects $i]] == 8} { set i2c $i } }
if {$i2c eq ""} { P "RESULT no_i2c_ila" ; exit 1 }

foreach q [get_hw_probes -of_objects $i2c] {
    if {[get_property NAME $q] eq "init_done_1"} { set_property COMPARE_VALUE.0 "eq1'b1" $q }
}
catch { set_property CONTROL.TRIGGER_POSITION 128 $i2c }
catch { run_hw_ila $i2c }
P "armed on init_done==1"

set v [lindex [get_hw_vios -quiet] 0]
array set N {}
foreach q [get_hw_probes -of_objects $v] { set N([get_property NAME $q]) $q }
proc wr {n val} { global N ; if {[info exists N($n)]} { set_property OUTPUT_VALUE $val $N($n) } }
proc rd {n} { global N ; if {![info exists N($n)]} { return -1 } ; set h 0 ; catch { set h [get_property INPUT_VALUE $N($n)] } ; set x 0 ; catch { scan $h %x x } ; return $x }

refresh_hw_vio $v
if {[rd init_done] != 1} {
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
    P "wake pulsed"
}
set ok 1
if {[catch { wait_on_hw_ila -timeout 3000 $i2c } e]} { set ok 0 ; P "wait: $e" }
P "triggered=$ok"
if {$ok} {
    set data [upload_hw_ila_data $i2c]
    catch { write_hw_ila_data -csv_file -force $CSV $data }
    P "csv: $CSV"
}
after 2500
refresh_hw_vio $v
P [format "after: done=%d regs d0=%d d1=%d d2=%d d3=%d ok=%d" \
    [rd init_done] [rd rdr_d0] [rd rdr_d1] [rd rdr_d2] [rd rdr_d3] [rd rdr_ok]]
P "RESULT ila_read_txn_done"
disconnect_hw_server
exit 0
