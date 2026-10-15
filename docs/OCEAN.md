# The ocean surface

The game had no water. Now it has a tide-driven, sea-state-scaled, animated
surface. This note explains how it is put together, what it costs, and —
importantly — what has and has not been verified.

## The composition

The surface one tile sits at:

```
surfaceY(x, z) = DATUM_Y                                  -- world Y of MLLW (0)
               + Tide.heightAt(hour) * STUDS_PER_METRE    -- the game's clock
               + Waves.conditions(seaState).baseOffset    -- wind setup, small
               + Waves.heightAt(x, z, t, amp, windDir)    -- the chop
```

Three modules, one rule each:

| Module | Purity | Owns |
|---|---|---|
| `src/Shared/Tide.luau` | pure, pre-existing | the harmonic tide — untouched |
| `src/Shared/Ocean/Waves.luau` | pure, new | wave sum, sea state, wind, depth compression |
| `src/Shared/Ocean/Water.luau` | pure, new | colour blend and foam |
| `src/Server/OceanSurface.luau` | Roblox | the part grid, the throttle, the writes |

The tide remains the dominant vertical signal: over a full cycle the surface
swings roughly ±8 studs, while wind setup never exceeds ~2.1 studs even in a
state-6 gale (a test pins the ratio). **Over a tidal day the whole ocean
visibly rises and falls, and a 2 m shoal dries out at low water and floods at
high** — pinned by test, because that is the core mechanic made visible.

One vertical scale for everything wet: `Waves.STUDS_PER_METRE = 3`. The tide,
the wave amplitudes and the ground depths all use it, so they can never
disagree about how tall a metre is.

## Sea state

There is no weather simulation to hang waves on (OceanSim tracks fish, not
wind), so sea state is a deterministic function of the calendar day index:
`Waves.dayIndex(month, day)` → `Waves.seaState` → 0..6, with Douglas-ish
bands weighted toward workable water (calm-to-slight ~64% of days, state 5+
rare but yearly). Same date, same sea, on every server, forever — the same
bargain the rest of the simulation makes with randomness. Wind direction is
rolled per day too. The renderer eases amplitude in over a few passes at the
day rollover; direction snaps (lerping an angle across its wrap spins the
long way round, which looks worse).

## The renderer: a grid of anchored Parts

Weighed against "~80% of players are on a phone":

1. **SurfaceGui plane** — cheapest possible, but cannot be displaced: no
   waves, and a tide that can only slide a flat plane. Rejected: the visibly
   rising/falling ocean is the game's signature.
2. **MeshPart / EditableMesh vertex animation** — Roblox has no custom
   shaders, so this means continuous vertex rewrites; unaffordable on
   low-end mobile, and worse server-side where every delta replicates.
   Rejected.
3. **Grid of anchored Parts** (chosen) — geometry built once; updates are
   CFrame/Color property writes on existing instances; density, cadence and
   write quanta are three knobs in `OceanSurface.TUNING`.

Two design points inside that choice:

- **Coherent full passes, not rotating subsets.** Every pass refreshes the
  whole grid at one shared timestamp. A rotating subset would write less per
  pass, but out-of-phase neighbours read as a torn sheet of water. The
  savings come from quanta instead: a tile whose height/colour has not moved
  past `HEIGHT_QUANTUM`/`COLOR_QUANTUM` is not written at all, so a calm sea
  is nearly free and only a storm pays full price.
- **The loop is throttled** to one pass per 0.25 s (4 Hz) on
  `RunService.Heartbeat`, with the catch-up clamped so a loading hitch
  cannot trigger a burst of passes.

## The world it sits in

- **Datum:** world `y = 0` is MLLW, the same zero the chart and tide use.
- **Grounds:** disc tops sit at `-Waves.depthToStuds(region.depth)` —
  effectively linear near the surface (a 2 m shoal sits at ~6 studs, which is
  what lets the tide genuinely expose it), saturating toward 46 studs so a
  500 m basin is still visible from the boat. Monotonic by test.
- **The boat floats:** `OceanSurface.ride(deck)` pivots the boat (with its
  dock and spawn) by the same tide + setup term the surface sits on, so
  freeboard is constant across the whole tidal range. A fixed deck would be
  a pier, and would go under at springs.
- **The dock:** Main drops every arrival at `(0, 40, 90)`. Before the ocean
  existed that landed on the bare rescue floor; with water it would be a
  swim with no way back onto the boat. A pontoon dock (part of the boat
  model, so it rides the tide) makes arrival read as a harbour.
- **Environment.luau** keeps the sky (overcast, atmosphere, clouds — that
  look is deliberate and unchanged). Its dead `Terrain:FindFirstChildOfClass("Water")`
  block is gone; no Water instance was ever created, so both lookups always
  returned nil and the water keys in its TUNING were unreachable. The sea's
  colour now has exactly one owner: `Water.luau`.

## Performance budget — measured and estimated, labelled

**Measured (headless, this dev machine, `luau` CLI):**

- One full pass — 676 tiles, `Waves.heightAt` + `Water.appearance` for each —
  costs **1.85 ms**. The renderer asks for 4 passes/sec, so the pure math is
  ~0.75% of one core. Not the bottleneck.

**Counted from the code:**

- 26×26 = **676 water parts** (12 triangles each ≈ 8.1 k tris), plus ~20
  world parts (boat, dock, grounds, floor). All anchored, `CastShadow = false`,
  `CanTouch/CanQuery = false`.
- Worst-case property writes: a state-6 storm moving everything = 676 CFrame
  + 676 Color writes per pass ≈ **5.4 k property changes/sec**. At ~50–60
  bytes replicated per change that is a very rough **250–350 KB/s per
  client**. This is the single biggest cost of the design and it is an
  *estimate, not a measurement*.
- A calm sea writes almost nothing (quanta skip sub-0.06-stud height changes
  and sub-2%-channel colour changes), so the typical day is far below the
  storm worst case.

**Honest verdict on mobile:** the geometry and per-pass math are comfortably
in budget, but this is a *server-side* renderer — every animated change
replicates to every client — and **actual in-game frame rate and bandwidth on
a low-end device are UNVERIFIED. They need a Studio test on a phone.** If the
replication cost bites, the fix is architectural and known: move the tile
animation client-side (a LocalScript building the same grid from
`tide/seaState/amp/dir` broadcast once), which drops server cost to ~zero.
That was out of scope here because the client belongs to other work.

## Verified vs unverified

Verified headlessly (30 tests in `tests/water-tests.luau`): determinism of
every layer and of the end-to-end composition; `|height| <= amp`; finite,
NaN-free output at ±1e12 coordinates; foam/colour bounds; crest > trough
foam; calm-water whitecap suppression; surf over shallows and drying ground;
depth compression monotonicity and near-surface honesty; tidal range ≥ 10
studs; tide dominance over weather setup; the 2 m shoal drying and flooding
cycle.

Also verified headlessly through the repo's boot harness (`tests/run-boot.sh`,
which executes the real `Main.server.luau` against a fake Roblox): the full
server boots with the surface in place and the suite's own assertions pass —
"the ocean has a water surface", solid deck, findable spawn, no NaN CFrames,
three pumped heartbeats tick the simulation without surface errors. A further
one-off scratch run (since deleted) additionally pinned: 676 water-material
tiles built; tiles track the tide level within one wave amplitude and move as
hours pass; the boat rides the tide; a 2 m ground added to the ocean **dries
at spring low and is covered at spring high through the real renderer**;
`WorldGen.build()` re-runs cleanly with a fresh 676-tile surface. Those extra
checks are worth re-homing into the boot suite if the harness grows
clock-stepping.

One honest caveat the verification surfaced: **the procedurally seeded ocean
cannot produce a drying shoal.** Habitat depth floors start at 5 m (estuary),
which sits ~12 studs below the datum — deeper than any low water. Drying
becomes visible only for grounds charted ≤ ~2.5 m, which the AI composer can
admit but the seed never generates. The math is pinned by tests; the spectacle
waits on a shallow bank.

**UNVERIFIED — nobody has run this in Studio, so do not claim it works:**

- Visual quality: whether 26×30-stud tiles read as a sea rather than a
  grid; seam slits between tiles at height differences; how the 55%
  transparency (and the `Water` material) stacks at grazing angles.
- The tide's *visibility* in play (the math says ±8 studs over a cycle, ~4
  real minutes at 20 s/hour).
- Whether characters standing on the boat/dock ride the tide-bound PivotTo
  smoothly (movement is slow — ~0.4 studs/sec — which should be safe, but
  character-vs-moving-anchored-part behaviour needs a real test).
- Arrivals actually landing on the dock at `(0, 40, 90)`.
- The surface's edge at ±390 studs against the fog (fog covers ~29% at that
  distance plus atmosphere; the SeaFloor is painted the deep-water colour to
  soften the boundary, but it may still be findable on a clear line).
- Mobile frame rate and replication bandwidth (see budget above).

## Tuning

| Knob | Where | Effect |
|---|---|---|
| `GRID`, `TILE` | `OceanSurface.TUNING` | ocean size vs part count (26×30 = 780-stud square) |
| `UPDATE_INTERVAL` | `OceanSurface.TUNING` | animation cadence; wave periods must stay ≥ ~2 sample intervals |
| `HEIGHT_QUANTUM` / `COLOR_QUANTUM` | `OceanSurface.TUNING` | write suppression — raise for cheaper calms |
| `DATUM_Y` | `OceanSurface.TUNING` | where MLLW sits in world Y (boat waterline follows it) |
| `STUDS_PER_METRE` | `Waves` | the one vertical scale; tide visibility and shoal drying both key off it |
| `COMPONENTS` | `Waves` | the wave sum; `ampFrac` must sum to 1 (pinned by test) |
| `CONDITIONS` | `Waves` | sea-state amplitudes and wind setup |
| `DEPTH_FADE`, `SHALLOW_FOAM_*`, `WHITECAP_*` | `Water` | where surf and whitecaps appear |
| `MAX_DISPLAY_DEPTH`, `DISPLAY_COMPRESS_K` | `Waves` | how deep grounds draw |

After touching anything in the first two rows, re-run `./tests/run.sh` — the
wave-math tests are cheap and catch tuning mistakes that silently break the
`|h| <= amp` bound or the Nyquist margin.
