# ARM(A9) 自写代码执行 —— 修正版
# 修正1：内存访问必须选中 Cortex-A9 核目标（选 APU* 组目标读出全 0）
# 修正2：mwr 的值必须是 Tcl 数字字面量，传字符串 "0x..." 会静默失败
proc P {s} { puts "\[ARM\] $s" ; flush stdout }
proc RD {addr} {
    if {[catch {set r [mrd -force $addr 1]} e]} { return "ERR" }
    set s [string toupper [lindex $r end]]
    if {[regexp {([0-9A-F]{8})} $s -> h]} { return $h }
    return $s
}
proc WR {addr val} {
    if {[catch {mwr -force $addr $val} e]} { return "ERR:$e" }
    return "OK"
}

connect
if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} { P "NO-CORE: $e" ; exit 2 }
catch {stop}
after 200
P "CORE0-SELECTED, PC=[rrd pc]"

# ---------------- 程序 1：写/读 OCM + ALU ----------------
# 0xFFFF4000: MOVW R1,#0x5000 ; MOVT R1,#0xFFFF  -> R1=0xFFFF5000
#             MOVW R0,#0x1234 ; MOVT R0,#0xA55A  -> R0=0xA55A1234
#             STR R0,[R1] ; LDR R2,[R1] ; ADD R2,R2,#1 ; STR R2,[R1,#4]
#             MOVW R3,#0x6004 ; MOVT R3,#0xFFFF ; MOVW R4,#0x5A5A ; MOVT R4,#0xA5A5
#             STR R4,[R3] ; B .
set BASE1 0xFFFF4000
set CODE1 {
    0xE3051000 0xE34F1FFF 0xE3010234 0xE34A055A
    0xE5810000 0xE5912000 0xE2822001 0xE5812004
    0xE3063004 0xE34F3FFF 0xE3054A5A 0xE34A45A5
    0xE5834000 0xEAFFFFFE
}
set a $BASE1
set werr 0
foreach w $CODE1 { set r [WR $a $w] ; if {$r ne "OK"} { if {!$werr} { P "WR-ERR @[format %08X $a]: $r" } ; set werr 1 } ; incr a 4 }
P "程序1 写入 $werr 个错误"
# 回读代码字，确认真的写进去了
set a $BASE1
set idx 0
set code_ok 1
foreach w $CODE1 {
    set g [RD $a]
    if {$g ne [format %08X $w]} { P "  CODE-MISMATCH @[format %08X $a] got=$g exp=[format %08X $w]" ; set code_ok 0 }
    incr a 4
}
if {$code_ok} { P "CODE1-VERIFIED (14 words @0xFFFF4000)" } else { P "CODE1-NOT-WRITTEN" }

WR 0xFFFF5000 0xDEADBEEF
WR 0xFFFF5004 0xDEADBEEF
WR 0xFFFF6004 0xDEADBEEF
P "预置 5000=[RD 0xFFFF5000] 5004=[RD 0xFFFF5004] 6004=[RD 0xFFFF6004]"

catch {rwr cpsr 0x000000D3}
catch {rwr pc $BASE1}
P "跳转 PC=[rrd pc]"
con
after 400
stop
after 100
P "停止 PC=[rrd pc]"
P "结果 5000=[RD 0xFFFF5000] 5004=[RD 0xFFFF5004] 6004=[RD 0xFFFF6004]"
set arm_ok 1
if {[RD 0xFFFF5000] ne "A55A1234"} { set arm_ok 0 }
if {[RD 0xFFFF5004] ne "A55A1235"} { set arm_ok 0 }
if {[RD 0xFFFF6004] ne "A5A55A5A"} { set arm_ok 0 }
if {$arm_ok} { P "P1-ARM-EXEC-PASS" } else { P "P1-ARM-EXEC-FAIL" }

# ---------------- 程序 2：CPU 侧读 SLCR（JTAG 读出来全是 0） ----------------
# 0xFFFF8000: R1=0xFFFF7000 ; R2=0xF8007080 ; LDR R3,[R2] ; STR R3,[R1]
#             R4=0xF8000128 ; LDR R3,[R4] ; STR R3,[R1,#4]
#             R5=0xA5A55A5A ; STR R5,[R1,#8] ; B .
set BASE2 0xFFFF8000
set CODE2 {
    0xE3071000 0xE34F1FFF 0xE3072080 0xE34F2800
    0xE5923000 0xE5813000 0xE3004128 0xE34F4800
    0xE5943000 0xE5813004 0xE3055A5A 0xE34A55A5
    0xE5815008 0xEAFFFFFE
}
set a $BASE2
foreach w $CODE2 { WR $a $w ; incr a 4 }
WR 0xFFFF7000 0x11111111
WR 0xFFFF7004 0x22222222
WR 0xFFFF7008 0x33333333
P "预置邮箱 7000=[RD 0xFFFF7000] 7004=[RD 0xFFFF7004] 7008=[RD 0xFFFF7008]"
catch {rwr cpsr 0x000000D3}
catch {rwr pc $BASE2}
P "跳转 PC=[rrd pc]"
con
after 400
stop
after 100
P "停止 PC=[rrd pc]"
set m0 [RD 0xFFFF7000]
set m1 [RD 0xFFFF7004]
set m2 [RD 0xFFFF7008]
P "邮箱 7000=$m0 (CPU 读 0xF8007080) 7004=$m1 (CPU 读 0xF8000128) 7008=$m2"
if {$m2 eq "A5A55A5A"} { P "P2-ARM-SLCR-READ-PASS" } else { P "P2-ARM-SLCR-READ-FAIL" }

if {$code_ok && $arm_ok} { P "RESULT=PASS" } else { P "RESULT=FAIL" }
catch {rst -cores}
after 300
catch {con}
P "RESTORED"
P "DONE"
exit 0
