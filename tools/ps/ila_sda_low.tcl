set LTX "E:/FPGA/v9_vivado_ila/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
set CSV "E:/FPGA/v9_vivado_ila/_diag/ila_sda.csv"
proc P {s} { puts "\[IL\] $s" ; flush stdout }
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
foreach q [get_hw_probes -of_objects $i2c] {
    if {[get_property NAME $q] eq "hdmi_scl_rd_1"} { set_property COMPARE_VALUE.0 "eq1'b0" $q ; P "trigger SCL=0" }
}
catch { set_property CONTROL.TRIGGER_POSITION 256 $i2c }
catch { run_hw_ila $i2c }
P "armed"
set v [lindex [get_hw_vios -quiet] 0]
array set N {}
foreach q [get_hw_probes -of_objects $v] { set N([get_property NAME $q]) $q }
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
if {[catch { wait_on_hw_ila -timeout 5000 $i2c } e]} { P "wait: $e" }
set data [upload_hw_ila_data $i2c]
catch { write_hw_ila_data -csv_file -force $CSV $data }
P "csv: $CSV"
disconnect_hw_server
exit 0