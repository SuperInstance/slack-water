# Client HUD panels

Everything in `src/Client/` is rendering. No panel computes a value, price,
scarcity or yield — each one lays out numbers the server already sent (house
rule 2). The one deliberate exception is the tide curve in `TideStrip`, which
calls the pure functions in `src/Shared/Tide.luau` for **display only**; the
server stays the sole authority on time.

## Files

| File | What it is |
| --- | --- |
| `Ui.luau` | Shared construction kit: typed instance builders, theme, meters/chips/sheets, connection tracking, and the `GameClock` extrapolator. A ModuleScript required by all panels via `script.Parent.Ui`. |
| `HUD.client.luau` | Persistent top-left readout: region, tide phase (`Tide.phaseName`), calendar (`month`/`day` from OceanSync), session running total (sum of CastResult values). |
| `TideStrip.client.luau` | The tide for the next ~12 game hours: 42-bar curve, gold slack stretches, "now" marker, next slack window with a real-time countdown, next HW/LW. |
| `CatchCard.client.luau` | The cast result: species, weight, value, and the four flags with distinct treatments — `inRun`/`rare` celebrate (gold), `contested` warns (amber), `depleted` is a quiet gut-punch (red banner + recovery note, never a bare number). Tap to dismiss. |
| `MarketPanel.client.luau` | MarketSync list, sorted by price. `RISING ▲` rows get a gold edge; scarce species (Shared `Market.isScarce` on server-sent numbers) get a red SCARCE chip. That callout *is* the player's routing decision. |
| `RegionChart.client.luau` | OceanSync grounds list, sorted richest-first: name, habitat (colour-stable across the UI), charted depth, what is present, and an abundance bar colour-coded against `Config.COLLAPSE_THRESHOLD`. Below-threshold grounds read `PICKED OVER`; any contested species flags `⚔ CONTESTED`. |
| `Notify.client.luau` | Toasts from Notify payloads (kinds: run/scarcity/contest/market/discover, each with its own icon+colour), plus RegionDiscovered mapped to a `discover` toast. Max 4 stacked, auto-dismiss. |
| `Casting.client.luau` | **Owned by another agent — do not edit here.** It is the fight minigame's state machine and creates no UI, so it neither collides with nor is referenced by these panels. |

## Layout (designed at 390x844, scaled everywhere else)

Every panel mounts its own ScreenGui in PlayerGui (`ResetOnSpawn = false`),
a full-screen transparent root, and one `UIScale` (`Ui.autoScale`) clamped to
0.75–1.5 against a 390x720 logical viewport. All offsets below are logical px.

```
┌─────────────────────────────────────┐
│ HUD  region · tide phase · date     │  y 12..92    left 300px
│ TideStrip  curve | SLACK 0:42       │  y 100..196  full width
│            (water — keep clear)     │
│ Notify toasts (transient)           │  from y 204, centred, auto-dismiss
│                                     │
│                     [💰] [🗺️]       │  right edge, y ~40%/58%
│         MarketPanel / RegionChart   │  sheets slide in from the right
│                                     │
│      CatchCard (transient, modal)   │  centre at 40% height, tap-dismiss
│                                     │
│  (bottom edge left free for the     │
│   casting controls, owned elsewhere)│
└─────────────────────────────────────┘
```

Only one sheet can be open at a time. They coordinate through a single
PlayerGui attribute (`SlackWaterOpenPanel`) set in `Ui.makeSheet` — no
cross-script references, so either panel file can change independently.

## How the client knows "what time is it"

OceanSync (`month`, `day`, `tick`) arrives every ~5 s; the tide must move
smoothly between syncs. `Ui.GameClock`:

- converts `tick` to absolute game hours via
  `Config.HOURS_PER_DAY / Config.TICKS_PER_DAY` (currently 2 h per tick),
- coasts between syncs on `os.clock`,
- **measures** real-seconds-per-tick from consecutive syncs (default 20 s,
  matching `OceanService._TICK_INTERVAL`) so countdowns stay honest if the
  server cadence is retuned, and re-anchors if the server restarts
  (tick goes backwards).

All tide rendering is derived from `Ui.clockHour(clock)` and the pure `Tide`
module — nothing feeds back into game state.

## Verifying in Studio

```bash
rojo serve default.project.json   # WSL side
# Studio → Plugins → Rojo → Connect → Play
```

Passive checks (no input needed — the server broadcasts every 5 s):

1. First frames: HUD shows a breathing `Reading the chart`, TideStrip shows
   `reading the chart…`, both panels' toggles are present. No red errors.
2. ≤ 5 s: HUD fills in (region `no ground chosen` until a first cast, tide
   phase, `Jan · day 1/4`); the tide curve animates, gold slack stretches
   drift right-to-left, the slack countdown ticks in real seconds.
3. `💰` opens MARKET (17 rows, sorted by price); `🗺️` opens GROUNDS (14 rows,
   richest first, coloured abundance bars); opening one closes the other.
4. Resize the viewport (Studio device emulator, 390x844 phone): nothing
   overlaps the screen centre; the HUD scales cleanly.

Active checks — paste into the **command bar while playing** (it runs server
context, so this fires the real remotes to the real client):

```lua
local rs = game:GetService("ReplicatedStorage")
local plr = game:GetService("Players"):GetPlayers()[1]
rs.Remotes.CastResult:FireClient(plr, {
	ok = true, speciesId = "chinook", regionId = "<an id from OceanSync>",
	yielded = 40, remaining = 300, abundanceBefore = 0.8, abundanceAfter = 0.22,
	depleted = true, contested = true, weightKg = 21.4, value = 880,
	rare = true, inRun = true,
})
rs.Remotes.Notify:FireClient(plr, {
	kind = "run", text = "Chinook are running at North Midchannel.",
	speciesId = "chinook",
})
```

Expect: a gold-bordered CatchCard (run + rare banners, contested warning,
depleted banner, ground bar at 22% with a pale before-tick), a gold 🐟 toast,
and the HUD total +880 on the next card.

## Known gaps

- **Default Roblox chrome** (chat top-left, player list top-right) can overlap
  the HUD cluster until the game disables it with
  `StarterGui:SetCoreGuiEnabled`; that call belongs to game bootstrap, not to
  a panel.
- **`day` is currently static on the server** — `OceanService` ticks but never
  calls `OceanSim.advanceDay`, so the HUD date stays at `day 1/4` on a fresh
  server. The HUD renders what it is sent; the fix belongs server-side.
- **`contested` arrives empty** from `broadcastOcean` (the map is always
  `{}`), so GROUNDS never shows `⚔ CONTESTED` from syncs — only the CatchCard
  flag can show it today. Again a server gap, not a panel one.
- Icons are emoji by choice: zero asset dependencies while the layout is
  being proven (the art language is placeholder project-wide, see the root
  README).
