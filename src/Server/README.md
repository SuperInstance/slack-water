# Server

Everything in `src/Server/` is authoritative. The ocean has exactly one owner
(`OceanService`, house rule 3), every number a client sees is computed here,
and nothing under `src/Shared/` is ever trusted from the wire without repair.

## Files

| File | What it is |
| --- | --- |
| `Main.server.luau` | Boot order: atmosphere, simulation, worldgen, cast handling, then the RegionDiscovered rebuild hook. Deliberately thin. |
| `OceanService.server.luau` | The single owner of ocean state: the simulation loop, the market refresh, tide-gated harvesting (`Service.harvest` is the only path by which a stock changes), the periodic broadcasts, and AI bank composition with procedural fallback. |
| `CastService.server.luau` | Turns cast intent into a catch. Clamps the client's effort claim to the gear in the player's **profile** (the anti-cheat line), resolves through `OceanService.harvest`, rolls weight/rarity, credits the catch to the career via ProfileService, and answers with a CastResult. Rate-limited by `Config.CAST_COOLDOWN` to protect the shared ocean. |
| `ProfileService.server.luau` | Per-player careers: level/xp/owned/equipped gear, persisted to DataStore, replicated to that one client. All rules come from `src/Shared/Progression.luau`; this service only owns storage, replication and failure handling. |
| `Remotes.server.luau` | Creates the progression remotes (`GearRequest`, `ProfileSync`) under `ReplicatedStorage.Remotes` at runtime. They are pending `Types.luau` additions — see below. |
| `WorldGen.server.luau` | Draws the ocean from whatever the simulation currently believes. |
| `Environment.server.luau` | Atmosphere and lighting; runs first so nothing ever sees an unlit ocean. |

## The career flow

1. A player joins: an in-memory `Progression.new()` profile exists
   immediately (a cast in the first seconds resolves against a real profile,
   not a DataStore race), then the save is loaded async and swapped in —
   unless the player already landed a catch during the read, in which case
   the newer session wins.
2. A catch lands: CastService builds a `Progression.CatchRecord` from what
   the server derived (`yielded`, the **clamped** `effortUsed`,
   `abundanceBefore`, `tideQuality`) and hands it to
   `ProfileService.awardCatch`, which runs `Progression.recordCatch` — the
   xp shaping (fresh grounds out-earn picked-over ones; light tackle earns
   more per fish killed) lives entirely in Progression and is never
   re-derived or flattened here.
3. A player taps a gear row: `GearRequest` → `Progression.equip` (owned gear
   only) → the next `ProfileSync` is the answer, success or refusal.
4. On the next cast, effort is clamped to the profile's equipped gear. A
   gear claim inside the cast payload itself is ignored — the server decides
   what the player holds.

## DataStore failure policy

A DataStore outage must be survivable, not fatal: `GetDataStore`,
`GetAsync` and `UpdateAsync` are each pcall'd; a failed open degrades the
whole service to in-memory play; a failed save leaves the profile dirty for
the next autosave pass; and no `PlayerAdded`/`PlayerRemoving`/remote handler
is allowed to throw (they are pcall'd at the boundary and downgrade to a
`warn`). Autosave runs every 120 s, `PlayerRemoving` saves immediately, and
`BindToClose` flushes dirty profiles within a bounded 2 s budget.

## Pending Types.luau additions

`Types.luau` is owned by a separate change, so the progression contract is
wired at runtime by `Remotes.server.luau` and mirrored in
`GearBar.client.luau`. To fold in properly:

```lua
Types.GearRequest = "GearRequest" -- client -> server: work different owned gear
Types.ProfileSync = "ProfileSync" -- server -> client: that player's profile

export type GearRequestPayload = {
	gearId: string,
}

export type ProfileSyncPayload = {
	level: number,
	levelInto: number, -- xp into the current level
	levelNeeded: number, -- xp to the next level
	fraction: number, -- 0..1
	xp: number, -- total career xp
	currentGearId: string,
	ownedGear: { string }, -- sorted gear ids
	equipError: string?, -- why the last GearRequest was refused, if it was
}
```

`CastResultPayload` also grows four fields (all server-derived, all optional
for older fixtures): `level: number?`, `xpGained: number?`,
`unlockedGear: { string }?` (ids of gear newly reachable, not granted), and
`currentGearId: string?` (the gear the cast actually used).

## Known gaps

- **`Config.CAST_COOLDOWN` is not defined** in the current
  `src/Shared/Config.luau` even though CastService rate-limits against it;
  the constant is believed to be part of an in-flight Shared change. Until it
  lands, the first cast from a player errors inside the handler.
- **Buying gear is wired.** `ProfileService` runs the transaction across both
  stores: `Progression.canBuy` validates, `WalletService.debit` takes the
  money, `Progression.grantGear` hands over the gear. Charge precedes grant on
  purpose. `ProfileSync` carries `balanceCents` so the gear sheet can price
  against a real purse, and `equipError` is now the refusal channel for buys
  too.
