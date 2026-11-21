# =============================================================================
# hdmi_reg41.tcl —— 读回 ADV7511 自己的 Power-Down 寄存器（0x41）与 0x42
# -----------------------------------------------------------------------------
# 要回答的问题：I2C 已经能 ACK、14 个寄存器都写进去了，但 TMDS 没输出。
#   是不是芯片自己认为"我在掉电态"（HPD 低）？
#   → 读回 0x41：bit6 = Power Down。我们最后写的是 0x41=0x10（bit4 置、bit6 清），
#     如果读回值 bit6=1，说明芯片自己又回到了掉电态（多半是 HPD 低）。
#
# 流程：先做一次手工总线恢复把片子唤醒（§52.15，5/5 有效）→ 触发重扫 →
#       读 f_h（地址位图）与三个寄存器（0x00 / 0x41 / 0x42，见 i2c_probe.sv 的 regsel）。
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"
proc P {s} { puts "\[R41\] $s" ; flush stdout }

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
array set PM {}
foreach p [get_hw_probes -of_objects $v] { set PM([get_property NAME $p]) $p }
proc rd {n} { global PM ; set h 0 ; catch { set h [get_property INPUT_VALUE $PM($n)] } ; set x 0 ; catch { scan $h %x x } ; return $x }
proc wr {n val} { global PM ; catch { set_property OUTPUT_VALUE $val $PM($n) } }

refresh_hw_vio $v
P [format "before: done=%d f_h=0x%04X id00=0x%02X id41=0x%02X id42=0x%02X" \
    [rd init_done] [rd f_h] [rd id00_h] [rd idf5_h] [rd idf6_h]]

# ---- 1) 手工总线恢复（唤醒）----
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
after 1200
refresh_hw_vio $v
P [format "woken : done=%d ack_err=%d" [rd init_done] [rd init_ack_err]]

# ---- 2) 重扫（让 i2c_probe 重新找地址并读寄存器）----
wr vio_rescan 1 ; commit_hw_vio $v
after 400
wr vio_rescan 0 ; commit_hw_vio $v
after 4000
refresh_hw_vio $v
set fh [rd f_h]
set id00 [rd id00_h]
set id41 [rd idf5_h]
set id42 [rd idf6_h]
P [format "after : f_h=0x%04X id00=0x%02X reg41=0x%02X reg42=0x%02X done=%d" \
    $fh $id00 $id41 $id42 [rd init_done]]

# ---- 3) 判定 ----
set verdict "UNKNOWN"
set pd ""
if {($id41 & 0x40) != 0} { set pd "POWER_DOWN_BIT_SET" } else { set pd "not_powered_down" }
if {$fh == 0} {
    set verdict "NO_DEVICE_IN_SCAN（重扫没找到 0x39）"
} else {
    set verdict "READ_OK（$pd）"
}
P "RESULT reg41 verdict=$verdict f_h=0x$fh id00=0x$id00 reg41=0x$id41 reg42=0x$id42"
disconnect_hw_server
exit 0
