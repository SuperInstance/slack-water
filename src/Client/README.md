# Client HUD panels

Everything in `src/Client/` is rendering. No panel computes a value, price,
scarcity or yield — each one lays out numbers the server already sent (house
rule 2). The one deliberate exception is the tide curve in `TideStrip`, which
calls the pure functions in `src/Shared/Tide.luau` for **display only**; the
server stays the sole authority on time.

## Files

| File | What it is |
| --- | --- |
| `Ui.luau` | Shared construction kit: typed instance builders, theme, meters/chips/sheets, connection tracking, wire-payload normalization (`normalizeRegions`/`normalizeMarketEntries`), and the `GameClock` extrapolator. A ModuleScript required by all panels via `script.Parent.Ui`; its top level stays pure so it loads under the standalone interpreter and is unit-tested by `tests/client-tests.luau`. |
| `HUD.client.luau` | Persistent top-left readout: region, tide phase (`Tide.phaseName`), calendar (`month`/`day` from OceanSync), session running total (sum of CastResult values). Also the system's connection status: `no ocean` when no sync ever lands, `lost the ocean` when syncs stop, and a SHARED OCEAN / LOCAL WATER tag from `OceanSync.shared`. |
| `TideStrip.client.luau` | The tide for the next ~12 game hours: 42-bar curve, gold slack stretches, "now" marker, next slack window with a real-time countdown, next HW/LW. Anchored on the server's own `tide.hour`, never a client-side conversion. |
| `CatchCard.client.luau` | The cast result: species, weight, value, and the four flags with distinct treatments — `inRun`/`rare` celebrate (gold), `contested` warns (amber), `depleted` is a quiet gut-punch (red banner + recovery note, never a bare number). Tap to dismiss. |
| `MarketPanel.client.luau` | MarketSync list, sorted by price. `RISING ▲` rows get a gold edge; scarce species (Shared `Market.isScarce` on server-sent numbers) get a red SCARCE chip. That callout *is* the player's routing decision. Switches to an out-of-date state if the feed stops. |
| `RegionChart.client.luau` | OceanSync grounds list, sorted richest-first: name, habitat (colour-stable across the UI), charted depth, what is present, and an abundance bar colour-coded against `Config.COLLAPSE_THRESHOLD`. Below-threshold grounds read `PICKED OVER`; any contested species flags `⚔ CONTESTED`; grounds the tide has cut off dim and read `WAIT FOR TIDE`; unsurveyed grounds carry a `~` suffix and the subtitle shows the server's `% of chart surveyed`. |
| `Notify.client.luau` | Toasts from Notify payloads (kinds: run/scarcity/contest/market/discover, each with its own icon+colour), plus RegionDiscovered mapped to a `discover` toast. Max 4 stacked, auto-dismiss. |
| `GearBar.client.luau` | The skipper's career sheet: level, xp bar and the gear ladder from ProfileSync (server-computed, sent to this player only). Owned gear rows send a `GearRequest` and re-render whatever the server answers; locked rows show the level requirement. Never computes effort or predicts yield. |
| `Casting.client.luau` | The fight minigame's state machine (UI-free: touch/mouse/keyboard input, tension/progress/stamina, the server round trip). Its boot block starts the machine and publishes `PlayerGui.SlackWaterCastBus`, the BindableEvent the other client scripts drive it through — LocalScripts cannot `require` each other, so that named instance is the whole contract (docs/CASTING.md). A resolve the server never answers times out after 12 s instead of sitting in `"waiting"` forever. |
| `CastBar.client.luau` | **The way in** — the cast loop's entry point, owning the bottom edge of the screen. A thumb-scale CAST button, a rig sheet (ground / target / depth; closed grounds say when the tide opens them), the fight readout (tension with the safe band, catch, stamina) while the line is out, and honest failure lines for refused casts, lost fights and dead resolves. Its pure half (selection legality, blind targeting, the tide walk, the double-cast guard, cooldown formatting) is unit- and execution-tested by tests/cast-loop-tests.luau; the selection rules only decide what to OFFER — the server arbitrates every outcome. Contract and failure-path table: docs/CASTING.md. |

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
│                     [💰] [🗺️] [🎣]  │  right edge, y ~40%/58%/76%
│         MarketPanel / RegionChart / │  sheets slide in from the right
│         GearBar (with LV badge)     │
│                                     │
│      CatchCard (transient, modal)   │  centre at 40% height, tap-dismiss
│         + xp line, level-up banner  │
│                                     │
│  CastBar rig sheet (when open)      │  y ~250..720, above the bar
│  ┌───────────────────────────────┐  │
│  │ status / failure line         │  │
│  │ [  CAST  ]  ground · rig ▴   │  │  y 732..832 — the bar. During a
│  └───────────────────────────────┘  │  fight it becomes the readout
└─────────────────────────────────────┘  (tension/catch/stamina meters)
```

Only one sheet can be open at a time. They coordinate through a single
PlayerGui attribute (`SlackWaterOpenPanel`) set in `Ui.makeSheet` — no
cross-script references, so either panel file can change independently.
CastBar's rig sheet joins that channel: opening it clears the attribute
(closing any right-edge sheet), and a right-edge sheet opening closes the
rig sheet. It matches the attribute by string because the name is a local
in `Ui.luau`.

## Progression on the wire

GearBar listens to two remotes that are **not yet in Types.luau** (it is owned
by a separate change): `GearRequest` (client → server, `{ gearId: string }`)
and `ProfileSync` (server → client, this player only). Until they are folded
into the contract, the names are mirrored from `src/Server/Remotes.server.luau`
— keep the two in step. CastResult also grows `level`, `xpGained`,
`unlockedGear` (id list) and `currentGearId` fields; CatchCard renders them
when present, so older payloads still lay out.

## How the client knows "what time is it"

OceanSync (`month`, `day`, `tick`, and the server's own `tide.hour`) arrives
every ~5 s; the tide must move smoothly between syncs. `Ui.GameClock`:

- **anchors on the server's `tide.hour`** — the same number
  `OceanService.harvest` gates casts against. The clock never converts
  `tick` on its own; it once did, at `HOURS_PER_DAY / TICKS_PER_DAY` = 2
  hours per tick while the server advances its hour by 1.0 per tick, and the
  HUD spent its life promising slack water the server had not reached.
- coasts between syncs on `os.clock`;
- **measures** game-hours-per-real-second over a rolling window (default
  1 h per 20 s, matching `OceanService._TICK_INTERVAL`) so countdowns stay
  honest if the server cadence is retuned — and measures the *average*, not
  the step, because the broadcast runs four times per tick;
- unwraps the midnight rollover so coasting stays continuous, and treats an
  hour that jumps backwards (a server restart) as a re-anchor, not motion;
- re-anchors on `tide.hour` every sync, so it can never drift for more than
  one broadcast interval.

All tide rendering is derived from `Ui.clockHour(clock)` and the pure `Tide`
module — nothing feeds back into game state. When syncs stop arriving the
HUD and TideStrip say so explicitly and blank their numbers rather than
animating a dead clock as if it were live.

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
rs.Remotes.ProfileSync:FireClient(plr, {
	level = 5, levelInto = 120, levelNeeded = 906, fraction = 0.13,
	xp = 402, currentGearId = "handline", ownedGear = { "handline" },
})
```

Expect: a gold-bordered CatchCard (run + rare banners, contested warning,
depleted banner, ground bar at 22% with a pale before-tick), a gold 🐟 toast,
and the HUD total +880 on the next card. The ProfileSync fires the 🎣 badge to
`LV 5` and fills the GearBar sheet (one held row, the rest showing their level
gates). A CastResult can also carry `xpGained`/`level`/`unlockedGear` to see
the card's xp line and level-up banner — e.g. add `xpGained = 37` to the
payload above.

The cast loop itself (never yet run in Studio — these are the checks that
matter first, in order):

5. The bottom bar appears: `CAST` (left, large) and a rig summary reading
   `no ground chosen`. Tapping the summary opens RIG THE LINE above the bar;
   the bar and its CAST button stay visible under it.
6. Pick a ground: rows show quality (`78% now`) or `WAIT FOR TIDE` with an
   opening time; the HUD flips to `bound for <ground>`. Pick a target and
   drag the depth slider (snaps to 5 m).
7. Press CAST: the bar swaps to the fight readout (species, TENSION with a
   pale safe band, CATCH, STAMINA). Hold anywhere on the water to reel;
   release to give line. A second press on CAST mid-fight must do nothing
   but say `the line is already out`. `✕ reel in` abandons.
8. On a win: `landed — the shore is weighing it…`, then a CatchCard and the
   bar's `landed · <value>` line. On a server refusal the bar's status line
   carries the reason in red. If the fight is lost, the bar is the only
   surface (`The line parted.` / `You reeled in.`).
9. Phone check (device emulator, 390x844): CAST reachable one-handed; the
   rig sheet's rows and slider work by touch; touches on the fight readout
   still reel (the meters must not sink input — only buttons do).

## Known gaps

- **The cast loop has never been played.** It has an entry point now
  (CastBar, tests, and docs/CASTING.md), and tests/cast-loop-tests.luau
  executes the whole client loop under a fake engine — but nothing has been
  run in Studio. Layout, hit areas and the fight's feel are unproven. The
  server-side breakages behind the loop are fixed as of this writing
  (`Config.CAST_COOLDOWN` exists; `performance` is declared and defaulted in
  Types.luau by the wallet pass).
- **The tide gate cannot bite with current constants.** The shallowest
  species band (pink salmon, 5 m) sits above the worst-case tide (-2.57 m)
  plus draught (1.8 m), so every ground that can host a legal species is
  always accessible — "WAIT FOR TIDE" is display-only until the constants or
  the roster change. See docs/CASTING.md for the arithmetic; the fix belongs
  in src/Shared, not here.
- **Buying gear is not wired.** `Progression.buy` exists and validates level +
  funds, but the server has no wallet/money store to deduct from, so GearBar
  only ever *equips* gear the profile already owns. Locked rows honestly show
  "reached at level N · price X" with no buy button. Wiring the buy needs a
  funds owner first (see `src/Server/README.md`).
- **Default Roblox chrome** (chat top-left, player list top-right, mobile
  jump button bottom-right) can overlap the HUD cluster and the CAST bar
  until the game disables it with `StarterGui:SetCoreGuiEnabled`; that call
  belongs to game bootstrap, not to a panel.
- **`contested` arrives empty** from `broadcastOcean` (the map is always
  `{}`), so GROUNDS never shows `⚔ CONTESTED` from syncs — only the CatchCard
  flag can show it today. Again a server gap, not a panel one.
- **`run` and `market` toasts never fire** — no server code sends those
  Notify kinds (only contest/scarcity from CastService).
- **A late CastResult after an abandoned resolve still shows its card**
  (CatchCard listens to the remote directly; Casting's token ignores the
  stale reply, but the card has no token). Small window, other owner's file.
- Icons are emoji by choice: zero asset dependencies while the layout is
  being proven (the art language is placeholder project-wide, see the root
  README).
