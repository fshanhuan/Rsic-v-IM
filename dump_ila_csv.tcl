# =============================================================================
# dump_ila_csv.tcl — 用**独立批处理会话**连到正在运行的 hw_server，
#                   自己触发一次 ILA 并把抓取数据导出成 CSV。
# -----------------------------------------------------------------------------
# 为什么能这么干：
#   ILA 的抓取数据存在 **FPGA 里的 ILA 缓冲**中，不在 GUI 的内存里。
#   只要能连上同一个 hw_server（localhost:3121），就能自己 run/upload/export。
#
# 刻意不做的事：
#   - 不 program_hw_devices（不动板上已有的 bitstream 和运行状态）
#   - 只做 run_hw_ila -trigger_now + upload + write
#
# 用法：
#   vivado -mode batch -notrace -source dump_ila_csv.tcl -log dump_ila_csv.log
# =============================================================================

set CSV  "E:/FPGA/v9_vivado_ila/ila_from_hw.csv"
set LTX  "E:/FPGA/v9_vivado_ila/v9_ila/v9_ila.runs/impl_1/board_top_gui.ltx"

proc hdr {t} { puts ""; puts "================ $t ================" }

hdr "1) 打开 Hardware Manager"
open_hw_manager

hdr "2) 连接 hw_server"
if {[catch { connect_hw_server -url localhost:3121 } e]} { puts "ERR connect: $e"; exit 1 }
puts "servers = [get_hw_servers]"

hdr "3) 找 target"
set tars [get_hw_targets]
puts "targets = $tars"
if {[llength $tars] == 0} { puts "ERR: 没有 target（GUI 可能占着，或服务器没连）"; exit 2 }
set tar [lindex $tars 0]
current_hw_target $tar

hdr "4) 打开 target"
if {[catch { open_hw_target } e]} { puts "ERR open_hw_target: $e"; exit 3 }
puts "target open = [get_hw_targets -of_objects [current_hw_server]]"

set devs [get_hw_devices]
puts "devices = $devs"
# ★ 关键：get_hw_devices 里第一个是 arm_dap_0（PS 的 ARM 调试口），
#   PL 的器件（带 ILA 的那个）是 xc7z020_1 —— 必须按名字挑出来。
set dev ""
foreach d $devs { if {[string match "*xc7z020*" $d]} { set dev $d ; break } }
if {$dev eq ""} { set dev [lindex $devs end] }
puts "device = $dev"
current_hw_device $dev

hdr "5) 关联探针文件（不烧板）"
if {[catch { set_property PROBES.FILE $LTX $dev } e]} { puts "PROBES.FILE warn: $e" } else { puts "PROBES.FILE ok" }
if {[catch { set_property FULL_PROBES.FILE $LTX $dev } e]} { puts "FULL_PROBES.FILE warn: $e" } else { puts "FULL_PROBES.FILE ok" }
# ★ 必须 -update_hw_probes true（默认）：它才会把 .ltx 里的探针定义读进来。
#   写成 false 就会出「No probes for hw_ila」——我上一版就是这么错的。
if {[catch { refresh_hw_device -update_hw_probes true $dev } e]} { puts "refresh warn: $e" } else { puts "refresh ok" }

hdr "6) 找 ILA core"
set ilas {}
catch { set ilas [get_hw_ilas -of_objects $dev] }
puts "ilas = $ilas"
if {[llength $ilas] == 0} {
    puts "ERR: 没找到 ILA core"
    catch { close_hw_target }
    catch { disconnect_hw_server }
    exit 4
}
current_hw_ila [lindex $ilas 0]
puts "current ila = [current_hw_ila]"
set prb [get_hw_probes -of_objects [current_hw_ila]]
puts "探针数 = [llength $prb]"
foreach p $prb { puts "   $p" }

hdr "7) 立刻触发一次抓取"
if {[catch { run_hw_ila -trigger_now [current_hw_ila] } e]} { puts "run warn: $e" } else { puts "run ok" }
if {[catch { wait_on_hw_ila -timeout 30 [current_hw_ila] } e]} { puts "wait warn: $e" } else { puts "wait ok" }

hdr "8) 上传 + 导出 CSV"
set d ""
if {[catch { set d [upload_hw_ila_data [current_hw_ila]] } e]} { puts "ERR upload: $e"; set d "" }
puts "data = $d"
if {$d ne ""} {
    if {[catch { write_hw_ila_data -force -csv_file $CSV $d } e]} {
        puts "ERR write: $e"
    } else {
        puts "OK -> $CSV"
        if {[file exists $CSV]} { puts "CSV 大小 = [file size $CSV] 字节" }
    }
}

hdr "9) 收尾：释放 target（让 GUI 能重新 Auto Connect）"
catch { close_hw_target }
catch { disconnect_hw_server }
puts "done"
