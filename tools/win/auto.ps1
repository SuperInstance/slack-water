param(
    [string]$WindowTitle = "",
    [int]$X = 0,
    [int]$Y = 0,
    [string]$Action = "click"   # click | key | keyshift | postclick | move
)
$ErrorActionPreference = "Stop"

# The P/Invoke lives in Auto.cs, NOT a here-string. Embedding C# in a PowerShell
# here-string inside a bash-quoted powershell.exe -Command call compounds two
# layers of quoting and the compile fails with a bare SOURCE_CODE_ERROR that
# hides the real message. A separate .cs file has no quoting to get wrong.
$csPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Auto.cs"
Add-Type -Path $csPath -ReferencedAssemblies System.Drawing

function Get-Win([string]$frag) {
    # Roblox Studio renames its title bar between states ("Place1 - Roblox
    # Studio" while editing, "RobloxStudio" maximized), so a title match is not
    # something to trust. Set SW_PROCESS to match on process name instead.
    if ($env:SW_PROCESS) {
        $q = Get-Process -Name $env:SW_PROCESS -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($q) { return $q.MainWindowHandle }
    }
    $p = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$frag*" } | Select-Object -First 1
    if ($p) { return $p.MainWindowHandle } else { return [IntPtr]::Zero }
}

$h = Get-Win $WindowTitle
if ($h -eq [IntPtr]::Zero) { Write-Output "WINDOW NOT FOUND: $WindowTitle"; exit 1 }

$r = New-Object Auto+R
$p = New-Object Auto+P
[Auto]::GetClientRect($h, [ref]$r) | Out-Null
[Auto]::ClientToScreen($h, [ref]$p) | Out-Null
$w = $r.Ri - $r.L; $ht = $r.B - $r.T
Write-Output "window client: origin=$($p.X),$($p.Y) size=${w}x${ht}"

[Auto]::ForceFocus($h)

$fg = [Auto]::GetForegroundWindow()
Write-Output "foreground handle: $fg (target $h)"

switch ($Action) {
    "click" {
        $sx = $p.X + $X; $sy = $p.Y + $Y
        [Auto]::ClickAt($sx, $sy)
        $cur = New-Object System.Drawing.Point
        [Auto]::GetCursorPos([ref]$cur) | Out-Null
        Write-Output "clicked at screen $sx,$sy (cursor now $($cur.X),$($cur.Y))"
    }
    "move" {
        $sx = $p.X + $X; $sy = $p.Y + $Y
        [Auto]::SetCursorPos($sx, $sy) | Out-Null
        Write-Output "moved to screen $sx,$sy"
    }
    "key" {
        [Auto]::Tap([uint16]$X)
        Write-Output "sent key $X"
    }
    "keyshift" {
        [Auto]::TapShifted([uint16]$X)
        Write-Output "sent Shift+key $X"
    }
    "postclick" {
        # client coords straight into the window, no cursor involved
        [Auto]::PostClick($h, $X, $Y)
        Write-Output "posted click at client $X,$Y"
    }
    "tapn" {
        # X = virtual key, Y = repeat count
        [Auto]::TapN([uint16]$X, $Y, 40)
        Write-Output "tapped key $X x$Y"
    }
    "hold" {
        # X = virtual key, Y = milliseconds
        [Auto]::Hold([uint16]$X, $Y)
        Write-Output "held key $X for ${Y}ms"
    }
}