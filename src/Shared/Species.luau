--!strict
--[[
	Species — the roster.

	These are real North Pacific species with real biology. The numbers that
	matter to the simulation are biological, not cosmetic:

	- `runMonths` is anadromy. Salmon do not spawn in the ocean; they return to
	  freshwater to spawn and die. That means a run is a real *inflow event*
	  into a region, followed by a real collapse. This is the single most
	  important dynamic in the game and it is not invented.

	- `minDepth`/`maxDepth` drive where a species can be found. Halibut really
	  do sit in far deeper water than salmon.

	- `growthRate` and `capacity` are gameplay-tuned. Real recruitment
	  coefficients are not directly usable in a game loop, so these are
	  calibrated so a ground takes days, not years, to be picked clean.

	`harvestDifficulty` is the minigame skill floor: you cannot land a 300lb
	halibut on the same drag that lands a herring.
]]

export type Habitat = "kelp" | "reef" | "sand" | "mud" | "open" | "estuary"

export type Species = {
	id: string,
	displayName: string,
	scientificName: string,
	habitat: Habitat,
	minDepth: number,
	maxDepth: number,
	capacity: number,
	growthRate: number,
	baseValue: number,
	weightRange: { min: number, max: number },
	anadromous: boolean,
	runMonths: { number }?,
	runStrength: number,
	harvestDifficulty: number,
	rarity: number,
}

local SPECIES_LIST: { Species } = {
	{
		id = "chinook",
		displayName = "Chinook Salmon",
		scientificName = "Oncorhynchus tshawytscha",
		habitat = "open",
		minDepth = 30,
		maxDepth = 300,
		capacity = 900,
		growthRate = 0.09,
		baseValue = 220,
		weightRange = { min = 10, max = 45 },
		anadromous = true,
		runMonths = { 3, 4, 5, 6 },
		runStrength = 1.0,
		harvestDifficulty = 4,
		rarity = 0.18,
	},
	{
		id = "coho",
		displayName = "Coho Salmon",
		scientificName = "Oncorhynchus kisutch",
		habitat = "open",
		minDepth = 20,
		maxDepth = 200,
		capacity = 1100,
		growthRate = 0.11,
		baseValue = 120,
		weightRange = { min = 6, max = 15 },
		anadromous = true,
		runMonths = { 8, 9, 10 },
		runStrength = 0.85,
		harvestDifficulty = 3,
		rarity = 0.26,
	},
	{
		id = "sockeye",
		displayName = "Sockeye Salmon",
		scientificName = "Oncorhynchus nerka",
		habitat = "open",
		minDepth = 100,
		maxDepth = 320,
		capacity = 800,
		growthRate = 0.10,
		baseValue = 95,
		weightRange = { min = 3, max = 8 },
		anadromous = true,
		runMonths = { 8, 9, 10 },
		runStrength = 0.90,
		harvestDifficulty = 3,
		rarity = 0.28,
	},
	{
		id = "pink",
		displayName = "Pink Salmon",
		scientificName = "Oncorhynchus gorbuscha",
		habitat = "estuary",
		minDepth = 5,
		maxDepth = 120,
		capacity = 2400,
		growthRate = 0.16,
		baseValue = 40,
		weightRange = { min = 2, max = 6 },
		anadromous = true,
		runMonths = { 7, 8, 9 },
		runStrength = 1.35,
		harvestDifficulty = 2,
		rarity = 0.42,
	},
	{
		id = "chum",
		displayName = "Chum Salmon",
		scientificName = "Oncorhynchus keta",
		habitat = "estuary",
		minDepth = 10,
		maxDepth = 180,
		capacity = 1300,
		growthRate = 0.12,
		baseValue = 60,
		weightRange = { min = 3, max = 9 },
		anadromous = true,
		runMonths = { 8, 9, 10, 11 },
		runStrength = 0.80,
		harvestDifficulty = 2,
		rarity = 0.34,
	},
	{
		id = "halibut",
		displayName = "Pacific Halibut",
		scientificName = "Hippoglossus stenolepis",
		habitat = "sand",
		minDepth = 200,
		maxDepth = 900,
		capacity = 420,
		growthRate = 0.045,
		baseValue = 460,
		weightRange = { min = 20, max = 160 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 5,
		rarity = 0.12,
	},
	{
		id = "sablefish",
		displayName = "Sablefish",
		scientificName = "Anoplopoma fimbria",
		habitat = "mud",
		minDepth = 300,
		maxDepth = 800,
		capacity = 380,
		growthRate = 0.04,
		baseValue = 340,
		weightRange = { min = 4, max = 25 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 4,
		rarity = 0.15,
	},
	{
		id = "cod",
		displayName = "Pacific Cod",
		scientificName = "Gadus macrocephalus",
		habitat = "mud",
		minDepth = 90,
		maxDepth = 300,
		capacity = 950,
		growthRate = 0.07,
		baseValue = 130,
		weightRange = { min = 3, max = 18 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 3,
		rarity = 0.30,
	},
	{
		id = "pollock",
		displayName = "Alaska Pollock",
		scientificName = "Scomber americanus",
		habitat = "open",
		minDepth = 80,
		maxDepth = 300,
		capacity = 1800,
		growthRate = 0.14,
		baseValue = 55,
		weightRange = { min = 2, max = 12 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 2,
		rarity = 0.44,
	},
	{
		id = "lingcod",
		displayName = "Lingcod",
		scientificName = "Ophiodon elongatus",
		habitat = "reef",
		minDepth = 90,
		maxDepth = 300,
		capacity = 620,
		growthRate = 0.06,
		baseValue = 175,
		weightRange = { min = 3, max = 30 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 4,
		rarity = 0.22,
	},
	{
		id = "rockfish",
		displayName = "Black Rockfish",
		scientificName = "Sebastes melanops",
		habitat = "reef",
		minDepth = 25,
		maxDepth = 120,
		capacity = 1100,
		growthRate = 0.08,
		baseValue = 145,
		weightRange = { min = 2, max = 10 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 3,
		rarity = 0.32,
	},
	{
		id = "yelloweye",
		displayName = "Yelloweye Rockfish",
		scientificName = "Sebastes flavidus",
		habitat = "reef",
		minDepth = 40,
		maxDepth = 180,
		capacity = 300,
		growthRate = 0.035,
		baseValue = 395,
		weightRange = { min = 4, max = 18 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 5,
		rarity = 0.11,
	},
	{
		id = "herring",
		displayName = "Pacific Herring",
		scientificName = "Clupea harengus pallasii",
		habitat = "kelp",
		minDepth = 15,
		maxDepth = 110,
		capacity = 2600,
		growthRate = 0.18,
		baseValue = 30,
		weightRange = { min = 0.2, max = 1.2 },
		anadromous = false,
		runMonths = { 3, 4, 5 },
		runStrength = 0.60,
		harvestDifficulty = 1,
		rarity = 0.52,
	},
	{
		id = "flounder",
		displayName = "Starry Flounder",
		scientificName = "Platichthys stellatus",
		habitat = "sand",
		minDepth = 15,
		maxDepth = 150,
		capacity = 1200,
		growthRate = 0.10,
		baseValue = 75,
		weightRange = { min = 1, max = 9 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 2,
		rarity = 0.38,
	},
	{
		id = "skate",
		displayName = "Big Skate",
		scientificName = "Raja montereyensis",
		habitat = "sand",
		minDepth = 60,
		maxDepth = 400,
		capacity = 480,
		growthRate = 0.05,
		baseValue = 210,
		weightRange = { min = 5, max = 35 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 4,
		rarity = 0.19,
	},
	{
		id = "dungeness",
		displayName = "Dungeness Crab",
		scientificName = "Metacarcinus magister",
		habitat = "reef",
		minDepth = 15,
		maxDepth = 200,
		capacity = 760,
		growthRate = 0.07,
		baseValue = 190,
		weightRange = { min = 0.6, max = 6 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 4,
		rarity = 0.24,
	},
	{
		id = "kingcrab",
		displayName = "Red King Crab",
		scientificName = "Paralithodes camtschaticus",
		habitat = "mud",
		minDepth = 200,
		maxDepth = 500,
		capacity = 260,
		growthRate = 0.03,
		baseValue = 580,
		weightRange = { min = 4, max = 18 },
		anadromous = false,
		runStrength = 0.0,
		harvestDifficulty = 5,
		rarity = 0.09,
	},
}

--=============================================================================
-- Lookup tables
--=============================================================================

local BY_ID: { [string]: Species } = {}
local BY_HABITAT: { [string]: { Species } } = {}

for _, species in SPECIES_LIST do
	BY_ID[species.id] = species
	local bucket = BY_HABITAT[species.habitat]
	if not bucket then
		bucket = {}
		BY_HABITAT[species.habitat] = bucket
	end
	table.insert(bucket, species)
end

local Species = {}

Species.list = SPECIES_LIST

function Species.get(id: string): Species?
	return BY_ID[id]
end

function Species.byHabitat(habitat: Habitat): { Species }
	return BY_HABITAT[habitat] or {}
end

function Species.habitats(): { Habitat }
	return { "kelp", "reef", "sand", "mud", "open", "estuary" }
end

--- Is this species running in the given month? Runs are the game's headline
--- events, so this is queried every tick and by the UI to flag a region.
function Species.isRunning(species: Species, month: number): boolean
	local months = species.runMonths
	if not months then
		return false
	end
	for _, m in months do
		if m == month then
			return true
		end
	end
	return false
end

--- Species that can plausibly inhabit a region at a given depth. Depth is the
--- hard filter; habitat affinity is handled separately by the region code.
function Species.candidatesAtDepth(depth: number): { Species }
	local out: { Species } = {}
	for _, species in SPECIES_LIST do
		if depth >= species.minDepth and depth <= species.maxDepth then
			table.insert(out, species)
		end
	end
	return out
end

return Species
