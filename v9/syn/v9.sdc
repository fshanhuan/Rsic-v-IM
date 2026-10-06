# =============================================================================
# BigBird v9 — 通用 SDC 时序约束模板（Quartus / 通用工具链）
# Quartus 用法：在 .qsf 中 set_global_assignment -name SDC_FILE syn/v9.sdc
# =============================================================================

# 主时钟。
# v9 修复：① 端口名改成 board/board_top.sv 的真实端口 sys_clk（原来写 fpga_clk，
#              全工程 *.sv 里零命中 → 时钟没约束上）；
#           ② 周期与 syn/v9.xdc、仿真时钟统一为 10ns(100MHz)，原来这里 20ns(50MHz)
#              与 xdc 的 10ns 自相矛盾。上板先跑通再逐步收紧即可。
create_clock -name sys_clk -period 10.000 [get_ports {sys_clk}]

# 复位为异步输入（board_top 的按键端口名）
set_false_path -from [get_ports {btn_rst_n}]

# 调试观察口不参与时序收敛
set_false_path -to [get_ports {debug_wb_*}]
set_false_path -to [get_ports {debug_icache_hit_cnt}]
set_false_path -to [get_ports {debug_icache_miss_cnt}]
set_false_path -to [get_ports {debug_dcache_hit_cnt}]
set_false_path -to [get_ports {debug_dcache_miss_cnt}]

# 输出/建立保持余量（可选）
# set_output_delay -clock sys_clk 3.000 [get_ports {debug_wb_*}]
