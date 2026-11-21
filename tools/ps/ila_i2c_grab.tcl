# =============================================================================
# ila_i2c_grab.tcl —— 抓一段 I2C 总线的原始波形（不猜了，直接看）
# -----------------------------------------------------------------------------
# 位流里的 ila_i2c：probe0[7:0] =
#   [7] init_no_dev  [6] hdmi_probed  [5] init_done  [4] init_busy
#   [3] hdmi_sda_rd  [2] hdmi_scl_rd  [1] init_sda_oe [0] init_scl_oe
# 采样时钟 50 MHz，深度 16384（≈328 µs）。
#
# 用法：vivado -mode batch -source _diag/ila_i2c_grab.tcl
# 输出：_diag/ila_i2c.csv（Vivado 原生 CSV），再由 Python 解码成边沿表
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
set CSV  "$WORK/_diag/ila_i2c.csv"
proc P {s} { puts "\[ILA\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] { catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } } }
if {$dev eq ""} { P "RESULT no_fpga" ; exit 1 }
current_hw_device $dev
if {[file exists $LTX]} { set_property PROBES.FILE $LTX $dev }
catch { refresh_hw_device -update_hw_probes true $dev }

set ilas [get_hw_ilas -quiet]
if {![llength $ilas]} { P "RESULT no_ila" ; exit 1 }
P "found [llength $ilas] ILA core(s)"

# 找 probe 数 = 1 的那个（ila_i2c），ila_pix 有 5 个
set i2c ""
foreach i $ilas {
    set ps [get_hw_probes -of_objects $i]
    P "  [get_property NAME $i] : [llength $ps] probe(s)"
    if {[llength $ps] == 8} { set i2c $i }   ;# 8 位被 Vivado 拆成 8 个单比特探针
}
if {$i2c eq ""} { P "RESULT no_i2c_ila" ; exit 1 }

set p [lindex [get_hw_probes -of_objects $i2c] 0]
foreach q [get_hw_probes -of_objects $i2c] { P "   probe: [get_property NAME $q]" }
P "using [get_property NAME $i2c] / [get_property NAME $p] width=[get_property WIDTH $p]"

# 触发条件：init_scl_oe = 1（主控开始驱动 SCL，低 = 一次传输开始）
# 重试周期 200 ms，所以最多等 0.3 s 就会撞上下一次尝试
set tp ""
foreach q [get_hw_probes -of_objects $i2c] {
    if {[get_property NAME $q] eq "init_scl_oe"} { set tp $q }
}
if {$tp ne ""} {
    catch { set_property TRIGGER_COMPARE_VALUE 1 $tp }
    catch { set_property CONTROL.TRIGGER_POSITION 64 $i2c }
    P "trigger on [get_property NAME $tp] = 1"
}
catch { run_hw_ila $i2c }
after 400
catch { wait_on_hw_ila $i2c }
set data [upload_hw_ila_data $i2c]
if {[llength $data] == 0} { P "RESULT upload_failed" ; exit 1 }
catch { write_hw_ila_data -csv_file $CSV $data }
if {[file exists $CSV]} {
    P "csv: $CSV ([file size $CSV] bytes)"
    P "RESULT ila_i2c_grabbed"
} else {
    P "RESULT csv_failed"
}
disconnect_hw_server
exit 0
