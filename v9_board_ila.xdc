# =============================================================================
# v9_board_ila.xdc — v9 在 EES-331 上的约束（ILA 版 / CPU 50MHz）
# -----------------------------------------------------------------------------
# 顶层：board/board_top_ila.sv     器件：xc7z020clg484-1（EES-331）
#
# 本版与 v9_board.xdc（引脚引出方案）的区别：
#   调试信号**一个都不引到引脚**，全部由片内 ILA 通过 JTAG 抓取。
#   因此这里没有 debug_wb_* / debug_*_cnt / debug_mcause 的任何约束 ——
#   它们已经是内部网络，只由 myCPU/board_top 上的 (* mark_debug *)/(* keep *)
#   决定被 ILA 抓走。
#
# 引脚来源：EES-331 用户手册的"管脚约束表"（**用 FPGA IO 约束列，不要用原理图位号**）
#   §5  系统时钟：PL 时钟 FPGA_CLK0 = 100MHz，FPGA IO 约束 = **M19**
#                 （PS 时钟 33.333MHz / F7 是另一个，与本设计无关）
#   §21 PL 按键：S1 / 标号 FPGA_RESET，FPGA IO 约束 = **L18**，4.7K 上拉、按下为低
#   §20 LED：LED0..LED7 = V4 U6 U5 V7 W7 W6 W5 U7
#
# 踩坑记录（实测暴露）：
#   曾经把按键写成 PACKAGE_PIN S5 —— 'S5' 是**原理图位号**而不是引脚名，Vivado 报
#     CRITICAL WARNING: [Common 17-69] Command failed:
#       'S5' is not a valid site or package pin name.
#   而且这条告警在综合阶段只是 CRITICAL WARNING，不会中止流程，
#   如果不去看日志就会带着一个"没生效的引脚约束"一路跑到实现。
#   所以：引脚号一律以手册"FPGA IO 约束"列为准。
# =============================================================================

# ---- 主时钟：板上真实输入是 100MHz，必须按 10ns 约束 ------------------------
# CPU 实际跑的 50MHz **不要**手写 create_clock —— 它由 board_top_ila 里的
# MMCM（100MHz × 10 / 20）派生，Vivado 会自动生成派生时钟约束。
# ★ 实测（v11）：自动派生时钟在报告里的名字是 **clk_sys_unbuf**（周期 20ns），
#   不是本注释原来写的 sys_clk_50m —— 名字取自驱动它的那条网。引用它时以报告为准
#   （见 project_src/timing_post_route.default.rpt 的 Clock Summary）。
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

# ---- 复位（按键，低有效） --------------------------------------------------
# 按键是异步输入，经 board/reset_sync.sv 做"异步置位、同步释放"，不做建立/保持要求。
set_false_path -from [get_ports btn_rst_n]

# ---- 复位同步器输出：同样是异步复位语义，必须切断 --------------------------
# 为什么这条不能省（实测踩过的坑，见 ../syn/vivado_50mhz_实测.md §2 问题 2）：
#   reset_sync 的输出扇出到**整个寄存器堆**（Reg_Stack 里 32×32 个 rf_reg）。
#   只写 set_false_path -from [get_ports btn_rst_n] 时，Vivado 仍会把同步器
#   **输出寄存器**的扇出当普通同步路径分析，于是时序报告里最差路径变成
#   "复位树延时"，把真正的数据通路关键路径完全盖住 ——
#   实测未加这条时 WNS=2.191ns，加了之后 WNS=5.283ns。
#   屏蔽它是**语义正确**的（异步置位、同步释放），不是为了让时序好看。
set_false_path -from [get_cells -hier -filter {NAME =~ *reset_sync_inst/sync_ff2_reg*}]

# ---- 心跳输出：不做时序分析（v11 新增） ------------------------------------
# debug_dead 是**唯一**引到引脚上的输出（LED0，V4），它只是"调试量的或"，没人看它的时序。
# 原来漏了这条 → 时序报告里有 `6. checking no_output_delay (1)`。
# ★ 顺手记一笔（别再照抄 noila 的约束）：syn/v9.xdc 里有 9 条
#   `set_false_path -to [get_ports debug_wb_* / debug_*_cnt]`，但**本 ILA 顶层没有那些端口** ——
#   board_top_gui 只有 sys_clk / btn_rst_n / debug_dead 三个端口，
#   debug_wb_*、各计数器、mcause/mepc/mtval 全是**内部网**（负载是 ILA 的 probe）。
#   照抄那 9 条只会得到一堆 "no objects matched" 告警。
# 同理 `5. checking no_input_delay (1)` 指的是 btn_rst_n —— 它已由上面两条 false_path
#   按"异步输入"处理，这个提示是预期的，不需要再补 input_delay。
set_false_path -to [get_ports debug_dead]

# ---- 时钟不确定性与抖动 ----------------------------------------------------
# v11（A）：CPU 实际跑的是 MMCM 派生的 50MHz（报告里叫 clk_sys_unbuf）。原来只给**输入**
#   时钟 sys_clk 加了 0.100ns，等于 **CPU 域完全没有用户保护带**，余量只剩 Vivado 自动
#   推导的 MMCM 抖动模型。
#   实测后果：post-route 的最差 hold 路径就落在 clk_sys_unbuf 域里，只剩 **0.020ns** ——
#     源 LSU_Inst0/rs2_value_reg_pipe_reg[11] （SLICE_X82Y47）
#     目的 DCache_inst/store2_wdata_reg[11]      （SLICE_X82Y50）
#     同一条时钟网（同一 BUFG，fo=23279）、**0 逻辑级**、数据路径 0.342ns、
#     时钟 skew +0.263ns 还是**帮忙**方向、CPPR 0.280ns 已生效。
#   20ps @ 50MHz = 周期的 0.1%，工程上应读作"擦线通过"而不是"有余量"。
#   setup 目前有 2.027ns 余量，所以给 hold 补保护带是**免费**的（代价只是短路径多绕一点线）。
#
# ★★ 教训（v11 第一次上板就踩了，别再犯）：**XDC 不是通用 Tcl 脚本**。
#   第一版这里写的是 set/get_clocks -include_generated_clocks + `foreach` + `puts`，
#   想让"父时钟派生出来的所有时钟"都吃到约束。结果综合日志直接报：
#     CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not supported  [:80]
#     CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not supported  [:87]
#     CRITICAL WARNING: [Designutils 20-1307] Command 'puts'    is not supported  [:90]
#   后果是双重的，而且都很隐蔽：
#     1) 循环体**整段被跳过** ⇒ clk_sys_unbuf 的 hold 约束根本没加上，WHS 还是 0.020
#        （= 以为加了、其实没加，这正是最坏的情况）；
#     2) 触发 INFO: [runtcl-6] "Synthesis results are not added to the cache due to
#        CRITICAL_WARNING" —— 综合结果不进缓存。
#   XDC 只支持一个**受限命令子集**：约束命令 + set/get_* / list / expr 等，
#   **不支持** foreach / while / if / proc / puts / source / exec / lappend。
#   （离线检查工具 _diag/chk_xdc.py 当时只验了"Tcl 语法能过"，而语法正确 ≠ XDC 合法。）
#
# ★ 现在的写法：一条 get_clocks 取"父时钟 + 它派生出的全部时钟"，再显式补上
#   clk_sys_unbuf 这个名字，全程零控制流。
#   - -include_generated_clocks 保证**将来**改 MMCM 分频/改名也不会漏（派生时钟名字会自动变）；
#   - 显式写 clk_sys_unbuf 是防止"-include_generated_clocks 在综合阶段还没派生"这种极端情况；
#   - 两个 pattern 一起给，命中集**一定至少含 sys_clk**，永远不会产生"空对象列表"
#     （空列表在 Vivado 里很可能直接 ERROR 让综合失败，那是比失效更糟的结果）；
#   - 某个名字此刻还不存在时只会被静默跳过（-quiet），不会中断流程。
#   - 生效与否**用时序报告的数字验证**，不靠日志打印：
#     跑完看 clk_sys_unbuf 的 WHS，从 0.020 抬到 ~0.20 才算真的生效。
#   时钟名以 project_src/timing_post_route.default.rpt 的 Clock Summary 为准：
#     sys_clk {0.000 5.000} 10ns 100MHz
#       clk_sys_unbuf {0.000 10.000} 20ns 50MHz   <-- CPU 逻辑全在这条上
#       clkfb        {0.000 5.000} 10ns 100MHz    <-- MMCM 反馈，无用户路径，不用管
set ila_unc_clks [get_clocks -quiet -include_generated_clocks {sys_clk clk_sys_unbuf}]
set_clock_uncertainty -setup 0.100 $ila_unc_clks
set_clock_uncertainty -hold  0.200 $ila_unc_clks

# =============================================================================
# 引脚约束：2 个输入 + 1 个状态输出
# =============================================================================
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports btn_rst_n]

# debug_dead = 全部调试量的"或"，本质上是个**心跳灯**：
#   CPU 在跑（PC/写回数据非 0）→ 输出高；被复位或彻底不动 → 低。
# 这里接到 EES-331 的 LED0（§20，FPGA IO 约束 = V4）。
# 如果你要把 LED0 挪作他用，删掉这一行即可；但删了之后 make_bit=1 会因为
# DRC UCIO-1/NSTD-1（端口无引脚/无电平）而失败 —— ILA 本身不受影响。
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports debug_dead]
