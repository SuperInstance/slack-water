# Driving Roblox Studio from the shell

Casey's machine runs Studio in a normal (medium integrity) Windows session that
WSL can reach over `powershell.exe`. This file records what actually works for
starting and stopping a play session, and what does not, so nobody spends
another afternoon rediscovering it.

Verified on 2026-10-15 against Studio 0.743.0.7431133.

## What works

**Keyboard does. Clicking does not.**

```
auto.ps1 -Action key      -X 116    # F5       -> Play
auto.ps1 -Action keyshift -X 116    # Shift+F5 -> Stop
auto.ps1 -Action tapn     -X 40  -Y 12      # repeat a key (arrow keys steer the camera)
auto.ps1 -Action hold     -X 87  -Y 1200    # hold W to walk
```

`Shift+F5` then `F5` is a complete restart loop. That is how the four boot
showstoppers in commit `45c4891` were finally confirmed in a real Roblox
runtime rather than only in the harness.

**Screenshots are the instrument.** `capture.ps1` writes a PNG of the Studio
client area and, with `-Meta`, the screen-space origin so image coordinates can
be converted. `crop.py` crops and nearest-neighbour zooms a region using only
the standard library (there is no PIL and no numpy on this machine), which is
how the toolbar and the 3D chart labels get read at 1:1 instead of guessed at.

**Match windows by process name, not title.** Studio renames its title bar
depending on state — `Place1 - Roblox Studio` while editing, `RobloxStudio` once
maximized. A title filter silently stops matching. Set `SW_PROCESS` and both
`capture.ps1` and `auto.ps1` will key off `RobloxStudioBeta` instead.

## What does not work, and why

Synthetic clicks never activated a Studio control. Both mechanisms were tried:

- `SetCursorPos` + `SendInput` LEFTDOWN/LEFTUP. The cursor moves and the click
  is delivered, but no button responds.
- `PostMessage` of WM_MOUSEMOVE / WM_LBUTTONDOWN / WM_LBUTTONUP straight to the
  window with client coordinates. Same result.

The obvious explanation was UIPI: a medium-integrity process cannot inject into
a window owned by a more privileged one. **That explanation is wrong here.**
Reading `TokenIntegrityLevel` for every relevant process returns
`S-1-16-8192`, RID 8192 — medium integrity — for the shell, `explorer`, the
player, and both Studio processes. Nothing is elevated, so UIPI is not
blocking anything.

The remaining explanation is that Studio's ribbon is QML, and QML does not
reliably consume posted Win32 mouse messages or synthetic cursor events. The
keyboard path works because QML handles real keyboard input normally. So:
use the keyboard, and use screenshots to *see* rather than to *click*.

`tools/win/toolbar.py` was deleted for this reason. It located buttons by
colour and clicked them, and its whole premise is contradicted by the evidence
above. Locating by colour (`find_button.py`) is still useful for reading the
toolbar state; acting on that reading is not.

## Two bugs this found

Neither was in a test suite. Both were visible only in a screenshot of a real
session.

**The default Baseplate was drawing over the sea.** Every new Roblox place
ships a 512x20x512 grey `Baseplate` at y = 0, which is exactly where the tide
sits, so the ocean rendered as a checkered floor and the water was invisible.
Nothing in `src/` referenced it. `WorldGenService.build()` now removes it,
identified by size and position rather than by name alone, and the boot harness
plants one before booting so the assertion has teeth.

**Region labels were wall-sized.** `BillboardGui.Size` offsets are in **studs**,
not pixels. At `UDim2.fromOffset(220, 60)` each label was over three times
wider than `REGION_SPACING` and swallowed the viewport. It is now 34x10 studs.

## A PowerShell quirk, honestly

`tools/win/maximize.ps1` takes no `param()` block. Adding one broke parsing in
this PowerShell build: a param block containing a defaulted parameter followed
by a second parameter reports `Missing ')' in function parameter list` at the
end of the *first* line. It is not the `[switch]` type specifically — a block
of `[int]$M = 0` then `[string]$A = "x"` fails the same way, while a lone
`[switch]$M` parses fine, and the pre-existing four-parameter `auto.ps1`
parses fine. `ParseInput` accepts the same text that `ParseFile` rejects.

This was isolated far enough to stop guessing and work around, and no further.
It is recorded rather than fixed because the actual cause is not known, and a
plausible-sounding explanation would be worse than saying so.

## Still needs Casey

- Publishing the place, so there is a URL and the game is playable outside
  Studio. This needs the Studio UI.
- A `MeshId` for the Eileen FBX, if the Part hull is ever to be replaced by
  the lofted mesh.