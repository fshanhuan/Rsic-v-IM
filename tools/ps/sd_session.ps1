# tools/ps/sd_session.ps1 -- one command for the whole SD validation session
#
# Why: when the card finally goes in, the sequence has order dependencies and each
# step prints a big log. This script runs them in the right order, parses the
# RESULT lines, and prints ONE verdict table. If a step fails it stops there and
# says which step, so nothing later is run on a half-broken card.
#
# Modes:
#   -Mode Plan   print the plan only (no hardware, safe)
#   -Mode Sim    host-only: bit-level simulation + FAT32 spec/third-party checks
#   -Mode Card   board: identify -> write synthetic CSV -> dump evidence -> verify   (default)
#   -Mode Full   Card + real recorder samples (sd_fat_sd) + re-dump/verify
#
# Usage:
#   powershell -NoProfile -File tools\ps\sd_session.ps1                 # Card mode
#   powershell -NoProfile -File tools\ps\sd_session.ps1 -Mode Plan
#   powershell -NoProfile -File tools\ps\sd_session.ps1 -Mode Sim
#   powershell -NoProfile -File tools\ps\sd_session.ps1 -Mode Full
#
# PREREQUISITES (the script cannot do these):
#   1) micro SD card inserted
#   2) board POWER-CYCLED after inserting (unplug DC 5 s), so the card sees a real
#      power-on reset. A PS soft reset is NOT enough.
#   3) PL bitstream with the recorder MMIO (only needed for -Mode Full):
#        xsdb _diag\restore_s6.tcl   or  board_top_ps_rec_S5.bit
#
# NOTE: pure ASCII only (PowerShell 5.1 decodes BOM-less .ps1 as OEM 936).
param(
    [ValidateSet('Plan', 'Sim', 'Card', 'Full')]
    [string] $Mode   = 'Card',
    [string] $Xsdb   = 'D:\vivado\2025.2\Vivado\bin\xsdb.bat',
    [string] $Root   = '',
    [string] $Python = 'python',
    [int]    $Wait   = 12000,
    [int]    $Samples = 1024
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrEmpty($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
Set-Location $Root

$results = New-Object System.Collections.ArrayList

function Add-Result($step, $status, $detail) {
    [void]$results.Add([pscustomobject]@{ Step = $step; Status = $status; Detail = $detail })
    Write-Host ("[{0}] {1} : {2}" -f $status, $step, $detail)
}

function Say($msg) { Write-Host $msg }

# ------------------------------------------------------------------ plan
$plan = @(
    'sim      : host bit-level simulation + FAT32 spec/third-party checks',
    'preflight: elf files present, board debug APB reachable',
    'sd_bit   : identify card, read LBA0 (proves the wire protocol works)',
    'write    : sd_fat_sd_syn -> format + 1024-sample CSV (synthetic samples)',
    'dump     : sd_dump reads the evidence sectors into OCM, JTAG dumps them',
    'verify   : fat32_verify_dump.py rebuilds the volume, compares bytes, extracts the CSV to the PC',
    'full     : (optional) sd_fat_sd uses the real recorder FIFO, then re-dump/verify'
)

if ($Mode -eq 'Plan') {
    Say "== SD session plan (mode Plan: nothing is touched) =="
    $i = 1
    foreach ($p in $plan) { Say ("  {0}. {1}" -f $i, $p); $i++ }
    Say ""
    Say "Card placement + POWER CYCLE are manual and required."
    exit 0
}

# ------------------------------------------------------------------ sim
if ($Mode -eq 'Sim' -or $Mode -eq 'Full') {
    Say "== [sim] host-only verification =="
    & powershell -NoProfile -ExecutionPolicy Bypass -File 'tools\ps\host\build_sim.ps1' 2>&1 |
        Select-String -Pattern 'checks:|RESULT' | ForEach-Object { Say "  $($_.Line)" }
    if ($LASTEXITCODE -eq 0) { Add-Result 'sim' 'PASS' 'bit-level sim + spec parse + pyfatfs' }
    else                     { Add-Result 'sim' 'FAIL' 'see output above' }
    if ($Mode -eq 'Sim') {
        & powershell -NoProfile -ExecutionPolicy Bypass -File 'tools\ps\host\build_and_run.ps1' 2>&1 |
            Select-String -Pattern 'checks:|RESULT' | ForEach-Object { Say "  $($_.Line)" }
        if ($LASTEXITCODE -eq 0) { Add-Result 'host-fat32' 'PASS' 'FAT32/product path/dump pipeline' }
        else                     { Add-Result 'host-fat32' 'FAIL' 'see output above' }
        $results | Format-Table -AutoSize | Out-String | Write-Host
        exit 0
    }
}

# ------------------------------------------------------------------ preflight
if (-not (Test-Path -LiteralPath $Xsdb)) { Add-Result 'preflight' 'FAIL' "xsdb not found: $Xsdb"; exit 1 }
$elfs = @('sd_bit', 'sd_fat_sd_syn', 'sd_fat_sd', 'sd_dump')
$missing = @()
foreach ($e in $elfs) {
    if (-not (Test-Path -LiteralPath "sw\build\ps\$e.elf")) { $missing += $e }
}
if ($missing.Count -gt 0) {
    Say ("== building missing apps: {0} ==" -f ($missing -join ', '))
    foreach ($e in $missing) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File sw\build_ps_sd.ps1 -App $e 2>&1 |
            Select-String -Pattern 'error:|OK:' | ForEach-Object { Say "  $($_.Line)" }
    }
}
Get-Process hw_server, cs_server, xsdb -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Seconds 2

Say "== [preflight] board debug APB =="
$probe = & $Xsdb _diag\_dap_probe.tcl 2>&1 | Out-String
# 2026-11-19 21:30 改：原来只认 `apb_ok (initial) = 1`，实测出现过
#   initial=0 但 `rst -processor` 之后 =1（APB 又能读了，读写测试 0xCAFEBABE 通过）。
#   这时报 "POWER CYCLE" 是**误诊** —— 板子其实已经可用。
#   所以判据改成：initial 通，或者任何一步复位之后通了，都算 PASS，并把是哪一步练出来。
$apbInit = ($probe -match 'apb_ok \(initial\) = 1')
$apbAfter = [regex]::Match($probe, 'apb_ok after (.+?) = 1')
if ($apbInit -or $apbAfter.Success) {
    if ($apbInit) {
        Add-Result 'preflight' 'PASS' 'debug APB reachable (initial)'
    } else {
        Add-Result 'preflight' 'PASS' ("debug APB recovered by " + $apbAfter.Groups[1].Value.Trim())
        Say "  (initial 时 APB 是死的，执行 $($apbAfter.Groups[1].Value.Trim()) 之后恢复)"
    }
} else {
    Add-Result 'preflight' 'FAIL' 'debug APB dead -- POWER CYCLE the board (unplug DC 5 s)'
    Say ""
    Say "The PS debug access port is stuck (rst -dap / -system / -processor do not clear it)."
    Say "Unplug DC, wait 5 s, plug back in WITH THE CARD INSERTED, then run this again."
    $results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

# ------------------------------------------------------------------ helper: run one board app
function Run-App($app, $waitMs, $logName) {
    $env:SD_ELF  = "sw/build/ps/$app.elf"
    $env:SD_WAIT = "$waitMs"
    $out = & $Xsdb _diag\ps_run_sd.tcl 2>&1 | Out-String
    Set-Content -Path "sim\build\sd\$logName.txt" -Value $out -Encoding UTF8
    return $out
}

# ------------------------------------------------------------------ sd_bit
Say "== [sd_bit] identify card =="
$log = Run-App 'sd_bit' 10000 'session_sd_bit'
if ($log -match 'RESULT PASS') {
    Add-Result 'sd_bit' 'PASS' 'card identified, LBA0 read'
} else {
    $m = [regex]::Match($log, 'ncr=(\d+)')
    $ncr = if ($m.Success) { $m.Groups[1].Value } else { '?' }
    Add-Result 'sd_bit' 'FAIL' "no usable card response (ncr=$ncr, 64 = nothing on the line)"
    Say "  -> check: card fully inserted? power-cycled WITH the card in? card is a plain SDHC/SDXC?"
    $results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

# ------------------------------------------------------------------ write (synthetic samples)
Say "== [write] sd_fat_sd_syn: format + 1024-sample CSV =="
if ($Mode -eq 'Full') { Say "   (Full mode writes real samples below; synthetic run still proves the wire+FS path)" }
$log = Run-App 'sd_fat_sd_syn' 60000 'session_write_syn'
if ($log -match 'RESULT PASS') {
    $m = [regex]::Match($log, 'diff=(\d+)')
    $diff = if ($m.Success) { $m.Groups[1].Value } else { '?' }
    Add-Result 'write' 'PASS' "CSV written and read back byte-identical (diff=$diff)"
    $m2 = [regex]::Match($log, 'synthetic samples: (\d+)')
    $n = if ($m2.Success) { [int]$m2.Groups[1].Value } else { $Samples }
} else {
    $m = [regex]::Match($log, 'RESULT FAIL_(\w+)')
    $why = if ($m.Success) { $m.Groups[1].Value } else { 'unknown' }
    Add-Result 'write' 'FAIL' "step=$why (see sim\build\sd\session_write_syn.txt)"
    $results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

# ------------------------------------------------------------------ dump + verify
function Dump-And-Verify($nsamp, $tag) {
    Say "== [dump] read evidence sectors via sd_dump =="
    $log = Run-App 'sd_dump' 30000 "session_dump_$tag"
    if ($log -notmatch 'RESULT PASS') {
        $m = [regex]::Match($log, 'RESULT FAIL_(\w+)')
        $why = if ($m.Success) { $m.Groups[1].Value } else { 'unknown' }
        Add-Result "dump-$tag" 'FAIL' "step=$why"
        return $false
    }
    Say "== [dump] JTAG dump of the 16 KB evidence buffer =="
    $d = & $Xsdb _diag\dump_sd_evidence.tcl 2>&1 | Out-String
    if (-not (Test-Path 'sim\build\sd\sd_dump.bin')) { Add-Result "dump-$tag" 'FAIL' 'no dump file'; return $false }

    Say "== [verify] rebuild the volume from those sectors and compare =="
    # --extract: 把"卡上那个文件"原样落到 PC 上（验收要求里的"PC 能打开"）。
    # 落盘的是从卡字节重建出来的内容，不是期望值，所以这个文件就是卡上的东西。
    $csvOut = "sim\build\sd\card_file_$tag.csv"
    $v = & $Python 'tools\ps\fat32_verify_dump.py' 'sim\build\sd\sd_dump.bin' --samples $nsamp --extract $csvOut 2>&1 | Out-String
    Set-Content -Path "sim\build\sd\session_verify_$tag.txt" -Value $v -Encoding UTF8
    $v -split "`n" | Where-Object { $_ -match 'BPB:|clusters=|dirent:|chain:|expected|got |extracted|csv open|RESULT' } |
        ForEach-Object { Say "  $($_.TrimEnd())" }
    $ok = ($v -match 'RESULT PASS') -and ($v -match 'RESULT_CSV PASS')

    # 独立打开第二次：用 PowerShell 的 Import-Csv（和 Python csv 模块完全不同的实现）
    if (Test-Path -LiteralPath $csvOut) {
        try {
            $rows = Import-Csv -LiteralPath $csvOut
            Say ("  [pc-open] Import-Csv: {0} rows, columns={1}" -f $rows.Count,
                 (($rows[0].PSObject.Properties.Name) -join ','))
            Say ("  [pc-open] first={0} last={1}  (file: {2})" -f
                 ($rows[0].idx + ':' + $rows[0].adc), ($rows[-1].idx + ':' + $rows[-1].adc), $csvOut)
            if ($rows.Count -lt 2) { $ok = $false }
        } catch {
            Say "  [pc-open] FAIL: $($_.Exception.Message)"
            $ok = $false
        }
    } else {
        Say "  [pc-open] FAIL: $csvOut was not produced"
        $ok = $false
    }

    Say "== [verify] third-party FAT driver on the same volume =="
    $p = & $Python 'tools\ps\fat32_probe_pyfatfs.py' 'sim\build\sd\from_dump.img' --samples $nsamp 2>&1 | Out-String
    $p -split "`n" | Where-Object { $_ -match 'root listing|read:|exp :|RESULT' } |
        ForEach-Object { Say "  $($_.TrimEnd())" }
    if ($ok -and ($p -match 'RESULT PASS')) {
        Add-Result "verify-$tag" 'PASS' "card bytes == CSV (djb2 match), CSV extracted to PC and opened twice, third-party FAT driver reads it"
        return $true
    }
    Add-Result "verify-$tag" 'FAIL' ("see sim\build\sd\session_verify_$tag.txt")
    return $false
}

$good = Dump-And-Verify $n 1024
if (-not $good) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

# ------------------------------------------------------------------ optional: real samples
if ($Mode -eq 'Full') {
    Say "== [full] sd_fat_sd: real recorder samples (needs the recorder bitstream) =="
    $log = Run-App 'sd_fat_sd' 60000 'session_write_real'
    $m = [regex]::Match($log, 'captured (\d+) samples')
    if ($log -match 'RESULT PASS' -and $m.Success) {
        $rn = [int]$m.Groups[1].Value
        Add-Result 'write-real' 'PASS' "captured $rn real samples and wrote them"
        if (-not (Dump-And-Verify $rn 'real')) {
            $results | Format-Table -AutoSize | Out-String | Write-Host
            exit 1
        }
    } else {
        $why = [regex]::Match($log, 'RESULT FAIL_(\w+)')
        Add-Result 'write-real' 'FAIL' ("step=" + ($(if ($why.Success) { $why.Groups[1].Value } else { 'unknown' })))
        Say "  -> -Mode Card already proved the card path; this step needs the recorder PL bitstream."
        $results | Format-Table -AutoSize | Out-String | Write-Host
        exit 1
    }
}

Say ""
$results | Format-Table -AutoSize | Out-String | Write-Host
Say "RESULT PASS (card validated end to end)"
exit 0
