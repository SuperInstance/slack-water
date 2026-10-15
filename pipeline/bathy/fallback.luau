--!strict
--[[
	fallback — the procedural stand-in for real Southeast Alaska bathymetry.

	The owner has a decade of real Sitka-area soundings on another machine.
	Until that file arrives, the game needs depths to swim in — but the repo's
	first rule applies: generated water is never presented as surveyed. This
	grid is born with surveyed:false, provenance "grown", and a description
	that says PLACEHOLDER in words a player could read.

	Generation is a documented closed-form function plus seeded value noise
	from src/Shared/Rng.luau (Park-Miller, no bitwise operators). Same seed,
	same bytes, forever: re-running the bake must produce an identical JSON
	file, so the committed artifact can always be audited against the code
	that made it.

	It is NOT a model of the actual seafloor. It is a plausible continental
	shelf: shallow near a convoluted shoreline, deepening offshore to a shelf
	break, with a few shoal banks and one basin. Anyone who mistakes it for
	Sitka has not read this paragraph.
]]

local Rng = require("./../../src/Shared/Ocean/Rng")

local Fallback = {}

-- Baked constants. Changing any of them changes the committed
-- shared/bathy/fallback-depth.json; re-run the bake after editing.
local SEED = 20261014
local BOUNDS = 600 -- world runs -600..600 studs (WorldGen floor is 1200x1200)
local CELL = 16 -- studs; 76x76 nodes
local VALUE_SCALE = 0.1
local NODATA = -32768

-- Shoal banks and one basin, in world studs: {cx, cz, radius, strength}.
-- Strength 0.5 means "this bank lifts the seabed by up to half its depth".
local FEATURES = {
	{ -210, -120, 140, 0.5 },
	{ 180, 90, 170, 0.45 },
	{ 20, 330, 90, 0.55 },
	{ -60, 240, 110, -0.5 }, -- basin: negative strength deepens
}

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

--- Bilinear value noise over an n×n random lattice in [0,1).
--- The lattice is filled once from the seed, so the field is a pure function
--- of (SEED, n, u, v).
local function makeLattice(n: number): { number }
	local rng = Rng.new(SEED + n * 7919)
	local lattice = {}
	for i = 1, n * n do
		lattice[i] = Rng.nextFloat(rng) * 2 - 1
	end
	return lattice
end

local function valueNoise(lattice: { number }, n: number, u: number, v: number): number
	local x = math.clamp(u, 0, 1) * (n - 1)
	local y = math.clamp(v, 0, 1) * (n - 1)
	local x0 = math.floor(x)
	local y0 = math.floor(y)
	local x1 = math.min(x0 + 1, n - 1)
	local y1 = math.min(y0 + 1, n - 1)
	local tx = smooth(x - x0)
	local ty = smooth(y - y0)
	local i00 = lattice[y0 * n + x0 + 1]
	local i10 = lattice[y0 * n + x1 + 1]
	local i01 = lattice[y1 * n + x0 + 1]
	local i11 = lattice[y1 * n + x1 + 1]
	local top = i00 + (i10 - i00) * tx
	local bottom = i01 + (i11 - i01) * tx
	return top + (bottom - top) * ty
end

--- Depth in metres at world (x, z). North (-z) is the shoreline; depth grows
--- to a shelf break at the southern edge. Deterministic pure function.
local function depthAtMetres(x: number, z: number, coarse: { number }, fine: { number }): number
	local u = (x + BOUNDS) / (2 * BOUNDS)
	local v = (z + BOUNDS) / (2 * BOUNDS)

	-- A convoluted coastline: the shoreline wanders ~35 m either way.
	local shoreline = 0.04 + 0.03 * valueNoise(coarse, 9, u, 0.5)
	local offshore = math.clamp((v - shoreline) / (1 - shoreline), 0, 1)

	-- Shelf profile: gentle near shore, steeper mid-shelf, flattening toward
	-- the break. 15 m at the beach, ~260 m at the edge.
	local base = 15 + 245 * offshore ^ 1.6

	-- Two octaves of relief: broad swells plus finer roughness.
	local relief = 22 * valueNoise(coarse, 9, u, v) + 9 * valueNoise(fine, 17, u, v)

	local depth = base + relief

	for _, f in FEATURES do
		local dx = x - f[1]
		local dz = z - f[2]
		local r = f[3]
		local g = math.exp(-(dx * dx + dz * dz) / (r * r))
		depth -= f[4] * g * depth
	end

	return math.clamp(depth, 3, 400)
end

--- Build the full fallback document, ready for Json.encode.
function Fallback.build(): any
	local coarse = makeLattice(9)
	local fine = makeLattice(17)

	local n = BOUNDS * 2 / CELL + 1 -- 76 nodes per axis
	local values = {}

	local sum = 0
	local minV, maxV = math.huge, -math.huge
	for j = 0, n - 1 do
		local z = -BOUNDS + j * CELL
		for i = 0, n - 1 do
			local x = -BOUNDS + i * CELL
			local q = math.floor(depthAtMetres(x, z, coarse, fine) / VALUE_SCALE + 0.5)
			values[j * n + i + 1] = q
			sum += q
			if q < minV then
				minV = q
			end
			if q > maxV then
				maxV = q
			end
		end
	end

	return {
		name = "fallback-depth",
		description = "PLACEHOLDER bathymetry — procedurally generated from a documented "
			.. "shelf profile and seeded noise (seed "
			.. SEED
			.. "). NOT real survey data. Replace by converting the owner's real "
			.. "soundings; see docs/BATHYMETRY.md.",
		surveyed = false,
		provenance = "grown",
		grid = {
			cols = n,
			rows = n,
			cellSize = CELL,
			minX = -BOUNDS,
			minZ = -BOUNDS,
			valueScale = VALUE_SCALE,
			noDataValue = NODATA,
			depthUnits = "studs",
			positive = "down",
			fallbackDepth = math.floor(sum / (n * n) + 0.5),
			values = values,
		},
		provenanceBlock = {
			sourceDescription = "procedural: documented shelf profile + two octaves of seeded value noise, "
				.. "three shoal banks and one basin (see pipeline/bathy/fallback.luau)",
			sourceFile = "",
			convertedAt = "2026-10-14T00:00:00Z", -- pinned so the bake is byte-reproducible
			converter = "slack-water pipeline/bathy fallback v1",
			formatDetected = "procedural",
			unitsInput = "m (implicit, generated in metres)",
			depthSign = "down",
			soundingsRead = n * n,
			soundingsUsed = n * n,
			rowsSkipped = 0,
			aboveDatumClamped = 0,
			outOfRangeSkipped = 0,
			depthMinMetres = minV * VALUE_SCALE,
			depthMaxMetres = maxV * VALUE_SCALE,
			cellSizeMetres = CELL,
			noDataPolicy = "full synthetic coverage; no no-data cells by construction",
			noDataCells = 0,
			coverageFraction = 1,
			valueScale = VALUE_SCALE,
			unitsOutput = "studs",
			gridBoundsStuds = { minX = -BOUNDS, maxX = BOUNDS, minZ = -BOUNDS, maxZ = BOUNDS },
			georeference = {
				mode = "none — not georeferenced to the real world",
				studsPerMetre = 1,
				northAxis = "-Z",
			},
			seed = SEED,
		},
	}
end

return Fallback
