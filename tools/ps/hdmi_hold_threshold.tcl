# =============================================================================
# hdmi_hold_threshold.tcl —— 到底要"按住多少毫秒"才能把 ADV7511 唤醒？
# -----------------------------------------------------------------------------
# 已知：RTL 里按住 50 ms + STOP + 9 个 2 ms 慢时钟 → 仍然 NACK（init_done=0）。
#       手工按住约 30 秒（脚本报错留在低电平）→ init_done=1。
# 这个脚本在同一次上电里按 100 ms → 500 ms → 2 s → 8 s 递增，每次之后读 done：
#   一旦 done=1 就停止，打印阈值。
# 注意：成功一次以后片子就配置好了，再往后测没有意义（done 会一直是 1）。
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
proc P {s} { puts "\[TH\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] { catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } } }
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
catch { refresh_hw_device -update_hw_probes true $dev }
set v [lindex [get_hw_vios -quiet] 0]
array set PM {}
foreach p [get_hw_probes -of_objects $v] { set PM([get_property NAME $p]) $p }
proc rd {n} { global PM ; set h 0 ; catch { set h [get_property INPUT_VALUE $PM($n)] } ; set x 0 ; catch { scan $h %x x } ; return $x }
proc wr {n val} { global PM ; if {![info exists PM($n)]} { return 0 } ; catch { set_property OUTPUT_VALUE $val $PM($n) } ; return 1 }

proc snap {tag} {
    global v
    refresh_hw_vio $v
    set d [rd init_done]
    P [format "%-22s done=%d ack_err=%d f_h=0x%04X" $tag $d [rd init_ack_err] [rd f_h]]
    return $d
}

proc hold_and_stop {ms} {
    global v
    wr vio_pull_scl 1 ; wr vio_pull_sda 1 ; commit_hw_vio $v
    after $ms
    wr vio_pull_scl 0 ; commit_hw_vio $v      ;# SCL 放开（高），SDA 仍低
    after 20
    wr vio_pull_sda 0 ; commit_hw_vio $v      ;# SDA 上升 = STOP
    after 20
    for {set i 0} {$i < 9} {incr i} {         ;# 9 个慢时钟
        wr vio_pull_scl 1 ; commit_hw_vio $v ; after 2
        wr vio_pull_scl 0 ; commit_hw_vio $v ; after 2
    }
    wr vio_pull_scl 0 ; wr vio_pull_sda 0 ; commit_hw_vio $v
    after 800
}

if {[snap "start"] == 1} { P "RESULT hold_threshold already_done" ; disconnect_hw_server ; exit 0 }

set threshold 0
foreach ms {100 500 2000 8000 30000} {
    hold_and_stop $ms
    set d [snap "hold=$ms ms"]
    if {$d == 1} { set threshold $ms ; break }
}

if {$threshold > 0} {
    P "RESULT hold_threshold OK_AT_$threshold"
} else {
    P "RESULT hold_threshold NONE（到 30 s 都没醒）"
}
disconnect_hw_server
exit 0
