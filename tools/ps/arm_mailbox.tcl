# arm_mailbox.tcl —— 让 A9 代读一串地址（SLCR/PL 寄存器），把结果写到 OCM 邮箱，再由 JTAG 读回
# 用法：xsdb 里设置 ::ADDRS_LIST 后 source 本脚本；或直接改下面的 ADDRS。
#
# 为什么需要它：Zynq 的 Debug-AP 对 SLCR 段读回恒 0，但 CPU 自己读得到。
# 编码由 Tcl 端"迷你汇编器"生成（movw/movt/ldr/str），不再手写机器码，避免错编码。
proc P {s} { puts "\[MB\] $s" ; flush stdout }

# ---------- 迷你汇编器（ARM/A32） ----------
proc a_movw {rd imm16} { expr {0xE3000000 | (($imm16 >> 12) << 16) | ($rd << 12) | ($imm16 & 0xFFF)} }
proc a_movt {rd imm16} { expr {0xE3400000 | (($imm16 >> 12) << 16) | ($rd << 12) | ($imm16 & 0xFFF)} }
proc a_ldr  {rd rn off} { expr {0xE5900000 | ($rn << 16) | ($rd << 12) | ($off & 0xFFF)} }
proc a_str  {rd rn off} { expr {0xE5800000 | ($rn << 16) | ($rd << 12) | ($off & 0xFFF)} }
proc a_spin {} { expr {0xEAFFFFFE} }
proc a_imm  {rd v} { list [a_movw $rd [expr {$v & 0xFFFF}]] [a_movt $rd [expr {($v >> 16) & 0xFFFF}]] }

proc RD {addr} {
    if {[catch {set r [mrd -force $addr 1]} e]} { return "ERR" }
    set s [string toupper [lindex $r end]]
    if {[regexp {([0-9A-F]{8})} $s -> h]} { return $h }
    return $s
}
proc WR {addr val} { if {[catch {mwr -force $addr $val} e]} { return "ERR:$e" } ; return "OK" }

# ---------- 参数 ----------
if {![info exists ::ADDRS]} {
    set ::ADDRS {0xF8000100 0xF800010C 0xF8000128 0xF800012C 0xF8000000 0xF8007080}
}
set CODE_BASE 0xFFFFA000
set MAIL_BASE 0xFFFFB000

# ---------- 生成程序 ----------
set code {}
lappend code {*}[a_imm 1 $MAIL_BASE]
set off 0
foreach a $::ADDRS {
    lappend code {*}[a_imm 2 $a]
    lappend code [a_ldr 3 2 0]
    lappend code [a_str 3 1 $off]
    incr off 4
}
lappend code {*}[a_imm 4 0xBEEF0001]
lappend code [a_str 4 1 $off]
lappend code [a_spin]
P "程序长度 [llength $code] 条，代码@0x[format %08X $CODE_BASE] 邮箱@0x[format %08X $MAIL_BASE]"

connect
if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} { P "NO-CORE: $e" ; exit 2 }
catch {stop}
after 200

set a $CODE_BASE
foreach w $code { set r [WR $a $w] ; if {$r ne "OK"} { P "WR-FAIL @[format %08X $a] $r" } ; incr a 4 }
# 回读校验
set a $CODE_BASE
set bad 0
foreach w $code { if {[RD $a] ne [format %08X $w]} { incr bad } ; incr a 4 }
P "代码回读：$bad 个不一致"
# 邮箱预置
set n [expr {[llength $::ADDRS] + 1}]
for {set i 0} {$i < $n} {incr i} { WR [expr {$MAIL_BASE + $i * 4}] 0xDEADBEEF }

catch {rwr cpsr 0x000000D3}
if {[catch {rwr pc $CODE_BASE} e]} { P "PC-FAIL: $e" ; exit 3 }
con
after 400
stop
after 100
P "PC = [rrd pc]"

for {set i 0} {$i < $n} {incr i} {
    set addr [expr {$MAIL_BASE + $i * 4}]
    set v [RD $addr]
    if {$i < [llength $::ADDRS]} {
        P "  [format 0x%08X [lindex $::ADDRS $i]] = $v"
    } else {
        P "  标记 = $v （期望 BEEF0001）"
    }
}
catch {rst -dap}
P "DONE"
exit 0
