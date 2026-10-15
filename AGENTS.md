# AGENTS.md

Conventions for anyone — human or agent — changing this repository.

## What this project is

A Roblox fishing game whose ocean is a shared, persistent, simulated resource.
The economy is emergent: nothing scripts scarcity, it falls out of population
dynamics and a price that responds to global abundance.

**The thesis: the AI proposes, the simulation arbitrates.** A language model in
a Cloudflare Worker invents fishing grounds. None of it is trusted. See
`src/Shared/Ocean/BankSpec.luau`.

## Before you touch anything

```bash
./tests/run.sh        # 74 tests, no Studio needed, ~1s
./scripts-check.sh    # parse check + selene + rojo build
```

Both must be green before you commit. If you break either, fix it or explain
why you can't.

## The three borrowed ideas

This project shares a design lineage with
[SuperInstance/shoalwater](https://github.com/SuperInstance/shoalwater). If you
change something that touches these, read the reasoning first.

1. **The tide is the clock** (`src/Shared/Tide.luau`). Grounds with less water
   over them than the boat's draught are unreachable; slack water fishes better
   than a running tide. Real harmonic constituents, not a sine wave. The
   amplitudes are ESTIMATED — see the accuracy note in that file and NOAA
   station **9451600**.

2. **The world is measured, not imagined** (`src/Shared/Ocean/Chart.luau`).
   Every region carries a `provenance` of `measured`, `grown` or `composed`, and
   **only `measured` may ever be shown to players as fact**. A load with an
   unrecognised provenance string is downgraded to `grown`, never trusted.

3. **The AI proposes, the simulation arbitrates**
   (`src/Shared/Ocean/BankSpec.luau`). Model output is repaired against
   simulation rules, never trusted. Validation is deterministic so the same
   output always yields the same bank.

## Two implementations, one economy

`src/Shared/**` (Luau) runs in Roblox. `worker/src/**` (TypeScript) owns the
shared state in D1. **They must produce identical numbers**, or every server
tells its players a different price for the same fish.

They once did not. The worker shipped a scarcity curve matching neither version
of the Luau one and its own suite passed, because it only tested itself.

The guard is `shared/economy-vectors.json`:

```bash
# after changing ANY economy constant or formula, regenerate the fixture:
luau tests/generate-vectors.luau > shared/economy-vectors.json

# the Luau side is authoritative; both sides then assert against it
./tests/run.sh
cd worker && npm test
```

Luau is the source of truth. If the two disagree, **the worker is wrong** until
proven otherwise.

## Hard rules

These are not style preferences. Breaking them breaks the game.

1. **`src/Shared/**` must stay pure Luau.** No Roblox globals. This is what
   makes the simulation testable headlessly and reproducible. If you need
   `HttpService`, it belongs in `Net/` and is allowed to break that rule.

2. **The client never computes value, price, scarcity or yield.** It renders
   what the server sent. A modified client must not be able to drain a shared
   fishery.

3. **Only `OceanService` mutates ocean state.** Single owner. If you find
   yourself writing to `ocean.stocks` somewhere else, that is the bug.

4. **Determinism.** Given the same seed and the same sequence of calls, the
   simulation must produce byte-identical results. No `Math.random`, no
   wall-clock, no iteration over unordered tables in anything that affects
   state.

5. **No bitwise operators in `src/Shared/**`.** The standalone `luau` build
   used by the tests cannot parse `<<`, `>>` or `~`. Code that runs in Studio
   but not in tests is worse than code that does neither.

6. **Never present generated water as surveyed.** If you add a region by any
   route, its provenance must be honest about it.

## The dual-target require idiom

Shared modules must load both in Roblox and under the standalone interpreter:

```lua
local scriptParent = script and script.Parent
local Rng = require(scriptParent and scriptParent.Rng or "./Rng")
local Config = require(scriptParent and scriptParent.Parent.Config or "../Config")
```

The `script` branch resolves in Studio; the relative-path branch resolves in
tests. **Keep the two in sync.** A wrong fallback path fails only in tests, which
is why `scripts-check.sh` exists.

## Luau gotchas that have bitten this repo

- **No tuple types.** `{ number, number }` is a syntax error. Use
  `{ number }` and index it, or declare a named type.
- **No `("r%d"):format(...)` shortcut.** `("r%d" :: string) .. n` yields the
  literal `r%d1`. Use `"r" .. tostring(n)`.
- **Doc comments do not wrap.** `--- text` followed by an indented plain line is
  a stray expression and fails to parse. Every line of a doc comment needs `---`.
- **`local function` is not `Service.method`.** Declaring a helper locally and
  calling `Service.helper(...)` throws every tick. Selene catches this; run it.

## Adding a species

`src/Shared/Species.luau`, then update `worker/src/species.ts` to match. The
backend mirrors the roster because it owns the global supply numbers, and the
two drifting apart would corrupt the shared economy.

The biological fields are load-bearing, not decoration:

- `minDepth`/`maxDepth` gate where a species can live.
- `anadromous` + `runMonths` create migration inflow during the run and a
  collapse after it. This is real salmon biology and it is the game's best
  mechanic. Do not fake it with a respawn timer.
- `capacity` and `growthRate` are gameplay-tuned. Real recruitment
  coefficients are not usable in a game loop.

## Tuning the economy

Everything tunable lives in `src/Shared/Config.luau` with a comment explaining
what it controls. Change it there, never inline.

After any economy change, re-run the tests. Several of them exist because they
caught genuine design bugs — the harvest cap once measured against current stock
instead of capacity, which decayed yield quadratically and made ground collapse
**unreachable**, silently killing the core mechanic.

## Layout

```
src/Shared/     pure Luau, no Roblox globals   -> ReplicatedStorage.Shared
src/Server/     authoritative                  -> ServerScriptService.Server
src/Client/     feel and rendering only        -> StarterPlayer.StarterPlayerScripts
worker/         Cloudflare Worker, D1 + KV + AI
tests/          headless, run via ./tests/run.sh
```

`src/Shared/Types.luau` is the wire contract between client and server. Renaming
a field there is a breaking change on both sides plus the Worker.

## Running in Studio

```bash
rojo serve default.project.json
```

Studio -> Plugins -> Rojo -> Connect, then Play. Studio runs on the Windows
side, `rojo` on the WSL side; WSL2 forwards localhost, so no host/port changes
are needed.

Expected console output:

```
[slack-water] ocean started: 14 regions, 17 species, seed 20261014
[slack-water] worldgen: 14 regions placed
[slack-water] cast service listening
[slack-water] ready
```