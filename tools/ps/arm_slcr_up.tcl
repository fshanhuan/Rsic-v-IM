# arm_slcr_up.tcl —— 只用 CPU 把 PS→PL 的几个总开关摆正（**完全不碰 AXI**，不会把互连挂死）
#
# 为什么需要：Zynq 上电后 SLCR 里这三样默认是"关"的，而 JTAG 烧 .bit 只配 PL、不配 PS，
# 所以 PL 侧的 AXI 从端拿不到时钟、也过不去信号，PS 一访问就会永久等待（实测把互连挂死）。
#
#   0xF8000900 LVL_SHFTR_EN  = 0xF     PS→PL 电平位移器全开（不开则 PS-PL 信号根本不通）
#   0xF8000128 FPGA0_CLK_CTRL = 0x00700F01  FCLK0 使能 + 50 MHz（这是 Vivado 给本 BD 算的值）
#   0xF8000240 RST_FPGA_CTRL  = 0     释放 PL 各 FCLK 域复位
#
# 程序只读写 SLCR（PS 内部），不碰 0x4000_0000/0x4001_0000，所以哪怕时钟没配对也不会挂。
proc P {s} { puts "\[SLCR\] $s" ; flush stdout }

proc a_movw {rd imm16} { expr {0xE3000000 | (($imm16 >> 12) << 16) | ($rd << 12) | ($imm16 & 0xFFF)} }
proc a_movt {rd imm16} { expr {0xE3400000 | (($imm16 >> 12) << 16) | ($rd << 12) | ($imm16 & 0xFFF)} }
proc a_mov_imm {rd v} { expr {0xE3A00000 | ($rd << 12) | ($v & 0xFF)} }
proc a_ldr {rd rn off} { expr {0xE5900000 | ($rn << 16) | ($rd << 12) | ($off & 0xFFF)} }
proc a_str {rd rn off} { expr {0xE5800000 | ($rn << 16) | ($rd << 12) | ($off & 0xFFF)} }
proc a_spin {} { expr {0xEAFFFFFE} }
proc a_imm {rd v} { list [a_movw $rd [expr {$v & 0xFFFF}]] [a_movt $rd [expr {($v >> 16) & 0xFFFF}]] }

proc RD {addr} {
    if {[catch {set r [mrd -force $addr 1]} e]} { return "ERR" }
    set s [string toupper [lindex $r end]]
    if {[regexp {([0-9A-F]{8})} $s -> h]} { return $h }
    return $s
}
proc WR {addr val} { if {[catch {mwr -force $addr $val} e]} { return "ERR:$e" } ; return "OK" }

set CODE 0xFFFFC000
set MAIL 0xFFFFD000

set code {}
lappend code {*}[a_imm 1 $MAIL]
# 解锁 SLCR
lappend code {*}[a_imm 2 0xF8000008]
lappend code {*}[a_imm 0 0x0000DF0D]
lappend code [a_str 0 2 0]
# LVL_SHFTR_EN = 0xF
lappend code {*}[a_imm 2 0xF8000900]
lappend code [a_mov_imm 0 0x0F]
lappend code [a_str 0 2 0]
# FCLK0 = 0x00700F01
lappend code {*}[a_imm 2 0xF8000128]
lappend code {*}[a_imm 3 0x00700F01]
lappend code [a_str 3 2 0]
# RST_FPGA = 0
lappend code {*}[a_imm 2 0xF8000240]
lappend code [a_mov_imm 0 0]
lappend code [a_str 0 2 0]
# 锁回 SLCR
lappend code {*}[a_imm 2 0xF8000004]
lappend code {*}[a_imm 0 0x0000767B]
lappend code [a_str 0 2 0]
# 回读 4 个寄存器 + 标记
set off 0
foreach a {0xF8000128 0xF8000900 0xF8000240 0xF800010C} {
    lappend code {*}[a_imm 2 $a]
    lappend code [a_ldr 3 2 0]
    lappend code [a_str 3 1 $off]
    incr off 4
}
lappend code {*}[a_imm 5 0xBEEF0006]
lappend code [a_str 5 1 $off]
lappend code [a_spin]
P "程序 [llength $code] 条"

if {[info exists ::env(SLCR_DUMP_ONLY)] && $::env(SLCR_DUMP_ONLY) != "0"} {
    set i 0
    foreach w $code { P [format "WORD|%d|%08X" $i $w] ; incr i }
    P "DUMP-ONLY"
    exit 0
}

connect
if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} { P "NO-CORE: $e" ; exit 2 }
if {[catch {stop} e]} { P "HALT-FAIL（核卡在总线访问上，需要断电重上电）: $e" ; exit 3 }
after 200

set a $CODE
foreach w $code { set r [WR $a $w] ; if {$r ne "OK"} { P "WR-FAIL @[format %08X $a] $r" } ; incr a 4 }
set a $CODE
set bad 0
foreach w $code { if {[RD $a] ne [format %08X $w]} { incr bad } ; incr a 4 }
P "代码回读 $bad 个不一致"
for {set i 0} {$i < 5} {incr i} { WR [expr {$MAIL + $i*4}] 0xDEADBEEF }

catch {rwr cpsr 0x000000D3}
catch {rwr pc $CODE}
con
after 500
catch {stop}
after 100
P "PC=[rrd pc]"
set v0 [RD $MAIL]
set v1 [RD [expr {$MAIL+4}]]
set v2 [RD [expr {$MAIL+8}]]
set v3 [RD [expr {$MAIL+12}]]
set mk [RD [expr {$MAIL+16}]]
P "FPGA0_CLK_CTRL=$v0 (期望 00700F01)  LVL_SHFTR_EN=$v1 (期望 0000000F)"
P "RST_FPGA=$v2 (期望 00000000)     PLL_STATUS=$v3 (期望 0000003F)"
P "标记=$mk (期望 BEEF0006)"
if {$v0 eq "00700F01" && $v1 eq "0000000F" && $mk eq "BEEF0006"} { P "RESULT=SLCR-PASS" } else { P "RESULT=SLCR-FAIL" }
P "DONE"
exit 0
