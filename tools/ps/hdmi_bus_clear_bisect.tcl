# =============================================================================
# hdmi_bus_clear_bisect.tcl —— 手工恢复时序里，到底是哪一步治好了 ADV7511？
# -----------------------------------------------------------------------------
# 已知（三次复现）：手工做 "两根按住 → 放开 SCL → 放开 SDA（STOP）→ 9 个慢时钟"
#   之后，`init_done` 立刻变 1。
# 但把这个时序放进 RTL（100 kHz、110 µs）**没有效果**，说明关键在**时间尺度**。
#
# 这个脚本把手工序列拆成两段，逐段看 done：
#   段 1：两根按住 20 ms → 放开 SCL（20 ms）→ 放开 SDA（STOP）      ← 只有 STOP
#   段 2：再打 9 个慢时钟（半周期 2 ms）                            ← 再加时钟
# 每一段之后都等 1.2 s 让 adv7511_init 自己重试，然后读 done/ack_err。
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
proc P {s} { puts "\[BS\] $s" ; flush stdout }

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
proc both_off {} { global v ; wr vio_pull_scl 0 ; wr vio_pull_sda 0 ; commit_hw_vio $v }
proc report {tag} {
    global v
    refresh_hw_vio $v
    P [format "%-28s done=%d ack_err=%d f_h=0x%04X" $tag [rd init_done] [rd init_ack_err] [rd f_h]]
    return [rd init_done]
}

report "start"

# ---- 段 1：只有 STOP（含 20 ms 按住）----
wr vio_pull_scl 1
wr vio_pull_sda 1
commit_hw_vio $v
after 20
wr vio_pull_scl 0
commit_hw_vio $v
after 20
wr vio_pull_sda 0
commit_hw_vio $v
after 1200
set d1 [report "段1 只有STOP"]

# ---- 段 2：再打 9 个慢时钟（半周期 2 ms），SDA 保持释放 ----
for {set i 0} {$i < 9} {incr i} {
    wr vio_pull_scl 1 ; commit_hw_vio $v ; after 2
    wr vio_pull_scl 0 ; commit_hw_vio $v ; after 2
}
both_off
after 1200
set d2 [report "段2 STOP+9慢时钟"]

if {$d1 == 1} {
    P "RESULT bisect STOP_ALONE_WORKS（只要一个长按 + STOP 就够）"
} elseif {$d2 == 1} {
    P "RESULT bisect NEEDS_SLOW_CLOCKS（STOP 不够，还要慢时钟）"
} else {
    P "RESULT bisect neither_worked（这一次没救回来，可能它本来就还没上电）"
}
disconnect_hw_server
exit 0
