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
./tests/run.sh          # 74 tests, no Studio required
```

Two suites:

- `tests/run-tests.luau` — RNG determinism, species biology, population
  dynamics, harvest and scarcity, global supply, snapshots
- `tests/economy-tests.luau` — AI validation and repair, the scarcity curve,
  market response, region generation

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

- The ocean is locally simulated per server until the Worker is wired up. Until
  then the scarcity economy is per-server, not global.
- No persistence layer yet — the simulation state is not saved across server
  restarts.
- Art is placeholder geometry. The world is built from discs and labels; the
  visual language is meant to be replaced once the layout is proven.
- Balance is tuned against tests, not players. The numbers in `Config.luau` are
  a starting point and should be expected to move.

## Licence

Unreleased. All rights reserved.