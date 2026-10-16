# Capture the Studio window AND report where it is, so a caller can convert
# image coordinates into screen coordinates.
#
# Hardcoding click positions broke the moment the window moved or Casey
# swapped monitors. Instead the caller locates the target by COLOUR in the
# returned image and converts using the reported origin.
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Meta = "",
    [string]$WindowTitle = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Cap {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, R2, B; }
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
}
"@

$x = 0; $y = 0; $w = 0; $h = 0

# Prefer matching on process name over window title. Roblox Studio renames its
# title bar depending on state -- "Place1 - Roblox Studio" while editing,
# "RobloxStudio" once maximized -- and a title filter silently stops matching.
$procName = $env:SW_PROCESS
if ($procName) {
    $p = Get-Process -Name $procName -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { Write-Output "PROCESS NOT FOUND: $procName"; exit 1 }
} elseif ($WindowTitle -ne "") {
    $p = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$WindowTitle*" } | Select-Object -First 1
    if (-not $p) { Write-Output "WINDOW NOT FOUND: $WindowTitle"; exit 1 }
}

if ($p) {
    $hwnd = $p.MainWindowHandle
    $r = New-Object Cap+R
    $pt = New-Object Cap+P
    [Cap]::GetClientRect($hwnd, [ref]$r) | Out-Null
    [Cap]::ClientToScreen($hwnd, [ref]$pt) | Out-Null
    $x = $pt.X; $y = $pt.Y
    $w = $r.R2 - $r.L; $h = $r.B - $r.T
}

if ($w -gt 0) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
} else {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x = $b.X; $y = $b.Y; $w = $b.Width; $h = $b.Height
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $b.Size)
}

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

if ($Meta -ne "") {
    $obj = [ordered]@{ originX = $x; originY = $y; width = $w; height = $h }
    $obj | ConvertTo-Json | Set-Content -Path $Meta -Encoding UTF8
}
Write-Output "saved $Out origin=$x,$y size=${w}x${h}"