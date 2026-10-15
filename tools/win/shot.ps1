# Screenshot the Windows desktop.
#
# Lets the agent see Roblox Studio (and the running game) without the owner
# having to describe what is on screen or manually attach images. This is the
# substitute for a real Studio MCP connection, which has not been reachable.
#
# usage: shot.ps1 <outfile.png> [windowTitleFilter]
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$WindowTitle = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

if ($WindowTitle -ne "") {
    $procs = Get-Process | Where-Object { $_.MainWindowTitle -like "*$WindowTitle*" }
    if ($procs) {
        $h = $procs[0].MainWindowHandle
        [Win]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
        [Win]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 700
        $c = New-Object Win+RECT
        [Win]::GetClientRect($h, [ref]$c) | Out-Null
        $p = New-Object Win+POINT
        [Win]::ClientToScreen($h, [ref]$p) | Out-Null
        $x = $p.X; $y = $p.Y
        $w = $c.R - $c.L; $ht = $c.B - $c.T
    }
}

if ($WindowTitle -ne "" -and $w -gt 0) {
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
} else {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
}

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved $Out"