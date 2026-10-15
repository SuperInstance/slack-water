# Testing Slack Water

Two kinds of test live in this repo, and they catch different things. If you
are about to commit, run both:

```bash
./tests/run.sh          # everything, ~seconds
./tests/run-boot.sh     # just the server boot smoke test
./scripts-check.sh      # parse + selene + tests + rojo build (the full gate)
```

## The unit suites (src/Shared)

`run-tests`, `economy-tests`, `tide-chart-tests`, `progression-tests`,
`reconcile-tests`, `client-tests` exercise the pure Luau in `src/Shared`
directly. They are fast, deterministic and the reason the simulation itself is
trustworthy — but they never execute a server. Three showstoppers shipped past
them (and past 172 passing tests) because every one of those bugs lived in the
gap between "the maths is right" and "the server actually runs":

1. six server modules were named `*.server.luau`, so Rojo made them Scripts —
   `require()` on a Script is dead code, and nothing complained;
2. `WorldGen` built the deck with `CanCollide = false` — UI worked, the
   simulation ticked, every player fell out of the world;
3. `Environment.apply()` configured a Terrain `Water` instance that nothing
   ever created — every water setting was dead code.

A unit test that passes trivially is worse than no test: it manufactures false
confidence. Hence the second kind.

## The boot smoke test (tests/boot-tests.luau)

This suite executes the **real server boot path** — `Main.server.luau`'s stage
list, world generation, the simulation loop, a player joining, and one full
cast — against a fake Roblox engine. It fails loudly, with a named assertion,
on exactly the class of bug above.

Run it on its own:

```bash
./tests/run-boot.sh
```

It is also part of `./tests/run.sh`, so the normal gate cannot pass while the
server boot is broken.

### How it works (the mechanism, not the incantation)

The standalone `luau` CLI has no Roblox globals, no `script`, and — crucially —
no file I/O, and its builtin `require` gives every module a fresh sandboxed
environment, so stubbed globals like `game` can never reach a module loaded the
normal way. The harness therefore bypasses the builtin require for everything
under `src/`:

1. `tests/run-boot.sh` feeds **every** `.luau` file under `src/Server` and
   `src/Shared` into the luau process as program arguments (`path`, `contents`
   pairs). Arguments pass through `execve` byte-exact, which is the only file
   channel the sandboxed CLI has. Each file is far below the per-argument
   limit; if the tree ever grows past the total argv limit (~2 MB) the wrapper
   fails loudly, not silently truncates.
2. `tests/harness/Runner.luau` compiles each module with `loadstring` and gives
   it an environment via `setfenv`: the Roblox stubs from
   `tests/harness/Roblox.luau` as globals, a fake `script` instance, and
   everything else falling through to the real standard library. Modules are
   cached by path, so identities are stable (OceanService's singleton depends
   on it).
3. The custom `require` in that environment maps fake instances back to
   embedded paths — `require(script.Parent.OceanService)` and
   `require(Shared.Ocean.OceanSim)` resolve exactly as they do in Studio — and
   also resolves Studio-style relative strings (`"../Config"`), which the
   dual-target idiom falls back to.
4. The fake DataModel mirrors `default.project.json`:
   `ServerScriptService.Server <- src/Server`, `ReplicatedStorage.Shared <-
   src/Shared`.

Time is deterministic: nothing runs on a wall clock. `task.spawn` runs
coroutines until their first `task.wait` and parks them (a parked loop is a
parked loop — the test decides when to pump `RunService.Heartbeat` and when to
flush the `task.defer` queue). Two runs of the suite are byte-identical.

### What it asserts

- Every stage of `Main.start()` completes. Main wraps stages in pcall and only
  *prints* failures; the harness tees every print/warn the server makes and the
  suite scans that capture, so a failed stage fails the test instead of
  scrolling past.
- After `WorldGen.build`: the deck is solid (`CanCollide`/`Anchored`), a spawn
  exists, a rescue sea floor exists, one marker model per simulated region, no
  NaN anywhere in a CFrame, and solid collidable ground near the origin.
- The ocean has a **water surface** (a Terrain `Water` child, parts of
  `Enum.Material.Water`, or OceanSurface's transparent tile grid). This is the
  assertion written to pin showstopper #3; it was red against the live tree
  when it was written, and the fix (OceanSurface) landed while the suite was
  being built.
- The market priced every species, all remotes exist, the first OceanSync
  broadcast went out.
- Pumped heartbeats tick the simulation; day-one composition grows the ocean
  and broadcasts `RegionDiscovered`; the built world then catches up.
- A joining player gets a join time, a placement above the boat, a profile and
  a `ProfileSync`; one cast produces exactly one `CastResult` and career credit;
  and **no background task or event handler ever errored**.

### What it does NOT simulate (the honesty section)

- **No rojo.** The `*.server.luau` → Script vs ModuleScript bug class (showstopper
  #1) is about name→instance mapping, which only rojo/Studio perform. The
  harness loads files by explicit path, so a mis-named module still loads here.
  `rojo build` in `scripts-check.sh` is the check for that class; the smoke test
  cannot catch it.
- **No physics.** "Solid under the player" is asserted by reading
  `CanCollide`/`Anchored`/CFrame, not by simulating a fall. A stack of parts
  that is collidable-but-weird could still pass.
- **CFrame tracks position only.** Composition adds positions — exact for every
  expression in this repo (rotations are only built with zero position via
  `CFrame.Angles` and multiplied in once, on the right), but a future
  rotation-dependent expression would get a wrong `LookVector` silently.
- **No scheduler fidelity.** Deferred tasks run only when the test flushes;
  waiting loops park forever. Ordering is deterministic but not Roblox's
  ordering.
- **No network, by design.** `HttpService:RequestAsync` always errors, so the
  Cloudflare Worker is permanently "down" and the locally-simulated-ocean
  degradation path is what runs. A backend bug cannot be caught here.
- **No persistence.** DataStores answer every read with nil (the
  Studio-without-API-access path).
- **No clients.** `FireAllClients`/`FireClient` are recorded, never delivered.
  What the client does with a payload is `client-tests`' territory.

### Known-red policy

The boot suite is allowed to be red — that is it doing its job. As of
2026-10-14 it pins two live server bugs (found by the suite itself):

- `Main.server.luau` "region listener" stage fails: it calls
  `RemoteEvent:Connect(...)` (a RemoteEvent is not a signal; it should be
  `OnServerEvent:Connect`), so newly discovered grounds never get built —
  caught by the stage scan and by the world/ocean desync assertion.
- `CastService.luau:40` compares against `Config.CAST_COOLDOWN`, which
  `Config.luau` does not define — every cast throws inside the handler; in
  Studio Roblox swallows remote errors, so the symptom is "casts silently do
  nothing".

When you fix those, the suite goes green with no test changes. If you add a
*new* known-red, write it here and say why, in the same way.

### Adding assertions

Put them in `tests/boot-tests.luau`, following the existing suites: reach into
`roblox.workspace` / `roblox.services` / `runner.captured` and assert on the
instance tree. If you need a new engine surface (a service, an instance method,
a datatype), add it to `tests/harness/Roblox.luau` — and if you stub something
with behaviour, say in a comment what the behaviour is and why it is honest.
