# Harness fidelity — `tests/harness/` vs real Roblox

The headless boot harness (`tests/harness/Roblox.luau` + `Runner.luau`, driven by
`tests/run-boot.sh`) exists so the real server boot path runs outside Studio. It
is only worth anything if it rejects what Studio rejects. This file is the
honest account of where it now does, where it deliberately does not, and where
nobody has verified it against anything.

Rule of thumb for future changes: **if you make the harness agree with the code
instead of with Roblox, you are reintroducing the disease this file documents.**
The boot suite's "harness fidelity" suites pin the strictness itself, so a
regression toward rubber-stamping is red, not silent.

---

## 1. The four confirmed divergences — status

Of the four known-fitted behaviours, only the first had actually been removed
from the stub when this audit started; the other three were still live and are
completed here.

| # | Old stub behaviour | Real current Roblox | Status |
|---|---|---|---|
| 1 | `RemoteEvent.Event` existed (grown to satisfy broken code) | No `Event` member; only `OnServerEvent`/`OnClientEvent` signals and `FireServer`/`FireClient`/`FireAllClients` methods (per the current API docs) | Removed, inert `if self.Event then ...` dead branches in `FireAllClients`/`FireClient` deleted, pinned by a fidelity test |
| 2 | `Model:SetPrimaryPart(part)` accepted | `PrimaryPart` is a plain property; no such method (Studio: `SetPrimaryPart is not a valid member of Model "..."`) | Method absent from the registry so it raises the Studio error; harness's own `makeCharacter` uses the property form; pinned |
| 3 | `Lighting.Technology = x` silently stored | Script Security write; Studio: `The current thread cannot write 'Technology' (lacking capability)` | Write raises with that exact message; pinned |
| 4 | Dot-access to a missing child returned nil, so `require(script.Parent.X)` fell through to a string fallback | Indexing an Instance for an absent child is an error: `Config is not a valid member of Folder "Ocean"` | Missing member/child reads raise; pinned end-to-end through the Runner with a probe module |

Each was also re-proven by deliberate reintroduction (bug planted in the real
source, suite run, bug reverted byte-exact); transcripts are in §5.

## 2. Divergences found in this audit and corrected

Beyond the four known ones, the audit found these places where the stub was
more permissive than Roblox (or modelled a different API):

1. **`Lighting.PropertyChangedSignal` was a fitted fake property.** Real
   Lighting has no such property; the API is the `GetPropertyChangedSignal(prop)`
   *method* on every Instance. The fake property hid
   `src/Server/Environment.luau:65` using the nonexistent member (game bug,
   §6). Removed; `GetPropertyChangedSignal` is now implemented for real.
2. **Any property could be set on any class.** Setting `CFrame` on a Folder or
   `Text` on a Part silently "worked". There is now a per-class member registry
   (`CLASS_SPECS` in `tests/harness/Roblox.luau`); unknown members raise
   `X is not a valid member of Class "Name"` on read AND write.
3. **Property writes were not type-checked.** `part.Anchored = 5` was accepted.
   Now raises `unable to assign property Anchored. boolean expected, got number`
   for every property in the registry.
4. **`GetPivot`/`PivotTo` existed on every Instance, including Folders.** In
   Roblox they are PVInstance members. Worse, `GetPivot` read `.PrimaryPart`
   unconditionally — not a valid member of a real Part — and `PivotTo` never
   moved a childless Part, so the spawn-rider (WorldGen registers the
   SpawnLocation with `OceanSurface.ride`) never actually floated in the
   harness. Both now dispatch correctly: models pivot via stored
   pivot/PrimaryPart and translate descendant parts; parts pivot via their own
   CFrame.
5. **`RemoteFunction` was stubbed with `OnServerEvent`/`OnClientEvent`
   signals.** A RemoteFunction has none; it has `OnServerInvoke`/`OnClientInvoke`
   callback properties. Reading `rf.OnServerEvent` now raises. (Nothing in the
   boot path uses RemoteFunction.)
6. **`HttpService:RequestAsync(url, options)` was accepted.** The real API is
   `HttpService:RequestAsync(options)` — one table carrying `Url`, `Method`,
   `Headers`, `Body`. The two-argument form is fitted to
   `src/Shared/Net/OceanClient.luau` (game bug, §6). The stub now enforces the
   real signature and then fails every request (no network — that property is
   under test).
7. **`Instance.new` accepted any class string**, including typos and abstract
   bases. Now validated against the registry; unknown classes and abstract
   bases (`BasePart`, `PVInstance`, `Instance`) raise.
8. **`Destroy` did not lock `Parent` and left descendants alive.** Real Destroy
   locks the Parent (`The Parent property of X "Y" is locked`) and destroys all
   descendants. Both modelled.
9. **`typeof` was the CLI's** — fake instances reported as `"table"`. The
   Runner's module environments now get a Roblox-shaped `typeof`
   (`"Instance"`, `"Vector3"`, `"CFrame"`, `"Color3"`, `"UDim2"`, `"EnumItem"`,
   passthrough otherwise).
10. **`FindFirstChild(name, recursive)` silently ignored `recursive`**,
    returning non-recursive results. Implemented.
11. **`Signal:Connect` accepted anything** and connections had no live
    `Connected`. Connect now requires a function; connections expose
    `Connected` and are read-only.
12. **Datatype gaps that worked only by accident.** `rider:GetPivot() +
    Vector3.new(...)` resolved through `Vector3.__add` and produced a *Vector3*,
    which only worked because `PivotTo` read `.X/.Y/.Z`. `CFrame.__add(CFrame,
    Vector3)` now exists and returns a CFrame, and `PivotTo` validates its
    argument is one. `Vector3` gained `__mul` (scalar) and `Magnitude`/`Unit`.
13. **`game` property reads were impossible** (`game.Workspace` returned nil).
    Real DataModel exposes services as properties; now the known services
    resolve and anything else raises `X is not a valid member of DataModel
    "game"`. `game` itself is read-only.
14. **Parent writes were unvalidated.** Now refuse non-Instance values and
    parenting an Instance to itself or its descendant.

## 3. Deliberate divergences (approximate ON PURPOSE — do not "fix" silently)

These are harness decisions that differ from Roblox for good reasons. Each one
is a trade, documented here so nobody mistakes the harness for a simulator:

- **`WaitForChild` on a missing child raises immediately.** Real Roblox yields
  forever (with an "Infinite yield possible" warning after ~5 s). A harness that
  hangs proves nothing; an error names the missing child and the incomplete tree.
- **Unset properties read as `nil`, not class defaults.** Real `part.Transparency`
  is `0` before you write it; here it is `nil`. This is what lets the boot tests
  detect dead tuning code ("was ever set at all"). Consequence: code relying on a
  Roblox default sees nil here. Falsy-ness matches for booleans; numeric use of
  an unset property would error in the harness while working in Studio.
- **`sentToAll` / `sentToPlayers` on RemoteEvent are harness telemetry**, not
  Roblox members: the outgoing-fire log the test files assert on. Read-only
  from Luau, pre-installed as empty tables. The one deliberate naming
  compromise (co-owned test files read them).
- **`HttpService` requests always fail** ("no network in the boot smoke test")
  and `JSONDecode` always raises (unreachable while requests fail — it is NOT
  stubbed, unlike the real offline-capable JSONDecode).
- **DataStores answer synchronously**: reads nil (Studio-without-API-access
  degradation), `UpdateAsync` runs the transform inline. No yields, no retries,
  no persistence.
- **`task.wait` parks forever; nothing resumes it.** Time advances only when the
  test fires `RunService.Heartbeat` and flushes the `task.defer` queue.
  `task.spawn` runs synchronously. `task.delay`/`task.cancel`/`task.clock` do
  not exist (any use errors — fail-safe, not fidelity).
- **`RunService`: only `Heartbeat` is driven** by tests. `PreSimulation`/
  `PostSimulation` exist as signals but nothing fires them. `IsServer()` /
  `IsClient()` / `IsStudio()` answer true/false/false (a production server's
  answers, not Studio's).
- **`GetPropertyChangedSignal` fires only when the stored value changes** and
  callbacks receive no arguments. Guards recursive self-writing listeners.
  See UNVERIFIED #3.
- **`game:BindToClose` collects callbacks but nothing ever runs them** (the
  harness never "shuts down").
- **Signals record handler errors instead of surfacing them**; the boot suite's
  "no background task or event handler ever errored" test drains those records.
  Real Roblox prints them.

## 4. Structural approximations (known, accepted)

- **No physics, rendering, streaming, or replication.** Geometry is asserted
  by reading properties, never simulated.
- **CFrame is position-only.** Rotation is never tracked; `CFrame.Angles`
  returns an identity, `lookAt` records a LookVector nothing consumes,
  `PivotTo` translates without rotating. Exact for every expression in this
  repo (see the harness header for why); silently wrong for a
  rotation-dependent expression.
- **Enum auto-vivifies.** `Enum.Fake.Type` produces a token instead of raising,
  so a typo'd enum *item* (vs. a typed property expecting the right enum) is
  indistinguishable from a real one. Property writes DO check the enum *type*
  (`Material` must be an `Enum.Material` item).
- **The class registry is a subset of Roblox's.** It covers every class the
  boot path creates plus margin (`BindableEvent`, `BindableFunction`, the
  `*Value` classes, `Humanoid`, `Script`, `LocalScript` — real current API and
  the natural material for the region-listener fix, so the harness does not
  falsely reject them). Property sets per class are the properties the code
  under test actually uses plus a small safety margin, not the full documented
  set: a *read* of a real-but-unlisted property would falsely raise `not a
  valid member`. If that happens, verify the property against the Roblox docs
  and add it to the registry — do not assume the code is right either way.
- **Inheritance map** covers the classes used; gui classes are parented
  directly to `Instance` (their real chain is deeper), which only affects
  `IsA("GuiObject")`-style queries nothing makes.
- **Error message wording**: `X is not a valid member of Class "Name"`,
  `unable to assign property P. T expected, got U`, the `Technology`
  capability text, and the Parent-locked text match Studio's observed wording;
  several others are harness-worded (see UNVERIFIED).

## 5. Proof transcripts (2026-10-15)

Every claim above that the suite catches a planted bug was demonstrated by
reintroducing the historical bug in the real source, running
`./tests/run-boot.sh`, and reverting byte-exact (md5-verified):

- **Green-ish baseline** (with the two known game bugs of §6 still present):
  `passed: 46 failed: 4` — all four failures are those game bugs; all 18
  harness-fidelity tests pass.
- **Bug 1** — `Main.server.luau:94` `.Event:Connect` reintroduced →
  `[slack-water] boot: region listener FAILED -> Event is not a valid member of RemoteEvent "RegionDiscovered"`; suite red, exit 1.
- **Bug 2** — `WorldGen.luau:315` `deck:SetPrimaryPart(hull)` reintroduced →
  `[slack-water] boot: worldgen FAILED -> SetPrimaryPart is not a valid member of Model "FVEileen"`; suite red (and the world cascades: no boat, no water, no markers), exit 1.
- **Bug 3** — bare (un-pcall'd) `Lighting.Technology = Enum.Technology.Future`
  in `Environment.luau` reintroduced →
  `[slack-water] boot: environment FAILED -> The current thread cannot write 'Technology' (lacking capability)`; suite red, exit 1.
- **Bug 4** — `Chart.luau:52` reintroduced as
  `require(script and script.Parent.Config or "../Config")` (the historical
  form that asked the Ocean folder for Config) → the entire boot dies:
  `BOOT FAILED OUTRIGHT — the server boot path threw: Config is not a valid member of Folder "Ocean"`; exit 1.

After each proof the source file was restored and md5-verified identical.

## 6. Game bugs found by the audit — NOT fixed (harness's success, not failure)

These are real-code bugs that the old stub masked. They are in `src/`, which
this audit does not touch. The boot suite is RED on the first two until they
are fixed — that red is truthful: Studio has both problems too.

1. **`src/Server/Environment.luau:65`** —
   `Lighting.PropertyChangedSignal:Connect(function(property) ... end)` reads a
   member real Lighting does not have (the API is the
   `GetPropertyChangedSignal("ClockTime")` method, which the harness now
   implements). In Studio this throws
   `PropertyChangedSignal is not a valid member of Lighting "Lighting"` inside
   `Environment.apply()`, so everything after line 65 — the Atmosphere and
   Clouds blocks — never runs: the game's entire sky/atmosphere configuration
   is dead code in Studio. Main's stage pcall prints it and moves on, which is
   exactly the silent failure class this harness exists to catch. The boot
   suite reports it three ways (stage FAILED marker, no Atmosphere, no Clouds).
2. **`src/Server/Main.server.luau:93-98`** — the region listener connects
   `svc.remotes[Types.RegionDiscovered].OnServerEvent`, but the only triggers
   are `src/Server/OceanService.luau:524` and `:558` calling
   `:FireAllClients(...)`. In real Roblox a server's own `OnServerEvent`
   connections do not fire from its own outgoing fires — clients receive
   `OnClientEvent`; the server sees nothing. So discovered grounds are
   announced to clients but **never built into the world in Studio**. The old
   stub papered over this by firing a fake `.Event` from `FireAllClients`
   (with a comment claiming that was real Roblox behaviour — it is not).
   Fix direction: a server-side signal (BindableEvent or a direct callback on
   the service), or rebuild from the heartbeat when `#ocean.order` grows.
3. **`src/Shared/Net/OceanClient.luau:69-71`** —
   `HttpService:RequestAsync(endpoint, options)` uses a two-argument form the
   real API does not have; the real signature is one options table with `Url`
   inside. In Studio the call fails on argument types regardless of network
   state, so the backend is permanently unreachable from a real server. The
   failure is pcall'd and degrades to the local ocean, which is why nobody
   noticed — the game is silently always-offline in Studio. (The harness now
   raises on the wrong shape; the pcall still catches it, so nothing went red
   on this one. It is listed here because it is exactly the fitted-stub class:
   the old stub's `RequestAsync(_url, _options)` parameters were shaped by
   this bug.)

Related-but-not-a-bug: `AGENTS.md` still documents the dual-target
`require(script and script.Parent.X or "./X")` idiom as the pattern in
`src/Shared`; the tree now uses plain relative string requires
(`require("../Config")`) throughout `src/Shared`. That is fine — require-by-string
is real current Roblox (announced January 2025) — but AGENTS.md's idiom section
and its Luau-gotcha framing are stale relative to the tree. AGENTS.md is
outside this audit's files.

## 7. UNVERIFIED — nobody has checked these against real Roblox

Honesty ledger. Each entry states what would settle it.

1. **Reading `Lighting.Technology` from a script.** Writes are confirmed
   blocked (the capability error is quoted from Studio). The harness allows
   reads (returns the stored value / nil) on the assumption reads are also
   capability-blocked in Studio but nothing in the boot path reads it. Settled
   by: one Play session with `print(pcall(function() return Lighting.Technology end))`.
2. **Exact Studio wording of several error texts.** Behaviour (it raises) is
   certain from the API surface; wording is harness-authored for: unknown
   `Instance.new` class, assigning to a read-only/signal property (the real
   text likely differs), `Connect` non-function argument, `IsA` non-string
   argument, parent-cycle refusal, method-assignment refusal, `game` unknown
   member, `FireServer`-from-server. Settled by: provoking each in Studio and
   copying the text back into the registry.
3. **Whether real `GetPropertyChangedSignal` fires on same-value writes.**
   The harness fires only on change (guards recursive listeners). Settled by:
   a Studio snippet writing the same value twice.
4. **Whether `Instance.new` of a service class (`"Lighting"`, `"Workspace"`)
   errors in Studio** (services are usually fetched, not created). The harness
   permits it because the harness itself creates the service instances.
5. **`Terrain` creatable via `Instance.new` in Studio**, and the exact
   creatable/abstract split for edge classes. Harness allows `Terrain`;
   nothing in the game creates one at runtime.
6. **Real class hierarchy depth for gui/effect classes** (BillboardGui,
   TextLabel, Atmosphere, Clouds are parented to `Instance` here). Only
   affects `IsA` with intermediate class names, which nothing queries.
7. **`FindFirstChildOfClass("Water")` probe**: whether a `Water` Instance class
   exists at all in current Roblox is unverified; the harness has none and the
   boot test uses it only as a negative probe (nil expected). If the game ever
   creates one, teach the registry after checking the docs.
8. **The claim that a modified client cannot drain the fishery** is enforced
   by game code, not the harness; the harness does not model exploit traffic.

## 8. What a green run does and does not mean

A green `./tests/run-boot.sh` means: the real `Main.server.luau` booted every
stage without a printed failure, built a world with a collidable boat, a spawn,
a floor, water tiles and one marker per simulated region; the simulation ticks
and composes; a player joins, is placed, is profiled; one cast round-trips; no
background task or signal handler errored; and the harness itself passed its
fidelity suites (removed members raise, members are per-class and type-checked,
the Runner resolves exactly what Studio resolves).

It does NOT mean: physics works, the water renders on a real GPU, replication
behaves, the backend is reachable, DataStores persist, or that any error
message wording matches Studio exactly. §3 and §4 are the complete list of the
known gaps.
