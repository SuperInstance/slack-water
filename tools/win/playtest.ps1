# One-shot playtest driver: focus Studio, press Play, wait, capture.
#
# WHY THIS IS A SINGLE SCRIPT
# Invoking powershell.exe from WSL attaches it to the foreground terminal and
# STEALS FOCUS. Any click using coordinates computed before that lands on the
# terminal instead of Studio. Running the whole sequence inside one detached,
# hidden PowerShell process means Studio holds the foreground for the entire
# click -> wait -> capture cycle and the coordinates stay valid.
#
# usage: playtest.ps1 <outdir> <button:"play"|"stop"> [waitSeconds] [x] [y]

param(
    [string]$OutDir = "C:\Users\casey\AppData\Local\slack-water-tools\shots",
    [string]$Button = "play",
    [int]$Wait = 20,
    [int]$X = 113,
    [int]$Y = 61
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Reuse the input/screenshot primitives from the sibling scripts.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$inputPs = Join-Path $here "input.ps1"
$shotPs = Join-Path $here "shot.ps1"

# Focus Studio first. input.ps1's 'focus' does ShowWindow + SetForegroundWindow.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputPs focus "Place1 - Roblox Studio" | Out-Null
Start-Sleep -Milliseconds 900

# Move the mouse and click WITHOUT letting anything else take focus.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputPs clickat $X $Y | Out-Null
Write-Output "clicked '$Button' at $X,$Y"

Start-Sleep -Seconds $Wait

$out = Join-Path $OutDir ("playtest_" + (Get-Date -Format "HHmmss") + ".png")
# Capture the STUDIO WINDOW specifically, not the whole desktop. Two displays
# are attached and Settings/another app can hold the foreground; a full-desktop
# capture led to clicking whatever happened to be at those coordinates.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shotPs -Out $out -WindowTitle "Place1 - Roblox Studio" | Out-Null
Write-Output "captured $out"