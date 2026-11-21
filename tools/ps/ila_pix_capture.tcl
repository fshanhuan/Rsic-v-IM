# =============================================================================
# ila_pix_capture.tcl —— 抓像素总线：确认屏幕上到底是"黑"还是"有内容"
# -----------------------------------------------------------------------------
# 如果采集卡锁上了 800x600 却拿到全黑，那 TMDS 很可能是好的，只是我们**画的是黑的**。
# 这个脚本用 ila_pix（像素域，5 个探针）在 de=1 时触发，把 16 位像素数据dump 出来：
#   probe0 = hdmi_d[15:0]   probe1 = de   probe2 = hsync  probe3 = vsync  probe4 = 行号
# 判据：像素值全 0（或只有极少数几个值）⇒ 画面是黑的。
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
set CSV  "$WORK/_diag/ila_pix.csv"
proc P {s} { puts "\[PIX\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] { catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } } }
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
catch { refresh_hw_device -update_hw_probes true $dev }

set pix ""
foreach i [get_hw_ilas -quiet] {
    if {[llength [get_hw_probes -of_objects $i]] == 5} { set pix $i }
}
if {$pix eq ""} { P "RESULT no_pix_ila" ; exit 1 }

# 触发条件：de = 1（有效像素期）
set dp ""
foreach q [get_hw_probes -of_objects $pix] {
    if {[get_property NAME $q] eq "hdmi_de"} { set dp $q }
    if {[string match "*de*" [get_property NAME $q]]} { if {$dp eq ""} { set dp $q } }
}
P "de probe = [get_property NAME $dp]"
catch { set_property COMPARE_VALUE.0 "eq1'b1" $dp }
catch { set_property CONTROL.TRIGGER_POSITION 64 $pix }
catch { run_hw_ila $pix }
set ok 1
if {[catch { wait_on_hw_ila -timeout 3000 $pix } e]} { set ok 0 ; P "wait: $e" }
P "triggered=$ok"
if {$ok} {
    set data [upload_hw_ila_data $pix]
    catch { write_hw_ila_data -csv_file -force $CSV $data }
    P "csv: $CSV"
}
P "RESULT pix_capture_done"
disconnect_hw_server
exit 0
