# =============================================================================
# v9_board.xdc — BigBird v9 / board_top 的 Vivado 约束（50MHz 起步版）
# -----------------------------------------------------------------------------
# 顶层：board/board_top.sv
# 器件：xc7z020clg484-1
#
# 本次目标是「内部时序验证」：先只约束时钟与异步复位，引脚位置留 TODO 占位。
# 因此 *不要* 直接 run write_bitstream / 上板 —— 引脚未分配，实现会在
# place_design 阶段报 IO placement 相关错误。等功能与时序都收敛后，再按实际
# 板卡把下面的 TODO 段填上（PACKAGE_PIN + IOSTANDARD），即可出 bit。
#
# 频率口径（三处必须一致，改一处就要改三处）：
#   本文件 create_clock 20.000ns = 50MHz
#   syn/v9.sdc        create_clock 20.000ns = 50MHz
#   sim/tb_iverilog.sv 时钟 10ns = 100MHz（仿真保持 100MHz 不动，只影响仿真）
# =============================================================================

# ---- 主时钟：50MHz ---------------------------------------------------------
# 20ns 周期。上板验证建议 50MHz 起步，功能确认后按 syn/timing_sweep.tcl
# 逐步收紧到 100MHz（10ns）/ 150MHz（6.667ns）。
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

# ---- 复位 ------------------------------------------------------------------
# btn_rst_n 是按键异步输入，经 board/reset_sync.sv 做「异步置位、同步释放」，
# 因此对时钟不做建立/保持要求，直接设 false_path。
# 注意：这里不是 set_false_path -from [get_ports btn_rst_n] 就完事 —— 按键抖动
# 属于板级输入调理，上板前应在顶层再加 ~10ms 消抖计数（见 board_top.sv 头部注释）。
set_false_path -from [get_ports btn_rst_n]

# 复位同步器的输出同样是**异步复位语义**，必须切断它的时序分析。
# 为什么这条不能省（第一次实测踩到的坑）：
#   只写 set_false_path -from [get_ports btn_rst_n] 时，Vivado 仍然把
#   reset_sync_inst/sync_ff2_reg 的输出当普通同步信号分析 —— 而它扇出到**整个
#   寄存器堆**（RegisterFile/Reg_Stack 的 32×32 个 rf_reg），于是时序报告里
#   最差路径变成了「复位树的扇出延时」，把真正的数据通路关键路径完全盖住了。
#   实测：不加这条时 post-route WNS = 2.191ns（最差路径 startpoint 全是
#   reset_sync_inst/sync_ff2_reg）；加上之后 WNS 才是数据通路的真实值。
#   注意：这里“屏蔽”复位路径是**语义正确**的，不是为了让时序好看 ——
#   reset_sync 的设计本就是「异步置位、同步释放」，释放沿之后所有 FF 都已退出复位，
#   复位网络不承担数据通路的时序要求。
set_false_path -from [get_cells -hier -filter {NAME =~ *reset_sync_inst/sync_ff2_reg*}]

# ---- 调试观测口：不参与时序收敛 --------------------------------------------
# 这 9 个 32 位/多位的调试输出只用来接数码管 / LED / UART，不参与关键路径。
set_false_path -to [get_ports debug_wb_have_inst]
set_false_path -to [get_ports debug_wb_pc]
set_false_path -to [get_ports debug_wb_ena]
set_false_path -to [get_ports debug_wb_reg]
set_false_path -to [get_ports debug_wb_value]
set_false_path -to [get_ports debug_icache_hit_cnt]
set_false_path -to [get_ports debug_icache_miss_cnt]
set_false_path -to [get_ports debug_dcache_hit_cnt]
set_false_path -to [get_ports debug_dcache_miss_cnt]

# ---- 时钟抖动（可选） ------------------------------------------------------
set_clock_uncertainty 0.100 [get_clocks sys_clk]

# =============================================================================
# TODO：引脚约束（按你实际板卡填写后才能出 bitstream）
# =============================================================================
# ZedBoard(xc7z020clg484-1) 的参考引脚（**请自行核对原理图，不要照抄**）：
#   GCLK 100MHz  -> Y9
#   BTNC (复位)  -> P16   注意：板载按键是高有效，board_top 的 btn_rst_n 是低有效，
#                          直接接会「上电就复位、按下才跑」，必须加反相或改端口极性。
#   LED / 数码管 -> 见 ZedBoard 原理图，本板没有 8 位数码管，需要外接或改用 LED 观察。
#
# 填法示例（把下面 4 行取消注释并核对引脚后再出 bit）：
#   set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33} [get_ports sys_clk]
#   set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports btn_rst_n]
#   set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS33} [get_ports debug_wb_have_inst]
#   set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports {debug_wb_pc[0]}]
#
# 另外两件上板前必须补的（当前 RTL 里没有，见 syn/上板改造说明.md §3 P4）：
#   1) 7 段数码管扫描 + 段选译码模块（1kHz 左右扫描，把 debug_wb_* 显示出来）；
#   2) 按键消抖（~10ms）。
# 约束里把它们标成异步/伪路径是可以的，但显示逻辑要自己写。
