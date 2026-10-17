# Drive Roblox Studio's Command Bar through UI Automation.
#
# Synthetic clicks do not activate Studio controls (see docs/STUDIO-AUTOMATION.md),
# and the Command Bar has no keyboard shortcut that focuses it -- Ctrl+Down opens
# the history dropdown instead. UIA can set an edit control's value directly and
# invoke its button, so this bypasses both problems.
#
# Reads the command from $env:SW_TEXT. Writes diagnostics to stdout.

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

$cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
)

$windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)

$studio = $null
foreach ($w in $windows) {
    if ($w.Current.Name -like "*Roblox*") { $studio = $w; break }
}

if (-not $studio) {
    Write-Output "UIA: no Roblox window found"
    exit 1
}

Write-Output "UIA: window '$($studio.Current.Name)'"

# Walk descendants once and report what we can actually see. Whether this
# returns anything useful is the whole question: Studio is Qt/QML, and Qt only
# exposes controls through its Windows accessibility bridge.
$all = $studio.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
)

Write-Output "UIA: $($all.Count) descendants"

$edits = 0
foreach ($e in $all) {
    $t = $e.Current.ControlType.ProgrammaticName
    if ($t -eq "ControlType.Edit") {
        $edits++
        if ($edits -le 5) {
            Write-Output ("UIA: Edit  name='" + $e.Current.Name + "' class='" + $e.Current.ClassName + "'")
        }
    }
}

Write-Output "UIA: $edits Edit controls"

$command = $env:SW_TEXT
if (-not $command) {
    Write-Output "SW_TEXT not set; probe only"
    exit 0
}

# Locate the command bar: the only Edit that starts empty and sits at the very
# bottom of the window. Match on position rather than name, because it has no
# stable accessible name.
$bottom = $studio.Current.BoundingRectangle.Bottom
$best = $null
$bestScore = -1

foreach ($e in $all) {
    if ($e.Current.ControlType.ProgrammaticName -ne "ControlType.Edit") { continue }
    $r = $e.Current.BoundingRectangle
    if ($r.Height -le 0) { continue }
    # prefer low on the window and wide
    $score = [int](($r.Bottom - $bottom)) + [int]($r.Width / 10)
    if ($score -gt $bestScore) { $bestScore = $score; $best = $e }
}

if (-not $best) {
    Write-Output "UIA: could not find the command bar edit"
    exit 1
}

Write-Output ("UIA: using Edit name='" + $best.Current.Name + "' rect=" + $best.Current.BoundingRectangle.ToString())

$vp = $best.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$vp.SetValue($command)
Start-Sleep -Milliseconds 400
Write-Output ("UIA: set value to '" + $vp.Current.Value + "'")

# Invoke the Run button (bottom right).
$buttonCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button
)
$buttons = $all.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCond)

foreach ($b in $buttons) {
    if ($b.Current.Name -eq "Run") {
        try {
            $ip = $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $ip.Invoke()
            Write-Output "UIA: invoked Run"
            exit 0
        } catch {
            Write-Output ("UIA: Run not invokable -- " + $_.Exception.Message)
        }
    }
}

Write-Output "UIA: no invokable Run button; press Enter instead"
$best.SetFocus()
Start-Sleep -Milliseconds 200
exit 2