# Maximize the Roblox Studio window.
#
# This deliberately has NO param() block. Adding one broke parsing in this
# PowerShell build: a param block with a defaulted parameter followed by a
# second parameter reports "Missing ')' in function parameter list" at the end
# of the first line. It is not the [switch] type specifically -- [int]$M = 0
# fails the same way, while a lone [switch]$M parses fine. Rather than keep
# bisecting a PowerShell parser quirk in a helper script, the flags are read
# from $env instead.
#
# Maximizing matters for automation: Studio restores its window to a different
# screen and size when a play session ends, which silently invalidates any
# button coordinate captured earlier. A maximized window on one display has a
# stable client rect that stays fully capturable.

Add-Type -AssemblyName System.Windows.Forms

$src = @"
using System;
using System.Runtime.InteropServices;
public class Max {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
}
"@
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Max {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R2, B; }
}
"@

$frag = $env:SW_TARGET
if (-not $frag) { $frag = "Roblox Studio" }

$p = Get-Process |
    Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$frag*" } |
    Select-Object -First 1

if (-not $p) { Write-Output "WINDOW NOT FOUND: $frag"; exit 1 }

$h = $p.MainWindowHandle

# Park it on the primary display BEFORE maximizing. The secondary display is
# 1120x700, and Studio's client alone is 1281x672, so a maximized Studio there
# is narrower than it wants to be and -- worse -- at y=145 the bottom of the
# window falls off a 768-tall screen entirely, taking the CAST bar with it.
# Casey reported the game "isn't there"; it was rendering below the bezel.
[Max]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1366, 720, 0x0040) | Out-Null
Start-Sleep -Milliseconds 400

[Max]::ShowWindow($h, 3) | Out-Null          # SW_MAXIMIZE
Start-Sleep -Milliseconds 900
[Max]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300

$w = New-Object Max+R
[Max]::GetWindowRect($h, [ref]$w) | Out-Null
Write-Output "maximized pid $($p.Id) hwnd $h rect=$($w.L),$($w.T) $($w.R2 - $w.L)x$($w.B - $w.T)"
exit 0