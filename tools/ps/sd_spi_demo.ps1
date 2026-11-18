# tools/ps/sd_spi_demo.ps1 -- one command for the "SPI-mode SD card" attempt
#
# Why: a card enters SPI mode only if CMD0 (with CS low) is the FIRST command it
#   sees after power-up. Any earlier SD-mode attempt leaves it in SD mode until
#   the card is physically power-cycled. So the recovery procedure is:
#     1) unplug the DC adapter, wait 5 s, plug it back in (card stays inserted)
#     2) run this script  -- it is the FIRST thing to touch the card
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\sd_spi_demo.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\sd_spi_demo.ps1 -App sd_raw
#
# NOTE: pure ASCII only (PowerShell 5.1 decodes BOM-less .ps1 as OEM 936).
param(
    [string] $App   = 'sd_spi',
    [string] $Xsdb  = 'D:\vivado\2025.2\Vivado\bin\xsdb.bat',
    [int]    $WaitMs = 9000
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

$elf = "sw/build/ps/$App.elf"
if (-not (Test-Path $elf)) {
    Write-Host "[sd] FAIL: no such ELF: $elf"
    Write-Host "[sd] build it first: powershell -NoProfile -File sw\build_ps_sd.ps1 -App $App"
    exit 1
}

Write-Host "[sd] app      : $App"
Write-Host "[sd] elf      : $elf"

# stale debug servers make xsdb see an empty target list
Get-Process hw_server, cs_server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$env:SD_ELF  = $elf
$env:SD_WAIT = "$WaitMs"

Write-Host "[sd] step 1/2: PSS soft reset + download + run (log goes to UART and OCM)"
& $Xsdb _diag/ps_run_sd.tcl 2>&1 | Out-Null

Write-Host "[sd] step 2/2: read the in-memory log back over JTAG"
& $Xsdb _diag/ps_log_dump.tcl 2>&1 | ForEach-Object { Write-Host $_ }

Write-Host ""
Write-Host "[sd] NOTE: this leaves the PL unprogrammed. Restore the recorder with:"
Write-Host "[sd]       D:\vivado\2025.2\Vivado\bin\xsdb.bat _diag/restore_s6.tcl"
exit 0
