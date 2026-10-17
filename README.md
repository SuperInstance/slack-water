# Slack Water

> *Slack water* is the still interval between tides — the moment the current
> stops and the boat finally gets moving.

A Roblox fishing game where the ocean is a real, shared, persistent resource.
Fish stocks reproduce, migrate, migrate in seasonal runs, and get fished out.
Every server plays against the same ocean.

**The thesis: the AI proposes, the simulation arbitrates.**

A language model running in a Cloudflare Worker invents new fishing grounds —
their habitat, depth, what lives there, what they're called. Nothing it emits is
trusted. Every bank is repaired against deterministic simulation rules before it
is allowed to exist, and the population model decides what actually lives in
the water. The model authors surface; the simulation decides truth.

---

## Why this game, and why this design

The dominant Roblox loop of 2026 is *steal-and-collect*: `Steal a Brainrot`,
`Steal An Egg`, and their clones — players take from other players, collectibles
are the currency, and `+1` scaling is the dopamine. It works. It has also been
cloned to death.

Three observations shaped this project:

1. **Nobody is fishing.** Zero ocean games in Roblox's top 25. Casual fishing is
   a large genre, but every one of them is idle-collection. None of them
   simulate an actual *fishery*.

2. **Content treadmill is the real problem.** Hobby studios build one good
   mechanic and then starve. The winners are content factories. A model
   generating validated, playable content is the cheapest content factory that
   has ever been available to an indie dev.

3. **Occupational authenticity punches above weight.** `Karinderya!` — a
   Filipino restaurant sim — pulls 91K CCU and climbing. The people who win are
   the ones whose content could only have been written by someone who has done
   the job. This project's author is a commercial fisherman out of Sitka, and
   the roster is real North Pacific species with real biology: halibut sit at
   200–900m because halibut sit at 200–900m; salmon runs in spring and autumn
   because they do.

## The economic loop

Nothing below is scripted. It all falls out of two numbers.

```
players fish a ground
    -> that ground's biomass falls
        -> the species' GLOBAL abundance falls
            -> scarcity multiplier climbs
                -> price climbs
                    -> players route somewhere else
```

A species fished by everyone becomes worthless. Leave it alone and the price
comes back. The market module knows exactly one number per species — global
abundance — and derives everything else from it. That is why a shared ocean
matters: the scarcity is real to everyone at once.

## Anadromy, the feature that matters most

Salmon do not spawn in the ocean. They return to freshwater to spawn, and they
die doing it. That is real biology, and it is the best mechanic in the game for
free:

- During a **run window**, biomass *arrives* at estuary and open-water regions.
  Grounds swell with fish.
- After the window closes, it **collapses** — post-spawn mortality is brutal.

So a salmon run has the shape of an event with a deadline. It is urgent rather
than grindy, and it is the same shape every year. No designer had to invent it.

## The AI boundary

`src/Shared/Ocean/BankSpec.luau` is the most important file in the project. It
receives untyped model output and **repairs rather than rejects**:

| Input problem | Behaviour |
| --- | --- |
| Unknown habitat | hard reject — guessing would corrupt the world's structure |
| Depth outside 5–900m | clamped to range, recorded as a repair |
| Richness / salinity out of range | clamped |
| Unknown species id | dropped from the mix |
| Mix empty after dropping | hard reject |
| Bad or blocked bank name | replaced with a safe fallback |
| Everything salvageable | accepted |

Two properties make this safe in front of players: a bank that is 95% sensible
is clamped rather than discarded, and validation is **completely deterministic**,
so the same model output always produces the same bank. The simulation stays
reproducible even though its content came from a language model.

The repair log is also telemetry — a high repair rate means the prompt is
drifting.

---

## The tide is the clock

Borrowed directly from the engine principle in
[SuperInstance/shoalwater](https://github.com/SuperInstance/shoalwater):

> The tide is the clock. A cove that is a harbor at high water is a mudflat
> with a winding channel at low water, and a boat can only leave when the tide
> says so. No invented puzzles: seamanship is the game mechanic.

That solved a problem this game had. Fishing on demand has no rhythm — you fish
whenever you log in, the ocean is a static resource, and there is never a reason
to be anywhere at a particular time. The tide supplies all three:

- **Gating.** A shoal charted at 2.0 m is dry rock at low water and fishable at
  high water. Chart depth plus current tide height is the water actually over
  the ground, and if that is less than the boat's draught you simply cannot go.
- **Quality.** Current is strongest mid-tide and slack at the extremes. A cast
  at dead slack pulls full effort; the same cast in a heavy current pulls a
  quarter of it.
- **Rhythm.** Slack water lands at a different hour every day, so there is a
  reason to look at the clock.

It is also the game's name. `Tide.luau` sums real harmonic constituents (M2, S2,
N2, K1, O1) rather than shaping a sine, which produces Southeast Alaska's real
*mixed semidiurnal* pattern — unequal successive heights, and slack water that
drifts around. Players learn "slack is about four, but sometimes five" without
being told.

> **Those amplitudes are estimated, not measured.** They are plausible for an
> exposed Alaskan sound and they get the *shape* right. The authoritative source
> is NOAA station **9451600**. Careful: the widely-copied pack "9452210 Sitka"
> is actually **Juneau** — that error is documented in shoalwater and is
> precisely why this project verifies rather than copies. Drop real constants
> into `Tide.CONSTITUENTS` and nothing else needs to change.

## The chart, and what it is honest about

`src/Shared/Ocean/Chart.luau` holds bathymetry **with provenance**, taking three
ideas from shoalwater:

| provenance | meaning | trust |
| --- | --- | --- |
| `measured` | a real sounding, verified | high |
| `grown` | generated from statistics, plausible only | low |
| `composed` | proposed by the language model, validated | model |

Only `measured` water is ever presented to players as fact. Everything else is
labelled, and `chartCoverage` is sent to the client so a player can see how much
of the map is really known — and has a reason to go survey the rest.

The chart format is a flat, stable schema so real soundings drop in by script
rather than by hand. CSB (crowdsourced boat soundings) and NOAA exports both
convert. Until then the ocean seeds procedurally and every region is honestly
marked `grown`.

**Ground truth is a practice, not a dataset.** `Chart.survey` is the gesture: an
existing region upgrades from grown to measured and the coverage metric moves.
Survey days are play days.

## Keeping the two implementations honest

There are two implementations of the same economy: the Luau simulation that
runs in Roblox, and the TypeScript worker that owns the shared state in D1. They
must agree exactly, or every server tells its players a different price for the
same fish.

They did not. The worker shipped a scarcity curve (`1 / abundance`) matching
neither version of the Luau one, and **its own test suite passed** — because it
only ever tested itself. A green suite proved nothing.

The fix is structural, not a code review:

```
tests/generate-vectors.luau  ->  shared/economy-vectors.json
                                          |
              both sides read it and assert the same numbers
```

The Luau side is authoritative and generates the fixture; the worker asserts
against it. `worker/tests/parity.test.ts` now covers scarcity, target prices,
market inertia path, effective capacity and harvest yield. Changing an economy
constant on one side without the other now fails a test instead of quietly
desyncing the game.

## Architecture

```
slack-water/
├── default.project.json          Rojo project
├── src/
│   ├── Shared/                   pure Luau — no Roblox globals, fully testable
│   │   ├── Config.luau           every tuning constant, documented
│   │   ├── Species.luau          17 real North Pacific species
│   │   ├── Types.luau            the client/server wire contract
│   │   ├── Market.luau           price from global abundance
│   │   ├── Ocean/
│   │   │   ├── Rng.luau          deterministic Park-Miller
│   │   │   ├── OceanSim.luau     population dynamics — the heart
│   │   │   ├── Regions.luau      procedural generation + fallback
│   │   │   └── BankSpec.luau     THE AI BOUNDARY
│   │   └── Net/
│   │       └── OceanClient.luau  Cloudflare backend, fails soft
│   ├── Server/                   authoritative — clients send intent only
│   │   ├── Main.server.luau      boot order
│   │   ├── OceanService.server.luau   single owner of ocean state
│   │   ├── CastService.server.luau     intent -> catch
│   │   └── WorldGen.server.luau        simulation -> world
│   └── Client/                   feel only; renders what the server sent
└── worker/                       Cloudflare Worker: D1, KV, Workers AI
```

### Single-owner rule

Only `OceanService` mutates ocean state. If cast handling could write to stocks
directly, the scarcity maths would drift from reality within minutes. That rule
is what makes the economy trustworthy.

### How the ocean is actually shared

The Worker is authoritative. Each Roblox server holds a *mirror* and answers
casts instantly against it, because a fishing game cannot pay a network round
trip on its core loop.

That optimistic path is only safe if divergence is bounded and self-healing:

```
cast ──> applied locally, queued as an unconfirmed delta
      └─> reported to the Worker
            ├─ confirmed  -> delta leaves the queue, next snapshot carries it
            └─ no answer  -> delta is REPLAYED on top of every snapshot
```

The replay is the load-bearing step. Without it, a snapshot generated before the
player landed their fish would silently undo it, and a fisher would watch a catch
vanish from their ledger. `src/Shared/Ocean/Reconcile.luau` holds that logic as
pure Luau with 22 tests, because it is the kind of bug that looks like nothing
happened.

The worst case of a stale mirror is that a player gets slightly less than their
cast was worth because the ground was picked over on another server. That is the
game working.

The snapshot also carries the authoritative month and day, which settles a real
disagreement: the Roblox tick ran every 20s and the Worker cron every 60s, so
the two implementations disagreed about what a day was — which would have
quietly desynced the salmon runs.

**The Worker also owns the geography.** A server seeds its own provisional
regions, but on first sync it adopts every region the Worker knows about,
including ones the model invented that it has never heard of. This was not
optional: the server seeded `r1..r14` while the Worker held `r_kelp_road`,
`r_flattop_sand` and the composed banks, so **not one id matched** and every
snapshot merged nothing. Two oceans, same codebase, tests green the whole time.

`OceanSync` carries `shared` and `sharedStatus` so a client can tell whether it
is looking at the shared ocean or a private one. "The ocean is shared" should be
a visible claim, not a marketing line that is quietly false on an empty server.

### Server authority

A client sends intent — region, species, gear, performance. It never sends an
outcome. Effort is clamped to what the gear actually provides, and every number
in a catch result is computed on the server. Because the ocean is shared, a
client that could write to a stock would be draining a fishery for everyone.

### Determinism

The simulation is pure Luau with no Roblox globals, so it runs headlessly under
the `luau` interpreter in milliseconds. The same seed and the same call sequence
produce byte-identical results. That is what makes the economy testable and the
ocean reproducible across restarts.

> The RNG is written with plain arithmetic and **no bitwise operators** — the
> standalone `luau` build does not parse `<<`, `>>` or `~`, so an xorshift
> implementation would run in Studio and fail in tests.

---

## Getting started

### Requirements

- Roblox Studio
- [Rojo](https://rojo.space) (`rojo`, `selene`, `stylua`, `luau` on `PATH`)
- Node 20+ for the worker

### Run it

```bash
# 1. serve the project
rojo serve default.project.json

# 2. in Roblox Studio
#    - open a Baseplate
#    - Plugins > Rojo > Connect  (defaults are fine)
#    - press Play
```

The server seeds a 14-region ocean and prints:

```
[slack-water] ocean started: 14 regions, 17 species, seed 20261014
[slack-water] worldgen: 14 regions placed
[slack-water] cast service listening
[slack-water] ready
```

### Tests

```bash
./tests/run.sh          # 172 tests, no Studio required
```

Two suites:

- `tests/run-tests.luau` — RNG determinism, species biology, population
  dynamics, harvest and scarcity, global supply, snapshots
- `tests/economy-tests.luau` — AI validation and repair, the scarcity curve,
  market response, region generation
- `tests/tide-chart-tests.luau` — tide shape, shallow-water gating, chart
  provenance and real-sounding loading
- `tests/progression-tests.luau` — XP, gear gating, and the rule that fishing a
  fresh ground out-earns a picked-over one
- `tests/reconcile-tests.luau` — snapshot merge, delta replay, backend health

Several of these tests exist because they caught real design bugs. The
harvest cap originally measured against current stock rather than capacity,
which made yield fall off quadratically and meant **a ground could never
actually be collapsed** — the core scarcity mechanic was unreachable and no
amount of playtesting would have shown that as clearly as a test asserting the
collapse threshold.

### Lint / build gate

```bash
./scripts-check.sh      # parse check, selene, rojo build
```

### The worker (optional)

The game plays perfectly well without it — that is deliberate. The backend is
what makes the ocean *global* and lets the model author new grounds.

```bash
cd worker
npm install
npx wrangler d1 create slack-water-ocean   # paste the id into wrangler.toml
npx wrangler d1 migrations apply DB
npx wrangler deploy
```

Then set `OceanClient.BASE_URL` in `src/Shared/Net/OceanClient.luau`.

---

## Design notes

**Why the cap is against capacity, not stock.** Capping a cast against current
stock makes yield decay quadratically once a ground is picked over, which
quietly prevents any ground from ever being depleted. Capping against carrying
capacity lets sustained pressure actually collapse a stock — which is the whole
economy. Depleted grounds still pay 25% of a full cast, so players rotate
instead of camping.

**Why prices have inertia.** A market that snaps to a new price on every catch
is unreadable. Inertia means a single big catch nudges the trend without
teleporting it, so players can plan around what they are seeing.

**Why the scarcity curve is bounded.** Otherwise the optimal strategy is to wipe
a stock to zero and farm the rebound. The curve asymptotes and is capped so a
collapsed species is worth going after, not worth destroying.

**Why there is no theft minigame.** The PvP layer is informational: if another
crew worked a ground this tick, you are told, because the consequence is
already shared through the economy. Stealing from a respawning NPC base is a
mechanic; two crews knowing they are fishing the same thinning water is
tension.

## Known gaps

**Start with [`docs/STATUS.md`](docs/STATUS.md).** It is the honest state of the
build: what has been verified and how, what has never been run, and the order
in which a new developer should attack the remainder. The summary is short —
the simulation is real and tested, the cast loop has never been played, and the
AI composer was dead until recently and has still never run inside the game.

- The Worker is deployed and running at
  `https://slack-water.casey-digennaro.workers.dev` with a real D1 database and
  KV namespace. The live AI composer returns real banks. The game now reaches
  it correctly, but that has not yet been confirmed in a live Studio session.
- No persistence layer yet — local simulation state is not saved across server
  restarts. The D1 copy is durable; the mirror is not.
- Art is placeholder geometry. The world is built from discs, labels and a
  low-poly shoreline; the visual language is meant to be replaced once the
  layout is proven.
- Balance is tuned against tests, not players. The numbers in `Config.luau` are
  a starting point and should be expected to move.
- The cast loop has never been played by a person. Its tests run against a fake
  engine, not Roblox.

## Licence

Unreleased. All rights reserved.