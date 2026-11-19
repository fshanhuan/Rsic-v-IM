# tools/ps/host/build_and_run.ps1 -- build + run the PC-side fat32/sd_wr test
#
# Why this exists: the board test can only use a 128-sector "small geometry"
# (OCM is 192 KB), but a real card uses 64 MB / 512 B clusters. This harness
# compiles the SAME sw/ps/fat32.c and sw/ps/sd_wr.c with MinGW gcc and runs the
# real-card geometry against a 64 MB RAM "card", then hands both images to
# tools/ps/fat32_verify.py for an independent FAT32 parse.
#
# Usage:
#   powershell -NoProfile -File tools\ps\host\build_and_run.ps1
#   powershell -NoProfile -File tools\ps\host\build_and_run.ps1 -Gcc 'C:\other\gcc.exe'
#
# Exit code: 0 only if the C test says RESULT PASS and both Python verifies pass.
#
# NOTE: pure ASCII only (PowerShell 5.1 decodes BOM-less .ps1 as OEM 936).
param(
    [string] $Gcc   = 'E:\MinGW\bin\gcc.exe',
    [string] $Root  = '',
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrEmpty($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}
Set-Location $Root

if (-not (Test-Path -LiteralPath $Gcc)) { Write-Host "[host] FAIL: gcc not found: $Gcc"; exit 1 }
New-Item -ItemType Directory -Force -Path 'sim\build\sd' | Out-Null

$exe = 'sim\build\sd\fat32_host_test.exe'
Write-Host "[host] compile"
& $Gcc -O2 -Wall -Wextra -Wno-unused-parameter `
    -Isw/ps -Isw/ps/port `
    'tools/ps/host/fat32_host_test.c' 'sw/ps/fat32.c' 'sw/ps/sd_wr.c' 'sw/ps/sd_record.c' 'sw/ps/sd_crc.c' `
    -o $exe 2>&1 | ForEach-Object { Write-Host "  $_" }
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "[host] FAIL: compile"; exit 1 }

Write-Host "[host] run"
& $exe
if ($LASTEXITCODE -ne 0) { Write-Host "[host] FAIL: test reported failures"; exit 1 }

Write-Host "[host] independent FAT32 parse (small image)"
& $Python 'tools\ps\fat32_verify.py' 'sim\build\sd\host_small.img'
$rc1 = $LASTEXITCODE

Write-Host "[host] independent FAT32 parse (64 MB real-card geometry)"
& $Python 'tools\ps\fat32_verify.py' 'sim\build\sd\host_64mb.img'
$rc2 = $LASTEXITCODE

Write-Host "[host] independent FAT32 parse (product path, 1000 samples)"
& $Python 'tools\ps\fat32_verify.py' 'sim\build\sd\host_record.img' --samples 1000
$rc2b = $LASTEXITCODE

Write-Host "[host] third-party FAT driver (pyfatfs) on the product-path image"
& $Python 'tools\ps\fat32_probe_pyfatfs.py' 'sim\build\sd\host_record.img' --samples 1000
$rc3 = $LASTEXITCODE

Write-Host "[host] evidence-dump pipeline (same format the board dumps)"
& $Python 'tools\ps\fat32_verify_dump.py' 'sim\build\sd\host_dump.bin' --samples 1000
$rc4 = $LASTEXITCODE

# 2026-11-20: 取样本那段的单元测试。这段逻辑（rec_capture.h）在板上**只有插了卡
# 才会跑到**，两个真 bug 因此活了几个月。这里用假的 rec_mmio 模型跑同一份代码：
# 窥视不弹 / 只读不弹 / 码值取错位 都会立刻红。
Write-Host "[host] rec_capture (peek/pop/shift protocol)"
& gcc -O2 -I sw/ps -o sim\build\rec_capture_test.exe tools\ps\host\rec_capture_test.c
if ($LASTEXITCODE -eq 0) {
    & 'sim\build\rec_capture_test.exe'
    $rc5 = $LASTEXITCODE
} else {
    Write-Host "[host] rec_capture_test did not compile"
    $rc5 = 1
}

if (($rc1 -ne 0) -or ($rc2 -ne 0) -or ($rc2b -ne 0) -or ($rc3 -ne 0) -or ($rc4 -ne 0) -or ($rc5 -ne 0)) {
    Write-Host "[host] RESULT FAIL_verify"; exit 1
}
Write-Host "[host] RESULT PASS (C test + spec parse + third-party driver + dump pipeline + rec_capture)"
exit 0
