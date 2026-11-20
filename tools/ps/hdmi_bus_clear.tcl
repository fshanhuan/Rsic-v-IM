# =============================================================================
# hdmi_bus_clear.tcl —— 手动做一次 I2C "总线恢复"（STOP + 9 拍时钟），再看会不会 ACK
# -----------------------------------------------------------------------------
# 动机：2026-11-20 21:05 曾观测到一次 `init_done=1 / no_dev=0`（= ADV7511 整套 14 个
#   寄存器都写进去了），而前后都没有。那之前刚跑过"把 SCL/SDA 强制拉低再放开"的实验 ——
#   放开的那一刻会在总线上产生一个**合法的 STOP**（SDA 上升沿落在 SCL 高电平期间）。
#   如果 ADV7511 之前被某个半截字节卡住（在等 STOP），这一下正好把它放出来。
#
# 这个脚本就用手工时序复现那一下，然后立刻读 init_done / f_h：
#   ① 两根都按低           → 保证从任何状态都能起
#   ② 放开 SCL（SCL 高，SDA 仍低）
#   ③ 放开 SDA（SDA 上升沿 + SCL 高 = STOP）
#   ④ 再打 9 个 SCL 时钟（清掉可能还在等时钟的从机）
#   ⑤ 等 200 ms 让它自己重试，读 done / f_h / ack_err
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"

proc P {s} { puts "\[BC\] $s" ; flush stdout }

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
proc wr {n val} { global PM ; if {![info exists PM($n)]} { return 0 } ; catch { set_property OUTPUT_VALUE $val $PM($n) } ; return 1 }

foreach need {vio_pull_scl vio_pull_sda init_done f_h} {
    if {![info exists PM($need)]} { P "RESULT no_probe:$need" ; exit 1 }
}

refresh_hw_vio $v
P [format "before: done=%d ack_err=%d f_h=0x%04X" [rd init_done] [rd init_ack_err] [rd f_h]]

# ① 两根都按低
wr vio_pull_scl 1
wr vio_pull_sda 1
commit_hw_vio $v
after 20

# ② SCL 放开（高），SDA 还是低
wr vio_pull_scl 0
commit_hw_vio $v
after 20

# ③ SDA 放开 → 上升沿（SCL 高）= STOP
wr vio_pull_sda 0
commit_hw_vio $v
after 20

# ④ 9 个 SCL 时钟（每拍 20 us，约 10 kHz）；SDA 保持高
for {set i 0} {$i < 9} {incr i} {
    wr vio_pull_scl 1 ; commit_hw_vio $v ; after 2
    wr vio_pull_scl 0 ; commit_hw_vio $v ; after 2
}
wr vio_pull_scl 0
wr vio_pull_sda 0
commit_hw_vio $v

# ⑤ 等它自己重试几轮
after 1200
refresh_hw_vio $v
set done [rd init_done]
set fh   [rd f_h]
set ae   [rd init_ack_err]
P [format "after : done=%d ack_err=%d f_h=0x%04X" $done $ae $fh]
if {$done == 1 || ($fh != 0 && $fh != 0xFFFF)} {
    P "RESULT bus_clear WOKE_THE_CHIP（总线恢复有效：加一段 STOP+9 拍的恢复时序就能治）"
} else {
    P "RESULT bus_clear still_dead（这一次没救回来）"
}
disconnect_hw_server
exit 0
