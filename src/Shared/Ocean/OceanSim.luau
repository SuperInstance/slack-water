--!strict
--[[
	OceanSim — the deterministic heart of Slack Water.

	The design thesis lives here: the AI proposes banks, but *this module
	arbitrates*. Nothing the language model emits is trusted. A proposed bank is
	only admitted if it survives `validate`, and the population dynamics below
	are what actually decide whether a ground holds fish. The model authors
	surface; the simulation decides truth.

	Determinism matters more than realism. Given the same seed and the same
	sequence of calls, this produces byte-identical results — that is what makes
	the economy testable and the ocean reproducible across server restarts.

	Population model per (region, species):

		biomass += growthRate * biomass * (1 - biomass/capacity)   [logistic]
		biomass += harvest                                              [pressure]
		biomass += runInflow                                           [migration]

	The logistic term is what makes a ground finite without any developer ever
	writing a "this ground has 100 fish left" number. Combined with a shared
	global supply, a heavily fished stock collapses on its own and the market
	notices. Nobody scripts that.
]]

export type Habitat = "kelp" | "reef" | "sand" | "mud" | "open" | "estuary"

export type Stock = {
	speciesId: string,
	biomass: number,
}

export type Region = {
	id: string,
	name: string,
	habitat: Habitat,
	depth: number,
	salinity: number,
	richness: number, -- 0.5..1.5, scales effective carrying capacity
	origin: "procedural" | "composed",
}

export type HarvestResult = {
	speciesId: string,
	regionId: string,
	yielded: number,
	remaining: number,
	abundanceBefore: number,
	abundanceAfter: number,
	depleted: boolean, -- region is now below the collapse threshold
	contested: boolean, -- another crew took a significant share this window
}

export type Ocean = {
	seed: number,
	regions: { [string]: Region },
	order: { string }, -- stable iteration order
	stocks: { [string]: { [string]: number } }, -- regionId -> speciesId -> biomass
	capacity: { [string]: { [string]: number } }, -- regionId -> speciesId -> K
	harvestedThisWindow: { [string]: number }, -- regionId -> biomass taken
	tickCount: number,
	month: number,
	day: number,
}

-- Dual-target requires.
--
-- In Roblox these resolve to script instances. Under the standalone `luau`
-- interpreter `script` does not exist, so the fallback relative path is used
-- instead, which lets the simulation run headlessly in tests. Keep the two in
-- sync — the fallback is the same file at the same depth.
local scriptParent = script and script.Parent
local Rng = require(scriptParent and scriptParent.Rng or "./Rng")
local Config = require(scriptParent and scriptParent.Parent.Config or "../Config")
local Species = require(scriptParent and scriptParent.Parent.Species or "../Species")

local OceanSim = {}
export type OceanSim = typeof(OceanSim)

--=============================================================================
-- Capacity
--=============================================================================

--- A species' effective carrying capacity in a region.

--- Four things move this number:
---   1. the species' own baseline capacity
---   2. regional richness
---   3. habitat affinity — a rockfish in a reef is thriving, in a mud bottom it
---      is barely holding on
---   4. run bonus — anadromous species get extra capacity during their run
local function habitatAffinity(speciesHab: Habitat, regionHab: Habitat): number
	if speciesHab == regionHab then
		return 1.0
	end
	-- adjacent habitats are degraded but not zero
	local adjacency: { [string]: { [string]: number } } = {
		open = { open = 1.0, estuary = 0.6, kelp = 0.55, sand = 0.35, reef = 0.3, mud = 0.25 },
		estuary = { estuary = 1.0, open = 0.6, kelp = 0.4, sand = 0.45, reef = 0.25, mud = 0.5 },
		kelp = { kelp = 1.0, open = 0.55, reef = 0.5, estuary = 0.4, sand = 0.3, mud = 0.2 },
		reef = { reef = 1.0, kelp = 0.5, sand = 0.35, open = 0.3, mud = 0.25, estuary = 0.25 },
		sand = { sand = 1.0, open = 0.35, estuary = 0.45, mud = 0.5, reef = 0.35, kelp = 0.3 },
		mud = { mud = 1.0, open = 0.25, sand = 0.5, reef = 0.25, estuary = 0.5, kelp = 0.2 },
	}
	return (adjacency[regionHab] or {})[speciesHab] or 0.2
end

local function effectiveCapacity(species: any, region: Region, month: number): number
	local affinity = habitatAffinity(species.habitat, region.habitat)

	-- depth compatibility is a hard-ish gate, not a soft one
	local depthOk = region.depth >= species.minDepth and region.depth <= species.maxDepth
	if not depthOk then
		-- outside the depth band the species can barely persist here
		affinity = affinity * 0.15
	end

	local base = species.capacity * region.richness * affinity

	local bonus = 1.0
	if affinity >= 0.95 then
		bonus = bonus + (Config.IDEAL_CAPACITY_BONUS - 1.0)
	end

	if species.runMonths and Species.isRunning(species, month) then
		local strength = species.runStrength or 1.0
		bonus = bonus + Config.RUN_CAPACITY_BONUS * strength
	end

	return math.max(base * bonus, 0.0)
end

--=============================================================================
-- Construction
--=============================================================================

function OceanSim.new(seed: number): Ocean
	return {
		seed = seed,
		regions = {},
		order = {},
		stocks = {},
		capacity = {},
		harvestedThisWindow = {},
		tickCount = 0,
		month = 1,
		day = 1,
	}
end

--- Add a region and seed it to its natural carrying capacity. Regions start
--- *healthy* — an empty ocean is not interesting, and players need somewhere to
--- fish before they have earned the right to deplete something.
function OceanSim.addRegion(ocean: Ocean, region: Region): ()
	if ocean.regions[region.id] then
		return
	end

	ocean.regions[region.id] = region
	table.insert(ocean.order, region.id)

	local stocks: { [string]: number } = {}
	local caps: { [string]: number } = {}

	for _, species in Species.list do
		local cap = effectiveCapacity(species, region, ocean.month)
		caps[species.id] = cap
		-- start at a healthy but not perfect fraction so the first few days
		-- still have somewhere for populations to visibly grow
		stocks[species.id] = cap * 0.82
	end

	ocean.stocks[region.id] = stocks
	ocean.capacity[region.id] = caps
	ocean.harvestedThisWindow[region.id] = 0.0
end

function OceanSim.getRegion(ocean: Ocean, id: string): Region?
	return ocean.regions[id]
end

function OceanSim.getStock(ocean: Ocean, regionId: string, speciesId: string): number
	local s = ocean.stocks[regionId]
	if not s then
		return 0.0
	end
	return s[speciesId] or 0.0
end

function OceanSim.getCapacity(ocean: Ocean, regionId: string, speciesId: string): number
	local c = ocean.capacity[regionId]
	if not c then
		return 0.0
	end
	return c[speciesId] or 0.0
end

--- Abundance as a fraction of carrying capacity. 1.0 means thriving.
function OceanSim.abundance(ocean: Ocean, regionId: string, speciesId: string): number
	local cap = OceanSim.getCapacity(ocean, regionId, speciesId)
	if cap <= 0 then
		return 0.0
	end
	return OceanSim.getStock(ocean, regionId, speciesId) / cap
end

--=============================================================================
-- The tick
--=============================================================================

--- Advance the whole ocean one step.
---
--- `runInflow` is the anadromy event: during a salmon's run window, biomass
--- arrives at the estuary and open regions from the open ocean. It is a real
--- inflow, and it decays after the window closes — which is exactly the shape
--- of a real salmon run. That collapse-after-bounty is what makes fishing a
--- run feel urgent instead of grindy.
function OceanSim.tick(ocean: Ocean, rng: Rng.Rng): ()
	ocean.tickCount += 1

	for _, regionId in ocean.order do
		local region = ocean.regions[regionId]
		if not region then
			continue
		end
		local stocks = ocean.stocks[regionId]
		local caps = ocean.capacity[regionId]
		if not stocks or not caps then
			continue
		end

		for _, species in Species.list do
			local cap = effectiveCapacity(species, region, ocean.month)
			caps[species.id] = cap

			local biomass = stocks[species.id] or 0.0
			local rate = species.growthRate

			if cap <= 0.0 then
				stocks[species.id] = 0.0
				continue
			end

			-- logistic growth toward carrying capacity
			local growth = rate * biomass * (1.0 - biomass / cap)

			-- collapse penalty: a stock that has been fished out recovers
			-- noticeably slower than one merely at low abundance
			if biomass / cap < Config.COLLAPSE_THRESHOLD then
				growth = growth * Config.COLLAPSE_RECOVERY_PENALTY
			end

			-- Seasonal run inflow.
			--
			-- Gated on `runMonths`, NOT on `anadromous`. Those are different
			-- facts and conflating them silently killed a feature: Pacific
			-- herring aggregate to spawn in spring but do not return to
			-- freshwater, so they are `anadromous = false` with a run window —
			-- and an `anadromous` gate meant the spring herring run never fired
			-- once, for the life of the game.
			--
			-- `anadromous` stays on the species record as biology. `runMonths`
			-- is the mechanic.
			local inflow = 0.0
			if species.runMonths and Species.isRunning(species, ocean.month) then
				local strength = species.runStrength or 1.0
				-- arrival is noisy per region so two players fishing the same
				-- species in different places do not see identical numbers
				local jitter = 0.7 + 0.6 * Rng.nextFloat(rng)
				inflow = cap * Config.RUN_CAPACITY_BONUS * strength * 0.35 * jitter
			end

			local next = biomass + growth + inflow

			-- extirpation floor: a stock cannot be driven to literal zero by
			-- fishing alone, it recolonises. Without this, one over-fishing
			-- crew permanently scars a region for everyone, forever.
			if next < cap * Config.EXTIRPATION_FLOOR then
				next = cap * Config.EXTIRPATION_FLOOR
			end

			stocks[species.id] = math.clamp(next, 0.0, cap * 1.15)
		end

		-- the contention window resets each tick
		ocean.harvestedThisWindow[regionId] = 0.0
	end
end

--- Advance one in-game day.
function OceanSim.advanceDay(ocean: Ocean, rng: Rng.Rng): ()
	for _ = 1, Config.TICKS_PER_DAY do
		OceanSim.tick(ocean, rng)
	end
	ocean.day = (ocean.day % Config.DAYS_PER_MONTH) + 1
	if ocean.day == 1 then
		ocean.month = (ocean.month % Config.MONTHS_PER_YEAR) + 1
	end
end

--- Advance the full month.
function OceanSim.advanceMonth(ocean: Ocean, rng: Rng.Rng): ()
	for _ = 1, Config.DAYS_PER_MONTH do
		OceanSim.advanceDay(ocean, rng)
	end
end

--=============================================================================
-- Harvest
--=============================================================================

--- Take `effort` worth of a species out of a region.
---
--- Three rules keep this honest:
---   1. you cannot take more than MAX_HARVEST_FRACTION of the region's
---      *capacity* in one event, so no single lucky cast empties a ground;
---   2. yield degrades with abundance but never to zero — a depleted ground is
---      still worth a trip, just a poor one, so players rotate rather than
---      camp;
---   3. because the cap is against capacity rather than current stock, heavy
---      sustained pressure genuinely collapses a stock. That collapse is what
---      the scarcity economy is built on.
---
--- `effort` is the player's gear/skill term; the returned yield is what the
--- ocean could actually give.
function OceanSim.harvest(
	ocean: Ocean,
	regionId: string,
	speciesId: string,
	effort: number
): HarvestResult?
	local species = Species.get(speciesId)
	if not species then
		return nil
	end

	-- An unknown region is a programming error, not a gameplay outcome, so it
	-- surfaces as nil rather than a silent zero.
	if not ocean.regions[regionId] then
		return nil
	end

	local cap = OceanSim.getCapacity(ocean, regionId, speciesId)
	local biomass = OceanSim.getStock(ocean, regionId, speciesId)

	local abundanceBefore = if cap > 0.0 then biomass / cap else 0.0

	if cap <= 0.0 then
		-- The region exists, but this species cannot live here at all.
		return {
			speciesId = speciesId,
			regionId = regionId,
			yielded = 0.0,
			remaining = biomass,
			abundanceBefore = 0.0,
			abundanceAfter = 0.0,
			depleted = true,
			contested = false,
		}
	end

	-- requested vs what is actually available
	local request = math.max(effort, 0.0)
	local ceiling = cap * Config.MAX_HARVEST_FRACTION
	local take = math.min(request, ceiling)

	-- Yield degrades with abundance but keeps a floor, so an empty ground is
	-- poor rather than pointless.
	local yieldFactor = Config.MIN_YIELD_FACTOR
		+ (1.0 - Config.MIN_YIELD_FACTOR) * math.clamp(abundanceBefore, 0.0, 1.0)
	local yielded = take * yieldFactor

	local remaining = math.max(biomass - yielded, 0.0)
	local stocks = ocean.stocks[regionId]
	if stocks then
		stocks[speciesId] = remaining
	end

	local previouslyHarvested = ocean.harvestedThisWindow[regionId] or 0.0
	ocean.harvestedThisWindow[regionId] = previouslyHarvested + yielded

	local abundanceAfter = remaining / cap

	return {
		speciesId = speciesId,
		regionId = regionId,
		yielded = yielded,
		remaining = remaining,
		abundanceBefore = abundanceBefore,
		abundanceAfter = abundanceAfter,
		depleted = abundanceAfter < Config.COLLAPSE_THRESHOLD,
		-- if another crew has already taken a significant share this tick,
		-- this ground is contested — the game's social-pressure signal
		contested = previouslyHarvested > cap * Config.CONTEST_THRESHOLD,
	}
end

--=============================================================================
-- Global supply
--=============================================================================

--- Total biomass of a species across every region. This is the number the
--- market prices against — it is what makes the ocean *global* rather than
--- merely persistent per server.
function OceanSim.totalSupply(ocean: Ocean, speciesId: string): number
	local total = 0.0
	for _, regionId in ocean.order do
		local stocks = ocean.stocks[regionId]
		if stocks then
			total += stocks[speciesId] or 0.0
		end
	end
	return total
end

--- Total capacity for a species across every region. Supply / capacity is the
--- global abundance the market responds to.
function OceanSim.totalCapacity(ocean: Ocean, speciesId: string): number
	local total = 0.0
	for _, regionId in ocean.order do
		local caps = ocean.capacity[regionId]
		if caps then
			total += caps[speciesId] or 0.0
		end
	end
	return total
end

--- Global abundance of a species in [0, 1+] terms.
function OceanSim.globalAbundance(ocean: Ocean, speciesId: string): number
	local cap = OceanSim.totalCapacity(ocean, speciesId)
	if cap <= 0.0 then
		return 1.0
	end
	return OceanSim.totalSupply(ocean, speciesId) / cap
end

--- Snapshot for the network layer / persistence. Order-stable so a diff is
--- meaningful and a hash is stable.
function OceanSim.snapshot(ocean: Ocean): { [string]: any }
	local regions = {}
	for _, regionId in ocean.order do
		local stocks = ocean.stocks[regionId]
		if stocks then
			regions[regionId] = stocks
		end
	end
	return {
		seed = ocean.seed,
		month = ocean.month,
		tickCount = ocean.tickCount,
		order = table.clone(ocean.order),
		regions = regions,
	}
end

--- Restore a snapshot, e.g. after the global ocean state is fetched from the
--- Worker on server start.
function OceanSim.restore(snapshot: { [string]: any }): Ocean
	local ocean = OceanSim.new(snapshot.seed or 0)
	ocean.month = snapshot.month or 1
	ocean.tickCount = snapshot.tickCount or 0
	ocean.order = {}
	ocean.regions = {}
	ocean.stocks = {}
	ocean.capacity = {}
	ocean.harvestedThisWindow = {}

	for _, regionId in (snapshot.order or {}) do
		local region = (snapshot.regionDefs or {})[regionId]
		if region then
			OceanSim.addRegion(ocean, region)
			local saved = (snapshot.regions or {})[regionId]
			if saved then
				ocean.stocks[regionId] = saved
			end
		end
	end

	return ocean
end

OceanSim._effectiveCapacity = effectiveCapacity
OceanSim._habitatAffinity = habitatAffinity

return OceanSim