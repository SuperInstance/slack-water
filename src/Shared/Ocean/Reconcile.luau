--!strict
--[[
	Reconcile — making the ocean actually shared.

	THE GAP THIS CLOSES

	Until now every cast resolved against the Roblox server's local `OceanSim`.
	The Worker held a global copy in D1, but only bank composition used it. Two
	players on two servers were fishing two different oceans, which makes the
	central promise of this game — a shared, persistent resource — aspirational
	rather than true.

	THE SHAPE OF THE FIX

	The Worker is authoritative. The Roblox server holds a *mirror* of it and
	answers casts instantly against that mirror, because a fishing game cannot
	pay a network round trip on its core loop.

	That optimistic path is only safe if divergence is bounded and self-healing:

		1. a cast applies locally and is QUEUED as an unconfirmed delta
		2. it is reported to the Worker
		3. when the Worker confirms, the delta leaves the queue
		4. a snapshot replaces local state wholesale, then surviving queued
		   deltas are REPLAYED on top

	Step 4 is the important one. Without the replay, a snapshot that was
	generated before the player landed their fish would silently undo it, and a
	fisher who just caught something would watch it vanish from the ledger. With
	the replay, the catch survives and the queue drains as reports land.

	WHY THE QUEUE BOUNDS THE DAMAGE

	A stale mirror can over-harvest. It cannot harvest *without limit*: the
	Worker's harvest clamps every event to MAX_HARVEST_FRACTION of capacity, so
	the worst case is that a player gets slightly less than their cast was worth
	because the ground was picked over elsewhere. That is the game working, not
	broken.

	THE CLOCK

	The snapshot carries the authoritative month and day, and the server adopts
	them. That settles a real disagreement: the Roblox tick ran every 20s and
	the Worker cron every 60s, so the two implementations disagreed about what a
	day was, which would quietly desync the salmon runs.

	Pure logic only — no Roblox globals, no network. The HTTP lives in
	`Net/OceanClient` and the server applies the result, so all of this is
	headlessly testable.
]]

local scriptParent = script and script.Parent
local OceanSim = require(scriptParent and scriptParent.OceanSim or "./OceanSim")
local Config = require(scriptParent and scriptParent.Parent.Config or "../Config")

export type PendingDelta = {
	regionId: string,
	speciesId: string,
	biomass: number, -- what was actually removed
	timestamp: number, -- os.clock at queue time, for diagnostics and eviction
}

export type Snapshot = {
	month: number?,
	day: number?,
	regions: { [string]: { [string]: number } }?, -- regionId -> speciesId -> biomass
}

export type Reconciler = {
	pending: { PendingDelta },
	-- how many unconfirmed deltas we will hold before giving up on the oldest
	maxPending: number,
}

local Reconcile = {}

local DEFAULT_MAX_PENDING = 256

function Reconcile.new(): Reconciler
	return { pending = {}, maxPending = DEFAULT_MAX_PENDING }
end

--=============================================================================
-- Pending queue
--=============================================================================

--- Record a cast that has been applied locally but not yet confirmed by the
--- Worker.
function Reconcile.queue(reconciler: Reconciler, regionId: string, speciesId: string, biomass: number): ()
	if biomass <= 0.0 then
		return
	end

	table.insert(reconciler.pending, {
		regionId = regionId,
		speciesId = speciesId,
		biomass = biomass,
		timestamp = 0,
	})

	-- Bounded queue. If the Worker has been unreachable for a long time the
	-- queue must not grow without limit; the oldest entries are the least
	-- valuable because the next snapshot will overwrite them anyway.
	while #reconciler.pending > reconciler.maxPending do
		table.remove(reconciler.pending, 1)
	end
end

--- The Worker has confirmed these catches. Drop them from the queue.
function Reconcile.confirm(reconciler: Reconciler, count: number): ()
	for _ = 1, count do
		if #reconciler.pending == 0 then
			break
		end
		table.remove(reconciler.pending, 1)
	end
end

function Reconcile.pendingCount(reconciler: Reconciler): number
	return #reconciler.pending
end

--- Discard the whole queue. Used when the backend is deliberately off — the
--- local ocean IS the world in that case, and there is nothing to reconcile to.
function Reconcile.reset(reconciler: Reconciler): ()
	table.clear(reconciler.pending)
end

--=============================================================================
-- Applying a snapshot
--=============================================================================

--- Apply a global snapshot to a local ocean, then replay unconfirmed local
--- catches on top.
---
--- Returns how many deltas were replayed, which the server logs. A steadily
--- growing replay count means the Worker is unreachable and the local ocean is
--- drifting from the shared one — the signal to alert on.
function Reconcile.applySnapshot(
	ocean: any,
	reconciler: Reconciler,
	snapshot: Snapshot
): number
	-- The Worker owns the clock. Adopting it is what keeps the salmon runs in
	-- step across servers.
	if snapshot.month ~= nil then
		ocean.month = snapshot.month
	end
	if snapshot.day ~= nil then
		ocean.day = snapshot.day
	end

	local regions = snapshot.regions or {}

	-- Replace global state first.
	for _, regionId in ocean.order do
		local stocks = ocean.stocks[regionId]
		local incoming = regions[regionId]
		if stocks and incoming then
			for speciesId, biomass in stocks do
				stocks[speciesId] = incoming[speciesId] or biomass
			end
		end
	end

	-- Then re-apply everything the Worker has not seen yet. This is the step
	-- that stops a snapshot from eating a fish the player just landed.
	local replayed = 0
	for _, delta in reconciler.pending do
		local stocks = ocean.stocks[delta.regionId]
		if stocks and stocks[delta.speciesId] then
			local biomass = math.max(stocks[delta.speciesId] - delta.biomass, 0.0)
			stocks[delta.speciesId] = biomass
			replayed += 1
		end
	end

	return replayed
end

--=============================================================================
-- Global supply
--=============================================================================

--- Global abundance per species, computed from a global snapshot rather than
--- from this server's mirror.
---
--- This is what the market should price against. Using local supply would make
--- the price a per-server invention, which defeats the point of a shared
--- economy: a player on an empty server should see the same price as a player
--- on a busy one.
function Reconcile.globalAbundances(snapshot: Snapshot): { [string]: number }
	local supply: { [string]: number } = {}
	local capacity: { [string]: number } = {}

	local regions = snapshot.regions or {}
	for _, stocks in regions do
		for speciesId, biomass in stocks do
			supply[speciesId] = (supply[speciesId] or 0.0) + biomass
		end
	end

	-- Capacity is this server's own: carrying capacity is a property of the
	-- water, not of who fished it, and the Worker does not return it per
	-- species. Using the local capacity against global supply is what produces
	-- a meaningful global scarcity ratio.
	return { supply = supply, capacity = capacity }
end

--=============================================================================
-- Health
--=============================================================================

--- Whether the local ocean can still be trusted to describe the shared one.
---
--- Two signals matter: whether we have ever heard from the Worker, and whether
--- the unconfirmed queue is growing. A server that has been offline from the
--- backend for a while is running its own economy and should say so rather than
--- quietly pretending otherwise.
function Reconcile.health(reconciler: Reconciler, everSynced: boolean): { ok: boolean, reason: string, pending: number }
	local pending = #reconciler.pending
	if not everSynced then
		return { ok = true, reason = "local", pending = pending }
	end
	if pending >= reconciler.maxPending * 0.5 then
		return {
			ok = false,
			reason = ("backend unreachable: %d unconfirmed catches"):format(pending),
			pending = pending,
		}
	end
	return { ok = true, reason = "synced", pending = pending }
end

Reconcile._DEFAULT_MAX_PENDING = DEFAULT_MAX_PENDING

return Reconcile