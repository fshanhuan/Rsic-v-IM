# tools/ps/hdmi_grab.ps1 -- capture one HDMI frame and decide whether it is OUR picture
#
# One command does three things:
#   1) grab a frame (or a short clip) from the USB capture card (UGREEN-25854)
#   2) run hdmi_frame_stats.py: near-black / green ratio + grid spacing
#   3) print one RESULT line a script can parse
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\hdmi_grab.ps1
#   ... -Seconds 2                 # 2 s clip (see whether the waveform moves)
#   ... -Tag after_repower         # tag in the output file name
#
# Verdicts (from hdmi_frame_stats.py):
#   NO_SIGNAL     capture card OSD -> the board is not driving TMDS
#   GRID_80       our picture (800 columns, 80 px column grid, 50 px row grid)
#   FRAME_NO_GRID something is there but it is not ours
#
# NOTE: pure ASCII only. PowerShell 5.1 decodes BOM-less .ps1 as OEM 936, so any
#       UTF-8 Chinese comment here turns into mojibake and breaks the parser.
param(
    [string] $Tag    = 'live',
    [int]    $Seconds = 0,
    [string] $Dev    = 'UGREEN-25854',
    [string] $Ffmpeg = 'C:\ffmpeg-master-latest-win64-gpl-shared\ffmpeg-master-latest-win64-gpl-shared\bin\ffmpeg.exe'
)
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root

if (-not (Test-Path -LiteralPath $Ffmpeg)) { Write-Host "FAIL: ffmpeg not found: $Ffmpeg"; exit 1 }

$png = "_diag\hdmi_$Tag.png"
Remove-Item -LiteralPath $png -ErrorAction SilentlyContinue

# Ask for 800x600; the card answers with whatever it can lock to. With no signal it
# hands back a 1920x1080 OSD frame -- that difference is itself evidence.
$ffArgs = @(
    '-hide_banner', '-loglevel', 'error',
    '-f', 'dshow', '-video_size', '800x600', '-framerate', '60',
    '-i', "video=$Dev"
)
$mp4 = "_diag\hdmi_$Tag.mp4"
if ($Seconds -gt 0) { $ffArgs += @('-t', "$Seconds", '-y', $mp4) }
else                { $ffArgs += @('-frames:v', '1', '-y', $png) }

$target = $png
if ($Seconds -gt 0) { $target = $mp4 }
Write-Host ("== [grab] {0}  ->  {1}" -f $Dev, $target)
& $Ffmpeg @ffArgs 2>&1 | Select-Object -First 6 | ForEach-Object { Write-Host "   $_" }

if ($Seconds -gt 0) {
    if (-not (Test-Path -LiteralPath $mp4)) { Write-Host "RESULT hdmi_grab FAIL (no clip)"; exit 1 }
    & $Ffmpeg -hide_banner -loglevel error -i $mp4 -frames:v 1 -y $png 2>&1 | Out-Null
    $size = (Get-Item $mp4).Length
    Write-Host ("== [clip] {0}  {1:N0} bytes" -f $mp4, $size)
}

if (-not (Test-Path -LiteralPath $png)) {
    Write-Host "RESULT hdmi_grab FAIL (capture produced no frame -- is another app holding the card?)"
    exit 1
}

Write-Host "== [stats]"
$lines = & python "tools\ps\hdmi_frame_stats.py" $png 2>&1
$lines | ForEach-Object { Write-Host "   $_" }
$res = ($lines | Where-Object { $_ -match 'RESULT frame_stats' } | Select-Object -Last 1)
if (-not $res) { Write-Host "RESULT hdmi_grab FAIL (no stats)"; exit 1 }

$verdict = 'UNKNOWN'
if ($res -match 'verdict=(\S+)') { $verdict = $Matches[1] }
Write-Host ""
Write-Host ("RESULT hdmi_grab tag={0} verdict={1} png={2}" -f $Tag, $verdict, $png)
if ($verdict -eq 'GRID_80') { exit 0 } else { exit 2 }
