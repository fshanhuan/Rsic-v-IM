# JTAG / PS(ARM) 可达性探针
# 目的：确认 xsdb 能否连上板上 Zynq，并列出目标（是否有 ARM/APU 核）
proc P {s} { puts "\[JTAG\] $s" }

if {[catch {connect} e]} {
    P "CONNECT-FAIL: $e"
    exit 1
}
P "CONNECT-OK"

if {[catch {targets} tg]} {
    P "TARGETS-FAIL: $tg"
    exit 2
}
P "TARGETS-BEGIN"
puts $tg
P "TARGETS-END"

# 逐个目标尝试识别
if {[catch {jtag targets} jt]} {
    P "JTAG-TARGETS-FAIL: $jt"
} else {
    P "JTAGTGT-BEGIN"
    puts $jt
    P "JTAGTGT-END"
}

P "DONE"
exit 0
