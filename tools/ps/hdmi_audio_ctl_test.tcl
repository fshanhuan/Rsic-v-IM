# =============================================================================
# hdmi_audio_ctl_test.tcl —— 对照实验：在**已知健康**的音频总线上做同样的"只拉低一根"
# -----------------------------------------------------------------------------
# 为什么要做：§52.14 用"只按低 SCL → SDA 也变 0"判定 HDMI 的 SCL/SDA 短接。
#   但有人可以质疑："是不是你的方法本身就把两根线耦合起来了？"
#   回答办法：拿一对**已知健康**的线（音频 ADAU1761，一直正常 ACK）做同样的事：
#   只按低它的 SCL，另一根必须**保持高**。做到就说明方法有效、HDMI 的联动是真的。
#
# 位流里的四个输出：
#   out6/out7 = 拉低 HDMI 的 SCL / SDA
#   out8/out9 = 拉低 音频的 SCL / SDA
# 探针：in40/41 = HDMI 两线的 21 ms 高电平计数；in43/44 = 音频两线的同一计数
#
# 用法：vivado -mode batch -source _diag/hdmi_audio_ctl_test.tcl
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"

proc P {s} { puts "\[CTL\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] {
    catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } }
}
if {$dev eq ""} { P "RESULT no_fpga" ; exit 1 }
current_hw_device $dev
if {[file exists $LTX]} { set_property PROBES.FILE $LTX $dev }
catch { refresh_hw_device -update_hw_probes true $dev }
set v [lindex [get_hw_vios -quiet] 0]
if {$v eq ""} { P "RESULT no_vio_core" ; exit 1 }

array set PM {}
foreach p [get_hw_probes -of_objects $v] { set PM([get_property NAME $p]) $p }
proc has {n} { global PM ; return [info exists PM($n)] }
proc rd {n} { global PM ; set h 0 ; catch { set h [get_property INPUT_VALUE $PM($n)] } ; set x 0 ; catch { scan $h %x x } ; return $x }
proc wr {n val} { global PM ; if {![info exists PM($n)]} { return 0 } ; catch { set_property OUTPUT_VALUE $val $PM($n) } ; return 1 }

foreach need {scl_hi_cnt sda_hi_cnt ascl_hi_cnt asda_hi_cnt vio_pull_ascl vio_pull_asda} {
    if {![has $need]} { P "RESULT no_probe:$need" ; exit 1 }
}

proc row {tag} {
    global v
    refresh_hw_vio $v
    P [format "%-30s HDMI SCL=%7d SDA=%7d | AUD SCL=%7d SDA=%7d" $tag \
        [rd scl_hi_cnt] [rd sda_hi_cnt] [rd ascl_hi_cnt] [rd asda_hi_cnt]]
}

# 0) 全释放
foreach o {vio_pull_scl vio_pull_sda vio_pull_ascl vio_pull_asda} { wr $o 0 }
commit_hw_vio $v
after 400
row "0 全释放（基线）"

# 1) 只按低**音频** SCL —— 音频 SDA 应当保持高
wr vio_pull_ascl 1
commit_hw_vio $v
after 400
row "1 只按低 音频SCL"
set a1 [rd asda_hi_cnt]
set c1 [rd ascl_hi_cnt]
after 200
row "1b 再读一次"

# 2) 只按低**音频** SDA —— 音频 SCL 应当保持高
wr vio_pull_ascl 0
wr vio_pull_asda 1
commit_hw_vio $v
after 400
row "2 只按低 音频SDA"
set c2 [rd ascl_hi_cnt]
set a2 [rd asda_hi_cnt]

# 3) 全释放
foreach o {vio_pull_scl vio_pull_sda vio_pull_ascl vio_pull_asda} { wr $o 0 }
commit_hw_vio $v
after 400
row "3 全释放（恢复）"

# ---- 判定 ----
# 音频侧：被按低的那根必须 ≈0，另一根必须 ≈高（> 50%）
set hi 524288
set lo 50000
set verdict "UNKNOWN"
if {$c1 < $lo && $a1 > $hi && $a2 < $lo && $c2 > $hi} {
    set verdict "CONTROL_OK（健康的一对线不会被互相拖低 ⇒ HDMI 的联动是真实短接）"
} elseif {$c1 < $lo && $c2 < $lo} {
    set verdict "CONTROL_BAD（两根都跟着低了 ⇒ 我们的测量方法本身在耦合，HDMI 的结论要重新做）"
} else {
    set verdict "CONTROL_INCONCLUSIVE（按低没生效？看上面的 AUD 数值）"
}
P "RESULT audio_ctl verdict=$verdict  pull_ascl: ascl=$c1 asda=$a1 | pull_asda: ascl=$c2 asda=$a2"
disconnect_hw_server
exit 0
