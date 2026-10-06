# =============================================================================
# BigBird v9 — Xilinx (Vivado) 时序约束模板
# -----------------------------------------------------------------------------
# 说明：本工程与板卡无关，因此这里只约束「逻辑内部」的时序路径；
#       引脚位置(PACKAGE_PIN)与电平(IOSTANDARD)需要按你实际板卡填写。
# 用法：在 Vivado 中 add_files 本文件，或在综合/实现脚本里 read_xdc v9.xdc。
# =============================================================================

# ---- 主时钟 ----------------------------------------------------------------
# v9 修复：端口名必须与 board/board_top.sv 的顶层端口一致。
#   原来写的是 fpga_clk / fpga_rst，而 board_top 的端口是 sys_clk / btn_rst_n
#   （全工程 *.sv 里 "fpga_clk" 零命中）→ Vivado 的 get_ports 找不到对象，
#   时钟根本没约束上，时序报告是假的。
# 教学与上板验证建议先从 50MHz 起，确认功能后逐步提高到 100/150MHz；
# 板载晶振频率请按实际修改（Nexys A7/Basys3 为 100MHz，DE2-115 为 50MHz），
# 并与 syn/v9.sdc、以及仿真的时钟周期保持一致（本模板统一用 10ns = 100MHz）。
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

# ---- 复位 ------------------------------------------------------------------
# 若板卡复位按键是异步的，请保留为异步输入并用同步器采样（见 syn/上板改造说明.md）。
set_false_path -from [get_ports btn_rst_n]

# ---- 异步复位/输入去抖（按需） ---------------------------------------------
# set_input_delay  -clock sys_clk 2.000 [get_ports btn_rst_n]
# set_output_delay -clock sys_clk 2.000 [get_ports debug_wb_*]

# ---- 调试口（可选：仅用于上板观察，不参与关键路径） ------------------------
set_false_path -to [get_ports debug_wb_have_inst]
set_false_path -to [get_ports debug_wb_pc]
set_false_path -to [get_ports debug_wb_ena]
set_false_path -to [get_ports debug_wb_reg]
set_false_path -to [get_ports debug_wb_value]
# v9 修复：board_top 还有 4 个 32 位性能计数器输出，原来漏了没设 false_path
set_false_path -to [get_ports debug_icache_hit_cnt]
set_false_path -to [get_ports debug_icache_miss_cnt]
set_false_path -to [get_ports debug_dcache_hit_cnt]
set_false_path -to [get_ports debug_dcache_miss_cnt]

# ---- 时钟不确定性与输入抖动 ------------------------------------------------
set_clock_uncertainty 0.100 [get_clocks sys_clk]
