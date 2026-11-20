# =============================================================================
# hdmi_pull_test.tcl —— 判断 HDMI 的 SCL/SDA 是不是**同一个电节点**（不需要万用表）
# -----------------------------------------------------------------------------
# 背景：两个占空比计数器在三个不同窗口给出三组**完全相同**的数
#       （65.17/65.17、87.95/87.95、14.21/14.21）；
#       而控制实验 _diag/tb_i2c_duty_probe.sv（接线正确、芯片不应答）显示
#       独立的两根线必然相差几十拍。于是怀疑板上 SCL/SDA 短接。
#
# 做法：新位流里加了两个 VIO 输出，可以**只把其中一根按低**：
#   out6 = vio_pull_scl   1 = 强制 SCL 低
#   out7 = vio_pull_sda   1 = 强制 SDA 低
# 然后看另一根的 21 ms 占空比计数：
#   只按低 SCL → 若 sda_hi_cnt 也掉到 ~0  ⇒ **短接**
#                              否则 ≈ 满   ⇒ 没短，问题在别处
#
# 用法：vivado -mode batch -source _diag/hdmi_pull_test.tcl
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/v9_rec/v9_rec.runs/impl_1/board_top_rec.ltx"

proc P {s} { puts "\[PULL\] $s" ; flush stdout }

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
proc rd {n} {
    global PM
    set h "0"
    catch { set h [get_property INPUT_VALUE $PM($n)] }
    set x 0
    catch { scan $h %x x }
    return $x
}
proc wr {n val} {
    global PM
    if {![info exists PM($n)]} { return 0 }
    catch { set_property OUTPUT_VALUE $val $PM($n) }
    return 1
}

foreach need {scl_hi_cnt sda_hi_cnt vio_pull_scl vio_pull_sda} {
    if {![has $need]} { P "RESULT no_probe:$need （这一版位流没有这个探针）" ; exit 1 }
}

proc settle {} { after 120 }

proc snap {tag} {
    global v
    refresh_hw_vio $v
    set sc [rd scl_hi_cnt]
    set sd [rd sda_hi_cnt]
    P [format "%-26s SCL=%7d (%6.2f%%)  SDA=%7d (%6.2f%%)" $tag $sc \
         [expr {100.0*$sc/1048576.0}] $sd [expr {100.0*$sd/1048576.0}]]
    return [list $sc $sd]
}

# ---------- 0) 两根都释放：基线 ----------
wr vio_pull_scl 0
wr vio_pull_sda 0
commit_hw_vio $v
settle
set base [snap "0 都释放（基线）"]

# ---------- 1) 只把 SCL 按低 ----------
# ★ 关键：多等 400 ms 再读。adv7511_init 的重试周期是 200 ms，它一旦被卡住，
#   最多在一次失败尝试后就回到"等 200 ms"的状态并**释放两根线**。所以如果
#   400 ms 之后（此时主控必然处于静默等待）SDA 仍然是 0，那就只能是外部短接，
#   而不是"主控自己把 SDA 按住"。
wr vio_pull_scl 1
wr vio_pull_sda 0
commit_hw_vio $v
after 400
set t1 [snap "1 只按低 SCL (+400ms)"]
after 200
set t1b [snap "1b 再读一次（静默期）"]
set scl1 [lindex $t1 0]
set sda1 [lindex $t1 1]

# ---------- 2) 只把 SDA 按低 ----------
wr vio_pull_scl 0
wr vio_pull_sda 1
commit_hw_vio $v
after 400
set t2 [snap "2 只按低 SDA (+400ms)"]
after 200
set t2b [snap "2b 再读一次（静默期）"]
set scl2 [lindex $t2 0]
set sda2 [lindex $t2 1]

# ---------- 3) 全部释放，恢复原状 ----------
wr vio_pull_scl 0
wr vio_pull_sda 0
commit_hw_vio $v
settle
snap "3 恢复（都释放）"

# ---- 判定 ----
# 按低 SCL 后：SCL 自己的计数必须掉到 0（否则实验没生效）
# 同一次里 SDA 的计数：
#   < 5%   → 短接（SDA 被 SCL 拖低）
#   > 50%  → 没短
set v1 "?"
set v2 "?"
if {$scl1 < 50000} { set v1 "PULL_WORKS" } else { set v1 "PULL_INEFFECTIVE" }
if {$scl2 < 50000} { set v2 "PULL_WORKS" } else { set v2 "PULL_INEFFECTIVE" }

set verdict "UNKNOWN"
set detail "pull_scl: scl=$scl1 sda=$sda1 | pull_sda: scl=$scl2 sda=$sda2 | base=$base"
if {$v1 eq "PULL_WORKS" && $v2 eq "PULL_WORKS"} {
    set th [expr {1048576 * 5 / 100}]
    if {$sda1 < $th && $scl2 < $th} {
        set verdict "SHORTED（SCL 与 SDA 是同一个电节点）"
    } elseif {$sda1 > 500000 && $scl2 > 500000} {
        set verdict "NOT_SHORTED（两根线互不影响）"
    } else {
        set verdict "PARTIAL（一根受影响、一根没有，需要看波形）"
    }
}
P "RESULT hdmi_pull_test verdict=$verdict $v1/$v2  $detail"
disconnect_hw_server
exit 0
