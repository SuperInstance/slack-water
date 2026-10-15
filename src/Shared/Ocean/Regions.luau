--!strict
--[[
	Regions — procedural ocean generation.

	Two jobs:

	1. Build the starting ocean. A new server needs somewhere to fish before any
	   AI bank exists, and that ocean has to be reproducible from a seed so every
	   player sees the same world.

	2. Provide the fallback. When the AI composer returns banks that fail
	   validation, or the Worker is unreachable, generation fills the gap. The
	   ocean must never be empty — an empty ocean is a dead game.

	The vocabulary is real North Pacific. Naming things after actual fishing
	grounds and conditions is deliberate: this game's whole claim is that its
	content was authored by someone who has stood on a boat, and procedurally
	generated "Region 47B" would quietly undercut that.
]]

local Rng = require("./Rng")
local Species = require("../Species")

type Habitat = "kelp" | "reef" | "sand" | "mud" | "open" | "estuary"

local Regions = {}

--=============================================================================
-- Vocabulary
--=============================================================================

-- Real terms from the North Pacific fishery. Each ground gets a name built
-- from a qualifier and a feature, so names read like places rather than
-- database rows.
local QUALIFIERS: { string } = {
	"North",
	"South",
	"Outer",
	"Inner",
	"Lower",
	"Upper",
	"Broken",
	"Slack",
	"Deep",
	"Sheltered",
	"Windward",
	"Cold",
}

local FEATURES_BY_HABITAT: { [string]: { string } } = {
	kelp = { "Kelp Bed", "Kelp Line", "Holdfast Shoal" },
	reef = { "Reef", "Rock Ledge", "Boulder Ground", "Coral Head" },
	sand = { "Flats", "Sandbar", "Trough" },
	mud = { "Flats", "Basin", "Slough", "Hole" },
	open = { "Sea", "Swells", "Water", "Reach" },
	estuary = { "Delta", "Mouth", "Estuary", "Sound" },
}

local HAZARDS: { string } = {
	"rip_current",
	"rocky_bottom",
	"deep_water",
	"kelp_tangle",
	"seabird_activity",
	"debris_field",
	"cold_drain",
}

--- Depth bands that suit each habitat. Halibut grounds sit deep and wide; a
--- kelp bed is shallow and narrow. These ranges are what make the generated
--- ocean feel like real water rather than noise.
-- Luau has no tuple type, so each range is a two-element array: [min, max].
local DEPTH_RANGE: { [string]: { number } } = {
	kelp = { 12, 90 },
	reef = { 25, 220 },
	sand = { 15, 320 },
	mud = { 60, 500 },
	open = { 40, 400 },
	estuary = { 5, 120 },
}

--=============================================================================
-- Generation
--=============================================================================

local function generateName(rng: Rng.Rng, habitat: string): string
	local features = FEATURES_BY_HABITAT[habitat]
	local feature = if features then (Rng.pick(rng, features) or "Ground") else "Ground"
	local qualifier = Rng.pick(rng, QUALIFIERS)
	return (qualifier .. " " .. feature) :: string
end

--- Build one region. The species mix is not hard-coded — every species with a
--- compatible depth and a viable habitat affinity is included, weighted by
--- rarity, so a rocky shallow bank naturally comes out full of rockfish and
--- almost devoid of sablefish.
local function generateRegion(rng: Rng.Rng, index: number): any
	local habitat = Rng.pick(rng, Species.habitats()) or "open"

	local range = DEPTH_RANGE[habitat] or { 20, 200 }
	local depth = Rng.int(rng, range[1], range[2])

	local region = {
		id = "r" .. tostring(index),
		name = generateName(rng, habitat),
		habitat = habitat :: any,
		depth = depth,
		salinity = Rng.range(rng, 24, 34),
		richness = Rng.range(rng, 0.7, 1.4),
		origin = "procedural" :: "procedural",
	}

	if Rng.chance(rng, 0.35) then
		region.hazard = Rng.pick(rng, HAZARDS)
	end

	return region
end

--- Build the starting ocean's worth of regions.
function Regions.generate(seed: number, count: number): { any }
	local rng = Rng.new(seed)
	local out: { any } = {}

	for i = 1, count do
		table.insert(out, generateRegion(rng, i))
	end

	return out
end

--- Build a single additional region at the given index. `index` is the
--- position the region will occupy in the world's id sequence, not a count of
--- regions that already exist.
function Regions.generateOne(seed: number, index: number): any
	local rng = Rng.new(seed + index * 7919)
	return generateRegion(rng, index)
end

--- Which species a player can actually target in this region, and how likely
--- each is to be present. The simulation's capacity already encodes whether a
--- species *can* live here; this is the UI-facing answer to "what is in this
--- water", so it must never list something with a capacity of zero.
function Regions.presentSpecies(region: any, ocean: any, OceanSim: any): { string }
	local present: { string } = {}

	for _, species in Species.list do
		local capacity = OceanSim.getCapacity(ocean, region.id, species.id)
		if capacity > 1.0 then
			local abundance = OceanSim.getStock(ocean, region.id, species.id) / capacity
			if abundance > 0.05 then
				table.insert(present, species.id)
			end
		end
	end

	return present
end

--- Fallback fill: given how many regions exist and how many we want, return
--- whatever procedural regions are needed to reach the target. The caller
--- decides whether to use them (procedural fallback) or surface them to players
--- as ordinary discoveries.
function Regions.fillTo(seed: number, existing: number, target: number): { any }
	local out: { any } = {}
	local n = existing
	while n < target do
		n += 1
		table.insert(out, Regions.generateOne(seed, n))
	end
	return out
end

Regions.HAZARDS = HAZARDS
Regions.DEPTH_RANGE = DEPTH_RANGE

return Regions
