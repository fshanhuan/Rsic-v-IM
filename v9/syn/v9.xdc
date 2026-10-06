# =============================================================================
# BigBird v9 — Xilinx (Vivado) 时序约束模板
# -----------------------------------------------------------------------------
# 说明：本工程与板卡无关，因此这里只约束「逻辑内部」的时序路径；
#       引脚位置(PACKAGE_PIN)与电平(IOSTANDARD)需要按你实际板卡填写。
# 用法：在 Vivado 中 add_files 本文件，或在综合/实现脚本里 read_xdc v9.xdc。
# =============================================================================

# ---- 主时钟 ----------------------------------------------------------------
# 教学与上板验证建议先从 50MHz 起，确认功能后逐步提高到 100/150MHz。
# 板载晶振频率请按实际修改（Nexys A7/Basys3 为 100MHz，DE2-115 为 50MHz）。
create_clock -period 10.000 -name sys_clk [get_ports fpga_clk]

# ---- 复位 ------------------------------------------------------------------
# 若板卡复位按键是异步的，请保留为异步输入并用同步器采样（见 syn/上板改造说明.md）。
set_false_path -from [get_ports fpga_rst]

# ---- 异步复位/输入去抖（按需） ---------------------------------------------
# set_input_delay  -clock sys_clk 2.000 [get_ports fpga_rst]
# set_output_delay -clock sys_clk 2.000 [get_ports debug_wb_*]

# ---- 调试口（可选：仅用于上板观察，不参与关键路径） ------------------------
set_false_path -to [get_ports debug_wb_have_inst]
set_false_path -to [get_ports debug_wb_pc]
set_false_path -to [get_ports debug_wb_ena]
set_false_path -to [get_ports debug_wb_reg]
set_false_path -to [get_ports debug_wb_value]

# ---- 时钟不确定性与输入抖动 ------------------------------------------------
set_clock_uncertainty 0.100 [get_clocks sys_clk]
