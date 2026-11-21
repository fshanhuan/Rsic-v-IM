set LTX "E:/FPGA/v9_vivado_ila/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
set CSV  "E:/FPGA/v9_vivado_ila/_diag/ila_busy.csv"
proc P {s} { puts "\[CB\] $s" ; flush stdout }
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
set tp ""
foreach q [get_hw_probes -of_objects $i2c] { if {[get_property NAME $q] eq "init_busy_1"} { set tp $q } }
P "probe = [get_property NAME $tp]  before = [get_property COMPARE_VALUE.0 $tp]"
set_property COMPARE_VALUE.0 "eq1'b1" $tp
P "after  = [get_property COMPARE_VALUE.0 $tp]"
catch { set_property CONTROL.TRIGGER_POSITION 64 $i2c }
catch { run_hw_ila $i2c }
P "armed, waiting up to 1 s"
set ok 1
if {[catch { wait_on_hw_ila -timeout 2000 $i2c } e]} { set ok 0 ; P "wait: $e" }
P "triggered=$ok"
if {$ok} {
    set data [upload_hw_ila_data $i2c]
    catch { write_hw_ila_data -csv_file -force $CSV $data }
    P "csv: $CSV"
    P "RESULT busy_capture_ok"
} else {
    P "RESULT busy_capture_timeout"
}
disconnect_hw_server
exit 0