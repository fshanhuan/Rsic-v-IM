# =============================================================================
# run_mem.ps1 — 「存储器专题」一键复现（Windows / PowerShell 7）
#   1) 重新生成演示程序      2) 编译 board_top + tb_mem
#   3) 跑 4700 拍（打印 22 条自检，写 CSV + VCD）
#   4) 重算数字              5) 重画 8 张图
# 用法：  pwsh sim/run_mem.ps1            # 全跑
#         pwsh sim/run_mem.ps1 -SkipSim   # 只重画图（沿用已有 CSV）
# 说明：  PowerShell 不会给原生程序展开 *.sv，所以这里把文件一个个列出来。
# =============================================================================
param([switch]$SkipSim, [int]$Stop = 4700)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$env:PYTHONIOENCODING = "utf-8"
New-Item -ItemType Directory -Force sim\build | Out-Null

$rtl = @(
    "board/board_top.sv", "board/sync_mem.sv", "board/sync_mem_dp.sv", "board/soc_bus.sv", "board/reset_sync.sv",
    "board/uart_tx.sv", "board/uart_rx.sv", "board/boot_loader.sv",
    "rtl/add.sv", "rtl/ALU.sv", "rtl/Branch_Predictor.sv", "rtl/Control.sv", "rtl/CSR.sv",
    "rtl/Data_hazard.sv", "rtl/DCache.sv", "rtl/EXU.sv", "rtl/ICache.sv", "rtl/IDU.sv",
    "rtl/IFU.sv", "rtl/LSU.sv", "rtl/MDU_pipelined.sv", "rtl/myCPU.sv", "rtl/Reg.sv",
    "rtl/RegisterFile.sv", "rtl/Reg_Stack.sv", "rtl/sext.sv", "rtl/WBU.sv",
"rtl/plic_lite.sv", "rtl/clint.sv"
)

if (-not $SkipSim) {
    Write-Host "[1/7] 生成演示程序 sim/mem_demo.hex" -ForegroundColor Cyan
    python sim\gen_mem_demo.py | Select-Object -First 3

    Write-Host "[2/7] 编译（iverilog）" -ForegroundColor Cyan
    iverilog -g2012 -I rtl -o sim\build\tb_mem.vvp @rtl sim\tb_mem.sv 2> sim\build\compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content sim\build\compile.log -Tail 20; throw "compile failed" }

    Write-Host "[3/7] 仿真 $Stop 拍" -ForegroundColor Cyan
    vvp sim\build\tb_mem.vvp +stop=$Stop +vcd=tb +wave=sim/build/mem_wave_long.vcd |
        Select-Object -Last 8
}

Write-Host "[4/7] 统计数字（sim/build/mem_facts.json）" -ForegroundColor Cyan
python sim\analyze_mem.py --json | Select-Object -Last 3

Write-Host "[5/7] 重画图（figures/存储器/）" -ForegroundColor Cyan
python sim\mem_wave.py
python sim\mem_map_fig.py

Write-Host "[6/7] WaveDrom：真实波形 → WaveJSON（IROM / DCache 全部端口）" -ForegroundColor Cyan
python sim\wd_mem.py

# W3/W4 用**另一份**演示程序（sw/sb/sh 三种宽度写 + MMIO 读写），trace 另存，
# 不动 mem_demo 的 mem_trace.csv —— 否则 W1/W2 与 M2~M8 会全错。
Write-Host "[6b/7] WaveDrom：DRAM / MMIO 两张图（sim/dram_mmio.hex + mem_trace_io.csv）" -ForegroundColor Cyan
python sim\gen_dram_mmio_demo.py | Select-Object -First 2
vvp sim\build\tb_mem.vvp +prog=sim/dram_mmio.hex +csv=sim/build/mem_trace_io.csv +stop=240 +nochk +wave=sim/build/mem_wave_io.vcd | Select-Object -Last 2
python sim\wd_io.py

Write-Host "[7/7] WaveDrom：两个工具各自的引擎出 SVG/PNG" -ForegroundColor Cyan
python sim\wd_vendor.py
python sim\wd_render.py

Write-Host "完成。讲义：docs/存储器专题_研讨.docx（重新生成用 python docs/report_src/make_mem_doc.py）" -ForegroundColor Green
