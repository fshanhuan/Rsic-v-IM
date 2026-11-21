# =============================================================================
# hdmi_rdback2.tcl —— 唤醒芯片后，读它自己的 0x00 / 0x41 / 0x42 / 0x16
# -----------------------------------------------------------------------------
# 位流里新增 adv7511_rdregs：`init_done` 上升沿后自动做 4 次
#   START,{0x39,W},reg, START,{0x39,R},读一字节(NACK), STOP
# 结果挂在 VIO 的 rdr_d0..d3 / rdr_ok / rdr_busy 上。
#
# 判据（Programming Guide）：
#   0x41[6] = 1 -> 主掉电（TMDS 不出，且 0x00–0x93 被复位）
#   0x42[6]     -> 芯片看到的 HPD 电平
#   0x16        -> 我们写的 0x34 有没有留住（留不住说明一直被复位）
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
proc P {s} { puts "\[RR\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] { catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } } }
if {$dev eq ""} { P "RESULT no_fpga" ; exit 1 }
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
catch { refresh_hw_device -update_hw_probes true $dev }
set v [lindex [get_hw_vios -quiet] 0]
array set N {}
foreach q [get_hw_probes -of_objects $v] { set N([get_property NAME $q]) $q }
proc rd {n} {
    global N
    if {![info exists N($n)]} { return -1 }
    set h 0 ; catch { set h [get_property INPUT_VALUE $N($n)] }
    set x 0 ; catch { scan $h %x x } ; return $x
}
proc wr {n val} { global N ; if {[info exists N($n)]} { set_property OUTPUT_VALUE $val $N($n) } }

refresh_hw_vio $v
P [format "start: done=%d ack_err=%d d0=%d d1=%d d2=%d d3=%d ok=%d busy=%d" \
    [rd init_done] [rd init_ack_err] [rd rdr_d0] [rd rdr_d1] [rd rdr_d2] [rd rdr_d3] [rd rdr_ok] [rd rdr_busy]]

if {[rd init_done] != 1} {
    # 唤醒：按住两根线 100 ms -> 放开 SCL -> 放开 SDA -> 9 个慢时钟
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
    after 1500
    refresh_hw_vio $v
    P [format "woken: done=%d ack_err=%d" [rd init_done] [rd init_ack_err]]
}

after 2500
refresh_hw_vio $v
set d0 [rd rdr_d0]
set d1 [rd rdr_d1]
set d2 [rd rdr_d2]
set d3 [rd rdr_d3]
set ok [rd rdr_ok]
P [format "regs : 0x00=0x%02X 0x41=0x%02X 0x42=0x%02X 0x16=0x%02X ok=%d" $d0 $d1 $d2 $d3 $ok]

set verdict "UNKNOWN"
set note ""
if {$ok != 1} {
    set verdict "READ_FAILED（读回没有全部 ACK）"
} else {
    set pdbit  [expr {($d1 >> 6) & 1}]
    set hpdbit [expr {($d2 >> 6) & 1}]
    set note [format "0x41[6](PD)=%d 0x42[6](HPD)=%d 0x16=0x%02X" $pdbit $hpdbit $d3]
    if {$pdbit == 1} {
        set verdict "MAIN_POWER_DOWN（芯片被 PD 脚按住 -> TMDS 不会输出）"
    } elseif {$hpdbit == 0} {
        set verdict "HPD_LOW_AT_CHIP"
    } elseif {$d3 != 0x34} {
        set verdict "CONFIG_NOT_STICKING（0x16 读回不是 0x34，配置被复位）"
    } else {
        set verdict "CHIP_OK_CONFIG_OK（那就只剩像素时钟/数据通路）"
    }
}
P "RESULT rdback2 verdict=$verdict id=0x$d0 r41=0x$d1 r42=0x$d2 r16=0x$d3 ok=$ok  $note"
disconnect_hw_server
exit 0
