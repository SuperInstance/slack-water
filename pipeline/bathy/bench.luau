--!strict
--[[
	bench — honest numbers for docs/BATHYMETRY.md.

	Measures the sampler at a realistic survey size (1000×1000 nodes) on this
	machine, under the standalone luau CLI:

	- heap cost of holding the loaded field (collectgarbage delta)
	- depthAt throughput (no allocation)
	- sample() throughput (allocates one result table per call)

	Run: luau pipeline/bathy/bench.luau
	These are measurements, not guarantees — Roblox's VM differs. The ratio
	between the paths is the useful part.
]]

local Bathymetry = require("./../../src/Shared/Ocean/Bathymetry")

local COLS, ROWS, CELL = 1000, 1000, 2 -- 2 km × 2 km at 2 m cells
local N = COLS * ROWS

print(string.format("grid: %dx%d nodes (cell %d studs)", COLS, ROWS, CELL))

-- Phase 1: the values array itself — the dominant cost. Measure the delta
-- with no GC in between, so it captures exactly the array's allocation.
local c0 = collectgarbage("count")
local values = {}
for j = 0, ROWS - 1 do
	for i = 0, COLS - 1 do
		-- plausible shelf: 10 m near the north edge deepening to ~250 m
		values[j * COLS + i + 1] = math.floor((10 + 240 * j / ROWS) * 10 + 0.5)
	end
end
local c1 = collectgarbage("count")
print(
	string.format(
		"heap for the %d-value array: %.1f MB (%.1f bytes/cell)",
		N,
		(c1 - c0) / 1024,
		(c1 - c0) * 1024 / N
	)
)

-- Phase 2: fromGrid adopts the array in place; its own cost is just the
-- small field table.
local c2 = collectgarbage("count")
local doc = {
	surveyed = false,
	provenance = "grown",
	grid = {
		cols = COLS,
		rows = ROWS,
		cellSize = CELL,
		minX = -1000,
		minZ = -1000,
		valueScale = 0.1,
		noDataValue = -32768,
		fallbackDepth = 1300,
		values = values,
	},
}
local field = Bathymetry.fromGrid(doc)
local c3 = collectgarbage("count")
print(
	string.format(
		"heap added by fromGrid (field table, adopts array in place): %.2f MB",
		(c3 - c2) / 1024
	)
)

-- deterministic probe coordinates spread across and outside the grid
local function probe(k: number): (number, number)
	local x = -1200 + (k % 997) * 2.5
	local z = -1200 + ((k * 31) % 991) * 2.5
	return x, z
end

local REPS = 200000
local t0 = os.clock()
local acc = 0.0
for k = 1, REPS do
	local x, z = probe(k)
	acc += Bathymetry.depthAt(field, x, z)
end
local t1 = os.clock()
print(
	string.format(
		"depthAt: %d calls in %.3fs — %.2f us/call (checksum %.1f)",
		REPS,
		t1 - t0,
		(t1 - t0) * 1e6 / REPS,
		acc
	)
)

local REPS_S = 50000
local inBoundsCount = 0
t0 = os.clock()
for k = 1, REPS_S do
	local x, z = probe(k)
	local s = Bathymetry.sample(field, x, z)
	if s.inBounds then
		inBoundsCount += 1
	end
end
t1 = os.clock()
print(
	string.format(
		"sample(): %d calls in %.3fs — %.2f us/call (in-bounds %d/%d; allocation included)",
		REPS_S,
		t1 - t0,
		(t1 - t0) * 1e6 / REPS_S,
		inBoundsCount,
		REPS_S
	)
)
