# =============================================================================
# build_project_ila.tcl — 生成「GUI 里全流程可见」的 v9 ILA 工程（工程模式）
# -----------------------------------------------------------------------------
# 和前两版的根本区别：
#   * 第 1 版 v9_vivado    ：非工程模式，顶层做引脚截断。已删。
#   * 第 2 版 v9_ila_gui   ：工程只是"壳"，设计靠 create_debug_core 在内存里
#                            做完再挂检查点上去 → 磁盘上没有 .runs/.srcs，
#                            GUI 里 Design Runs 全灰、点不动。
#   * 本版 v9_ila          ：ILA 是**标准 IP 例化**，synth_1 / impl_1 都是
#                            真实的 run，工程模式下把流程完整跑一遍。
#
# 用法（约 20~40 分钟，建议后台跑）：
#   & 'D:\vivado\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
#       -source 'E:/FPGA/v9_vivado_ila/build_project_ila.tcl' `
#       -log 'E:/FPGA/v9_vivado_ila/build_project_ila.log'
#
# 开关：
#   DO_SYNTH = 1  重建工程并重跑综合；= 0 保留已有工程和 synth_1，直接进实现
#   DO_IMPL  = 1  一路跑到 bitstream；= 0 只到综合（调 RTL 时用，省时间）
# =============================================================================

set WORK  "E:/FPGA/v9_vivado_ila"
set PROJ  "E:/FPGA/v9_vivado_ila/v9_boot"
# ★ 目录布局（2026-10 整理：CPU RTL 从仓库根目录收进 rtl\）：
#     核心 RTL  -> $WORK\rtl\      （21 个 CPU RTL，含 para.sv 与 MDU_pipelined.sv）
#     板级件    -> $WORK\board\    （board_top.sv / board_top_ila.sv / sync_mem.sv / reset_sync.sv）
#     顶层外壳  -> $WORK\project_src\board_top_gui.sv
#     历史副本  -> $WORK\experimental\MDU_pipelined.sv（**不再参与编译**，只留档）
#   ★ 为什么板级件不并进 rtl\：board_top*.sv 例化了 Xilinx 原语（MMCME2_BASE / IBUF / BUFG），
#     而官方 cdp-tests 用 Verilator 编译 rtl\*.sv —— 混在一起会直接编译不过。
#   $SRC = 核心 RTL 目录，下面所有核心 .sv 都从这里取。
set SRC   "$WORK/rtl"
# ★★ 重要（v10 起默认关闭）★★
#   原来这里会把 "E:/share doc/v9" 这份**仓库正本**的 board/ 与 rtl/ 覆盖到 $WORK/ 上。
#   在"本目录就是工作副本"的情况下这等于**每次综合都把刚改的 RTL 冲掉** —— 综合出来的
#   是旧代码，而日志里看不出来（源文件清单只打文件名，不打时间戳）。
#   v10 的 RTL 改造（前端解耦 / MDU radix-4 / 异常体系）就落在 $WORK/rtl 里，所以默认
#   **不再从 WSRC 同步**；只有显式把 SYNC_FROM_WSRC 置 1（确实要拿正本覆盖）时才拷。
#   board/ 下的板级件同理。
set WSRC  "E:/share doc/v9"     ;# 仓库正本（只在 SYNC_FROM_WSRC=1 时才用）
set SYNC_FROM_WSRC 0            ;# 0 = 只补缺失文件（推荐）；1 = 用正本强制覆盖

set PART       "xc7z020clg484-1"
set TOP        "board_top_gui_boot"
set ILA_DEPTH  2048
# 16 个 probe（v9 B9 新增末三根：dnpc_flag / ready / ifu_pc，
#   用来在板上区分"重定向请求没发"和"请求被 ready 门控吃掉"）。
# ★ 顺序即 probe 编号，必须与 project_src/board_top_gui.sv 的 .probeN 一一对应。
set ILA_PROBES {1 32 1 5 32 32 32 32 32 32 32 32 1 1 1 32}
set ILA_NPROBES 16

set DO_SYNTH 1       ;# 0 = 保留已完成的 synth_1，直接进实现
set DO_IMPL  1       ;# 0 = 只建工程 + 综合；1 = 一路跑到 bitstream

# =============================================================================
# ★ v10 新增：实现策略开关（"优化布局约束 / 实现策略"这一项的实现载体）
# -----------------------------------------------------------------------------
#   IMPL_MODE = "default"  : 与改动前完全一致的流程（synth/impl 都用工具默认 directive，
#                            phys_opt_design 关闭），用来做**对照**。
#   IMPL_MODE = "strategy" : 策略版，四件事一起上——
#     1) synth -directive PerformanceOptimized ：综合阶段就按"时序优先"做，面积换速度
#        （默认 default 会偏向面积）。
#     2) impl 各步 directive：opt=Explore / place=AltSpreadLogic_high / route=AggressiveExplore
#        —— 本设计的关键路径 78.8% 是**布线延时**（15.897ns 里 12.532ns），
#        所以要么把逻辑摊开减少拥塞（AltSpreadLogic_high），要么让布线器多迭代
#        （AggressiveExplore）；只调综合 directive 是治不好的。
#     3) phys_opt_design（place 后 + route 后各一次）并加 -force_replication_on_nets：
#        针对实测的 fo=278 / fo=128 两根高扇出广播网做**寄存器复制**，把一条长线拆成几条短线。
#     4) 可选的 Pblock（PB_ENABLE=1）：把 CPU 核心、存储器、ILA 分到不同时钟区域，
#        见下面 5b 段。
#   ★ 两个模式用**不同的工程目录**（$PROJ 后缀不同），可以先后跑、直接比报告。
# =============================================================================
set IMPL_MODE "default"    ;# "default" | "strategy"
# 允许用环境变量覆盖，方便一条命令跑对照组而不改文件：
#   set IMPL_MODE=default && vivado -mode batch -source build_project_ila.tcl
if {[info exists ::env(IMPL_MODE)]} { set IMPL_MODE $::env(IMPL_MODE) }
set PB_ENABLE 0            ;# 只在 IMPL_MODE=strategy 时有效。★ 实测建议 0：本设计 24% 面积/无拥塞，Pblock 只会限制工具
if {[info exists ::env(PB_ENABLE)]} { set PB_ENABLE $::env(PB_ENABLE) }
set RUN_TAG   "boot"   ;# 报告文件后缀：*.boot.rpt，避免覆盖 v11 的 *.default.rpt 基线
set PROJ      $PROJ    ;# boot 版不拼后缀（RUN_TAG 只用来区分报告名）

# =============================================================================
# 0) 目录准备
#    DO_SYNTH=1 时整工程重建（干净）；DO_SYNTH=0 时保留已有工程和
#    synth_1 结果，只重跑实现 —— 调实现阶段时用这个，省一次综合。
# =============================================================================
if {$DO_SYNTH} {
    # ★ 注意：如果 Vivado GUI 正开着这个工程，目录里有文件被占用，
    #   Tcl 的 file delete 会报 "permission denied" 然后整个脚本中止。
    #   这里先给出人话提示，说清楚怎么办。
    if {[file exists $PROJ]} {
        if {[catch {file delete -force $PROJ} msg]} {
            puts "================================================================"
            puts "ERROR: 删不掉已有工程目录 $PROJ"
            puts "原因：$msg"
            puts ""
            puts "最可能的情况：**Vivado GUI 正开着这个工程**（v9_ila.xpr）。"
            puts "处理办法（任选）："
            puts "  1) 先在 GUI 里 File -> Close Project 关掉它，再重跑本脚本；"
            puts "  2) 或者把本脚本开头的 DO_SYNTH 改成 0 —— 那样会保留已有工程"
            puts "     和 synth_1 结果，只重跑实现，不会删目录；"
            puts "  3) 或者手工把 $PROJ 删掉/改名后再重跑。"
            puts "================================================================"
            error "工程目录被占用，无法重建"
        }
    }
}
file mkdir "$WORK/project_src"

# prog.hex 放到工程目录里，让 IROM_INIT 用相对路径（工程自包含、可搬走）
file copy -force "$WORK/prog.hex" "$WORK/project_src/prog.hex"

# board_top_ila.sv 等板级件：默认**不再**从仓库正本覆盖（见上面 SYNC_FROM_WSRC 的说明）
if {$SYNC_FROM_WSRC} {
    foreach f {board_top_ila.sv board_top.sv sync_mem.sv sync_mem_dp.sv reset_sync.sv} {
        file copy -force "$WSRC/board/$f" "$WORK/board/$f"
    }
    file mkdir "$WORK/rtl"
    foreach f [glob -nocomplain "$WSRC/rtl/*.sv"] {
        file copy -force $f "$WORK/rtl/[file tail $f]"
    }
    puts "==> 已从仓库正本 $WSRC 覆盖 board/ 与 rtl/（SYNC_FROM_WSRC=1）"
} else {
    # 只补缺失：rsync 语义的"安全版"，绝不会覆盖本目录里已有的（也就是刚改过的）文件
    file mkdir "$WORK/rtl"
    foreach f [glob -nocomplain "$WSRC/rtl/*.sv"] {
        set dst "$WORK/rtl/[file tail $f]"
        if {![file exists $dst]} {
            file copy -force $f $dst
            puts "==> 补缺失 RTL: [file tail $f]"
        }
    }
    foreach f {board_top_ila.sv board_top.sv sync_mem.sv sync_mem_dp.sv reset_sync.sv} {
        set dst "$WORK/board/$f"
        if {![file exists $dst]} {
            file copy -force "$WSRC/board/$f" $dst
            puts "==> 补缺失 board: $f"
        }
    }
    puts "==> 未覆盖已有 RTL（SYNC_FROM_WSRC=0）；rtl/ 共 [llength [glob -nocomplain $WORK/rtl/*.sv]] 个 .sv"
}

# =============================================================================
# 1) 建工程
# =============================================================================
create_project -force v9_ila $PROJ -part $PART
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]
# ★ v10 修复：把源管理切成**手工编译顺序**（None）。
#   原因：2025.2 在这个环境里 "automatic hierarchy update" 的层次扫描会静默失败，
#   于是 set_property top 之后报
#       CRITICAL WARNING: [filemgmt 20-730] Could not find a top module in the fileset sources_1
#   接着 launch_runs 直接以
#       ERROR: [Common 17-53] User Exception: Unable to launch Synthesis run.
#              No Verilog or VHDL sources found in project
#   失败 —— 但文件其实都在 fileset 里、file_type 都是 SystemVerilog、逐文件 read_verilog
#   也零报错（已用原始 RTL 复现，与本轮 RTL 改动无关）。
#   手工模式跳过层次扫描：综合只按 fileset 里的文件清单跑，结果是等价的。
set_property source_mgmt_mode None [current_project]

# =============================================================================
# 2) 加 RTL
#    刻意逐个列出，不用通配符，免得杂文件混进来。
#    ★ 这里列的就是本目录下真实的文件位置（核心 RTL 在 rtl\、板级件在 board\、
#      顶层外壳在 project_src\）。
#    ★ experimental\MDU_pipelined.sv **故意不再加入**：现在编译的是
#      rtl\MDU_pipelined.sv（与它逐字相同）。两份都加会变成重复模块定义。
# =============================================================================
set RTL_SRC [list \
    "$SRC/myCPU.sv" "$SRC/IFU.sv" "$SRC/ICache.sv" \
    "$SRC/Branch_Predictor.sv" "$SRC/IDU.sv" "$SRC/Reg_Stack.sv" \
    "$SRC/RegisterFile.sv" "$SRC/CSR.sv" "$SRC/EXU.sv" \
    "$SRC/ALU.sv" "$SRC/LSU.sv" "$SRC/DCache.sv" \
    "$SRC/WBU.sv" "$SRC/Data_hazard.sv" "$SRC/Control.sv" \
    "$SRC/add.sv" "$SRC/sext.sv" "$SRC/Reg.sv" \
    "$SRC/MDU_pipelined.sv" \
    "$WORK/board/sync_mem.sv" "$WORK/board/sync_mem_dp.sv" \
    "$WORK/board/reset_sync.sv" \
    "$WORK/board/uart_rx.sv" "$WORK/board/boot_loader.sv" \
    "$WORK/board/uart_tx.sv" \
    "$WORK/board/board_top.sv" "$WORK/board/board_top_ila.sv" \
    "$WORK/project_src/board_top_gui_boot.sv" \
]
foreach f $RTL_SRC { if {![file exists $f]} { error "缺 RTL 源文件: $f" } }

add_files -norecurse $RTL_SRC
add_files -norecurse [list "$WORK/project_src/prog.hex"]

# include 路径：para.sv 在 rtl\ 下（$SRC 就是 rtl\），用 `include "para.sv"` 引用
set_property include_dirs [list $SRC "$WORK/project_src"] [current_fileset]
catch { set_property file_type {Memory Initialization Files} [get_files "$WORK/project_src/prog.hex"] }

# .sv 必须逐个标成 SystemVerilog（工程默认按 Verilog 解析 .sv，接口会解析错）
foreach f [get_files -of [get_filesets sources_1]] {
    if {[string equal -nocase [file extension $f] ".sv"]} {
        set_property file_type SystemVerilog $f
    }
}

set_property top $TOP [current_fileset]

# =============================================================================
# 3) 加约束
# =============================================================================
add_files -fileset constrs_1 -norecurse "$WORK/v9_board_boot.xdc"

# =============================================================================
# 3b) ★ v10 新增：实现策略（directive / phys_opt / Pblock）
#     全部通过 run 的 STEPS.* 属性下发，不改 v9_board_ila.xdc —— 时序/引脚约束与
#     实现策略解耦，两种模式共用同一份 XDC，报告才可比。
# =============================================================================
if {$IMPL_MODE eq "strategy"} {
    # ---- (1) 综合：时序优先 ----
    #   只用 directive，**不要**再往 MORE_OPTIONS 里塞 -flatten_hierarchy / -max_fanout：
    #   这些选项和 directive 内部已设的值冲突时会直接报 Synth 8-706 之类的错。
    #   高扇出交给实现阶段的 phys_opt -force_replication_on_nets（见 (3)）。
    set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized [get_runs synth_1]

    # ---- (2) 实现各步 directive ----
    set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE    Explore            [get_runs impl_1]
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE  AltSpreadLogic_high [get_runs impl_1]
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE  AggressiveExplore  [get_runs impl_1]

    # ---- (3) 物理优化：place 后 + route 后各一次 ----
    #   ★ 注意：**不要**写 `phys_opt_design -force_replication_on_nets`（不带参数）——
    #   它的签名是 `-force_replication_on_nets <args>`，要显式给**网表对象列表**，
    #   不带参数会直接报 `ERROR: [Common 17-157] Error parsing command line options`
    #   （实测踩过）。想"让工具自己挑高扇出网做复制"应该用 directive：
    #     AggressiveFanoutOpt   = 对**很高扇出**的网做复制（本设计最长路径就卡在
    #                             fo=278/fo=128 两根广播网上）
    #     ExploreWithHoldFix    = route 后再修 hold（实测 WHS 只有 +0.013ns，很紧）
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveFanoutOpt [get_runs impl_1]
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithHoldFix [get_runs impl_1]

    puts "==> IMPL_MODE=strategy：synth=PerformanceOptimized，opt=Explore，place=AltSpreadLogic_high，\
route=AggressiveExplore，phys_opt=AggressiveFanoutOpt + post-route ExploreWithHoldFix"
} else {
    puts "==> IMPL_MODE=default：全部用工具默认 directive、phys_opt 关闭（对照组）"
}

# =============================================================================
# 3c) ★ v10 新增：Pblock（只在 strategy 模式 + PB_ENABLE=1 时生成并加入工程）
# -----------------------------------------------------------------------------
#   为什么要分区：实测关键路径 15.897ns 里布线占 12.532ns（78.8%），且全设计只有
#   13006 LUT/14765 FF（占 7z020 的 24%/14%）—— 面积不是问题，**摆放过散**才是。
#   把三个功能区推到不同时钟区域，让每条**区域内**的线尽量短，同时给布线器留出通道：
#     p_cpu  : u_board_top/u_cpu          → 左半 (X0Y0:X0Y1)
#     p_mem  : IROM/DRAM（BRAM 原语）      → 右下 (X1Y1)
#     p_ila  : u_ila_0（ILA 自身极大）     → 右上 (X1Y0)
#   ★ 提醒：Pblock 收得太紧会**反噬**（工具无法合法化 → 局部拥塞）。所以这里用
#     "半个器件"这种粗粒度，并且通过 IMPL_MODE=default 随时可以跑对照组量化收益。
# =============================================================================
if {$IMPL_MODE eq "strategy" && $PB_ENABLE} {
    set PBX "$WORK/project_src/v10_pblocks.xdc"
    set fh [open $PBX w]
    puts $fh "# ============================================================================="
    puts $fh "# v10_pblocks.xdc — 由 build_project_ila.tcl 自动生成，请勿手改"
    puts $fh "#   分区思路见 build_project_ila.tcl 的 3c 段。粗粒度分区 = 只调\"邻居关系\"，"
    puts $fh "#   不追求把每个模块钉死在某个 site 上（那是反噬的主要来源）。"
    puts $fh "# ============================================================================="
    puts $fh "puts \"==> v10_pblocks.xdc 生效\""
    puts $fh ""
    puts $fh "# ---- CPU 核心：左半器件 ----"
    puts $fh "create_pblock p_cpu"
    puts $fh "add_cells_to_pblock p_cpu \[get_cells -quiet -hierarchical -filter {NAME =~ *u_board_top/u_cpu}\]"
    puts $fh "resize_pblock p_cpu -add {SLICE_X0Y0:SLICE_X49Y299}"
    puts $fh "resize_pblock p_cpu -add {DSP48_X0Y0:DSP48_X0Y159}"
    puts $fh "resize_pblock p_cpu -add {RAMB18_X0Y0:RAMB18_X0Y159}"
    puts $fh "resize_pblock p_cpu -add {RAMB36_X0Y0:RAMB36_X0Y79}"
    puts $fh ""
    puts $fh "# ---- 存储器（IROM/DRAM 的 BRAM 原语）：右下 ----"
    puts $fh "create_pblock p_mem"
    puts $fh "add_cells_to_pblock p_mem \[get_cells -quiet -hierarchical -filter {NAME =~ *u_board_top/irom_inst*}\]"
    puts $fh "add_cells_to_pblock p_mem \[get_cells -quiet -hierarchical -filter {NAME =~ *u_board_top/dram_inst*}\]"
    puts $fh "resize_pblock p_mem -add {RAMB18_X1Y160:RAMB18_X1Y319}"
    puts $fh "resize_pblock p_mem -add {RAMB36_X1Y80:RAMB36_X1Y159}"
    puts $fh ""
    puts $fh "# ---- ILA：右上（它自己就有 ~24 个 BRAM + 大量 FF，单独给一块地方）----"
    puts $fh "create_pblock p_ila"
    puts $fh "add_cells_to_pblock p_ila \[get_cells -quiet u_ila_0\]"
    puts $fh "resize_pblock p_ila -add {SLICE_X50Y150:SLICE_X99Y299}"
    puts $fh "resize_pblock p_ila -add {RAMB18_X1Y0:RAMB18_X1Y159}"
    puts $fh "resize_pblock p_ila -add {RAMB36_X1Y0:RAMB36_X1Y79}"
    puts $fh ""
    puts $fh "# 每个 Pblock 只装本区逻辑，不许包含别的（exclusive）—— 防止工具把 CPU 逻辑"
    puts $fh "#   偷偷放进 ILA 区导致两区互相挤"
    puts $fh "set_property IS_CONTAIN_ROUTING 0 \[get_pblocks p_cpu\]"
    close $fh
    add_files -fileset constrs_1 -norecurse $PBX
    puts "==> 已生成并加入 Pblock 约束: $PBX"
}

# =============================================================================
# 4) 例化并配置 ILA IP
#    ★ 顺序很重要：先 C_NUM_OF_PROBES，再逐个 C_PROBEn_WIDTH。
#    ★ create_ip 默认不加 -force，重复建同名 IP 会报错，所以先判断一下。
# =============================================================================
if {[llength [get_ips -quiet u_ila_0]] == 0} {
    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name u_ila_0
}
set ip [get_ips u_ila_0]

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES       $ILA_NPROBES \
    CONFIG.C_DATA_DEPTH          $ILA_DEPTH \
    CONFIG.C_INPUT_PIPE_STAGES   1 \
    CONFIG.C_EN_STRG_QUAL        1 \
    CONFIG.C_ADV_TRIGGER         false \
    CONFIG.ALL_PROBE_SAME_MU_CNT 2 \
] $ip

set i 0
foreach w $ILA_PROBES {
    set_property CONFIG.C_PROBE${i}_WIDTH $w $ip
    incr i
}
puts "==> ILA IP 配置完成：$ILA_NPROBES 个 probe，宽度 {$ILA_PROBES}，深度 $ILA_DEPTH"

generate_target all $ip
puts "==> ILA IP 输出已生成"

# 例化模板留一份，方便对照端口名
set veo [glob -nocomplain "$PROJ/v9_ila.gen/sources_1/ip/u_ila_0/u_ila_0.veo"]
if {[llength $veo]} { file copy -force [lindex $veo 0] "$WORK/project_src/u_ila_0.veo.template" }

update_compile_order -fileset sources_1

# 打一份源文件清单，方便 GUI 里核对
puts "---- 工程源文件清单 ----"
foreach f [get_files -of [get_filesets sources_1]] { puts "  SRC  [file tail $f]" }
foreach f [get_files -of [get_filesets constrs_1]] { puts "  XDC  [file tail $f]" }
puts "  TOP  = [get_property top [current_fileset]]"
puts "  PART = [get_property part [current_project]]"

catch { set_property target_simulator XSim [current_project] }

# =============================================================================
# 5) 跑流程：synth_1 → impl_1
# =============================================================================
if {$DO_SYNTH} {
    reset_run synth_1
    # ★ 重要：reset_run 会把 run 的 STEPS.* 属性重置，所以上面 3b 段下发的 directive
    #   必须在这里**重新下发一次**（放在 reset_run 之后才是有效的）。
    if {$IMPL_MODE eq "strategy"} {
        set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized [get_runs synth_1]
    }
    puts "==> synth_1 directive = [get_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE [get_runs synth_1]]"
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
} else {
    puts "==> DO_SYNTH=0，复用已有 synth_1"
}

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "综合失败：PROGRESS=[get_property PROGRESS [get_runs synth_1]]  STATUS=[get_property STATUS [get_runs synth_1]]"
}
puts "==> 综合完成"

open_run synth_1 -name synth_1
report_utilization -file "$WORK/project_src/util_post_synth.$RUN_TAG.rpt"
report_debug_core  -file "$WORK/project_src/debug_core_post_synth.$RUN_TAG.rpt"
# ILA 有没有真的挂进设计，在综合这一步就能确认
puts "RESULT synth_debug_cores = [get_debug_cores -quiet]"
close_design

if {$DO_IMPL} {
    # ★ 同 synth：reset 之后重新下发实现各步 directive（这里是 impl_1 的首次 launch，
    #   属性还在，但为了和 synth 一致、且避免被任何 reset 抹掉，统一再写一遍）
    if {$IMPL_MODE eq "strategy"} {
        set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE    Explore             [get_runs impl_1]
        set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE  AltSpreadLogic_high [get_runs impl_1]
        set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE  AggressiveExplore   [get_runs impl_1]
        set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
        set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveFanoutOpt [get_runs impl_1]
        set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
        set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithHoldFix [get_runs impl_1]
    }
    puts "==> impl_1: place=[get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] \
route=[get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] \
phys_opt=[get_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED [get_runs impl_1]]"
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1

    if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
        error "实现失败：PROGRESS=[get_property PROGRESS [get_runs impl_1]]  STATUS=[get_property STATUS [get_runs impl_1]]"
    }
    puts "==> 实现 + bitstream 完成"

    open_run impl_1
    report_utilization        -file "$WORK/project_src/util_post_route.$RUN_TAG.rpt"
    report_timing_summary     -file "$WORK/project_src/timing_post_route.$RUN_TAG.rpt"
    report_timing -sort_by group -max_paths 20 -path_type summary \
                  -file "$WORK/project_src/timing_worst_paths.$RUN_TAG.rpt"
    report_drc                -file "$WORK/project_src/drc.$RUN_TAG.rpt"
    report_clock_utilization  -file "$WORK/project_src/clock_util.$RUN_TAG.rpt"
    report_debug_core         -file "$WORK/project_src/debug_core_post_route.$RUN_TAG.rpt"
    # v10 新增：高扇出网与拥塞，用来验证"寄存器复制/分区"到底有没有生效
    catch { report_high_fanout_nets -timing -load_types -max_nets 20 \
            -file "$WORK/project_src/high_fanout.$RUN_TAG.rpt" }
    catch { report_design_analysis -congestion -complexity \
            -file "$WORK/project_src/design_analysis.$RUN_TAG.rpt" }

    puts "RESULT debug_cores = [get_debug_cores -quiet]"

    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    set whs [get_property SLACK [get_timing_paths -delay_type min]]
    puts "RESULT WNS = $wns ns"
    puts "RESULT WHS = $whs ns"

    # 50MHz 时钟自己的 WNS —— 本次验证最关心的数
    set p [get_timing_paths -delay_type max -from [get_clocks clk_sys_unbuf] -max_paths 1]
    if {[llength $p]} { puts "RESULT 50MHz WNS = [get_property SLACK $p] ns" }

    # 是否存在建立时间违例路径
    set tp [get_timing_paths -delay_type max -max_paths 1 -slack_lesser_than 0]
    puts "RESULT setup_failing_paths_exist = [expr {[llength $tp] > 0}]"

    report_timing_summary -no_header -no_detailed_paths \
                          -file "$WORK/project_src/ts_brief.$RUN_TAG.rpt"
    close_design
}

puts "================================================================"
puts "RESULT xpr   = $PROJ/v9_ila.xpr"
puts "RESULT bit   = $PROJ/v9_ila.runs/impl_1/board_top_gui.bit"
puts "RESULT ltx   = $PROJ/v9_ila.runs/impl_1/board_top_gui.ltx"
puts "RESULT files = [llength [get_files]]"
puts "RESULT runs  = [get_runs]"
puts "RESULT build OK"
puts "================================================================"

close_project
