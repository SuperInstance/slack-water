--!strict
--[[
	Generate the cross-language parity fixture.

	Run from the repo root:

		luau tests/generate-vectors.luau > shared/economy-vectors.json

	The Luau side is authoritative. This writes the exact expected values that
	BOTH the Luau simulation and the TypeScript worker must reproduce, so the two
	implementations cannot drift apart silently.

	Why this exists: during the first build the worker shipped a scarcity curve
	(`1/abundance`) that matched neither version of the Luau one, and its own
	tests passed because they only tested itself. Two implementations of the same
	economy, each green, quietly disagreeing about what a fish is worth.

	Shared economics are only safe if both sides compute the same numbers.
]]

local Market = require("./../src/Shared/Market")
local Species = require("./../src/Shared/Species")
local Config = require("./../src/Shared/Config")
local OceanSim = require("./../src/Shared/Ocean/OceanSim")
local Regions = require("./../src/Shared/Ocean/Regions")

local function round(value: number, places: number): number
	local mult = 10 ^ places
	return math.floor(value * mult + 0.5) / mult
end

--=============================================================================
-- Scarcity and pricing
--=============================================================================

local scarcityCases = {}
for _, abundance in { 0.0, 0.05, 0.1, 0.2, 0.25, 0.33, 0.5, 0.66, 0.75, 0.9, 1.0 } do
	table.insert(scarcityCases, {
		abundance = abundance,
		multiplier = round(Market.scarcityMultiplier(abundance), 6),
	})
end

local priceCases = {}
for _, id in { "herring", "cod", "rockfish", "halibut", "kingcrab", "yelloweye" } do
	local species = Species.get(id)
	if species then
		for _, abundance in { 0.1, 0.35, 0.6, 1.0 } do
			table.insert(priceCases, {
				speciesId = id,
				abundance = abundance,
				targetPrice = round(Market.targetPrice(species.baseValue, abundance), 4),
			})
		end
	end
end

-- Market inertia: a step, then the settled value after N steps. Both sides must
-- land on the same number or prices will visibly diverge across servers.
local inertiaCases = {}
do
	local market = Market.new()
	local halibutBase = Species.get("halibut").baseValue
	for i = 1, 8 do
		Market.updateSpecies(market, "halibut", 0.2)
		table.insert(inertiaCases, {
			step = i,
			abundance = 0.2,
			price = round(market.entries["halibut"].price, 4),
			direction = market.entries["halibut"].direction,
		})
	end
	table.insert(inertiaCases, {
		settledFrom = halibutBase,
		settledAbundance = 0.2,
		settledPrice = round(market.entries["halibut"].price, 4),
	})
end

--=============================================================================
-- Harvest arithmetic
--=============================================================================

local harvestCases = {}
do
	local ocean = OceanSim.new(4242)
	OceanSim.addRegion(ocean, {
		id = "vectorRegion",
		name = "Vector Region",
		habitat = "reef" :: any,
		depth = 60,
		salinity = 32,
		richness = 1.0,
		origin = "procedural" :: any,
	})

	local capacity = OceanSim.getCapacity(ocean, "vectorRegion", "rockfish")
	for _, effort in { 0, 5, 25, 100, 100000 } do
		local probe = OceanSim.new(4242)
		OceanSim.addRegion(probe, {
			id = "vectorRegion",
			name = "Vector Region",
			habitat = "reef" :: any,
			depth = 60,
			salinity = 32,
			richness = 1.0,
			origin = "procedural" :: any,
		})
		local before = OceanSim.abundance(probe, "vectorRegion", "rockfish")
		local result = OceanSim.harvest(probe, "vectorRegion", "rockfish", effort)
		table.insert(harvestCases, {
			speciesId = "rockfish",
			effort = effort,
			capacity = round(capacity, 4),
			abundanceBefore = round(before, 6),
			yielded = round(result.yielded, 4),
			abundanceAfter = round(result.abundanceAfter, 6),
			depleted = result.depleted,
		})
	end
end

--=============================================================================
-- Capacity
--=============================================================================

local capacityCases = {}
do
	local ocean = OceanSim.new(99)
	OceanSim.addRegion(ocean, {
		id = "capRegion",
		name = "Cap Region",
		habitat = "reef" :: any,
		depth = 60,
		salinity = 32,
		richness = 1.0,
		origin = "procedural" :: any,
	})
	for _, id in { "rockfish", "herring", "halibut", "yelloweye", "kingcrab", "chinook" } do
		table.insert(capacityCases, {
			speciesId = id,
			habitat = "reef",
			depth = 60,
			richness = 1.0,
			capacity = round(OceanSim.getCapacity(ocean, "capRegion", id), 4),
		})
	end
end

--=============================================================================
-- Region generation determinism
--=============================================================================

local regionCases = {}
for i = 1, 8 do
	local region = Regions.generateOne(20261014, i)
	table.insert(regionCases, {
		index = i,
		id = region.id,
		name = region.name,
		habitat = region.habitat,
		depth = region.depth,
		richness = round(region.richness, 6),
	})
end

--=============================================================================
-- Emit
--=============================================================================

local payload = {
	generatedBy = "tests/generate-vectors.luau",
	note = "Luau is authoritative. The worker TypeScript must reproduce these exactly.",
	config = {
		MAX_SCARCITY_MULTIPLIER = Config.MAX_SCARCITY_MULTIPLIER,
		SCARCITY_FLOOR = Config.SCARCITY_FLOOR,
		PRICE_INERTIA = Config.PRICE_INERTIA,
		MAX_HARVEST_FRACTION = Config.MAX_HARVEST_FRACTION,
		MIN_YIELD_FACTOR = Config.MIN_YIELD_FACTOR,
		COLLAPSE_THRESHOLD = Config.COLLAPSE_THRESHOLD,
	},
	scarcity = scarcityCases,
	prices = priceCases,
	inertia = inertiaCases,
	harvest = harvestCases,
	capacity = capacityCases,
	regions = regionCases,
}

local function serialize(value: any, indent: number): string
	local pad = ("  "):rep(indent)
	local inner = ("  "):rep(indent + 1)

	if type(value) == "table" then
		local isArray = #value > 0
		if isArray then
			local parts = {}
			for _, item in value do
				table.insert(parts, inner .. serialize(item, indent + 1))
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
		end
		local keys = {}
		for k in value do
			table.insert(keys, k)
		end
		table.sort(keys)
		local parts = {}
		for _, k in keys do
			table.insert(parts, inner .. '"' .. tostring(k) .. '": ' .. serialize(value[k], indent + 1))
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
	end

	if type(value) == "string" then
		return '"' .. value .. '"'
	end
	if type(value) == "boolean" then
		return tostring(value)
	end
	return tostring(value)
end

print(serialize(payload, 0))