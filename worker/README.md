# Slack Water worker

The Cloudflare backend for Slack Water's shared ocean. Roblox servers run
`src/Shared/Ocean/OceanSim.luau` locally for smooth prediction, but this
worker's D1 database is the truth every server harvests against: one crew's
catch is every crew's scarcity. The design rule carried over from the client
unchanged — **the AI proposes, the simulation arbitrates**: nothing the model
emits reaches the world without passing the validator ported from
`src/Shared/Ocean/BankSpec.luau`.

## Setup

```bash
cd worker
npm install
```

### 1. Create the D1 database

```bash
npx wrangler d1 create slack-water-ocean
```

Copy the printed `database_id` into `wrangler.toml` (replacing
`REPLACE_WITH_D1_DATABASE_ID`).

### 2. Create the KV namespace

```bash
npx wrangler kv namespace create OCEAN_KV
```

Copy the printed `id` into `wrangler.toml` (replacing
`REPLACE_WITH_KV_NAMESPACE_ID`).

### 3. Apply migrations

```bash
# local dev (miniflare, .wrangler/state)
npm run migrate:local

# production
npm run migrate:remote
```

`migrations/0001_ocean.sql` creates the schema and seeds the reference data
(species roster, run months, habitat affinity matrix), one starting ground
per habitat stocked to 0.82·K, and a `market_prices` row per species.

### 4. Run / deploy

```bash
npm run dev        # local dev server with live D1/AI bindings
npm run deploy     # or: npx wrangler deploy
```

The `[ai]` binding in `wrangler.toml` is all the AI setup there is — Workers
AI needs no account keys, just the binding. Override the model with the
`AI_MODEL` var. Deployment includes a cron trigger (`* * * * *`) that ticks
the simulation once per minute; the cron handler runs exactly the same code
as `POST /ocean/tick`.

### Tests and typecheck

```bash
npm test           # vitest: validation, harvest math, market, tick, composer, SQL integration
npm run typecheck  # tsc --noEmit, strict
```

The integration tests apply the real migration to `node:sqlite` and replay
the exact D1 statement plans, pinning the SQL rendering of the simulation to
the TypeScript port to floating-point tolerance.

## API

All responses are JSON. Mutation endpoints take JSON bodies.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | `{ ok, regions, species, version }` |
| GET | `/ocean/snapshot` | every region with its stocks, plus current sim month/day/tick |
| POST | `/ocean/harvest` | apply catches (see below) |
| POST | `/ocean/tick` | advance the simulation (cron normally does this) |
| GET | `/market` | price per species with scarcity multiplier |
| GET | `/market/:speciesId` | one species' price plus history |
| POST | `/banks/compose` | propose + validate + persist new banks via Workers AI |
| POST | `/banks/validate` | validate a caller-supplied candidate, get the repaired bank |

### POST /ocean/harvest — exactly-once

```json
{
  "requestId": "5f2c…",           // required, client-generated, stable across retries
  "catches": [
    { "regionId": "r_saddle_reef", "speciesId": "rockfish", "effort": 14 }
  ]
}
```

The worker applies the deterministic rules server-side and trusts nothing
from the client: the take is capped at **12% of the region's capacity** per
event (capacity, not current stock — that is what lets sustained pressure
actually collapse a ground), and the yield factor is
**25% + 75%·abundance** so a depleted ground is poor, not pointless.

Each response includes per-catch `abundanceBefore/After`, `depleted`
(below the 0.25 collapse threshold) and `contested` (the region lost more
than 5% of capacity to other crews within the last 60s).

Idempotency: the whole request — requestId claim, stock updates, catch log
rows — commits as **one D1 transaction**. A retry with the same `requestId`
replays the stored response (header `x-idempotent-replay: true`); a
different payload under the same id gets a `409`. A crash mid-request
applies nothing, never part.

### POST /banks/compose

Asks Workers AI (default `@cf/meta/llama-3.3-70b-instruct-fp8-fast`, JSON
mode, North-Pacific-anchored system prompt that forbids inventing species
ids) for new banks, repairs each candidate through the validator
(`depth 5..900`, `richness 0.5..1.5`, `salinity 18..36` are clamped; unknown
habitat or an empty mix is rejected; unknown species are dropped), and
persists only survivors — each becoming a real region stocked at 0.82·K. If
the model returns nothing usable the endpoint falls back to deterministic
procedural generation, so it never fails and never returns an empty list.

### POST /ocean/tick

Advance up to 12 ticks (one per call is the cron cadence). If the `ADMIN_TOKEN`
var/secret is set, requires header `x-admin-token`.

## Sim time

One tick per minute: 12 ticks/day, 4 days/month, 12 months/year (the
`Config.luau` calendar), so an in-game year is 9.6 wall-clock hours and
salmon runs arrive on their real months. `calendarFromTick` in
`src/ocean.ts` is the single source for month/day.

## Keeping the ports in sync

- `src/config.ts` mirrors `src/Shared/Config.luau` — change numbers in both
  or servers desync from the worker.
- `src/species.ts` mirrors `src/Shared/Species.luau`; the same 17 species
  (and their run months) are also seeded into D1 by the migration, because
  the tick recomputes capacity in SQL.
- `src/validation.ts` ports `src/Shared/Ocean/BankSpec.luau` exactly,
  including its quirks (comma is an allowed name character; a weight of 0
  silently drops a species rather than counting it "unknown").
- `src/ocean.ts` ports the population math; the SQL in `src/sql.ts` renders
  it for D1 transactions, and `tests/integration.test.ts` fails if the two
  disagree by more than 1e-9.
