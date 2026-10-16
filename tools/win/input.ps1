# Drive the Windows desktop: move, click, type, send keys.
#
# Paired with shot.ps1 this gives the agent eyes and hands on Roblox Studio.
# Uses SendInput rather than UI Automation because Studio is a Qt app and its
# accessibility tree is unreliable — but SendInput goes through the OS input
# stack, so it does not care what framework drew the button.
#
# usage:
#   input.ps1 move <x> <y>
#   input.ps1 click [left|right|double]
#   input.ps1 key <name>            e.g. F5, enter, escape, space, tab, ctrl+shift+p
#   input.ps1 type <text>
#   input.ps1 focus "<window title substring>"
#   input.ps1 windows
#   input.ps1 drag <x1> <y1> <x2> <y2>

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Input {
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int size);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out System.Drawing.Point p);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004, KEYEVENTF_EXTENDEDKEY = 0x0001;

    static void Send(INPUT[] inputs) { SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))); }

    public static void MoveTo(int x, int y) { SetCursorPos(x, y); }

    public static void Click(string which) {
        uint down, up;
        if (which == "right") { down = MOUSEEVENTF_RIGHTDOWN; up = MOUSEEVENTF_RIGHTUP; }
        else { down = MOUSEEVENTF_LEFTDOWN; up = MOUSEEVENTF_LEFTUP; }
        Send(new INPUT[] {
            new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = down } } },
            new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = up } } }
        });
    }

    public static void Drag(int x1, int y1, int x2, int y2) {
        MoveTo(x1, y1);
        Send(new INPUT[] { new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_LEFTDOWN } } } });
        int steps = 24;
        for (int i = 1; i <= steps; i++) {
            MoveTo(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps);
            System.Threading.Thread.Sleep(12);
        }
        Send(new INPUT[] { new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_LEFTUP } } } });
    }

    public static void KeyDown(ushort vk, bool up, bool extended) {
        var k = new KEYBDINPUT { wVk = vk, wScan = 0, dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (extended ? KEYEVENTF_EXTENDEDKEY : 0) };
        Send(new INPUT[] { new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = k } } });
    }

    public static void TypeText(string s) {
        foreach (char c in s) {
            if (c == '\n') { KeyDown(0x0D, false, false); KeyDown(0x0D, true, false); continue; }
            var d = new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wScan = (ushort)c, dwFlags = KEYEVENTF_UNICODE } } };
            var u = new INPUT { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wScan = (ushort)c, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } } };
            Send(new INPUT[] { d, u });
            System.Threading.Thread.Sleep(8);
        }
    }

    public static IntPtr FindByTitle(string frag) {
        foreach (var p in System.Diagnostics.Process.GetProcesses()) {
            if (p.MainWindowHandle != IntPtr.Zero && p.MainWindowTitle.Contains(frag)) return p.MainWindowHandle;
        }
        return IntPtr.Zero;
    }

    // Convert CLIENT-relative coords to screen coords, move, and click.
    // Needed because a window capture starts at the client origin, so image
    // coordinates are offset from screen coordinates by the window position.
    public static void ClickWin(IntPtr h, int cx, int cy, string which) {
        RECT c; POINT p;
        GetClientRect(h, out c);
        ClientToScreen(h, ref p);
        MoveTo(p.X + cx, p.Y + cy);
        System.Threading.Thread.Sleep(150);
        Click(which);
    }

    public static void Focus(IntPtr h) {
        // Windows FOREGROUND LOCK: a background process cannot simply call
        // SetForegroundWindow; the call is silently refused. The documented
        // bypass is to synthesise an ALT press first, which grants the
        // process temporary foreground rights. Without this the click is
        // delivered to whatever window already had focus.
        ShowWindow(h, 9);            // SW_RESTORE
        KeyDown(0x12, false, false); // ALT down
        KeyDown(0x12, true, false);  // ALT up
        SetForegroundWindow(h);
        System.Threading.Thread.Sleep(400);
    }

    public static void ClickSlow(string which) {
        uint down = which == "right" ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
        uint up   = which == "right" ? MOUSEEVENTF_RIGHTUP   : MOUSEEVENTF_LEFTUP;
        Send(new INPUT[] { new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = down } } } });
        System.Threading.Thread.Sleep(80);
        Send(new INPUT[] { new INPUT { type = INPUT_MOUSE, u = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = up } } } });
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

$cmd = $args[0]
switch ($cmd) {
    "move"    { [Input]::MoveTo([int]$args[1], [int]$args[2]); Write-Output "moved to $($args[1]),$($args[2])" }
    "click"   {
        $which = if ($args.Count -gt 1) { $args[1] } else { "left" }
        [Input]::MoveTo([int]$args[2], [int]$args[3]) 2>$null
        if ($args.Count -ge 4) { Start-Sleep -Milliseconds 120 }
        if ($which -eq "double") { [Input]::Click("left"); Start-Sleep -Milliseconds 60; [Input]::Click("left") }
        else { [Input]::Click($which) }
        Write-Output "clicked $which"
    }
    "clickat" { [Input]::MoveTo([int]$args[1], [int]$args[2]); Start-Sleep -Milliseconds 120; [Input]::Click($(if ($args.Count -gt 3) { $args[3] } else { "left" })); Write-Output "clicked at $($args[1]),$($args[2])" }
    "drag"    { [Input]::Drag([int]$args[1], [int]$args[2], [int]$args[3], [int]$args[4]); Write-Output "dragged" }
    "type"    { [Input]::TypeText($args[1]); Write-Output "typed" }
    "clickwin" {
        # clickwin <title> <cx> <cy> [which]  -- cx/cy relative to the window's client area
        $h = [Input]::FindByTitle($args[1])
        if ($h -eq [IntPtr]::Zero) { Write-Output "NOT FOUND: $($args[1])"; exit 1 }
        [Input]::Focus($h)
        Start-Sleep -Milliseconds 400
        $w = if ($args.Count -gt 4) { $args[4] } else { "left" }
        [Input]::ClickWin($h, [int]$args[2], [int]$args[3], $w)
        Start-Sleep -Milliseconds 250
        [Input]::ClickSlow($w)
        Write-Output "clicked '$w' at client $($args[2]),$($args[3]) of '$($args[1])'"
    }
    "focus"   { $h = [Input]::FindByTitle($args[1]); if ($h -eq [IntPtr]::Zero) { Write-Output "NOT FOUND: $($args[1])" } else { [Input]::Focus($h); Write-Output "focused" } }
    "windows" { Get-Process | Where-Object { $_.MainWindowTitle -ne "" } | ForEach-Object { "$($_.ProcessName)`t$($_.MainWindowTitle)" } }
    "key"     {
        # comma-separated chord, e.g. ctrl+shift+p  |  named keys
        $map = @{
            "enter"=0x0D; "tab"=0x09; "escape"=0x1B; "esc"=0x1B; "space"=0x20;
            "backspace"=0x08; "delete"=0x2E; "home"=0x24; "end"=0x23;
            "up"=0x26; "down"=0x28; "left"=0x25; "right"=0x27;
            "f1"=0x70; "f2"=0x71; "f3"=0x72; "f4"=0x73; "f5"=0x74; "f6"=0x75;
            "f7"=0x76; "f8"=0x77; "f9"=0x78; "f10"=0x79; "f11"=0x7A; "f12"=0x7B;
            "ctrl"=0x11; "shift"=0x10; "alt"=0x12; "win"=0x5B
        }
        $parts = $args[1] -split "\+"
        $vks = @()
        foreach ($p in $parts) {
            $p = $p.Trim().ToLower()
            if ($map.ContainsKey($p)) { $vks += [int]$map[$p] }
            elseif ($p.Length -eq 1) { $vks += [int][char]$p.ToUpper() }
            else { Write-Output "unknown key: $p"; exit 1 }
        }
        foreach ($v in $vks) { [Input]::KeyDown([ushort]$v, $false, $false) }
        Start-Sleep -Milliseconds 40
        for ($i = $vks.Count - 1; $i -ge 0; $i--) { [Input]::KeyDown([ushort]$vks[$i], $true, $false) }
        Write-Output "sent $($args[1])"
    }
    default { Write-Output "unknown command: $cmd" }
}