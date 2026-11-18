# sw/build_ps_sd.ps1 -- build the PS-side SD-card programs (Cortex-A9, bare metal)
#
# Why a separate script from build_ps_app.ps1:
#   the SD programs compile the vendored Xilinx xsdps driver (sw\ps\sdps) plus a
#   freestanding port layer (sw\ps\port), need -lgcc (integer division helpers)
#   and use their own linker script (sw\ps\link_ps_sd.ld) that reserves the SD
#   DMA buffer at 0x28000.
#
# Usage:
#   powershell -NoProfile -File sw\build_ps_sd.ps1                     # sd_probe
#   powershell -NoProfile -File sw\build_ps_sd.ps1 -App sd_csv
#
# Products: sw\build\ps\<app>.elf / .bin / .map
#
# NOTE: pure ASCII only (PowerShell 5.1 decodes BOM-less .ps1 as OEM 936).
param(
    [string] $Gcc = 'E:\renases_e2s\toolchains\gcc_arm\13.2.rel1\bin\arm-none-eabi-gcc.exe',
    [string] $App = 'sd_probe',
    [string] $Ld  = 'sw\ps\link_ps_sd.ld'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$out = Join-Path $root 'sw\build\ps'
New-Item -ItemType Directory -Force -Path $out | Out-Null

if (-not (Test-Path -LiteralPath $Gcc)) { Write-Host "[sd] FAIL: gcc not found: $Gcc"; exit 1 }
$bindir  = Split-Path -Parent $Gcc
$objcopy = Join-Path $bindir 'arm-none-eabi-objcopy.exe'
$size    = Join-Path $bindir 'arm-none-eabi-size.exe'

$cflags = @(
    '-mcpu=cortex-a9', '-marm', '-O2', '-g',
    '-mno-unaligned-access',
    '-ffreestanding', '-fno-builtin', '-fno-common', '-nostdlib',
    '-ffunction-sections', '-fdata-sections',
    '-Wall', '-Wno-unused-parameter', '-Wno-unused-variable',
    '-Isw/ps', '-Isw/ps/port', '-Isw/ps/sdps'
)

# driver sources: note xsdps_g.c (XPAR_* config table) and xsdps_sinit.c
# (XSdPs_LookupConfig) are NOT built -- sd_probe.c supplies its own config.
#
# $extra: apps that share a hardware layer. sd_bit.c / sd_fat_sd.c both sit on top
# of sd_bit_bus.c (MIO bit-bang + sd_bus adapter); sd_wr_test.c needs nothing else
# because its "card" is a memory model inside the same file.
$extra = @{
    'sd_bit'         = @('sw\ps\sd_bit_bus.c')
    'sd_fat_sd'      = @('sw\ps\sd_bit_bus.c')
    'sd_fat_sd_syn'  = @('sw\ps\sd_bit_bus.c')
    'sd_dump'        = @('sw\ps\sd_bit_bus.c')
}
$srcs = @("sw\ps\$App.c")
if ($extra.ContainsKey($App)) { $srcs += $extra[$App] }
$srcs += @(
    'sw\ps\port\xil_shim.c',
    'sw\ps\fat32.c',
    'sw\ps\sd_wr.c',
    'sw\ps\sd_crc.c',
    'sw\ps\sd_record.c',
    'sw\ps\sdps\xsdps.c',
    'sw\ps\sdps\xsdps_card.c',
    'sw\ps\sdps\xsdps_host.c',
    'sw\ps\sdps\xsdps_options.c'
)

$objs = @()
$rc = 0
foreach ($s in $srcs) {
    if (-not (Test-Path -LiteralPath $s)) { Write-Host "[sd] FAIL: no such source: $s"; exit 1 }
    $o = Join-Path $out ((Split-Path -Leaf $s) -replace '\.c$', '.sd.o')
    Write-Host "[sd] compile $s"
    & $Gcc @cflags -c $s -o $o 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { Write-Host "[sd] FAIL: compile $s"; $rc = 1; }
    $objs += $o
}
if ($rc -ne 0) { exit 1 }

$ostart = Join-Path $out 'start_ps_sd.o'
Write-Host "[sd] assemble sw\ps\start_ps_sd.S"
& $Gcc @cflags -c 'sw\ps\start_ps_sd.S' -o $ostart 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "[sd] FAIL: assemble"; exit 1 }

Write-Host "[sd] link"
$linkArgs = @('-mcpu=cortex-a9', '-marm', '-nostdlib',
              '-Wl,--gc-sections',
              '-T', $Ld, "-Wl,-Map,sw/build/ps/$App.map",
              $ostart) + $objs + @('-o', "$out\$App.elf", '-lgcc')
& $Gcc @linkArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "[sd] FAIL: link"; exit 1 }

& $size "$out\$App.elf"
& $objcopy '-O' 'binary' "$out\$App.elf" "$out\$App.bin"
if ($LASTEXITCODE -ne 0) { Write-Host "[sd] FAIL: objcopy"; exit 1 }

$elf = Get-Item "$out\$App.elf"
Write-Host ("[sd] OK: {0} ({1} B)" -f $elf.Name, $elf.Length)
Write-Host "[sd] run: _diag\ps_run_sd.tcl (fpga -> ps7_init -> dow $App.elf -> con)"
exit 0

