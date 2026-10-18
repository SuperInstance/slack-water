# Roadmap — for whoever picks this up next

Written 17 October 2026 at the end of a long working session, by an agent that
built the foundation and is now handing it over. It is deliberately blunt about
what is finished, what is merely plausible, and what order to attack the rest
in.

If you read one other document, read [`STATUS.md`](STATUS.md). This one is
forward-looking; that one is the current truth.

---

## The honest headline

**The foundation is real. The game is not played.**

What exists is a genuinely working simulation — populations that reproduce and
get fished out, a market whose prices move with abundance, a tide that gates
access to the water, and an AI that invents new fishing grounds that a
deterministic simulation is allowed to reject. That is the hard part of this
project and it is done, tested, and deployed.

What does not exist is a game someone has played. The cast loop has never been
completed by a person. Mobile has never been opened. Nothing has been published.
Those are not polish items; they are the distance between a simulation and a
game, and they are where all the remaining risk lives.

Nobody should read the commit history and assume the later commits mean the
later work is more complete. They are not sequential; they are interleaved.

---

## The three gates

Everything below hangs off these. In order.

### Gate 1 — Someone plays it

**Nothing else matters until this is true.** Until a person casts a line,
lands a fish, and sells it, every statement about how the game feels is
theory.

- [ ] Play one full loop in Studio: tap the rig summary, pick a ground, pick a
      target, set depth, CAST, fight, land, keep or sell.
- [ ] Write down everything that looks wrong, even things that seem cosmetic.
      Especially things that seem cosmetic.
- [ ] Watch the server log while doing it. Several of the worst bugs in this
      project were only visible there:

      ```bash
      grep '\[slack-water\]' /mnt/c/Users/casey/AppData/Local/Roblox/logs/*_Studio_*_last.log
      ```

- [ ] Fix what breaks. Expect layout and hit-area problems; nothing in the cast
      loop has ever run in a real engine.

### Gate 2 — It has a URL

- [ ] **Enable HTTP requests first.** This blocks everything else in this gate
      and is one line in Studio's Command Bar:

      ```lua
      game:GetService("HttpService").HttpEnabled = true
      ```

      Or `File ⟩ Experience Settings ⟩ Security ⟩ Allow HTTP Requests` for a
      published experience. It cannot be set from runtime game code, and it is
      not managed by Rojo, so a fresh clone reproduces the problem.

      Without it the game logs `backend unusable (request failed: HTTP requests
      are not enabled. Enable via Experience Settings)` every composition
      round and silently falls back to procedural banks. This is the third
      distinct cause of that same symptom — see the note below.
- [ ] Publish the place. Needs a human in Studio's UI.
- [ ] Confirm the AI composer actually admits banks in a live session. The call
      signature bug is fixed and covered by a test, and the Worker is verified
      independently (`POST /banks/compose` returns `usedModel:true`), so this is
      the last link in the chain.
- [ ] Confirm persistence: restart the server and check the ocean comes back.
      Everything currently runs in-memory.

### Gate 3 — It works on a phone

Robo is roughly 80% of players. The entire HUD is designed against a 390×844
viewport and scales through a single `UIScale`, and the device emulator has
never been opened.

- [ ] Run the device emulator at 390×844 and fix what breaks.
- [ ] Confirm CAST is reachable one-handed and the rig sheet's rows and depth
      slider work by touch.
- [ ] Confirm touches on the fight readout still reel — the meters must not
      swallow input.

---

## Then, in priority order

### High

4. **Wire gear purchases.** `Progression.buy` validates level and funds but
   there is no funds owner on the server to deduct from, so locked rows
   honestly show "reached at level N · price X" with no buy button. Needs a
   server-side funds owner first.
5. ~~**Apply `OceanClient.TIMEOUT`.**~~ — resolved honestly rather than
   cosmetically. Roblox cannot cancel an in-flight `RequestAsync`, so no client
   timeout is possible. `advanceCalendar` now defers the compose round, which is
   the protection that actually works.
6. ~~**Check `contested` end to end.**~~ — resolved by populating it. The
   GROUNDS panel can now show `⚔ CONTESTED` from a real signal. Still worth a
   human eye: the flag has never been seen on screen.
7. ~~Abandoned-cast race~~ — already fixed. `Casting` is now the only listener
   on the remote and validates against a generation that increments on start
   and on cancel.

### Medium

8. **Land real Sitka bathymetry.** The pipeline is built and tested
   (`docs/BATHYMETRY.md`). It needs soundings off the machine that has them.
   Until then the chart is labelled `grown`, not `surveyed` — **that labelling
   must stay.** Never present generated bathymetry as surveyed data.
9. **Replace the Part hull with the mesh.** `art/fv_eileen/` holds the lofted
   FBX built from Casey's own photographs. Rojo cannot embed binary assets and
   Roblox cannot import FBX at runtime, so the boat ships as Parts until
   someone uploads the FBX and supplies a `MeshId`.
10. **Balance against players.** Every number in `Config.luau` is a starting
    point tuned against tests. Nothing has met a real player.

### Low

11. Replace emoji icons and placeholder art language.
12. Chat and social features, once there is anyone to chat with.

---

## Risks, stated as risks

**"The tests pass" has lied before, repeatedly.** 432 assertions passed while
the AI composer was dead in the real engine, because the harness proved the
correct `RequestAsync` signature while nothing checked that the production code
used it. Treat a green suite as necessary, never sufficient. What saved these
bugs was a screenshot or a log line, not a test.

**"It falls back to procedural banks" has now had three separate causes** — the
removed two-argument `RequestAsync` signature, and HTTP requests not being
enabled for the experience. The log message is identical for every one of them,
which is exactly why it survived so long. When you see that line, read the text
*after* `request failed:`; it names the cause, and it changed each time.

**Studio-only settings do not travel with the repo.** `HttpEnabled` is not
managed by Rojo, so it resets for anyone who clones this. Expect to re-enable
it after every fresh clone or new machine.

**The harness is a model of Roblox, not Roblox.** It is deliberately strict —
it raises on removed APIs, on type-confused property writes, on Script Security
writes — but it is still a model. `docs/HARNESS-FIDELITY.md` records what is
modelled exactly, what is approximate on purpose, and what is unverified. Read
it before extending it, and never fit the harness to the code under test.

**Mobile performance is unmeasured.** The shoreline was built as 14 parts
specifically because parts are memory Robo must hold. That reasoning has never
been checked against a real device. Measure before adding any more geometry.

**`docs/TESTING.md` and the harness will need the same scepticism the product
code received.** They were written by the same kind of process.

---

## Rules that will bite you if you break them

These are not style preferences. Each one exists because breaking it has
already cost real time.

- **`src/Shared/**` stays pure Luau.** No Roblox globals. It is the
  simulation, and it must stay runnable outside the engine.
- **`src/Shared/**` uses string requires only.** Instance-path requires
  (`require(script.Parent.Config)`) fail under Roblox's strict mode. Nineteen
  of them existed; all were converted.
- **Only `OceanService` mutates ocean state.** Everything else reads.
- **The client never computes value, price, scarcity or yield.** It renders
  what the server sends. An earlier version invented a session total on the
  client and it had to be torn out.
- **Determinism is required.** Two servers adopting the same snapshot must
  produce the same region sequence.
- **AI proposes, simulation arbitrates.** Never let model output become state
  without passing `BankSpec.validate`.
- **Never present generated bathymetry as surveyed.** The provenance fields
  exist so this is hard to do by accident. Keep it that way.
- **A test that has never been seen to fail is not a test.** Every behavioural
  fix in this project was confirmed red before it was accepted.

---

## Where the interesting code is

| Area | Path | Why you would care |
| --- | --- | --- |
| Population model | `src/Shared/Ocean/OceanSim.luau` | The actual thesis of the game |
| AI boundary | `src/Shared/Ocean/BankSpec.luau` | How model output is policed |
| Ocean ownership | `src/Server/OceanService.luau` | The only thing allowed to mutate |
| The world | `src/Server/WorldGen.luau` | Boat, water, shoreline, grounds |
| Cast loop | `src/Client/Casting.client.luau`, `CastBar.client.luau` | **Unproven. Go here first.** |
| Backend | `worker/src/` | The composer, D1 and KV |
| Harness | `tests/harness/Roblox.luau` | Strict by design; read before extending |

---

## If you only remember one thing

The simulation is sound and the backend is live. **The game has never been
played.** Put a human in front of it before optimising anything else, because
everything else in this document is downstream of what that reveals.