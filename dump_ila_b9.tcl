# =============================================================================
# dump_ila_b9.tcl — 烧新 bitstream，并**用 ILA 直接验证 v9 B9 修复**：
#                  ecall 之后 PC 到底有没有回到 mtvec。
# -----------------------------------------------------------------------------
# 与前一个脚本（dump_ila_csv.tcl）的区别：
#   * 这个会 **program_hw_devices**（烧新 bit）—— 因为它要验证的是新 RTL；
#   * 探针从 13 根变成 16 根（多了 probe13/14/15），必须用新的 .ltx；
#   * 做两次抓取，各自写一个 CSV：
#       ① 触发 probe15(debug_ifu_pc) == 0x00000000
#          → 修复前**永远抓不到**（PC 从不回 0）；修复后 1~2µs 内必然命中
#       ② 触发 probe13(debug_dnpc_flag) == 1
#          → 抓一次重定向，同拍看 probe14(debug_ready) / probe15(debug_ifu_pc)
#
# 用法：
#   vivado -mode batch -notrace -source dump_ila_b9.tcl -log dump_ila_b9.log
# =============================================================================

set BIT    "E:/FPGA/v9_vivado_ila/v9_ila/v9_ila.runs/impl_1/board_top_gui.bit"
set LTX    "E:/FPGA/v9_vivado_ila/v9_ila/v9_ila.runs/impl_1/board_top_gui.ltx"
set CSV_PC "E:/FPGA/v9_vivado_ila/ila_b9_pc0.csv"
set CSV_RD "E:/FPGA/v9_vivado_ila/ila_b9_redir.csv"

proc hdr {t} { puts ""; puts "================ $t ================" }

hdr "0) 检查输入文件"
if {![file exists $BIT]} { puts "ERR: 找不到 bitstream $BIT"; exit 1 }
if {![file exists $LTX]} { puts "ERR: 找不到探针文件 $LTX"; exit 1 }
puts "bit = $BIT  ([file size $BIT] 字节)"
puts "ltx = $LTX  ([file size $LTX] 字节)"

hdr "1) 打开 Hardware Manager"
open_hw_manager

hdr "2) 连接 hw_server（GUI 已经关掉了，可能要自己把 server 拉起来）"
set ok 0
if {[catch { connect_hw_server -url localhost:3121 } e]} {
    puts "connect 失败：$e"
    puts "--- 尝试 start_hw_server ---"
    if {[catch { start_hw_server -url localhost:3121 } e2]} {
        puts "ERR start_hw_server: $e2"
        exit 1
    }
    after 3000
    if {[catch { connect_hw_server -url localhost:3121 } e3]} {
        puts "ERR 仍然连不上: $e3"
        exit 1
    }
}
puts "servers = [get_hw_servers]"

hdr "3) 找 target 并打开"
set tars [get_hw_targets]
puts "targets = $tars"
if {[llength $tars] == 0} { puts "ERR: 没有 target（板子/下载器没插好？）"; exit 2 }
set tar [lindex $tars 0]
current_hw_target $tar
if {[catch { open_hw_target } e]} { puts "ERR open_hw_target: $e"; exit 3 }
puts "target open ok"

hdr "4) 挑出 PL 器件（不是 arm_dap_0）"
set devs [get_hw_devices]
puts "devices = $devs"
set dev ""
foreach d $devs { if {[string match "*xc7z020*" $d]} { set dev $d ; break } }
if {$dev eq ""} { set dev [lindex $devs end] }
current_hw_device $dev
puts "device = $dev"

hdr "5) 烧录新 bitstream（B9 修复版）"
set_property PROGRAM.FILE $BIT [current_hw_device]
if {[catch { program_hw_devices [current_hw_device] } e]} { puts "ERR program: $e"; exit 4 }
puts "program ok"
refresh_hw_device -quiet [current_hw_device]

hdr "6) 关联 16 探针的 .ltx"
if {[catch { set_property PROBES.FILE $LTX $dev } e]} { puts "PROBES.FILE warn: $e" } else { puts "PROBES.FILE ok" }
if {[catch { set_property FULL_PROBES.FILE $LTX $dev } e]} { puts "FULL_PROBES.FILE warn: $e" } else { puts "FULL_PROBES.FILE ok" }
# ★ 必须 -update_hw_probes true，否则会报 "No probes for hw_ila"
if {[catch { refresh_hw_device -update_hw_probes true $dev } e]} { puts "refresh warn: $e" } else { puts "refresh ok" }

hdr "7) 找 ILA core + 列出探针"
set ilas {}
catch { set ilas [get_hw_ilas -of_objects $dev] }
puts "ilas = $ilas"
if {[llength $ilas] == 0} {
    puts "ERR: 没找到 ILA core"
    catch { close_hw_target }; catch { disconnect_hw_server }
    exit 5
}
current_hw_ila [lindex $ilas 0]
set prb [get_hw_probes -of_objects [current_hw_ila]]
puts "探针数 = [llength $prb]   （修复版应为 16）"
foreach p $prb { puts "   $p" }

# -----------------------------------------------------------------------------
# 抓取任务：设触发条件 → run → wait → upload → 写 CSV
#   ★ 触发值语法（这里是唯一容易写错的地方，实测踩过）：
#       set_property TRIGGER_COMPARE_VALUE <比较串> <探针对象>
#     比较串必须写成 **运算符 + 位宽 + 进制 + 值** 连在一起，例如
#       eq32'h00000000      （32 位等于 0）
#       eq1'h1              （1 位等于 1）
#     写成裸值 32'h00000000 会报：
#       ERROR: [Designutils 20-610] Invalid logic operator '3' in string: 32'h00000000
#     （它把 '3' 当成运算符去找了）
#   另外 CONTROL.TRIGGER_MODE 在当前版本是**只读**的（默认已是 BASIC_ONLY），
#     不要去 set，否则报 Labtoolstcl 44-156。
#   直接传 **探针对象** 给 set_property，绕开 "$hier/probeN" 名字拼写的问题。
# -----------------------------------------------------------------------------
proc grab {tag ila probe_obj cmp_str csv} {
    puts ""
    puts "================ 抓取：$tag ================"
    if {[catch { set_property TRIGGER_COMPARE_VALUE $cmp_str $probe_obj } e]} {
        puts "ERR 设触发条件失败: $e"
        return 0
    }
    puts "触发条件 = $probe_obj  $cmp_str"
    if {[catch { run_hw_ila $ila } e]} { puts "ERR run: $e"; return 0 }
    if {[catch { wait_on_hw_ila -timeout 60 $ila } e]} { puts "wait warn: $e" }
    set d ""
    if {[catch { set d [upload_hw_ila_data $ila] } e]} { puts "ERR upload: $e"; return 0 }
    if {$d eq ""} { puts "ERR: upload 返回空"; return 0 }
    if {[catch { write_hw_ila_data -force -csv_file $csv $d } e]} { puts "ERR write: $e"; return 0 }
    puts "OK -> $csv  ([file size $csv] 字节)"
    # 抓完把触发条件清掉，免得影响下一次
    catch { reset_hw_ila $ila }
    return 1
}

set p_ifu_pc    [get_hw_probes -quiet -of_objects [current_hw_ila] debug_ifu_pc]
set p_dnpc_flag [get_hw_probes -quiet -of_objects [current_hw_ila] debug_dnpc_flag]
puts ""
puts "probe(debug_ifu_pc)    = $p_ifu_pc"
puts "probe(debug_dnpc_flag) = $p_dnpc_flag"

# ① 最关键的验证：PC 回到 mtvec(=0)
if {[llength $p_ifu_pc]} {
    grab "debug_ifu_pc == 0 (PC 回到 mtvec)" [current_hw_ila] $p_ifu_pc {eq32'h00000000} $CSV_PC
} else {
    puts "WARN: 找不到 debug_ifu_pc 探针，跳过抓取①"
}

# ② 抓一次重定向，看请求 / 背压 / 结果三者
if {[llength $p_dnpc_flag]} {
    grab "debug_dnpc_flag == 1 (任意重定向)" [current_hw_ila] $p_dnpc_flag {eq1'h1} $CSV_RD
} else {
    puts "WARN: 找不到 debug_dnpc_flag 探针，跳过抓取②"
}

hdr "8) 收尾"
catch { close_hw_target }
catch { disconnect_hw_server }
puts "done"
