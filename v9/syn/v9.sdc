# =============================================================================
# BigBird v9 — 通用 SDC 时序约束模板（Quartus / 通用工具链）
# Quartus 用法：在 .qsf 中 set_global_assignment -name SDC_FILE syn/v9.sdc
# =============================================================================

# 主时钟：50MHz（20ns）。上板先跑通再逐步收紧。
create_clock -name sys_clk -period 20.000 [get_ports {fpga_clk}]

# 复位为异步输入
set_false_path -from [get_ports {fpga_rst}]

# 调试观察口不参与时序收敛
set_false_path -to [get_ports {debug_wb_*}]

# 输出/建立保持余量（可选）
# set_output_delay -clock sys_clk 3.000 [get_ports {debug_wb_*}]
