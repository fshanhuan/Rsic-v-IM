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
# MMCM（100MHz × 10 / 20）派生，Vivado 会自动生成派生时钟约束，
# 报告里能看到 sys_clk_50m（周期 20ns）。
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

# ---- 时钟不确定性与抖动 ----------------------------------------------------
set_clock_uncertainty 0.100 [get_clocks sys_clk]

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
