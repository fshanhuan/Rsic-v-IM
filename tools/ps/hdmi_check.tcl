# =============================================================================
# hdmi_check.tcl — 一条命令判 HDMI 通没通（上电/插线之后跑这个）
# -----------------------------------------------------------------------------
# 只读不写（除了一次 vio_rescan），用来回答三个问题：
#   1) ADV7511 到底 ACK 了没有（init_done / no_dev / ack_err 是否还在涨）
#   2) I2C 两根线现在是高还是低（被拉着就是 0）
#   3) 视频流水线本身是不是好的（帧参数对不对 —— 用来把"没图"和"没时序"分开）
#
# 用法：
#   vivado -mode batch -source _diag/hdmi_check.tcl
#   HDMI_LTX 可覆盖 ltx
# 判定：
#   init_done=1                 → ADV7511 已配置，若仍无图则查 0x15/0x16/0x18 格式表
#   ack_err 两次读数相同         → 状态机已停（done 或彻底失败）
#   ack_err 仍在涨 + f_h 无 ACK  → 芯片没上电/没 ACK，还是 I2C 层面的问题
# =============================================================================
set WORK "E:/FPGA/v9_vivado_ila"
set LTX  "$WORK/_baseline_v9/board_top_rec_S2b2.ltx"
if {[info exists ::env(HDMI_LTX)]} { set LTX $::env(HDMI_LTX) }

proc P {s} { puts "\[HDMI\] $s" ; flush stdout }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev ""
foreach d [get_hw_devices] {
    catch { if {[string match "xc7z020*" [get_property PART $d]]} { set dev $d } }
}
current_hw_device $dev
set_property PROBES.FILE $LTX $dev
catch { refresh_hw_device -update_hw_probes true $dev }
set v [lindex [get_hw_vios -quiet] 0]
if {$v eq ""} {
    P "RESULT no_vio（PL 没配置？先烧 board_top_rec_S2b2.bit）"
    exit 1
}
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

refresh_hw_vio $v
set e0 [rd init_ack_err]
P [format "T0: done=%d no_dev=%d busy=%d idx=%2d reg=0x%02X val=0x%02X ack_err=%d" \
        [rd init_done] [rd init_no_dev] [rd init_busy] [rd init_idx] [rd init_reg] [rd init_val] $e0]
P [format "T0: hdmi_scl=%d hdmi_sda=%d  line_health=0x%02X  f_h=0x%04X f_a=0x%04X" \
        [rd hdmi_scl_rd] [rd hdmi_sda_rd] [rd line_health] [rd f_h] [rd f_a]]

# 2026-11-20 13:0x：SW0/SW1 拨码的实际电平（probe_in42）。
# 起因：怀疑 `wire swap = sw[0]` 配 PULLTYPE PULLUP ⇒ 拨码不动读 1 ⇒ "互换 SCL/SDA
# 的实验"默认开着。现在 swap 恒 0，这个探针用来回答"开关到底在哪一侧"（只读）。
# ★ 探针名字坑：Vivado 会把 `{6'b0, sw}` 这种拼接拆开命名，实测名字是 **sw_IBUF**
#   （不是 sw）—— 第一次没找到它，误报成"这一版位流还是旧的"。两个名字都试。
set swprobe ""
foreach cand {sw sw_IBUF sw_IN sw_1} {
    if {[has $cand]} { set swprobe $cand ; break }
}
if {$swprobe ne ""} {
    set s [rd $swprobe]
    P [format "T0: %s=0x%02X  SW0=%s  SW1=%s  （bit0=1 曾是「互换 SCL/SDA」档）" $swprobe $s \
        [expr {($s & 1) ? "悬空/1" : "接地/0"}] [expr {($s & 2) ? "悬空/1" : "接地/0"}]]
} else {
    P "T0: (没有 sw 探针 -- 这一版位流还是旧的，swap 可能仍由拨码决定)"
}

# 2026-11-20：占空比计数（probe_in40/41, 20 位，窗口 2^20 拍 ≈ 21 ms）。
# 这两个数把"线是高还是低"变成数字，**不受 JTAG 采样时刻影响** —— 1 位探针
# 采到 0 可能只是刚好停在驱动低电平那一小段（§52.2 的教训）。
if {[has scl_hi_cnt] && [has sda_hi_cnt]} {
    set sc [rd scl_hi_cnt]
    set sd [rd sda_hi_cnt]
    set w  [expr {1048576.0}]
    set pc_s [expr {100.0 * $sc / $w}]
    set pc_d [expr {100.0 * $sd / $w}]
    P [format "T0: 占空比 SCL=%d/1048576 (%.2f%%)  SDA=%d/1048576 (%.2f%%)  \[窗口 21 ms\]" \
            $sc $pc_s $sd $pc_d]
    if {$sc > 1000000 && $sd > 1000000} {
        P "T0: => 两根线都是**空闲高**：上拉活着、没人按住（之前的 BUS_HELD_LOW 是采样偏差）"
    } elseif {$sc < 1000 && $sd < 1000} {
        P "T0: => 两根线**确实被按住**（都是低）"
    } else {
        P "T0: => 有周期性总线活动（init 重试），占空比见上"
    }
} else {
    P "T0: (没有 scl_hi_cnt/sda_hi_cnt 探针 -- 板上不是带占空比计数的位流)"
}
P [format "T0: 视频流水线 mmcm=%d pix=%d  frame_clk=%d lines=%d de_pix=%d hs_low=%d vs_low=%d" \
        [rd mmcm_locked] [rd pix_locked] [rd m_frame_clk] [rd m_frame_lines] [rd m_de_pix] [rd m_hs_low] [rd m_vs_low]]

# 重新扫一次总线（插拔 HDMI 线之后必须做，HPD 一变就得重扫）
if {[has vio_rescan]} {
    catch { set_property OUTPUT_VALUE 1 $PM(vio_rescan) }
    catch { commit_hw_vio $v }
    after 400
    catch { set_property OUTPUT_VALUE 0 $PM(vio_rescan) }
    catch { commit_hw_vio $v }
    after 2500
    refresh_hw_vio $v
    P [format "T1(重扫后): f_h=0x%04X f_a=0x%04X addr_h=0x%02X busy_h=%d" \
            [rd f_h] [rd f_a] [rd addr_h] [rd busy_h]]
}

after 4000
refresh_hw_vio $v
set e1 [rd init_ack_err]
P [format "T2: done=%d no_dev=%d ack_err=%d（4 s 内 %+d）scl=%d sda=%d" \
        [rd init_done] [rd init_no_dev] $e1 [expr {$e1 - $e0}] [rd hdmi_scl_rd] [rd hdmi_sda_rd]]

# ---- 判定 ----
set done [rd init_done]
set no  [rd init_no_dev]
set fh  [rd f_h]
if {$done == 1} {
    set verdict "ADV7511_CONFIGURED"
} elseif {$fh != 0 && $fh != 0xFFFF} {
    set verdict "PARTIAL_ACK（总线上有器件，但配置没走完）"
} elseif {[rd hdmi_scl_rd] == 0 && [rd hdmi_sda_rd] == 0} {
    set verdict "BUS_HELD_LOW（两根线都被拉低：芯片掉电或上拉没供电）"
} else {
    set verdict "NO_ACK（总线空闲电平正常，但 0x39 不应答）"
}
P [format "RESULT hdmi_check verdict=%s done=%d no_dev=%d f_h=0x%04X ack_err=%d frame_clk=%d lines=%d" \
        $verdict $done $no $fh $e1 [rd m_frame_clk] [rd m_frame_lines]]
disconnect_hw_server
exit 0
