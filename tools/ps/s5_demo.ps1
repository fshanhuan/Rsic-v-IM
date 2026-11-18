# s5_demo.ps1 —— 一条命令复现 S5/S7：烧 S5 位流 → ARM 排空 N 个样本导 CSV → 烧回记录仪 → 读 VIO 复核
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\s5_demo.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\s5_demo.ps1 -N 2048
#
# 说明：
#   · 每一步之间会清掉残留的 hw_server（否则下一次 xsdb 可能看到空目标列表）；
#   · 结束后板上是**记录仪位流**，不会把板子留在 S5 状态；
#   · 产物：sim/build/drain_<时间戳>.csv
param(
    [int]$N = 2048
)
$ErrorActionPreference = 'Continue'
$root = 'E:\FPGA\v9_vivado_ila'
$xsdb = 'D:\vivado\2025.2\Vivado\bin\xsdb.bat'
$viv  = 'D:\vivado\2025.2\Vivado\bin\vivado.bat'

function Kill-Hw {
    Get-Process hw_server,cs_server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}
function Step([string]$msg) { Write-Host "" ; Write-Host "==== $msg" -ForegroundColor Cyan }

Step "1/4 烧 S5 位流（PS + 记录仪 MMIO）"
Kill-Hw
& $xsdb "$root\_diag\prog_s5.tcl" 2>&1 | Where-Object { $_ -match '^\[PG\]' } | ForEach-Object { Write-Host $_ }

Step "2/4 ARM 排空 $N 个样本并导出 CSV"
Kill-Hw
$env:DRAIN_N = "$N"
$drainLog = "$root\sim\build\s5_demo_drain.log"
& $xsdb "$root\tools\ps\arm_drain.tcl" 2>&1 | Tee-Object -FilePath $drainLog |
    Where-Object { $_ -match '^\[DRAIN\]' } | ForEach-Object { Write-Host $_ }

Step "3/4 烧回记录仪位流"
Kill-Hw
& $xsdb "$root\_diag\restore_rec2.tcl" 2>&1 | Where-Object { $_ -match '^\[R\] prog|Legacy Debug Hub' } | ForEach-Object { Write-Host $_ }

Step "4/4 读 VIO 复核记录仪"
Kill-Hw
$env:VIO_SAMPLES = '1'
$env:VIO_INTH = '1'
& $viv -mode batch -nolog -nojournal -notrace -source "$root\_diag\read_vio.tcl" 2>&1 |
    Where-Object { $_ -match 'VIOIN\|(adc_cnt|adc_level|m_frame_clk|meas_m)' } | ForEach-Object { Write-Host $_ }

# ---------------- 汇总 ----------------
$txt = if (Test-Path $drainLog) { Get-Content $drainLog -Raw } else { '' }
$pass = $txt -match 'RESULT=DRAIN-PASS'
$run  = $txt -match 'RESULT=RUNLEN-PASS'
$csv  = Get-ChildItem "$root\sim\build\drain_*.csv" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1

Write-Host ""
Write-Host "================ 汇总 ================"
Write-Host ("排空       : " + $(if ($pass) { 'PASS' } else { 'FAIL' }))
Write-Host ("游程连续   : " + $(if ($run)  { 'PASS（中间段全 128）' } else { '未通过/未判定' }))
Write-Host ("CSV         : " + $(if ($csv) { $csv.FullName } else { '没找到' }))
if ($pass) { exit 0 } else { exit 1 }
