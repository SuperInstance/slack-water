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
Add-Type -TypeDefinition $src

$frag = $env:SW_TARGET
if (-not $frag) { $frag = "Roblox Studio" }

$p = Get-Process |
    Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$frag*" } |
    Select-Object -First 1

if (-not $p) { Write-Output "WINDOW NOT FOUND: $frag"; exit 1 }

$h = $p.MainWindowHandle
[Max]::ShowWindow($h, 3) | Out-Null          # SW_MAXIMIZE
Start-Sleep -Milliseconds 900
[Max]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300
Write-Output "maximized pid $($p.Id) hwnd $h"
exit 0