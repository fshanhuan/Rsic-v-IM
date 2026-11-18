# tools/ps/host/build_sim.ps1 -- build + run the bit-level SD simulation
#
# What it does: compiles the REAL sw/ps/sd_bit_bus.c (the GPIO bit-bang driver)
# together with sw/ps/sd_wr.c, sw/ps/fat32.c, sw/ps/sd_record.c and a bit-level
# SD card model, then runs the whole product path on the PC. The only thing not
# simulated is how long a clock edge takes on real wires.
#
# The sim's xil_io.h / sleep.h shims (tools/ps/host/sim) must come FIRST on the
# include path so they shadow the real MMIO macros.
#
# Usage:
#   powershell -NoProfile -File tools\ps\host\build_sim.ps1
#
# Exit code: 0 only if the C test says RESULT PASS and the independent FAT32
# parse of the simulated card image passes.
#
# NOTE: pure ASCII only (PowerShell 5.1 decodes BOM-less .ps1 as OEM 936).
param(
    [string] $Gcc    = 'E:\MinGW\bin\gcc.exe',
    [string] $Root   = '',
    [string] $Python = 'python',
    [int]    $Samples = 1000
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrEmpty($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}
Set-Location $Root

if (-not (Test-Path -LiteralPath $Gcc)) { Write-Host "[sim] FAIL: gcc not found: $Gcc"; exit 1 }
New-Item -ItemType Directory -Force -Path 'sim\build\sd' | Out-Null

$exe = 'sim\build\sd\sd_bit_sim.exe'
Write-Host "[sim] compile (real driver + bit-level card model)"
& $Gcc -O2 -Wall -Wextra -Wno-unused-parameter `
    '-Itools/ps/host/sim' -Isw/ps -Isw/ps/port `
    'tools/ps/host/sd_bit_sim_test.c' 'sw/ps/sd_bit_bus.c' 'sw/ps/sd_wr.c' `
    'sw/ps/sd_record.c' 'sw/ps/fat32.c' 'sw/ps/sd_crc.c' `
    -o $exe 2>&1 | ForEach-Object { Write-Host "  $_" }
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "[sim] FAIL: compile"; exit 1 }

Write-Host "[sim] run"
& $exe
if ($LASTEXITCODE -ne 0) { Write-Host "[sim] FAIL: simulation reported failures"; exit 1 }

Write-Host "[sim] independent FAT32 parse of the simulated card image"
& $Python 'tools\ps\fat32_verify.py' 'sim\build\sd\sim_card.img' --samples $Samples
$rc1 = $LASTEXITCODE

Write-Host "[sim] third-party FAT driver (pyfatfs) on the same image"
& $Python 'tools\ps\fat32_probe_pyfatfs.py' 'sim\build\sd\sim_card.img' --samples $Samples
$rc2 = $LASTEXITCODE

if (($rc1 -ne 0) -or ($rc2 -ne 0)) { Write-Host "[sim] RESULT FAIL_verify"; exit 1 }
Write-Host "[sim] RESULT PASS (bit-level sim + spec parse + third-party driver)"
exit 0
