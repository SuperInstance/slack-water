# Status — 17 October 2026

An honest map of what exists, what has been proven, and what has not. Written
so someone picking this up cold can tell in five minutes whether a thing works
because it was verified or because nobody looked.

The short version: **the simulation is real, tested, and deployed. The cast
loop has never been played. The AI composer was dead until an hour ago and has
still never run inside the game.**

---

## What this is

A Roblox fishing game where the ocean is a shared, persistent resource rather
than a respawning prop. Fish stocks reproduce and get fished out, prices move
with abundance, and every server plays the same water. The AI authors new
fishing grounds; a deterministic simulation decides whether they are allowed to
exist.

The design argument is in `README.md`. This file is about state of build, not
about whether the idea is good.

---

## Honest scoreboard

| Area | State | How it was established |
| --- | --- | --- |
| Simulation core (17 species, abundance, capacity, market) | **Working** | 432 assertions |
| Tide model, chart, reconcile/merge | **Working** | 118 assertions |
| Server boot in real Roblox | **Working** | Clean boot, 5/5 stages, in Studio |
| World generation, water surface, shoreline | **Working** | Visible in Studio |
| Cloudflare Worker + D1 | **Live** | `/health` returns `{"ok":true,...}` |
| AI composer endpoint | **Works standalone** | `usedModel:true`, real banks |
| **AI composer in-game** | **Just fixed, unconfirmed** | See below |
| **Cast → fight → catch** | **Never played** | Tests only, fake engine |
| Persistence across sessions | **Never exercised** | Studio runs in-memory |
| Mobile layout | **Never run** | Device emulator untouched |
| Publishing / live URL | **Not done** | Needs a human in the UI |

---

## Verified working

**Server boot.** A real Studio session, not the harness:

```
boot: environment ok      boot: cast service ok
boot: ocean service ok    boot: region listener ok
boot: worldgen ok
```

Four showstoppers were fixed to get here and are documented in
`docs/STUDIO-AUTOMATION.md`: `Config.CAST_COOLDOWN` missing, instance-path
requires failing under `--!strict`, `Model:SetPrimaryPart` removed,
`RemoteEvent.Event` removed, and `Lighting.Technology` being Script Security.

**The world.** Water surface on a tide, a shoreline of forested peaks ringing
the bay, grounds that dry out as the tide falls, the F/V Eileen riding the
water, and region markers labelled with real soundings.

**The ocean runs itself.** Tide advances, populations move, the market drifts.
Grounds appear as the chart fills and stop at 60.

**The backend is deployed and healthy.** D1 `slack-water-ocean`, KV `OCEAN_KV`,
Worker at `https://slack-water.casey-digennaro.workers.dev`.

---

## The two bugs worth reading about

Both were found by looking at the running game, and both would have survived a
perfect test suite. They are the argument for this project's testing approach.

**The default Baseplate was drawing over the sea.** Roblox ships every place
with a 512×20×512 grey `Baseplate` at y=0 — exactly where the tide sits. The
ocean rendered as a checkered floor and the water was invisible. No test could
have caught this; the assertion now plants a baseplate before boot so the test
has teeth.

**The AI composer had never once run.** `HttpService:RequestAsync` takes a
single options table; the two-argument form was removed. `OceanClient` used the
removed form, so every backend call failed. Both failure paths returned in
silence, so an unreachable backend looked exactly like one that was never
called. Meanwhile the harness had already modelled the correct signature and
the fidelity suite already asserted the wrong form raises — but nothing
connected the two. 432 assertions passed the entire time.

The generalisable lesson, and the reason `docs/HARNESS-FIDELITY.md` exists:
**a harness that proves an API has one shape is worthless unless a test also
asserts the production code uses that shape.** Silence is what let the second
bug survive; every fallback now prints why it fell back.

---

## Never been played

This is the honest centre of the project.

**The cast loop has never completed a cast.** `tests/cast-loop-tests.luau`
executes the entire client loop — choose ground, pick target, set depth, cast,
fight, land, keep or sell — against a fake engine. Nothing has run it in
Studio. Layout, hit areas and the feel of the fight are unproven, and the
controls have never been tried by a human.

To play it: click into the game viewport (Studio only captures the mouse after
you do), tap the rig summary at the bottom, pick a ground and a target, press
CAST, then hold left mouse or Space to reel and release to give line.

**Persistence has never run.** In Studio both ProfileService and Wallet fall
back to in-memory because DataStore is unavailable. The reconcile and merge
logic is well tested; that it survives a real restart is untested.

**Mobile has never been run.** The whole HUD is designed against a 390×844
phone and scales through one `UIScale`, but the device emulator has never been
opened. Robo is roughly 80% of players, so this is the largest untested surface
in the project.

---

## Known gaps

Kept honest: items that were open when this file was first written and have
since been fixed are marked, not quietly deleted.

**Fixed since first written:**

- ~~**Default Roblox chrome** overlaps the HUD.~~ — `Main.server.luau` now
  disables Chat, PlayerList, Health, Backpack and EmotesMenu at bootstrap.
  (An earlier attempt silently disabled nothing because `CoreGui` is not a
  member of `CoreGuiType`; selene caught it before it ever reached Studio.)
- ~~**The tide gate cannot bite.**~~ — the original diagnosis blamed the
  species roster and was wrong. No ground could ever dry because
  `Regions.DEPTH_RANGE` bottomed its shallowest habitat at 5 m while the
  threshold is 3.83 m. The mechanic was unreachable for a geographical reason,
  and estuaries now reach 1.5 m.
- ~~**A late CastResult after an abandoned resolve still shows its card.**~~
  — `Casting` is now the only listener on the remote and validates against a
  generation that increments on start *and* cancel; HUD and CatchCard take the
  outcome from the shared bus.

**Still open:**

- **The cast loop has never been played by a person.** This remains the
  largest unknown in the project.
- **Buying gear is not wired.** `Progression.buy` validates level and funds but
  there is no funds owner to deduct from. Locked rows honestly show
  "reached at level N · price X" with no buy button.
- **`contested` always arrives empty** — GROUNDS can never show `⚔ CONTESTED`.
- **`run` and `market` toasts never fire** — no server code sends those kinds.
- ~~**`OceanClient.TIMEOUT` is declared but never applied.**~~ — the comment
  now says plainly what it is and is not: Roblox exposes no way to cancel an
  in-flight `RequestAsync`, so no timeout is possible from this side. The real
  mitigation is structural and now exists: `advanceCalendar` defers the compose
  round, so a slow model cannot stall the heartbeat that started it.
- **The AI composer has still not admitted a bank in a live session.** The call
  signature bug is fixed and covered by a test, and the Worker is verified
  independently, but Roblox blocks the call itself:
  `HTTP requests are not enabled. Enable via Experience Settings`. For an
  unpublished experience this is enabled from Studio's Command Bar with
  `game:GetService("HttpService").HttpEnabled = true` — it cannot be set from
  runtime game code, and Rojo does not carry it, so it resets on a fresh clone.
- **Mobile has never been run in the device emulator.**
- **Persistence has never survived a restart** — Studio runs in-memory.

---

## Where a new developer should start

In this order, because each one unblocks something else.

1. **Play the cast loop once and write down what breaks.** This is the largest
   unknown in the project and it is cheap. Everything else is verified; this is
   not.
2. **Publish the place.** Until it has a URL, nobody but Casey can play it,
   and every subsequent finding costs a Studio round trip instead of a link.
3. **Run the device emulator at 390×844.** Mobile is 80% of the audience and
   completely unexercised.
4. **Wire gear purchases** — needs a funds owner on the server first.
5. **Land real Sitka bathymetry.** The pipeline is built and tested
   (`docs/BATHYMETRY.md`); it just needs soundings off the machine that has
   them. Until then the chart is honestly labelled `grown`, not `surveyed`, and
   that labelling must stay.
6. **Apply `OceanClient.TIMEOUT`.**

---

## Running it

**Requirements:** Rojo, a Roblox Studio install, and the Rojo plugin.

```bash
rojo serve default.project.json     # in the project root
```

Then connect the Rojo plugin in Studio (it listens on `localhost:34872`) and
press Play. No build step, no bundler — Rojo maps `src/` straight into the
DataModel.

**Tests.** Everything, including the headless boot harness that executes the
real server boot path against a modelled Roblox:

```bash
./tests/run.sh          # 432 assertions, 11 suites
./scripts-check.sh      # tests + lint
```

**Backend.** Deployed and live. `curl https://slack-water.casey-digennaro.workers.dev/health`
should return `{"ok":true,"regions":10,"species":17}`.

**Studio automation.** `tools/win/` can start and stop play sessions from a
shell (keyboard only — clicking never worked, and `docs/STUDIO-AUTOMATION.md`
explains why). Useful for reading the server log without a human present:

```bash
grep '\[slack-water\]' /mnt/c/Users/casey/AppData/Local/Roblox/logs/*_Studio_*_last.log
```

That log is the ground truth. Several bugs above were found there rather than
in a test.

---

## Architecture in one paragraph

`src/Shared/**` is pure Luau with no Roblox globals — the simulation, the
market, the tide, the chart. `src/Server/**` owns all mutation of ocean state
and is the only thing allowed to write to it. `src/Client/**` never computes
value, price, scarcity or yield; it renders what the server sends. The Worker
proposes banks over HTTP; `BankSpec` validates every candidate against
deterministic rules before admission, and the population model decides what
actually lives there.

Two rules that will bite anyone who breaks them: `src/Shared/**` must stay pure
Luau and use string requires only, because instance-path requires fail under
Roblox's strict mode. And generated bathymetry must never be presented as
surveyed data.

---

## Documentation index

| Document | What it covers |
| --- | --- |
| `README.md` | The design argument and why this game should exist |
| `docs/DESIGN.md` | Game design in detail |
| `docs/OCEAN.md` | Population model, capacity, scarcity |
| `docs/PLAYLOOP.md` | What a player does, minute to minute |
| `docs/CASTING.md` | The cast loop and the tide gate arithmetic |
| `docs/WALLET.md` | Money, keep-or-sell, persistence |
| `docs/BATHYMETRY.md` | Chart provenance and the survey pipeline |
| `docs/TESTING.md` | How the test suite is organised |
| `docs/HARNESS-FIDELITY.md` | What the fake Roblox does and does not model |
| `docs/STUDIO-AUTOMATION.md` | Driving Studio from a shell, and what fails |
| `docs/WORKLOG.md` | This session: what was done, what it proved, and token use |
| `docs/ROADMAP.md` | What to do next, in what order, and what to avoid breaking |