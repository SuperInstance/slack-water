# CASTING — how a player fishes

Written 2026-10-15 by the cast-loop pass. This is the documentation for the
client half of the cast loop: the CastBar panel, the rendezvous that drives
the `Casting` minigame, the selection rules, and every failure path. It
exists because that loop was dead on arrival once already —
`Casting.start()` was called by nothing, there was no picker and no cast
button, and a player could not fish (docs/PLAYLOOP.md, defect 1).

**Verification level:** static + headless. Everything here was executed
under the fake client engine in `tests/cast-loop-tests.luau` (49 tests,
including a full driven loop from OceanSync to CastResult). Nothing has been
run in Studio; no human has played it. See "What is not verified" before
trusting any claim about how this *looks* or *feels*.

---

## The shape of it

Three LocalScripts and one BindableEvent:

```
StarterPlayerScripts.Client
├── CastBar.client.luau    the UI: picker, CAST button, fight readout
├── Casting.client.luau    the minigame state machine (UI-free)
├── HUD.client.luau        listens for the selection, shows "bound for X"
└── Ui.luau                shared ModuleScript (construction kit)

PlayerGui.SlackWaterCastBus   a BindableEvent — the only channel between them
```

**Why a BindableEvent:** rojo's default rules map `*.client.luau` to
LocalScripts, and a LocalScript cannot be `require`d by its siblings. Before
this pass, that fact was the whole bug — `Casting.start()` existed and no
other script could reach it. The options were renaming files into
ModuleScripts (changing the tree other passes were editing against), shared
mutable state in `Ui.luau`, or one named instance as a rendezvous. The named
instance is the smallest contract: `Casting` creates
`PlayerGui.SlackWaterCastBus` at boot, and every message anyone may send is
in the table below.

## The CastBus contract

All messages are plain tables with a `kind` field. Unknown kinds are ignored
by every listener — additions are backward-safe.

| Direction | `kind` | Shape | Meaning |
| --- | --- | --- | --- |
| CastBar → Casting | `"cast"` | `{ kind, regionId: string, speciesId: string, depth: number? }` | Begin a fight. `depth = nil` means mid-band — the informed default `Casting.beginFight` applies. |
| CastBar → Casting | `"abort"` | `{ kind }` | Reel in / give up. From `"fighting"` it is a lost fight; from `"waiting"` it cancels the resolve. |
| CastBar → HUD | `"selection"` | `{ kind, regionId: string?, regionName: string? }` | The ground the player rigged for. HUD renders `bound for <name>` until a CastResult says where they actually are. |
| Casting → CastBar | `"fight"` | `{ kind, event: string, data: any }` | A forwarded minigame event. `event` is one of `begin`, `update`, `landed`, `lost`, `result`, `cancel`, plus `error` for intents that never became a fight. |
| Casting → HUD | `"fight"` / `"result"` | `{ kind, event, data }` | The server's answer to the cast in flight. HUD adds `data.value` to the session total. |
| Casting → CatchCard | `"fight"` / `"result"` | `{ kind, event, data }` | Same payload, verbatim. CatchCard renders the card. |

The `"update"` event fires every Heartbeat during a fight and carries
`Casting.snapshot` (tension01, progress, stamina, inBand…). `"result"`
carries the server's `CastResultPayload` verbatim.

**Casting owns the `CastResult` remote. Nobody else listens to it.** HUD and
CatchCard used to subscribe to the wire themselves, which was wrong twice
over: Roblox fires handlers in connection order and Casting unsubscribes
after each reply, so from the *second* cast onward both listeners ran before
the staleness check they were relying on; and three subscribers meant three
copies of "is this still relevant", only one of which had an answer. The
answer is now computed once, in `Casting._resolveOnServer`, against a
generation counter that increments when a cast **begins** and when it is
**abandoned** — so a reply for a cast that has been replaced or reeled in is
dropped before anyone else hears it. If you are adding a third consumer, take
it from the bus, not the remote.

## The loop, step by step

1. **Sync.** CastBar listens to `OceanSync` and normalizes regions through
   `Ui.normalizeRegions` — the same defense every panel uses. Its `GameClock`
   anchors on the server's `tide.hour` exactly as the HUD's does.
2. **Rig.** The summary button opens the rig sheet: grounds (open first by
   quality, then closed grounds by soonest opening), a target (blind or a
   species), and a depth slider. Choosing a ground publishes `"selection"`.
3. **Cast.** The CAST button validates the selection, applies the tide
   pre-gate, checks the double-cast guard, and fires `"cast"`.
4. **Fight.** Casting binds the input it already had (touch/mouse/space —
   hold anywhere to reel) and drives `update` off Heartbeat. CastBar swaps
   its bottom bar to the fight readout: tension (with the safe band drawn),
   catch progress, stamina.
5. **Resolve.** On a win, Casting fires `CastRequest` with
   `{ regionId, speciesId, effort = 0, depth, performance }` and waits on
   `CastResult`. Casting checks the reply against the cast's generation and
   republishes it as `"result"`; CatchCard renders the card and the HUD adds
   to the session total, CastBar echoes the value (or the failure reason) in
   its status line.
6. **Again.** The guard releases on result/loss/cancel/timeout; the button
   shows a countdown only while the server's cooldown would actually refuse
   a request.

## Selection rules (what the client will OFFER)

The client never computes an outcome; these rules only decide which intents
are offered, and the server arbitrates every one of them:

- **Presence.** A species is offered at a ground only if the server's
  `region.species` list has it. The rest render disabled with
  "not in these waters".
- **Depth window.** `[species.minDepth, min(species.maxDepth, chartedDepth)]`
  — the biological band, capped by the charted floor. A line set deeper than
  the floor is not fishing. Empty window renders "lives deeper than this
  ground". This is chart honesty, not simulation: **the server does not
  currently validate depth at all** (see "Contract notes").
- **Blind cast.** "Whatever's there" resolves, at cast time, to the most
  abundant present species with a legal window (server-sent abundances,
  id-ascending tie-break so it is deterministic). `depth` goes out as nil and
  `Casting` sets mid-band — the picker says "auto".
- **Tide.** Grounds are offered with the server's quality when open, or
  "WAIT FOR TIDE · opens ~13:40 · in 2.3 h" when closed — computed by walking
  `Tide.accessAt` forward over the same harmonic sum the server gates with,
  on the server-sent `chartedDepth`. This is display math (the same
  sanctioned use as TideStrip's curve); the server's check at resolve time
  is the only one that counts.

### A finding about the tide gate — resolved

**This section previously recorded a defect. It was fixed, and the diagnosis
in the original write-up was wrong in an instructive way.**

The finding was that `WAIT FOR TIDE` could never fire: the shallowest species
band sat above the water line at lowest tide, so nothing fishable was ever shut
out. Two things were wrong with that account.

First, the arithmetic. The tide's actual lowest water is **-2.03 m**, not the
~-2.57 m estimated here — the harmonic constants sum lower than assumed. The
drying threshold is therefore `TIDE_MIN_DRAUGHT - lowest` ≈ **3.83 m**, not
4.4 m.

Second, and more importantly, the roster was never the constraint. Even a
species band at 0 m could not have mattered, because **no ground in the ocean
was ever shallow enough to dry**. `Regions.DEPTH_RANGE` bottomed its shallowest
habitat out at 5 m — above the 3.83 m threshold. The mechanic was unreachable
for a geographical reason, and no amount of moving species around would have
reached it.

The fix, in `src/Shared`:

- `estuary` reaches **1.5 m**, and 45% of estuaries are generated as intertidal
  flats in the 1.5–3.5 m band, because that is what an estuary mostly is.
- `kelp` and `reef` reach 3–4 m — nearshore, not just offshore.
- **Dungeness Crab** carries its honest intertidal band from 2 m. In Southeast
  Alaska they are worked from the shallows, so this is the truthful value as
  well as the one that makes the mechanic fire.

About **7.5%** of generated grounds now dry out — roughly **4–5 of a 60-ground
ocean** are tide-gated, which is enough for a player to meet one and not enough
to dominate play.

Two tests in `tests/tide-chart-tests.luau` pin this behaviourally, and both were
confirmed red before the fix:

- a meaningful share of generated grounds must dry out
- the shallowest ground must be genuinely shut for at least an hour a day

The lesson worth keeping: the write-up blamed the constants in the module it
happened to be looking at, and would have been fixed in the wrong place by
anyone who trusted it. The gate was fine. The coastline was wrong.

## Failure paths (nothing fails silently)

| Failure | Where it surfaces |
| --- | --- |
| No ground chosen / blocked species / depth outside window | status line above CAST, and the offending picker rows are disabled with their reason |
| Ground left the chart (expired/removed between syncs) | selection cleared + "your ground left the chart" |
| Tide pre-gate (ground dry at press time) | "The tide has this ground under you — opens ~13:40 · in 2.3 h." (cast does not start) |
| Server refuses the resolve (`ok = false`, any reason incl. its tide prose) | CastBar status line in danger red + CatchCard's failure card |
| Fight lost (line parted / reeled in) | status line — **CastBar is the only surface for these**; lost fights never touch a remote, so no card exists |
| Resolve never answered | Casting times out after 12 s ("The landing never resolved — no answer from the shore."), guard releases; CastBar's watchdog at 16 s is a second belt |
| CastBus missing (Casting dead) | "the rig is not answering — cannot cast"; a press 5 s after a cast that never began also recovers the guard |
| Ocean feed stale (>12 s) | picker header reads "feed lost, times may lie", open/close captions replaced |
| Cooldown | button reads "WAIT 1.2s" for exactly as long as the server would refuse |

## The double-cast guard (three layers)

1. **CastBar's guard** (pure, unit-tested): `guardTryBegin` refuses while a
   cast is busy or inside the cooldown, which is measured from the server's
   *answer*, not the press.
2. **Casting's boot block**: a `"cast"` message while
   `state == "fighting" | "waiting"` is dropped — the state machine cannot
   be restarted out from under a live fight even by a client that skips the
   UI.
3. **The server**: `CastService.isRateLimited` (`Config.CAST_COOLDOWN`,
   2 s — the constant whose absence once threw on every cast). A refused
   cast there is silent server-side; the client's own countdown exists so
   honest players never hit it.

## Contract notes

- **Nothing new is needed from the wallet pass.** The one field this loop
  needs beyond the pre-existing contract — `performance: number` on
  `CastRequestPayload`, sent by `Casting._resolveOnServer` and read by
  `CastService` — is declared in `src/Shared/Types.luau` as of their
  in-flight change (with a server-side default when absent, closing PLAYLOOP
  defect 3 from the server side).
- `CastResult` may carry `catchId` / `valueCents` (wallet pass). CastBar
  ignores unknown fields; CatchCard renders what it knows.
- **The server does not validate `depth` or species-at-ground.** A modified
  client can send any depth; it only shifts the fight's own `performance`
  scoring (which the server clamps). If the server should ever arbitrate
  depth, `Types.CastRequestPayload.depth` is the place, and CastBar's picker
  already sends honest numbers.
- Late `CastResult` after an abandoned resolve used to show a card for a
  fish the player had reeled in, and — worse — land on top of whatever cast
  was running now and end it. Fixed: the generation counter moves when a cast
  begins and when it is cancelled, and Casting is the only listener on the
  remote. Three tests in `tests/cast-loop-tests.luau` pin it, including the
  case where the live cast's own result must still work.

## What is verified, and how

- `tests/cast-loop-tests.luau` — 41 pure tests of the selection rules, tide
  walk, guard and formatting, plus 8 executed tests that load the REAL
  `CastBar.client.luau` / `Casting.client.luau` / `HUD.client.luau` under a
  fake client engine (PlayerGui, UserInputService, BindableEvents, UI
  instances; the same loadstring+setfenv technique as the server boot
  harness) and drive a full loop: sync → pick through the actual UI
  instances → press CAST → win the fight through the real input signals →
  capture the `CastRequest` payload off the fake remote → answer the result
  → confirm the guard freed. The double-cast refusal, the give-up path and
  the resolve timeout are all driven, not mocked around.
- `./tests/run.sh` (all suites), `scripts-check.sh` (parse, selene 0 errors,
  rojo build) — green at the time of writing.
- A mutation control was run once against the harness (a deliberately wrong
  expectation fails; a correct one passes) because a test that cannot fail
  is worse than no test.

## What is NOT verified

- **Studio.** Nothing here has been run in Roblox. The UI has never been
  rendered: layout, hit areas, the slider's drag feel, the fight meters'
  readability, and one-handed reach are unproven design, not tested fact.
- **Real input.** The fake engine fires `UserInputService` signals directly;
  real touch/mouse/keyboard routing through `gameProcessedEvent` (touches on
  GUI must not reel) is reasoned about, not observed.
- **Real remotes.** `BindableEvent`/`RemoteEvent` semantics are faked
  synchronously; deferred signal ordering and network latency are not
  modeled. `WaitForChild` never yields in the fake engine, so
  join-ordering races between the three scripts are untested.
- **The picker's visual sorting** (open-first, soonest-opening) is computed
  deterministically but has never been looked at.

## Known edges

- The rig sheet rebuilds on open, never under a finger: an OceanSync that
  arrives while the sheet is open is folded into the next open. Stale
  abundances while open are the trade.
- The blind pick is recomputed at cast time, so the "≈ Herring" hint can
  name a different species than the one hooked if the ground shifted
  between render and press. The cast is honest either way — it targets
  whatever is most abundant at press time.
- CastBar hardcodes the sheet-coordination attribute string
  (`SlackWaterOpenPanel`, matching `Ui.makeSheet`) because the attribute
  name is a local in `Ui.luau`. Renaming it there breaks the yield-the-screen
  behaviour here, silently.
