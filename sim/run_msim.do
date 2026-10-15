# =============================================================================
# sim/run_msim.do — v9 在 ModelSim 下的**单个程序**回归（GUI 与批处理通用）
# -----------------------------------------------------------------------------
# 用法（必须先 cd 到 v9 根目录，因为测试台用相对路径 $readmemh）：
#
#   :: 批处理：跑默认的 prog.hex
#   cd /d "E:\share doc\v9"
#   vsim -c -do sim/run_msim.do
#
#   :: 换程序：在 vsim 命令行里给 plusarg
#   vsim -c -do sim/run_msim.do +prog=sim/prog_mul.hex +prog_id=1 +max=600
#
#   :: GUI（要波形）：先编译好 work 库，然后
#   vsim -do sim/run_msim.do work.tb_msim +prog=sim/prog.hex +prog_id=0
#
# 全量回归（7 个程序 + D-Cache 单元测试）请用：
#   powershell -ExecutionPolicy Bypass -File sim\run_msim.ps1
#   或  sim\run_msim.bat
#   —— 批处理下 vsim 的退出码不可靠，所以全量回归靠日志里的
#      "[SELFCHECK] status=..." 判定，由脚本负责汇总。
# =============================================================================

# ---- 1) 建库 + 编译（已编译过则跳过，加快重复运行）----------------------------
if {![file exists work]} {
    vlib work
    vmap work work
}

if {![file exists work/_info]} {
    set RTL {rtl/myCPU.sv rtl/IFU.sv rtl/ICache.sv rtl/Branch_Predictor.sv rtl/IDU.sv rtl/Reg_Stack.sv rtl/RegisterFile.sv rtl/CSR.sv rtl/EXU.sv rtl/ALU.sv rtl/MDU_pipelined.sv rtl/LSU.sv rtl/DCache.sv rtl/WBU.sv rtl/Data_hazard.sv rtl/Control.sv rtl/add.sv rtl/sext.sv rtl/Reg.sv}
    # 必须用相对路径：工程根目录 "E:\share doc\v9" 含空格，Tcl 会把
    # "+incdir+$ROOT" 拆成两个参数，vlog 报 Failed to open "doc/v9"。
    eval vlog -sv -quiet -suppress 7061 -work work -incr "+incdir+." "+incdir+rtl" {*}$RTL
    vlog -sv -quiet -suppress 7061 -work work -incr "+incdir+." "+incdir+rtl" "sim/tb_msim.sv"
}

# ---- 2) 载入 + 跑到底 --------------------------------------------------------
#   没给 -do 之外的额外参数时，vsim 会沿用命令行上的 plusarg；
#   这里不再覆盖 +prog/+prog_id/+max，默认值由测试台自身提供。
if {[catch {vsim -quiet -suppress 7061 -L work work.tb_msim} err]} {
    puts "\[FATAL\] vsim load failed: $err"
    quit -code 1
}

run -all
# run -all 结束后测试台一定 $finish 了，quit -f 只是把 vsim 收掉；
# 判定请看 transcript / 日志里的 "[SELFCHECK] status=..." 一行。
quit -f
