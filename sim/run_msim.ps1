# =============================================================================
# sim/run_msim.ps1 -- v9 full regression driver for ModelSim (Windows)
# -----------------------------------------------------------------------------
# ASCII-ONLY ON PURPOSE. Windows PowerShell 5.1 (powershell.exe) reads a .ps1
# file using the ANSI/OEM code page (936 on this machine) unless the file has a
# UTF-8 BOM. UTF-8 Chinese comments then decode into bytes that swallow the
# following newlines and merge lines together, which produces nonsense errors
# such as:
#     Join-Path : Cannot bind argument to parameter 'Path' because it is null.
# The Chinese documentation lives in sim/README_msim.md instead.
# (Same reason sim/run_iverilog.bat is ASCII-only.)
#
# usage (from anywhere):
#     powershell -NoProfile -ExecutionPolicy Bypass -File sim\run_msim.ps1
#   or simply:
#     sim\run_msim.bat
#
# what it does:
#   1) vlib work + vlog -sv of the RTL and sim/tb_msim.sv
#   2) 7 programs in normal mode and 7 in strict mode (+no_wbu_force +raw_rf)
#   3) the D-Cache unit testbench
#   4) a summary table; exit code 0 only if everything passed
#
# why an external driver instead of a single .do:
#   * vsim exit codes are NOT reliable in -c batch mode (even $fatal can return 0)
#   * Tcl's `redirect` command does not exist in -c mode
#     (invalid command name "redirect")
#   so we call vsim once per program and parse "[SELFCHECK] status=..." from logs.
# =============================================================================

$ErrorActionPreference = 'Stop'

# NOTE: never name a variable $MSIM -- PowerShell has a reserved $MSIM
#   (the ModelSim automation object, $null when not installed); assigning to it
#   is silently ignored and the next Join-Path fails with "Path ... is null".
$MsimBin = 'E:\FPGA\ModelSim_10.5se\win64'
$vlib = Join-Path $MsimBin 'vlib.exe'
$vlog = Join-Path $MsimBin 'vlog.exe'
$vsim = Join-Path $MsimBin 'vsim.exe'

foreach ($t in @($vlib, $vlog, $vsim)) {
    if (-not (Test-Path $t)) { throw "ModelSim tool not found: $t" }
}

$CpuRoot = Split-Path -Parent $PSScriptRoot          # v9 project root
$LogDir = Join-Path $CpuRoot 'msim\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Set-Location $CpuRoot

# ------------------------------------------------------------------ 1) compile
Write-Host "=== [1/3] vlib + vlog (RTL + sim/tb_msim.sv) ===" -ForegroundColor Cyan
if (Test-Path 'work') { Remove-Item -Recurse -Force 'work' }
& $vlib work | Out-Null

$RTL = @(
    'rtl/myCPU.sv', 'rtl/IFU.sv', 'rtl/ICache.sv', 'rtl/Branch_Predictor.sv', 'rtl/IDU.sv',
    'rtl/Reg_Stack.sv', 'rtl/RegisterFile.sv', 'rtl/CSR.sv', 'rtl/EXU.sv', 'rtl/ALU.sv',
    'rtl/MDU_pipelined.sv', 'rtl/LSU.sv', 'rtl/DCache.sv', 'rtl/WBU.sv',
    'rtl/Data_hazard.sv', 'rtl/Control.sv', 'rtl/add.sv', 'rtl/sext.sv', 'rtl/Reg.sv'
)
# relative +incdir on purpose: the project root contains a space, and an
# absolute "+incdir+E:/share doc/v9" gets split into two arguments by vlog.
# NOTE: no -incr. We delete 'work' right above, so incremental compilation buys
#   nothing -- but it CAN hurt: vlog -incr decides purely on file timestamps
#   whether to re-read a source, and a stale object then silently keeps an old
#   port list (observed: "Port 'irom_en' not found in module 'myCPU'" from
#   tb_board_top after myCPU gained ports). Always full-compile here.
# -suppress 7061 on vlog (not just vsim): the testbenches preload memory arrays
# with an initial block while an always_ff also writes them; ModelSim treats that
# as an error, iverilog accepts it. Suppressing keeps the testbench untouched.
& $vlog -sv -quiet -suppress 7061 -work work '+incdir+.' '+incdir+rtl' @RTL 'sim/tb_msim.sv'
if ($LASTEXITCODE -ne 0) { throw "vlog failed (rc=$LASTEXITCODE)" }
Write-Host "    compile OK"

# ------------------------------------------------------------- 2) regressions
$Progs = @(
    @{ n = 'prog';           id = 0; mx = 600  },
    @{ n = 'prog_mul';       id = 1; mx = 600  },
    @{ n = 'prog_div';       id = 2; mx = 900  },
    @{ n = 'prog_load_lane'; id = 3; mx = 900  },
    @{ n = 'prog_load_use';  id = 4; mx = 900  },
    @{ n = 'prog_loop';      id = 5; mx = 1200 },
    @{ n = 'prog_div_pair';  id = 6; mx = 1200 }
)

function Invoke-One {
    param([string]$Name, [int]$Id, [int]$Max, [string]$Tag, [string[]]$Extra)
    $log = Join-Path $LogDir ("msim_{0}_{1}.log" -f $Name, $Tag)
    $vargs = @('-c', '-quiet', '-suppress', '7061', '-L', 'work', 'work.tb_msim',
        "+prog=sim/$Name.hex", "+prog_id=$Id", "+max=$Max") + $Extra +
        @('-do', 'run -all; quit -f')
    & $vsim @vargs 2>&1 | Out-File -Encoding utf8 $log
    $txt = Get-Content $log -Raw
    if ($txt -match 'status=PASS\s+\((\d+)/(\d+) checks passed\)') {
        return @{ ok = $true; msg = "PASS $($Matches[1])/$($Matches[2])" }
    }
    elseif ($txt -match 'status=NO_EXPECTATION') { return @{ ok = $true; msg = 'N/A (measured only)' } }
    elseif ($txt -match 'status=FAIL:\s+(\d+) mismatch') { return @{ ok = $false; msg = "FAIL $($Matches[1]) mismatch(es)" } }
    elseif ($txt -match 'status=TIMEOUT') { return @{ ok = $false; msg = 'TIMEOUT (no ecall)' } }
    else { return @{ ok = $false; msg = 'NO VERDICT in log (load error?)' } }
}

Write-Host "`n=== [2/3] 7 programs x {normal, strict} + dcache unit ===" -ForegroundColor Cyan
$results = @()
foreach ($p in $Progs) {
    $r1 = Invoke-One -Name $p.n -Id $p.id -Max $p.mx -Tag 'normal' -Extra @()
    $r2 = Invoke-One -Name $p.n -Id $p.id -Max $p.mx -Tag 'strict' -Extra @('+no_wbu_force', '+raw_rf')
    $results += [pscustomobject]@{ Prog = $p.n; Mode = 'normal'; Result = $r1.msg; OK = $r1.ok }
    $results += [pscustomobject]@{ Prog = $p.n; Mode = 'strict'; Result = $r2.msg; OK = $r2.ok }
    $mark = if ($r1.ok -and $r2.ok) { 'OK  ' } else { 'BAD ' }
    Write-Host ("  [{0}] {1,-16} normal: {2,-22} strict: {3}" -f $mark, $p.n, $r1.msg, $r2.msg)
}

$dcOk = $true
$dcMsg = 'SKIP (file not found)'
if (Test-Path (Join-Path $CpuRoot 'sim\tb_dcache_unit.sv')) {
    & $vlog -sv -quiet -suppress 7061 -work work -incr '+incdir+.' 'sim/tb_dcache_unit.sv' | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $log = Join-Path $LogDir 'msim_dcache_unit.log'
        & $vsim -c -quiet -L work work.tb_dcache_unit -do 'run -all; quit -f' 2>&1 | Out-File -Encoding utf8 $log
        $txt = Get-Content $log -Raw
        # the unit testbench prints its verdict as "DCACHE-UNIT: PASS"
        if ($txt -match 'DCACHE-UNIT:\s*PASS') { $dcMsg = 'PASS' }
        else { $dcMsg = 'FAIL / no verdict'; $dcOk = $false }
    }
    else { $dcMsg = 'compile failed'; $dcOk = $false }
}
$results += [pscustomobject]@{ Prog = 'tb_dcache_unit'; Mode = 'unit'; Result = $dcMsg; OK = $dcOk }
$dcMark = if ($dcOk) { 'OK  ' } else { 'BAD ' }
Write-Host ("  [{0}] {1,-16} {2}" -f $dcMark, 'tb_dcache_unit', $dcMsg)

# ------------------------------------------------------------------ 3) summary
$bad = @($results | Where-Object { -not $_.OK })
Write-Host "`n=== [3/3] SUMMARY ===" -ForegroundColor Cyan
Write-Host ("  checks run : {0}" -f $results.Count)
Write-Host ("  failures   : {0}" -f $bad.Count)
if ($bad.Count -eq 0) {
    Write-Host "  RESULT     : ALL PASS" -ForegroundColor Green
}
else {
    Write-Host "  RESULT     : FAIL" -ForegroundColor Red
    $bad | Format-Table -AutoSize | Out-String | Write-Host
}

$results | Format-Table -AutoSize | Out-File -Encoding utf8 (Join-Path $LogDir 'msim_summary.txt')
Write-Host "  logs       : $LogDir"

exit $(if ($bad.Count -eq 0) { 0 } else { 1 })
