# PLAYLOOP — the loop traced end to end, and where it breaks

Written 2026-10-14 by the client-audit pass. **Verification level: static
trace.** Every remote name and payload field below was read on both sides of
the wire in this tree. Nothing here was verified in Studio — the audit ran on
the Luau CLI only, and no playthrough has ever happened. Where a runtime
harness (tests/boot-tests.luau, added concurrently by another agent)
independently confirms a finding, that is noted.

The intended loop: aim → cast → the `Casting` minigame runs → a fish is
resolved server-side against the shared ocean → a catch card appears → you
keep or sell it → the market price moves because scarcity changed.

**Bottom line: the loop is dead at step one.** There is no cast button, no
aim UI, and nothing that starts the minigame. Steps 2–3 are additionally
broken server-side (`Config.CAST_COOLDOWN` does not exist, so the first real
cast would throw). Steps 4 (keep/sell) does not exist at all. Steps 5–7
work mechanically, with client-side display defects around them that this
pass fixed.

---

## The trace

### 1. Player presses cast — DEAD

- `src/Client/Casting.client.luau` is the fight state machine. Rojo maps it
  as a **LocalScript** (`.client.luau` under `src/Client` →
  `StarterPlayerScripts`). It defines the module, `return`s, and stops.
- `Casting.start()` — which binds input and creates the state — is **never
  called by anything**. Grep for `Casting` outside its own file: zero hits.
  As a LocalScript it cannot be required; no panel references it
  (src/Client/README.md says so explicitly).
- Even if it started, `beginFight(regionId, speciesId, depth)` needs a caller
  that knows which ground and species the player chose. No such UI exists:
  there is no region picker, no species picker, no depth slider, no cast
  button anywhere in `src/Client`.
- Player experience: you stand on the boat. Holding/tapping does nothing.
  The HUD, tide strip, market and grounds panels all work; the game's core
  verb is absent.

### 2. Server receives a cast and resolves — BROKEN (server)

Wire (would be): client fires `Remotes.CastRequest` with
`{ regionId: string, speciesId: string, effort: number, depth: number }`
(plus `performance: number`, which `Casting` sends but
`Types.CastRequestPayload` does not declare). Server handler:
`src/Server/CastService.luau:78`.

- `src/Server/CastService.luau:40` — `now - last < Config.CAST_COOLDOWN`
  compares against **a constant that does not exist** in
  `src/Shared/Config.luau`. The first cast of any player throws
  `attempt to compare number < nil` inside `OnServerEvent`; no `CastResult`
  is ever sent. Confirmed at runtime by tests/boot-tests.luau
  ("no background task or event handler ever errored … CastService.luau:40").
  (src/Server/README.md:82 already admits this; it is still true.)
- `src/Server/CastService.luau:205` — `math.clamp(payload.performance, 0, 1)`
  is unguarded and undeclared in the contract. A client that sends exactly
  the documented `CastRequestPayload` (no `performance`) crashes the handler.
- Rate-limited casts are dropped silently (`return` with no `CastResult`,
  CastService.luau:86), and `Casting._resolveOnServer`
  (Casting.client.luau:451-469) waits on `CastResult` with no timeout — the
  state machine would sit in `"waiting"` forever.
- If the handler did run: `OceanService.harvest` (OceanService.luau:266)
  gates on `Tide.accessAt(chartedDepth, svc.hour)`, scales effort by tide
  quality, harvests via `OceanSim.harvest`, queues the reconcile delta, and
  refreshes the market. Failure paths answer with `ok = false` and a prose
  `reason`. This half is sound.

### 3. Client receives the result and shows it — works, hardened by this pass

- `Remotes.CastResult` → `CatchCard.client.luau` renders the card
  (species, weight, value, flags, ground bar, xp line). `HUD.client.luau`
  adds `value` to the session total. Both handlers guard `typeof(payload)`.
- Defects found and fixed client-side this pass: string/NaN fields could
  reach format strings; the region-name map could hold the literal string
  `"nil"`; every card's dismiss connection leaked into the panel tracker.
- `tideQuality` is sent and documented ("lets the UI connect cause and
  effect") but no panel renders it. Cosmetic gap, left as is.

### 4. Keep or sell — DOES NOT EXIST

- `Types.luau` declares no keep/sell/valute remote. The CatchCard's only
  interaction is tap-to-dismiss. There is no wallet server-side
  (src/Server/README.md known gap), so nothing could debit or credit one.
- The "session running total" on the HUD is a client-side sum of
  `CastResult.value` — display only; the server does not track money.
- Player experience: nothing to click, and no consequence to not clicking.

### 5. Market price moves — works

- `OceanService.harvest` → `Service.refreshMarket`
  (OceanService.luau:247) → `Market.updateAll` applies scarcity + inertia →
  `Service.broadcastMarket` (OceanService.luau:457) fires
  `Remotes.MarketSync` with `{ entries = { speciesId, displayName, price,
  baseValue, scarcityMultiplier, globalAbundance, direction } }` to all
  clients every 5 s.
- `MarketPanel.client.luau` renders it sorted by price with RISING/SCARCE
  callouts. Names and types match the server exactly (verified field by
  field). This pass made the handler partial-payload-proof and added an
  out-of-date state.

### 6. Tide update — mechanically works, client display was 2× wrong (fixed)

- Server: `tickOcean` (OceanService.luau:173) advances `svc.hour` by **1.0
  per tick** and `OceanSim.tick` increments `tickCount` by 1 — one tick is
  one game hour. Every `OceanSync` carries the authoritative hour in
  `tide.hour` (OceanService.luau:378-392).
- Client (before this pass): `HUD.client.luau`/`TideStrip.client.luau` built
  the clock with `hoursPerTick = Config.HOURS_PER_DAY / Config.TICKS_PER_DAY`
  = **2** and ignored `tide.hour` entirely. The client's tide ran at twice
  the server's: the HUD could say "high slack" while the server's
  `Tide.accessAt` fails the cast ("the tide has this ground under you"), and
  slack countdowns were half their true length. Fixed: `Ui.GameClock` now
  anchors on the server-sent `tide.hour`, unwraps the midnight rollover,
  measures the real rate over a rolling window, and treats a backwards jump
  as a server restart.

### 7. Region discovery (AI composes a ground) — half works

- `Service.advanceCalendar` (OceanService.luau:197) → `composeNewBanks`
  (OceanService.luau:494): the Worker proposes, `BankSpec.validate`
  arbitrates, admitted regions are added and `Remotes.RegionDiscovered` is
  fired with `{ id, name, habitat, depth, richness, hazard, species = {},
  origin }`. Procedural fallback keeps the treadmill running offline. The
  payload matches `Types.RegionDiscoveredPayload`; `Notify.client.luau`
  renders it as a discover toast, defensively.
- BROKEN (server): the world never learns about new grounds.
  `src/Server/Main.server.luau:73` does
  `svc.remotes[Shared.Types.RegionDiscovered]:Connect(...)` — two errors in
  one line: `Shared.Types` is the ModuleScript *instance* (its
  `.RegionDiscovered` looks up a child that does not exist, so the index is
  nil), and a RemoteEvent has no `:Connect` (it is `.OnServerEvent:Connect`).
  The stage is pcall'd so boot prints `region listener FAILED` and continues.
  Confirmed at runtime by tests/boot-tests.luau ("discovered grounds are
  built into the world … expected 20, got 0"). New grounds appear in the
  GROUNDS list and are castable, but no disc or billboard is ever built —
  invisible water.

---

## Defect list

Ordered by how early they kill the loop. `[fixed]` items were fixed in this
pass and are in `src/Client/**` only; everything else is documented, not
touched (server/shared files are outside this pass's write scope, and
`Casting.client.luau` is marked "owned by another agent — do not edit" in
src/Client/README.md:21).

1. **[NOT FIXED — client, dormant owner] The cast loop has no entry point.**
   `src/Client/Casting.client.luau` — `Casting.start()` is never called by
   any file; nothing picks a region/species/depth; no cast button exists.
   A player cannot fish. Building the aim/fight driver is a feature, not a
   robustness fix, and the README assigns the file to another agent, so this
   pass reports it instead of writing it.
2. **[NOT FIXED — server] `Config.CAST_COOLDOWN` is undefined.**
   `src/Server/CastService.luau:40` compares `number < nil` → the first cast
   from any player throws inside `OnServerEvent`; no result is returned.
   Runtime-confirmed by tests/boot-tests.luau. Fix belongs in
   `src/Shared/Config.luau` (the file is owned by an in-flight change).
3. **[NOT FIXED — server/contract] `performance` is read but not declared
   and not validated.** `src/Server/CastService.luau:205`;
   `Types.CastRequestPayload` (src/Shared/Types.luau:38-43) has no such
   field. A contract-conforming sender crashes the handler with
   `math.clamp(nil, 0, 1)`.
4. **[NOT FIXED — server] The RegionDiscovered world-rebuild listener is
   broken twice over.** `src/Server/Main.server.luau:73` — indexes the
   ModuleScript instance instead of the required table AND calls `:Connect`
   on the RemoteEvent instead of `.OnServerEvent:Connect`. Boot logs
   `region listener FAILED`; runtime-confirmed by tests/boot-tests.luau.
   Discovered grounds are never built into the world.
5. **[NOT FIXED — server] `Environment.apply()` throws mid-function.**
   `src/Server/Environment.luau:52` uses `Lighting.PropertyChangedSignal`,
   which is not a Roblox API (it is `Lighting:GetPropertyChangedSignal("ClockTime")`).
   Everything after line 52 — Atmosphere, Clouds, water colour — never runs,
   and boot logs `environment FAILED`. (In the concurrent boot harness the
   stage fails even earlier on a mock limitation; the API misuse stands
   regardless.)
6. **[fixed] The client tide ran at 2× the server's.** The GameClock
   converted `tickCount` at `HOURS_PER_DAY / TICKS_PER_DAY` = 2 h/tick while
   the server advances 1.0 h/tick, and ignored the authoritative
   `OceanSync.tide.hour`. HUD phase, slack countdowns and the tide strip
   disagreed with the server's actual gating. Fixed in `Ui.GameClock`
   (anchored on `tide.hour`, measured rate, wrap/restart handling) —
   HUD.client.luau, TideStrip.client.luau, Ui.luau.
7. **[fixed] No offline state; stale data read as live.** If OceanSync never
   arrived, the HUD breathed "Reading the chart" forever; if syncs stopped,
   the HUD and tide strip kept coasting on the dead clock as if time still
   passed, and the sheets froze silently. Fixed: explicit "no ocean — server
   not answering" (>30 s cold), "lost the ocean — waiting on the server"
   (>12 s stale, numbers blanked), plus per-sheet out-of-date states with
   watchdogs. HUD, TideStrip, MarketPanel, RegionChart.
8. **[fixed] `formatInt` produced garbage above 1e15.** `Ui.formatInt` used
   `tostring`, which goes scientific ("1e+15") and left the grouping loop
   shredding it into "1e,15". Now `string.format("%d")` with NaN/∞ guards.
   (Unreachable with today's economy numbers; the HUD must still never show
   it.) Ui.luau.
9. **[fixed] Partial payloads could crash remote handlers mid-render.**
   MarketPanel: `Market.isScarce` compared a possibly-nil
   `globalAbundance`, and `%d`/`%.1f` formats received unvalidated fields —
   either kills `rebuild` with rows half-built. HUD: a non-number `day`
   reached `string.format("%d")` every frame. Fixed by normalizing every
   payload through `Ui.normalizeMarketEntries` / `Ui.normalizeRegions` /
   `Ui.tonum` before any field is read. Ui, HUD, MarketPanel, RegionChart,
   CatchCard.
10. **[fixed] A region without a name showed as the literal text "nil".**
    `tostring(region.name)` in HUD/CatchCard name maps. Now the id is the
    fallback. Ui.normalizeRegions.
11. **[fixed] Connection accumulation over a session.** CatchCard pushed
    every card's dismiss connection into the panel tracker and never removed
    it on destroy; GearBar did the same for each owned row's equip overlay
    on every rebuild (rebuilds happen per ProfileSync while open). Both now
    disconnect with the instances they belong to. (Respawn does NOT
    duplicate listeners: panels mount `ResetOnSpawn = false` ScreenGuis and
    StarterPlayerScripts run once per join — verified, no fix needed.)
12. **[fixed] RegionChart ignored the fields the server sends for routing.**
    `accessible` (sent explicitly so the client can grey out unreachable
    grounds — OceanService.luau:415-418) was never read: a player could plan
    a trip to a ground that is dry. Now: dimmed row + "WAIT FOR TIDE".
    Depth showed `region.depth` where the README promises charted depth —
    now `chartedDepth` (with depth fallback). Provenance and
    `chartCoverage` were never surfaced — now unsurveyed grounds carry a
    "~" suffix (only `measured` reads as surveyed fact, house rule 6) and
    the sheet subtitle shows "% of the chart surveyed".
13. **[NOT FIXED — server] `run` and `market` toasts never fire.** Notify
    kinds exist client-side; grep finds no server code sending
    `kind = "run"` or `"market"` (only contest/scarcity from CastService).
    The salmon-run headline notification is unimplemented.
14. **[NOT FIXED — design] Keep/sell and a wallet do not exist** (see trace
    step 4). Not fixable client-side: there is nothing to render and no
    remote to call.

## Client changes made by this pass

- `src/Client/Ui.luau` — robust `formatInt`/`clockFace`/`countdown`/
  `formatWeight` (no scientific notation, NaN/∞ degrade); `Ui.tonum`;
  `Ui.normalizeRegions` / `Ui.normalizeMarketEntries` (typed, tested wire
  normalization); GameClock re-anchored on `tide.hour` with rolling-rate
  measurement, midnight unwrap, restart detection; `Sheet.setSubtitle`.
- `src/Client/HUD.client.luau` — server-hour clock; never-synced / stale
  states; SHARED OCEAN / LOCAL WATER status from `OceanSync.shared`; name
  map from normalized regions; `value` coercion.
- `src/Client/TideStrip.client.luau` — server-hour clock; "no ocean" /
  "lost the ocean" states; stops rendering (and blanks countdowns) when
  stale instead of animating a dead clock.
- `src/Client/CatchCard.client.luau` — all wire numbers through `Ui.tonum`;
  normalized region names; per-card connection cleanup.
- `src/Client/MarketPanel.client.luau` — normalized entries; out-of-date
  state + watchdog.
- `src/Client/RegionChart.client.luau` — normalized regions; charted depth;
  WAIT FOR TIDE + dimmed inaccessible rows; "~" unsurveyed marker; coverage
  subtitle; lost-feed state + watchdog.
- `src/Client/GearBar.client.luau` — row connections disconnect on rebuild.
- `tests/client-tests.luau` (new, 41 tests) + wired into `tests/run.sh`.
- `src/Client/README.md` updated where it described the old clock and stale
  known-gaps.

## Not verified / uncertainties

- Nothing was run in Studio. Every `[fixed]` claim rests on the headless
  test suite plus reading; layout/visual behaviour of the new states is
  unproven.
- `stylua --check src tests` cannot reach zero in this environment: the
  installed stylua 2.6.0 flags files untouched since before this pass
  (e.g. src/Shared/Ocean/Rng.luau, 18:19 mtime) — formatter version drift
  against the committed tree. Every file this pass touched is
  stylua-clean under 2.6.0; reformatting other owners' files was not this
  pass's call.
- `tests/boot-tests.luau` (added concurrently by another agent while this
  pass ran) fails on defects 2, 4 and 5 above — all in `src/Server/**`.
  All five pre-existing suites plus `client-tests.luau` pass.
- Defect 1's fix (a cast driver UI) is a design decision — where aim UI
  lives, how a species is chosen — that belongs to the Casting owner, not
  to a robustness pass.
