# Slack Water — Design Document

October 2026. This document describes what is built, distinguishes it from what is
proposed, and marks tuned-but-unmeasured numbers as such. Claims are cross-referenced
to files; the three headless suites (104 assertions at time of writing, `./tests/run.sh`)
are the behavioural specification, and the README's "74 tests" is stale.

Status in one line: the simulation, market, tide, chart and AI boundary exist and are
tested; the client is one minigame script; gear, progression, persistence and
monetisation do not exist yet.

## 1. Premise and pillars

Premise: commercial fishing out of a Southeast Alaskan sound, on Roblox. The ocean is
one shared, persistent, simulated fishery; the economy falls out of population
dynamics rather than scripts.

1. **Scarcity is real.** Every fish anyone catches is removed from a finite stock,
   and price is derived from global abundance alone (`src/Shared/Market.luau`).
   Nobody scripts a shortage; overfishing produces one.
2. **The AI proposes, the simulation arbitrates.** A language model authors new
   fishing grounds; nothing it emits exists until deterministic validation repairs
   it and the population model decides what actually lives there
   (`src/Shared/Ocean/BankSpec.luau`, `OceanSim.luau`).
3. **Seamanship is the mechanic.** The tide is the clock: it gates where a boat can
   go and how well the water fishes (`src/Shared/Tide.luau`). No invented puzzles.

Market position: steal-and-collect is cloned to death; occupational authenticity
(`Karinderya!`, ~91K CCU) and AI-as-gameplay (Dream Racers, Sept 2026) are both
validated; no ocean sim is in Roblox's top 25. This game is a bet on all three
observations at once — which is also three risks at once (§8).

## 2. The core loop

**Minute to minute.** Read the tide (broadcast every 5 s, `OceanService`), pick an
accessible ground, pick a species and a depth inside its band, fight the fish,
get paid at the market price. The fight is one button — hold to reel (tension
rises), release to give (tension bleeds, ground lost); land it before tension
hits 100 (`src/Client/Casting.client.luau`). Difficulty 1–5 changes the character
of the fight, not a damage number: stamina runs `1.0 + 0.42·(difficulty−1)`, pull
`0.34` per level, so a herring is over immediately and a yelloweye is a genuine
contest. The client computes only *performance* (depth quality × 0.45 + tension
discipline × 0.55) and sends intent; every outcome number is computed server-side
(`src/Server/CastService.server.luau`).

**Hour to hour.** Rotate grounds as abundance falls; follow prices (every catch
nudges them); fish a run window; discover newly composed banks.

**Day to day.** Salmon runs swell then collapse grounds on the calendar; the market
recovers where everyone left; new banks arrive each odd sim month. The engine is
negative feedback — fishing a ground makes it poorer and its species dearer, which
pushes players elsewhere (§5).

## 3. The day shape

Three clocks run at once, tuned at different speeds. All cadence numbers here are
tuning levers (`Config.HOURS_PER_DAY`; `TICK_INTERVAL` in `OceanService`), not
measured play values — nothing has been playtested.

| clock | real-time pace (Roblox server) | what it shapes |
| --- | --- | --- |
| tide | 1 in-game hour / 20 s → full cycle ~8 min | which ground is fishable *now* |
| month | ~32 min | run windows, composition rounds |
| year | ~6.4 h (9.6 h on the worker's 1 tick/min cron) | the run calendar |

**On login**, the first `OceanSync` delivers the tide state and per-ground
access/quality — "where can I go right now" is answered within seconds.

**The ~6-hour pull** is the market and the biology: prices drift toward scarcity
targets on every tick while you are away, and a ground you thinned yesterday is
restocking (logistic growth plus run inflow). Coming back has information value.

**The 24-hour pull** is the calendar: run windows opening and closing (a closing
run is a real deadline), and the composition round that adds banks on odd sim
months (~hourly at current pace).

Honest caveat: as tuned, the tide is a *session* rhythm, not a daily appointment —
slack water arrives somewhere every couple of real minutes, in windows lasting
seconds, deliberately (`OceanService` wants a tidal cycle to pass "over a couple
of minutes of play"). The appointment feel — the good shoal fishable only at
4 pm — needs a clock an order of magnitude slower, trading against in-session
liveliness. Unresolved (§11).

## 4. Progression

The gear table exists (`Types.Gear`, `src/Shared/Types.luau`) and **is not wired
up**: the client never sends `gearId`, so `CastService.gearEffortFor` falls back
to the handline for everyone, and nothing checks `price` or `unlockLevel`. The
design below is a proposal built on those numbers.

| gear | effort | price | level | role |
| --- | --- | --- | --- | --- |
| Handline | 6 | 0 | 1 | starting gear |
| Fishing Rod | 14 | 250 | 2 | first purchase |
| Barbed Hook | 22 | 1,200 | 5 | mid-tier |
| Crab Pot | 30 | 4,200 | 7 | specialisation |
| Longline Rig | 38 | 6,500 | 9 | volume fishing |
| Trawler Gear | 60 | 28,000 | 14 | deep-water industrial |

What gear does: `effort` is the *ceiling* on what one cast may take, and the take
is further capped at 12% of the ground's capacity (`MAX_HARVEST_FRACTION`) no
matter what. What gear does not do: it does not touch price (scarcity does), the
weight roll (performance does), or rare chance (performance and abundance do).
Those separations are the design.

**Why the handline keeps a place.** First, skill multipliers are gear-independent:
the tide scales everyone's effort by 0.25–1.0 (`OceanService.harvest`), so a
handliner at dead slack beats a trawler in a ripping current. Second, the cap
binds where the fish is precious: on an ideal yelloweye reef (capacity ≈ 405),
the 12% ceiling is ~49, so the trawler's 60 effort buys 49 — the tier gap
compresses exactly on the high-value grounds. Third, *proposed, not built*:
draught gating — access is already depth-based (`TIDE_MIN_DRAUGHT` = 1.8 m); tie
gear tiers to draught so shallow shoals, reachable only in high-water windows,
stay handline-and-rod water. That niche is exclusive timing, not superior
quality — deep grounds always fish at full depth margin (`Tide.fishingQuality`).

Levels and currency: propose skipper levels from logged landings, purchases gated
server-side by level plus currency. Income exists — `floor(yield · price / 10)`
per catch (`CastService`) — but there is no sink until purchases are wired, and
ownership checks are mandatory before this ships: today the server trusts the
client's `gearId` unchecked.

**Command angle.** The "command" genre is rising and this game already has the
substrate: the information layer (tide, market direction, contested flags,
`RegionDiscovered`) is broadcast shared state. Propose Skipper mode: one player
holds the chart and dispatches a crew to grounds; the crew fights the fish. The
skipper plays the deepest existing system; nothing new is simulated. It is a
proposal, and first on the cut list (§12).

## 5. Economy rules

The loop, pinned by tests in `tests/economy-tests.luau` and `tests/run-tests.luau`:

> fish a ground → region stock falls → global abundance falls → scarcity
> multiplier climbs → price climbs → players reroute → the fished ground recovers

The formulas (`src/Shared/Market.luau`, `src/Shared/Config.luau`):

- Global abundance `a = Σbiomass / Σcapacity` over all regions
  (`OceanSim.globalAbundance`).
- Scarcity: `M(a) = clamp(1 / (0.15 + 0.85·a), 1, 6)`. The asymptote `1/0.15 ≈ 6.67`
  sits just above the 6.0 cap so the cap is reachable, not dead configuration.
- Target price `= baseValue · M(a)`; each update moves the price 18% of the way
  there (`PRICE_INERTIA = 0.82`).
- One cast: `take = min(effort, 0.12·K)`; `yield = take · (0.25 + 0.75·abundance)`;
  `value = floor(yield · price / 10)`.
- Per tick: logistic growth `r·B·(1−B/K)`, recovery ×0.6 below 25% abundance,
  extirpation floor at 2% of K, ceiling 115% of K; during a run, inflow
  `K · 0.85 · runStrength · 0.35 · jitter`.

What a designer should tune, and how each lever breaks:

| lever | value | how it breaks |
| --- | --- | --- |
| `MAX_HARVEST_FRACTION` | 0.12 | must measure against **capacity**, not stock — against stock, yield decays quadratically and collapse becomes unreachable (the historical bug, now a test) |
| `MIN_YIELD_FACTOR` | 0.25 | to 0: camping empty grounds; to 1: no reason to rotate |
| `SCARCITY_FLOOR` / `MAX_SCARCITY_MULTIPLIER` | 0.15 / 6.0 | unbounded curve makes wipe-it-and-farm-the-rebound optimal |
| `PRICE_INERTIA` | 0.82 | too low: unreadable ping-pong; too high: market ignores runs |
| `COLLAPSE_THRESHOLD` / penalty | 0.25 / 0.6 | too harsh: grounds never come back; too soft: no cost to collapsing |
| `CONTEST_THRESHOLD` | 0.05 | too low: everything reads contested; too high: the social signal never fires |

Two standing rules. Change `Config.luau`, never inline — and change
`worker/src/config.ts` in the same commit: the parity vectors
(`shared/economy-vectors.json` from `tests/generate-vectors.luau`) exist because
the worker once shipped a `1/abundance` curve matching neither Luau version while
its own suite stayed green. One cadence caveat: `Config`'s comments describe price
inertia "per day", but `refreshMarket` runs on every tick and after every harvest,
so prices settle over minutes, not days. Retune knowingly.

## 6. The AI content loop

**What the model authors:** a bank's name, habitat (one of six), depth, richness,
salinity, one hazard from an eight-item whitelist, and a 2–5 entry species mix.
That is the entire surface. Defaults: Llama 3.3 70B via Workers AI, JSON mode,
temperature 0.8, 25 s budget (`worker/src/composer.ts`). Cadence: 2 banks per
round (`BANKS_PER_ROUND`), triggered by `OceanService` on odd sim months; the
endpoint never fails and never returns empty — any shortfall fills
deterministically from procedural generation.

**What the simulation does with it** (`BankSpec.validate` — repair, not reject):

| input problem | behaviour |
| --- | --- |
| unknown habitat | hard reject — guessing would corrupt world structure |
| depth outside 5–900 m | clamped, recorded as a repair |
| richness / salinity out of range | clamped |
| unknown species id | dropped from the mix |
| mix empty after drops | hard reject |
| blocked or malformed name | replaced with "Unnamed Ground" |
| everything salvageable | accepted, repairs logged |

**Why this is safe.** Validation is deterministic — same model output, same bank,
always. The species mix is never an override: `toRegion` compresses it into a
richness nudge, and `OceanSim` still derives what lives there from habitat
affinity and depth gates (out-of-band species get ×0.15 affinity). A model that
puts halibut at 5 m has authored a ground where halibut barely persist; the model
authors surface, the simulation decides truth. Names pass a blocklist plus a
character whitelist — a first line, not a substitute for Roblox's moderation.

**Failure modes.** Model drift is the live one, and the repair log is the
telemetry: a rising repair rate means the prompt is drifting (the procedural
fallback is deliberately shaped to validate without repairs so it doesn't pollute
that signal; `ComposeResult` carries `modelError` and `rejections` too). Prompt
rot: the system prompt hardcodes all 17 species ids — add a species to
`Species.luau` without editing the prompt and the model will never propose it.
And the blocklist catches obscenity, not blandness; a drifting model that names
every bank "Silver Shoal" passes validation while quietly killing the
authenticity pillar.

## 7. Social design

The PvP layer is informational. When a crew works a ground that has already lost
more than 5% of capacity this window, their result comes back `contested` and the
server tells them: "Another crew is working this ground." (Window = one sim tick
on the Roblox server; 60 s in the worker's catch log.) The consequence is already
shared through the economy — two crews thinning the same water lower the same
yield and raise the same price — so the signal is the whole mechanic.

What deliberately does not exist: no stealing catches, no gear loss, no ground
ownership or exclusion, no dueling. The reasoning (README, and it holds): stealing
from a respawning NPC base is a mechanic; two crews knowing they are fishing the
same thinning water is tension. Cooperation is emergent — rotation is
individually optimal, slack concentrates boats on the same few good grounds, and
`RegionDiscovered` is a broadcast land-rush. One gap: `Market.bestOpportunity`
exists as a shared routing hint but is not carried in `MarketSync` yet.

## 8. Retention and session length

The risk, stated plainly: this is a slower game than the steal-and-collect meta,
aimed at a player slightly older than the Roblox core, and there is no playtest
data — balance is tuned against tests, not players (README "Known gaps"). The
tide gives ~8-minute cycles and 10–20 minute sessions: good for mobile (~80% of
Roblox), weak for watch-time. No daily-login hook exists.

What mitigates it, honestly: run windows are a published calendar with hard
deadlines — urgency without grind, and August–September is a four-species derby
for free. The market gives return value: your ground restocks, and the species
you crashed drifts back toward base price. Composition rounds mean the map is
never finished; chart coverage (`Chart.coverage`) is a permanent long-tail goal.
The one-button fight is genuinely playable with a thumb. Externally, Roblox
opening standalone and browser publishing suits a deep-slow-sim audience the
core loop churns. Missing if retention matters: out-of-session notification (a
run opening, your species spiking), a home-port identity, a slower tide clock if
the appointment feel is wanted. None are built.

## 9. Monetisation

Today nothing in the codebase sells anything — no Robux, pass, or product
reference exists in `src/` or `worker/`. Everything here is proposed.

Safe lane: cosmetics strictly off the economy — liveries, cabin décor, name
plates. Sell look, never yield.

The minefield, flagged plainly: this game's premise is scarcity, and scarcity +
Robux is where Roblox policy and player trust both bite.

- **Selling gear or effort for Robux** converts money into harvest pressure on a
  shared commons — pay-to-win against every other player at once, and it
  accelerates the depletion the economy exists to make meaningful. Don't.
- **Selling fish or stock** bypasses the simulation and destroys the price
  signal. Never.
- **A player-traded market plus Robux** is the highest-risk lane: Roblox requires
  its own commerce systems, real-money trading is prohibited, and sanctioned
  trading of a scarce commodity invites fee, policy, and exploit review. There is
  no trading today; if ever added it is a day-one policy item, not a bolt-on.
- **Anything lottery-adjacent** (selling better rare-catch luck) is
  gambling-adjacent on a platform full of minors; rare rolls are earned
  (`rollRare` keys off performance and abundance), keep them that way.

Viable middle: side-grade gear variants with identical effort, chart annotation
conveniences, cosmetic season passes. All proposal; none built.

## 10. Live-ops

The salmon calendar gives the event schedule for free: chinook months 3–6, pink
7–9, coho and sockeye 8–10, chum 8–11. Spring and autumn are event seasons with
zero authored content — the biology is the event. Publish the calendar in-game;
it is deterministic.

Cadence: composition rounds (~hourly at current clock) are the content drip, and
the composer's system prompt is itself a live-ops surface — themes, hazard
emphasis, and name vocabularies are prompt edits, with repair-rate telemetry
telling you when an edit broke the model. Candidates, not built: survey seasons
upgrading chart provenance via `Chart.survey`; a "chart correction" event when
real NOAA constants (station 9451600) replace the estimated ones; price-history
leaderboards off the worker's existing per-species history.

One calendar hole, verified in code: herring's `runMonths` (3–5) are inert — run
inflow only applies to `anadromous` species and herring is not one, so the spring
herring spawn never fires. Either add a non-anadromous spawn mechanic or accept
the hole.

## 11. Open questions

1. **Per-server vs global economy.** The worker is optional and, on the harvest
   path, unused: `OceanService` calls it only for `composeBanks`; every cast is
   applied to the local `OceanSim`. Until casts reconcile against D1, scarcity is
   per-server and the "global" pillar is aspirational. Related and unresolved:
   whose clock wins — the Roblox server ticks every 20 s, the worker cron every
   60 s, a 3× disagreement about what a day is.
2. **Art budget.** Placeholder discs and labels (README). A game sold on
   authenticity needs boats, water, and weather that read as the North Pacific.
   This is the largest unbudgeted line item.
3. **The tide constants are estimated**, not measured. The harmonic amplitudes
   get the shape right; NOAA 9451600 is authoritative, and
   `TIDE_CURRENT_SLOPE_REF` must be recalibrated if real constituents drop in
   (`Config.luau` says so itself).
4. **Gear wiring.** No currency sink, no levels, no server-side ownership check;
   the wire contract (`Types.CastRequestPayload`) doesn't carry `gearId` or
   `performance` even though the client sends `performance` and the server reads
   both. The contract file and the code have drifted.
5. **Tide pacing**: session rhythm (§3) vs daily appointment — pick deliberately.
6. **Market cadence**: inertia applies per tick/per catch, not per day as
   `Config` comments imply; a settled price is minutes of play, not a day.
7. **Persistence**: no save across server restarts yet.

## 12. What to cut for a three-month ship

Cut: global-economy reconciliation (ship per-server; the compose-only worker is
already fail-soft); the survey/NOAA import pipeline (provenance labels stay, real
data waits); Skipper/command mode; all monetisation; the trawler tier and any
crab-pot soak mechanic (ship the four lower tiers as plain effort steps);
price-history UI.

Keep: the simulation + market + tide core (it *is* the game), server-enforced
gear ownership, the one-button fight with touch input, the autumn salmon runs,
and procedural-fallback composition. The test suites are the specification —
they ship with the game.
