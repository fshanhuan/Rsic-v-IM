# tools/ps/sd_wr_test.ps1 -- one command: build, run on board, dump fake card, verify with Python
#
# What it proves (no SD card needed):
#   sw/ps/sd_wr_test.c puts a "fake card" in OCM (0x1_0000, 64 KB). The fake card
#   answers CMD17/CMD24 per spec, recomputes CRC16 itself, asserts busy, and can
#   inject 8 different failures. Every sd_wr.c return code is exercised once, and a
#   full FAT32 volume is written through fat32_io -> sd_fat_read/write -> sd_wr.
#
# Usage:
#   powershell -NoProfile -File tools\ps\sd_wr_test.ps1              # build + run + verify
#   powershell -NoProfile -File tools\ps\sd_wr_test.ps1 -SkipRun     # build only
#   powershell -NoProfile -File tools\ps\sd_wr_test.ps1 -Wait 12000  # longer settle time
#
# Exit code: 0 only if the board log says RESULT PASS *and* the Python verifier passes.
#
# NOTE: pure ASCII only (PowerShell 5.1 decodes BOM-less .ps1 as OEM 936).
param(
    [int] $Wait = 9000,
    [switch] $SkipRun,
    [string] $Xsdb = 'D:\vivado\2025.2\Vivado\bin\xsdb.bat'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

Write-Host "== [1/4] build sd_wr_test =="
& powershell -NoProfile -ExecutionPolicy Bypass -File sw\build_ps_sd.ps1 -App sd_wr_test
if ($LASTEXITCODE -ne 0) { Write-Host "RESULT FAIL_build"; exit 1 }

if ($SkipRun) { Write-Host "== skip run (build only) =="; exit 0 }

# stale JTAG servers wedge the DAP -- always clear them
Get-Process hw_server, cs_server, xsdb -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Seconds 2

Write-Host "== [2/4] run on board =="
$env:SD_ELF  = 'sw/build/ps/sd_wr_test.elf'
$env:SD_WAIT = "$Wait"
$log = & $Xsdb _diag\ps_run_sd.tcl 2>&1 | Out-String
$log | Set-Content -Path 'sim\build\sd\sd_wr_test_run.txt' -Encoding UTF8
Write-Host $log

if ($log -notmatch 'RESULT PASS') {
    Write-Host "RESULT FAIL_board (see sim\build\sd\sd_wr_test_run.txt)"
    exit 1
}

Write-Host "== [3/4] dump fake card image =="
& $Xsdb _diag\dump_card.tcl 2>&1 | Write-Host
if (-not (Test-Path 'sim\build\sd\cardimage.bin')) { Write-Host "RESULT FAIL_dump"; exit 1 }

Write-Host "== [4/4] independent FAT32 verify =="
python tools\ps\fat32_verify.py sim\build\sd\cardimage.bin
if ($LASTEXITCODE -ne 0) { Write-Host "RESULT FAIL_verify"; exit 1 }

Write-Host "RESULT PASS (board log + independent Python parse)"
exit 0
