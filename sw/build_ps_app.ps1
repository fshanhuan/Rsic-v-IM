# sw/build_ps_app.ps1 -- build PS-side (Cortex-A9) bare-metal programs
#
# Why PowerShell and not WSL: the ARM toolchain is a Windows install
#   E:\renases_e2s\toolchains\gcc_arm\13.2.rel1\bin\arm-none-eabi-gcc.exe
# (this machine's Vitis install has no hsi/BSP, but the compiler itself is fine)
#
# Usage:
#   powershell -NoProfile -File sw\build_ps_app.ps1                 # default: ps_axil_test
#   powershell -NoProfile -File sw\build_ps_app.ps1 -App riscv_loader
#
# Products: sw\build\ps\<app>.elf / .bin / .map
#
# NOTE: pure ASCII only (PowerShell 5.1 decodes BOM-less .ps1 as OEM 936).
param(
    [string] $Gcc = 'E:\renases_e2s\toolchains\gcc_arm\13.2.rel1\bin\arm-none-eabi-gcc.exe',
    [string] $App = 'ps_axil_test',
    [string] $Start = 'start_ps.S',
    [string] $Ld = 'link_ps.ld'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$out = Join-Path $root 'sw\build\ps'
New-Item -ItemType Directory -Force -Path $out | Out-Null

if (-not (Test-Path -LiteralPath $Gcc)) { Write-Host "[ps] FAIL: gcc not found: $Gcc"; exit 1 }
$bindir = Split-Path -Parent $Gcc
$objcopy = Join-Path $bindir 'arm-none-eabi-objcopy.exe'
$size    = Join-Path $bindir 'arm-none-eabi-size.exe'

$cflags = @(
    '-mcpu=cortex-a9', '-marm', '-O2', '-g',
    '-ffreestanding', '-fno-builtin', '-fno-common', '-nostdlib',
    '-Wall', '-Isw/ps'
)

$src  = "sw\ps\$App.c"
$start = "sw\ps\$Start"
$ld   = "sw\ps\$Ld"

if (-not (Test-Path -LiteralPath $src)) { Write-Host "[ps] FAIL: no such source: $src"; exit 1 }

Write-Host "[ps] compile $src"
& $Gcc @cflags -c $src -o "$out\$App.o" 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "[ps] FAIL: compile"; exit 1 }

Write-Host "[ps] assemble $start"
& $Gcc @cflags -c $start -o "$out\start_ps.o" 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "[ps] FAIL: assemble"; exit 1 }

Write-Host "[ps] link"
& $Gcc '-mcpu=cortex-a9' '-marm' '-nostdlib' '-T' $ld "-Wl,-Map,sw/build/ps/$App.map" `
       "$out\start_ps.o" "$out\$App.o" '-o' "$out\$App.elf" 2>&1 |
    ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "[ps] FAIL: link"; exit 1 }

& $size "$out\$App.elf"
& $objcopy '-O' 'binary' "$out\$App.elf" "$out\$App.bin"
if ($LASTEXITCODE -ne 0) { Write-Host "[ps] FAIL: objcopy"; exit 1 }

$elf = Get-Item "$out\$App.elf"
$bin = Get-Item "$out\$App.bin"
Write-Host ("[ps] OK: {0} ({1} B), {2} ({3} B)" -f $elf.Name, $elf.Length, $bin.Name, $bin.Length)
Write-Host "[ps] NOTE: loader = D:\vivado\2025.2\Vivado\bin\xsdb.bat (Vivado ships xsdb);"
Write-Host "[ps]       run _diag\ps_run.tcl to program PL + ps7_init + dow + con."
exit 0
