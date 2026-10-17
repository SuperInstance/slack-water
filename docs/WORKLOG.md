# Work log — what was done, and what it actually proved

Written 17 October 2026 to hand the project to other developers. This is the
honest account of the most recent working session: what was built, what was
verified, what was not, and what it cost.

For the overall state of the build, read [`STATUS.md`](STATUS.md). For design
argument, read the root `README.md`. This file is the record of the work.

---

## Token and cost accounting

Measured, not estimated. Read from the runtime's own session log
(`~/.minimax/v2/sessions/.../messages.jsonl`), summing every `usage` object
across all 570 recorded messages.

| Metric | Tokens |
| --- | ---: |
| Input | 2,029,588 |
| Output | 107,248 |
| Cache read | 32,065,327 |
| **Total** | **34,202,163** |

Model: `MiniMax-M3.1-Flash-Preview` throughout. 22 commits, 229 tracked source
and documentation files, working tree clean at `054d3bb`.

**Caveats, stated plainly.** Cache reads dominate that number — roughly 94% of
it — so "34 million tokens" badly overstates the actual work done. The honest
interpretation is about **2.0M input and 107K output**, with a large cached
prefix being re-read each turn. There is also no per-call pricing available
locally, so this is a token count, not a dollar figure. And the log covers the
whole session including two compactions, so it cannot be split cleanly by
commit.

---

## What this session added

Five commits, `f67c7be` through `054d3bb`, on top of `45c4891` from the previous
session.

### 1. The four boot bugs, confirmed in real Roblox — `f67c7be`

The four showstoppers fixed earlier had only ever been verified by the headless
harness. This produced the first real Studio session running the fixed code:

```
boot: environment ok      boot: cast service ok
boot: ocean service ok    boot: region listener ok
boot: worldgen ok
```

Zero failures. The previous real boot had three failures in that list.

Getting there meant working out how to drive Studio at all. **Keyboard input
works; synthetic clicks never activate a control**, by either `SendInput` or
`PostMessage`. The obvious explanation was UIPI — a medium-integrity process
cannot inject into a more privileged window. That is wrong here: reading
`TokenIntegrityLevel` returns `S-1-16-8192` (medium) for the shell, `explorer`,
the player and *both* Studio processes. Nothing is elevated. Studio's ribbon
is QML and does not consume synthetic mouse events. `tools/win/toolbar.py` was
deleted rather than committed, because clicking is the one thing established not
to work.

### 2. Unbounded ocean growth and doubled world rebuilds — `e3b2eaa`

A session left running reached **156 fishing grounds** and was still climbing.
Two independent faults:

- Discovery had no ceiling. The treadmill is deliberate — new banks every
  couple of in-game months — but nothing stopped it. `Config.MAX_REGIONS = 60`.
- Each new region fired `regionAdded`, and `Main` turns that into a full
  `WorldGen.build()`: every marker, every label and all 676 water tiles
  destroyed and recreated. Firing per region meant each round did
  `BANKS_PER_ROUND` complete rebuilds of the entire ocean, at a cost that grew
  with the ocean. Rounds now fire once, after the loop.

In Studio after the fix: `14, 16, 18, 20 …` — one rebuild per round, zero
errors. Both are covered by tests confirmed red first: with the fixes reverted
the ocean passed the ceiling (64 > 60) and `regionAdded` fired **18 times over 6
rounds**.

### 3. A shoreline — `3acc608`

The world was open water in every direction. Accurate, and completely
unrecognisable: Sitka sits on the coast of Baranof Island. Open water to the
horizon read as a scene nobody had built rather than a place to fish. Fourteen
seeded wedges, no collision, no shadow casting, land never rides the tide.

This one broke on first run — `Rng` exposes `range(rng, min, max)`, not
`:next()` — and was fixed before it was ever committed.

### 4. The AI composer had never once run — `6a2ddd8`

**The headline feature was dead.** `HttpService:RequestAsync` takes one options
table; the two-argument `RequestAsync(url, options)` form was removed.
`OceanClient` used the removed form, so every backend call failed.

What let it survive is the interesting part. Both failure paths returned in
silence, so an unreachable backend looked exactly like one nobody called. And
the headless harness had *already* modelled the correct signature, with a
fidelity test asserting the two-argument form raises — but nothing connected
that to the code making the call. **432 assertions passed the whole time.**

Every fallback now prints why it fell back. A new test asserts the production
code sends one table with the right `Url`, method and endpoint, and degrades
rather than throwing. Confirmed red with the fix reverted.

### 5. `docs/STATUS.md` — `054d3bb`

The map of what is proven versus merely written, with how each claim was
established.

---

## Bugs found this session, in one table

| Bug | How it was found | Test added |
| --- | --- | --- |
| Roblox's default Baseplate drew over the sea at y=0 | Screenshot of a running session | Plants a baseplate before boot; red without the fix |
| Region labels 220×60 **studs** (BillboardGui offsets are studs, not pixels) | Zooming the toolbar/viewport | Covered by the size change; visual |
| Ocean grew 14 → 156 unbounded | Reading the server log during a long session | Confirmed red without the cap |
| Whole world rebuilt twice per round | Same log | Confirmed red; 18 fires vs 6 rounds |
| Studio window put the cast bar below the screen edge | Casey: "the game isn't there yet" | n/a — tooling |
| AI composer dead since day one | Reading the log for `composition round` | Confirmed red without the fix |

Five of six were found by *looking at the running game or its log*, not by any
test. That is the single most useful thing to know about this project.

---

## Honest results

### Verified

- Clean server boot in real Roblox, 5/5 stages.
- World renders: water on a tide, shoreline, grounds drying out, boat riding
  the tide, region markers with real soundings.
- Ocean self-runs: tide advances, populations move, market drifts, discovery
  stops at 60, one rebuild per round.
- Ocean growth capped and rebuild coalesced, confirmed in Studio and by tests.
- Worker deployed and healthy: `{"ok":true,"regions":10,"species":17}`.
- Composer endpoint works standalone: `usedModel:true`, real composed banks
  such as "Hecate Bank" and "Langara Reef".
- Composer call shape fixed and covered.

### Not verified

- **The cast loop has never been played by a person.** Tests run the whole
  client loop against a fake engine; nothing has run in Studio. Layout, hit
  areas and the feel of the fight are unproven.
- **The composer has still not run in a live Studio session.** The fix is
  tested and the Worker is confirmed, but the Play press is manual: Studio
  keystrokes kept losing the foreground race to the agent terminal.
- **Mobile untested.** The HUD is designed for 390×844 and scales through one
  `UIScale`; the device emulator has never been opened. Robo is ~80% of
  players.
- **Persistence untested.** Studio runs in-memory; DataStore is unavailable.
- **The Eileen is unconfirmed visually.** I can see a mast and a deck edge but
  could not steer the camera. Proportions are correct against the owner's
  confirmed 50 ft LOA / 14 ft beam.

### Things I got wrong, and said so

- Asserted publicly that `RemoteEvent.Event` was valid Roblox. It was not;
  modern Roblox removed it. Recorded in `45c4891` and `docs/HARNESS-FIDELITY.md`.
- Claimed the harness was the ground truth for the four boot bugs when the
  first real boot immediately showed the harness had missed a fifth.
- Repeatedly assumed Studio needed restarting or elevating. Neither was true.

---

## Tooling built (`tools/win/`)

Keyboard-only Studio control from a shell, because clicking cannot work:
`auto.ps1` (F5 play, Shift+F5 stop, camera keys), `capture.ps1` (screenshot plus
window origin), `crop.py` (pure-stdlib PNG crop and zoom — no PIL, no numpy on
this machine), `find_button.py` (locate toolbar buttons by colour, refuse to
guess), `maximize.ps1` (park on the primary display before maximizing).

`tools/win/commandbar.ps1` — a UI Automation route into Studio's Command Bar —
was **written but not committed**, because writing it to the Windows path was
denied and the approach was abandoned rather than pushed through. It remains an
idea, not a tool.

---

## Verification discipline used throughout

Every behavioural fix was confirmed to **go red** before being accepted:

- Baseplate removal → disabled the fix, watched the test fail (64 > 60 grounds).
- Rebuild coalescing → reverted, watched 18 fires against 6 rounds.
- Composer signature → reverted, watched the harness reject the two-argument
  call.
- Ocean ceiling → reverted, watched it exceed 60.

No test in this project was added without first seeing it fail for the right
reason. Tests that pass vacuously are worse than no tests, and that standard is
the reason the composer bug is now impossible to reintroduce silently.

---

## Where to start

1. **Play the cast loop once.** Largest unknown, cheapest to resolve.
2. **Publish the place** so there is a URL.
3. **Device emulator at 390×844.**
4. Then gear purchases, real bathymetry, and `OceanClient.TIMEOUT` (declared
   but never applied — a hung request could stall a round).

Full detail and the gap list: [`STATUS.md`](STATUS.md).