# arm_drain.tcl —— S5：让 A9 把记录仪 FIFO 排空到 PL 侧 DRAM，再经 JTAG 导出 CSV
#
# 前置：烧 _baseline_v9/board_top_ps_rec_S5.bit（PS + 记录仪 MMIO）
#        地址：DRAM 0x4000_0000（64 KB）、MMIO 0x4001_0000（4 KB，寄存器索引<<2）
#
# 寄存器（rec_mmio）：
#   idx35 (0x8C) 读 = FIFO 队头（只窥视）
#   idx37 (0x94) 读 = FIFO 深度
#   idx38 (0x98) 写 = ADC_CTL：bit0 使能、bit2 弹出
#   idx40 (0xA0) 读 = 累计样本数
#
# 程序做的事：
#   ADC_CTL <- 1（使能）→ 循环 256 次 { 读队头 → 存 DRAM → 弹出 } → 计数写邮箱
proc P {s} { puts "\[DRAIN\] $s" ; flush stdout }

# ---------- 迷你汇编器（只实现要用的几条，全部 ARM/A32） ----------
proc a_movw {rd imm16} { expr {0xE3000000 | (($imm16 >> 12) << 16) | ($rd << 12) | ($imm16 & 0xFFF)} }
proc a_movt {rd imm16} { expr {0xE3400000 | (($imm16 >> 12) << 16) | ($rd << 12) | ($imm16 & 0xFFF)} }
proc a_mov_imm {rd v} { expr {0xE3A00000 | ($rd << 12) | ($v & 0xFF)} }        ;# 0..255 够用
proc a_ldr {rd rn off} { expr {0xE5900000 | ($rn << 16) | ($rd << 12) | ($off & 0xFFF)} }
proc a_str {rd rn off} { expr {0xE5800000 | ($rn << 16) | ($rd << 12) | ($off & 0xFFF)} }
proc a_add_imm {rd rn off} { expr {0xE2800000 | ($rn << 16) | ($rd << 12) | ($off & 0xFFF)} }
proc a_cmp_reg {rn rm} { expr {0xE1500000 | ($rn << 16) | $rm} }
proc a_cmp_imm {rn imm} { expr {0xE3500000 | ($rn << 16) | ($imm & 0xFFF)} }
proc a_bne_back {k} { expr {0x1A000000 | (((-($k + 2)) & 0xFFFFFF))} }         ;# 回跳 k 条之前
proc a_beq_back {k} { expr {0x0A000000 | (((-($k + 2)) & 0xFFFFFF))} }         ;# 回跳 k 条之前
proc a_spin {} { expr {0xEAFFFFFE} }
proc a_imm {rd v} { list [a_movw $rd [expr {$v & 0xFFFF}]] [a_movt $rd [expr {($v >> 16) & 0xFFFF}]] }

proc RD {addr} {
    for {set t 0} {$t < 3} {incr t} {
        if {[catch {set r [mrd -force $addr 1]} e]} { after 150 ; continue }
        set s [string toupper [lindex $r end]]
        if {[regexp {([0-9A-F]{8})} $s -> h]} { return $h }
        return $s
    }
    return "ERR"
}
proc WR {addr val} { if {[catch {mwr -force $addr $val} e]} { return "ERR:$e" } ; return "OK" }
proc H2D {h} { if {[catch {expr "0x$h"} v]} { return -1 } ; return $v }   ;# ★ 必须用"引号"先替换，expr 的 {0x$h} 会当成裸字报错

# ---------- 参数 ----------
set N        256                    ;# 排空样本数（可用环境变量 DRAIN_N 覆盖）
if {[info exists ::env(DRAIN_N)]} { set N [expr {$::env(DRAIN_N) + 0}] }
if {$N < 1 || $N > 8192} { puts "DRAIN_N 超范围（1..8192）" ; exit 2 }
set CODE     0xFFFFA000
set MAIL     0xFFFFB000
set DRAM     0x40000000
set MMIO     0x40010000

# ---------- 生成程序 ----------
# 寄存器约定：R6=DRAM 指针 R9=MMIO 基址 R10=邮箱 R8=i R7=N R0=弹出码 R1..R5=临时
#
# ★★ 必须先做 PS→PL 的总开关（前 15 条）：JTAG 烧 .bit 只配 PL、不配 PS，
#    上电后 LVL_SHFTR_EN=0、FCLK0 没使能、PL 复位没释放。此时**任何** AXI 访问都会
#    永远等不到响应，把 PS 互连锁死（实测只能断电重上电，2026-11-18 01:05）。
#    所以本程序自己先把这三样打开，再自检 FCLK0 的使能位，最后才碰 AXI。
set code {}
proc a_and_imm {rd rn imm} { expr {0xE2000000 | ($rn << 16) | ($rd << 12) | ($imm & 0xFFF)} }

# (1) 解锁 SLCR
lappend code {*}[a_imm 2 0xF8000008]
lappend code {*}[a_imm 0 0x0000DF0D]
lappend code [a_str 0 2 0]
# (2) PS→PL 电平位移器全开
lappend code {*}[a_imm 2 0xF8000900]
lappend code [a_mov_imm 0 0x0F]
lappend code [a_str 0 2 0]
# (3) FCLK0 使能 + 50 MHz（Vivado 给本 BD 算出来的值）
lappend code {*}[a_imm 2 0xF8000128]
lappend code {*}[a_imm 3 0x00700F01]
lappend code [a_str 3 2 0]
# (4) 释放 PL 各 FCLK 域复位
lappend code {*}[a_imm 2 0xF8000240]
lappend code [a_mov_imm 0 0x00]
lappend code [a_str 0 2 0]
# (5) 锁回 SLCR
lappend code {*}[a_imm 2 0xF8000004]
lappend code {*}[a_imm 0 0x0000767B]
lappend code [a_str 0 2 0]

# (6) 自检：FCLK0 的 CLKACT 位必须为 1，否则**不要**去碰 AXI（先把结论写邮箱然后自旋）
lappend code {*}[a_imm 2 0xF8000128]
lappend code [a_ldr 4 2 0]
lappend code [a_and_imm 4 4 1]
lappend code [a_cmp_imm 4 0]
set guard_beq [llength $code]
lappend code 0x00000000                      ;# 占位：EQ -> 失败出口

# (7) 正常路径
lappend code {*}[a_imm 10 $MAIL]
lappend code {*}[a_imm 6 $DRAM]
lappend code {*}[a_imm 9 $MMIO]
lappend code [a_movw 7 [expr {$N & 0xFFFF}]]  ;# ★ 不能用 mov imm8：N=256 会被截成 0
if {$N > 0xFFFF} { lappend code [a_movt 7 [expr {($N >> 16) & 0xFFFF}]] }
lappend code [a_mov_imm 0 5]                 ;# ADC_CTL: en=1 + pop=1
lappend code [a_mov_imm 1 1]                 ;# 先只使能
lappend code [a_str 1 9 152]                 ;# idx38 (38*4=152) <- 1
# ---------- 先排空历史积压（这一段不计数）----------
# 为什么：FIFO 满时 xadc_sampler 是"丢新样本"，积压尾部与新数据头部之间有一段被丢掉的
# 空白，直接连着数会在中间出现一个相位断点。先把积压清空，再开始计数，拿到的就是
# 连续的新样本，游程应当全是 128（波形半周期）。
set flush_top [llength $code]
lappend code [a_ldr 4 9 148]                 ;# idx37 深度
lappend code [a_cmp_imm 4 0]
set flush_beq [llength $code]
lappend code 0x00000000                      ;# 占位：EQ -> 出口
lappend code [a_str 0 9 152]                 ;# pop
lappend code 0xF57FF04F                      ;# DSB
set flush_b [llength $code]
lappend code 0x00000000                      ;# 占位：B -> flush_top
set flush_end [llength $code]
lset code $flush_beq [expr {0x0A000000 | (($flush_end - ($flush_beq + 2)) & 0xFFFFFF)}]
lset code $flush_b   [expr {0xEA000000 | ((($flush_top - ($flush_b + 2)) & 0xFFFFFF))}]
lappend code [a_mov_imm 8 0]                 ;# i = 0
# ★ S7 用：排空开始前的 PL 侧采样计数（idx40，偏移 160）→ 邮箱[2]
lappend code [a_ldr 4 9 160]
lappend code [a_str 4 10 8]
# ★ 循环里必须**先等 FIFO 有数据**：ARM 一轮只要几百纳秒，采样却是 5 µs 一个，
#   不等的话会把空 FIFO 读成垃圾。所以先读 idx37（深度）自旋，直到非 0。
set loop_start [llength $code]
lappend code [a_ldr 4 9 148]                 ;# idx37 (37*4=148) FIFO 深度
lappend code [a_cmp_imm 4 0]
lappend code [a_beq_back 2]                  ;# 深度为 0 -> 回到上一条 LDR
lappend code [a_ldr 3 9 140]                 ;# idx35 (35*4=140) 队头
lappend code [a_str 3 6 0]                   ;# 存到 [R6]
lappend code [a_add_imm 6 6 4]               ;# DRAM 指针 +4
lappend code [a_str 0 9 152]                 ;# idx38 <- 5（en+pop）
# ★ 关键：A9 的 STR 是 posting 的（走写缓冲），不保证下一条 LDR 能看到它生效。
#   不加屏障时，紧跟着的 peek 可能又读到**旧队头** → 同一样本被排空两次（实测游程里
#   出现 215 这种 >128 的段）。DSB 强制等写完成，保证 pop 之后再 peek。
lappend code 0xF57FF04F                      ;# DSB SY
lappend code [a_add_imm 8 8 1]               ;# i++
lappend code [a_cmp_reg 8 7]
set k [expr {[llength $code] - $loop_start}]
lappend code [a_bne_back $k]
# ★ S7 用：排空结束后的采样计数 → 邮箱[3]
lappend code [a_ldr 4 9 160]
lappend code [a_str 4 10 12]
lappend code [a_str 8 10 0]                  ;# 邮箱[0] = 实际循环次数
lappend code {*}[a_imm 5 0xBEEF0005]
lappend code [a_str 5 10 4]                  ;# 邮箱[1] = 标记
lappend code [a_spin]

# (8) 失败出口：FCLK0 没使能（写标记 0xDEAD0001 后自旋，绝不去碰 AXI）
set fail_at [llength $code]
lappend code {*}[a_imm 10 $MAIL]
lappend code {*}[a_imm 5 0xDEAD0001]
lappend code [a_str 5 10 4]
lappend code [a_spin]
set off [expr {$fail_at - ($guard_beq + 2)}]
lset code $guard_beq [expr {0x0A000000 | ($off & 0xFFFFFF)}]

P "程序 [llength $code] 条（循环体 $k 条，失败出口在第 $fail_at 条）"

# 离线自检：只打印机器码，不碰硬件（给 tools/ps/arm_a32_disasm.py 反汇编核对）
if {[info exists ::env(DRAIN_DUMP_ONLY)] && $::env(DRAIN_DUMP_ONLY) != "0"} {
    set idx 0
    foreach w $code { P [format "WORD|%d|%08X" $idx $w] ; incr idx }
    P "DUMP-ONLY 结束"
    exit 0
}

connect
# ★ DAP 有时会锁在 "AHB AP transaction error, DAP status 0x30000021"，此时 APU 列不出来；
#   `rst -dap` 能救回来（实测多次）。先正常选核，失败就复位 DAP 再重试。
set got 0
for {set i 1} {$i <= 5} {incr i} {
    if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} {
        catch {targets -set -filter {name =~ "DAP*"}}
        catch {rst -dap}
        after 900
    } else { set got 1 ; break }
}
if {!$got} { P "NO-CORE（DAP 复位后仍无核）" ; catch {puts [targets]} ; exit 2 }
set halt_err [catch {stop} e]
# "Already stopped" 不是错误（前面的 rst -dap 可能已经把核停住了）
if {$halt_err && ![string match "*Already stopped*" $e]} {
    P "HALT-FAIL（核卡在总线访问上，需要断电重上电）: $e" ; exit 3
}
after 200

set a $CODE
foreach w $code { set r [WR $a $w] ; if {$r ne "OK"} { P "WR-FAIL @[format %08X $a] $r" } ; incr a 4 }
set a $CODE
set bad 0
foreach w $code { if {[RD $a] ne [format %08X $w]} { incr bad } ; incr a 4 }
P "代码回读 $bad 个不一致"
WR $MAIL 0xDEADBEEF
WR [expr {$MAIL+4}] 0xDEADBEEF
WR [expr {$MAIL+8}] 0xDEADBEEF
WR [expr {$MAIL+12}] 0xDEADBEEF

catch {rwr cpsr 0x000000D3}
catch {rwr pc $CODE}
con
after 2500
if {[catch {stop} e]} { P "停不下来（可能卡在 AXI 上，看是否有 SLVERR）: $e" }
after 100
P "PC=[rrd pc]"
set cnt  [RD $MAIL]
set mark [RD [expr {$MAIL+4}]]
set c0   [RD [expr {$MAIL+8}]]
set c1   [RD [expr {$MAIL+12}]]
P "邮箱: 循环次数=$cnt（dec=[H2D $cnt]，期望 [format %08X $N]） 标记=$mark（期望 BEEF0005）"
P "采样计数: 起=0x$c0 止=0x$c1"

# ---------- 导出 DRAM 内容 ----------
set WORK "E:/FPGA/v9_vivado_ila"
set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set out "$WORK/sim/build/drain_$stamp.csv"
set fp [open $out w]
puts $fp "index,raw_hex,code_dec,voltage_v"
set got 0
set hi 0
set lo 0
set prev -1
set run 0
set runs {}
for {set i 0} {$i < $N} {incr i} {
    set w [RD [expr {$DRAM + $i*4}]]
    set v [H2D $w]
    if {$v < 0} { break }
    set code [expr {($v >> 4) & 0xFFF}]           ;# XADC 结果左对齐在 [15:4]
    set volt [expr {$code * 1.0 / 4096.0}]
    puts $fp [format "%d,0x%04X,%d,%.4f" $i $code $code $volt]
    if {$code >= 2048} { incr hi } else { incr lo }
    if {$code == $prev} { incr run } else { if {$run > 0} { lappend runs $run } ; set run 1 ; set prev $code }
    incr got
}
if {$run > 0} { lappend runs $run }
close $fp
P "CSV 导出 $got 行 -> $out  （高电平样本 $hi，低电平样本 $lo）"
P "波形游程：$runs  （假 DRP 的方波半周期 = 128 样本）"

# ---------- 吞吐/解耦（S7）----------
set dc  [expr {[H2D $c1] - [H2D $c0]}]
if {$dc > 0} {
    set dur_us [expr {$dc * 5}]                    ;# 200 kHz -> 每样本 5 µs
    set rate   [expr {$got * 1000000.0 / $dur_us}]
    P [format "排空期间 PL 侧新增样本 = %d（= %.2f ms），排空 %d 样本 -> %.0f kSa/s" \
        $dc [expr {$dur_us/1000.0}] $got [expr {$rate/1000.0}]]
}

# 判据：标记对、行数对、两档都有；**中间段**（去掉首尾不完整段）必须全是 128
set mid {}
set nr [llength $runs]
for {set i 1} {$i < $nr - 1} {incr i} { lappend mid [lindex $runs $i] }
set mid_ok 1
foreach r $mid { if {$r != 128} { set mid_ok 0 } }
if {$mark eq "BEEF0005" && $got == $N && $hi > 0 && $lo > 0} {
    P "RESULT=DRAIN-PASS"
    if {$mid_ok} {
        P "RESULT=RUNLEN-PASS（中间 [llength $mid] 段全部恰好 128 样本，无丢失/重复）"
    } else {
        P "RESULT=RUNLEN-MIXED（中间段异常）"
    }
} else {
    P "RESULT=DRAIN-FAIL"
}
P "DONE"
exit 0
