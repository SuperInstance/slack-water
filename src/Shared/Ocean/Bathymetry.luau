--!strict
--[[
	Bathymetry — O(1) depth sampling over a baked grid, with provenance.

	This is the runtime half of the bathymetry pipeline (see
	pipeline/bathy/ and docs/BATHYMETRY.md). It takes an already-decoded grid
	document — parsed JSON, injected by the caller — and answers one question
	fast: how deep is the water here, and can that number be trusted?

	STORAGE DESIGN — why one flat array

	The grid is a single flat, row-major array of depths: values[row * cols +
	col + 1]. A 1000×1000 survey is one table with a dense array part, which in
	Luau costs roughly 16 bytes per cell (a boxed double per slot) — about
	16 MB, viable on a server. The alternatives are worse:

	- nested {[x] = {[z] = depth}} costs a hash table per row plus a hash node
	  per cell (~40+ bytes/cell) and an extra pointer chase per sample;
	- a sparse {[x .. "," .. z] = depth} map is the same idea with string
	  keys on top — slower and larger again;
	- the flat array is also the shape JSON decodes into, so `fromGrid` adopts
	  the decoded array in place instead of copying 16 MB.

	Sampling is bilinear over the four surrounding nodes: O(1), branch-light,
	no allocation. `sample()` allocates one small result table for callers
	that need provenance; the hot path `depthAt()` returns a bare number.

	PROVENANCE IS THE POINT

	The grid document carries a `surveyed` flag and a provenance word shared
	with Chart.luau: `measured` (operator-asserted real soundings) or `grown`
	(everything else). `fromGrid` enforces the same distrust rule as
	Chart.loadFromChart: `measured` is only believed when the document ALSO
	says surveyed:true; anything contradictory or unrecognised is downgraded
	to `grown`. A depth that came from the fallback, a coverage hole, or
	outside the survey footprint is reported as `grown` — never as fact.

	Out-of-bounds and no-data queries return the grid's documented
	fallbackDepth (the mean of its valid cells, baked by the converter) —
	a finite, positive, boring number, never NaN, never an error.

	Loading is the caller's business: Roblox cannot read files at runtime.
	How a grid reaches the server (committed via rojo, fetched from the
	worker, hand-pasted) is deliberately unsolved here — this module only
	defines the contract. See docs/BATHYMETRY.md.

	Pure Luau: no Roblox globals, no RNG, no clock, no bitwise operators.
	Deterministic by construction.
]]

export type Provenance = "measured" | "grown"

export type Sample = {
	-- water depth in studs, positive down; always finite and >= 0
	depth: number,
	-- "measured" only if this exact value came from real surveyed nodes
	provenance: Provenance,
	surveyed: boolean,
	-- true when the query fell inside the grid footprint but onto a
	-- no-data cell (a coverage hole); the depth is then the fallback
	noData: boolean,
	inBounds: boolean,
}

export type Field = {
	name: string,
	description: string,
	surveyed: boolean,
	provenance: Provenance,
	cols: number,
	rows: number,
	cellSize: number,
	minX: number,
	minZ: number,
	-- flat row-major depth array in studs; no-data cells hold the raw
	-- (negative) sentinel, which cannot collide with a real depth
	values: { number },
	noDataValue: number,
	fallbackDepth: number,
	validCells: number,
	totalCells: number,
}

local Bathymetry = {}

-- Hard bounds on what fromGrid will accept, so a corrupt or hostile document
-- cannot ask for a nonsensical allocation. 2,500,000 cells ≈ 40 MB.
Bathymetry.MAX_CELLS = 2500000
-- Depths beyond this (studs) are treated as corrupt values, not deep water.
Bathymetry.MAX_DEPTH = 20000

--=============================================================================
-- Loading
--=============================================================================

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function intField(v: any): number?
	if isFiniteNumber(v) and math.floor(v) == v then
		return v
	end
	return nil
end

--- Adopt a decoded grid document (the shape pipeline/bathy emits).
---
--- Returns nil for a document that cannot be trusted at all — wrong shape,
--- truncated values array, zero coverage. Contradictory provenance is NOT a
--- nil: it is downgraded to `grown` and the field still loads, because a
--- provisional depth is still useful and the honesty rule is about labels,
--- not about refusing to run.
---
--- The decoded values array is scaled in place; callers must not reuse it.
function Bathymetry.fromGrid(doc: any): Field?
	if type(doc) ~= "table" or type(doc.grid) ~= "table" then
		return nil
	end
	local g = doc.grid

	local cols = intField(g.cols)
	local rows = intField(g.rows)
	if cols == nil or rows == nil or cols < 2 or rows < 2 then
		return nil
	end
	local total = cols * rows
	if total > Bathymetry.MAX_CELLS or type(g.values) ~= "table" or #g.values ~= total then
		return nil
	end
	if not isFiniteNumber(g.cellSize) or g.cellSize <= 0 then
		return nil
	end
	if not isFiniteNumber(g.minX) or not isFiniteNumber(g.minZ) then
		return nil
	end

	-- Provenance distrust, mirroring Chart.loadFromChart: `measured` is only
	-- believed when surveyed agrees, and never inherited from an unknown word.
	local surveyed = doc.surveyed == true
	local provenance: Provenance = "grown"
	if surveyed and doc.provenance == "measured" then
		provenance = "measured"
	else
		surveyed = false
	end

	local noDataValue = if isFiniteNumber(g.noDataValue) then g.noDataValue else -32768
	if noDataValue >= 0 then
		return nil -- a sentinel that could collide with real depth is unusable
	end
	local scale = if isFiniteNumber(g.valueScale) and g.valueScale > 0 then g.valueScale else 1

	-- Scale values into studs, in place. Out-of-range entries degrade to the
	-- no-data sentinel rather than failing the whole load — a corrupt cell is
	-- a hole, not a reason to run the ocean without a chart.
	local values = g.values
	local valid = 0
	for i = 1, total do
		local v = values[i]
		if type(v) == "number" and v ~= noDataValue then
			local d = v * scale
			if d >= 0 and d <= Bathymetry.MAX_DEPTH then
				values[i] = d
				valid += 1
				continue
			end
		end
		values[i] = noDataValue
	end
	if valid == 0 then
		return nil
	end

	local fallbackDepth: number
	if isFiniteNumber(g.fallbackDepth) and g.fallbackDepth >= 0 then
		fallbackDepth = g.fallbackDepth * scale
		if fallbackDepth > Bathymetry.MAX_DEPTH then
			fallbackDepth = Bathymetry.MAX_DEPTH
		end
	else
		-- document omitted it: derive it, deterministically, as the mean
		local sum = 0.0
		for i = 1, total do
			if values[i] ~= noDataValue then
				sum += values[i]
			end
		end
		fallbackDepth = sum / valid
	end

	local name = if type(doc.name) == "string" then doc.name else "unnamed"
	local description = if type(doc.description) == "string"
		then doc.description
		else if surveyed
			then "surveyed grid (no description provided)"
			else "unsurveyed grid (no description provided)"

	return {
		name = name,
		description = description,
		surveyed = surveyed,
		provenance = provenance,
		cols = cols,
		rows = rows,
		cellSize = g.cellSize,
		minX = g.minX,
		minZ = g.minZ,
		values = values,
		noDataValue = noDataValue,
		fallbackDepth = fallbackDepth,
		validCells = valid,
		totalCells = total,
	}
end

--=============================================================================
-- Sampling
--=============================================================================

--- Shared core: returns depth, whether the position fell on a coverage hole,
--- and whether it was inside the footprint at all. Never throws, never
--- returns NaN — degenerate coordinates (NaN) are treated as out of bounds.
local function rawSample(field: Field, x: number, z: number): (number, boolean, boolean)
	local maxX = field.minX + (field.cols - 1) * field.cellSize
	local maxZ = field.minZ + (field.rows - 1) * field.cellSize
	-- NaN fails every comparison, so it needs its own guard before the bounds
	-- test — otherwise it slips through as "in bounds" and poisons the index
	-- arithmetic. No error, no wild number, just the documented fallback.
	if x ~= x or z ~= z or x < field.minX or x > maxX or z < field.minZ or z > maxZ then
		return field.fallbackDepth, false, false
	end

	local fx = (x - field.minX) / field.cellSize
	local fz = (z - field.minZ) / field.cellSize
	local col = math.floor(fx)
	local row = math.floor(fz)
	-- the last row/column of nodes has no cell beyond it; clamp into the
	-- final interval so x == maxX is an interpolation, not an error
	if col > field.cols - 2 then
		col = field.cols - 2
	end
	if row > field.rows - 2 then
		row = field.rows - 2
	end
	local tx = fx - col
	local tz = fz - row
	if tx < 0 then
		tx = 0
	elseif tx > 1 then
		tx = 1
	end
	if tz < 0 then
		tz = 0
	elseif tz > 1 then
		tz = 1
	end

	local values = field.values
	local cols = field.cols
	local i00 = row * cols + col + 1
	local c00 = values[i00]
	local c10 = values[i00 + 1]
	local c01 = values[i00 + cols]
	local c11 = values[i00 + cols + 1]

	-- A corner with NON-ZERO weight that carries no data makes this depth a
	-- guess: fall back. Corners with zero weight (exactly on a node or edge)
	-- are ignored — standing on a surveyed node is not polluted by the hole
	-- next to it. The zero-weight sentinel never enters the arithmetic below
	-- because it is multiplied by exactly 0.
	local nodata = field.noDataValue
	local holed = (tx < 1 and tz < 1 and c00 == nodata)
		or (tx > 0 and tz < 1 and c10 == nodata)
		or (tx < 1 and tz > 0 and c01 == nodata)
		or (tx > 0 and tz > 0 and c11 == nodata)
	if holed then
		return field.fallbackDepth, true, true
	end

	-- weighted-sum bilinear rather than nested lerps: identical result, and
	-- sentinel corners with zero weight contribute exactly 0
	local w00 = (1 - tx) * (1 - tz)
	local w10 = tx * (1 - tz)
	local w01 = (1 - tx) * tz
	local w11 = tx * tz
	return c00 * w00 + c10 * w10 + c01 * w01 + c11 * w11, false, true
end

--- Fast path: just the depth, in studs, positive down.
---
--- Out-of-bounds and no-data positions return the grid's documented
--- fallbackDepth — finite, positive, never NaN. Use sample() when you need
--- to know which of those three cases you are in.
function Bathymetry.depthAt(field: Field, x: number, z: number): number
	local depth, _, _ = rawSample(field, x, z)
	return depth
end

--- Full query: depth plus where it came from.
---
--- This is the honesty mechanism. A result only says surveyed:true when the
--- position was inside the survey footprint AND every corner that actually
--- weights the interpolation carries real data. Everything else — coverage
--- holes, outside the footprint, a grid that was never asserted as surveyed —
--- reports provenance "grown".
function Bathymetry.sample(field: Field, x: number, z: number): Sample
	local depth, holed, inBounds = rawSample(field, x, z)
	if not inBounds then
		return {
			depth = depth,
			provenance = "grown",
			surveyed = false,
			noData = false,
			inBounds = false,
		}
	end
	if holed then
		return {
			depth = depth,
			provenance = "grown",
			surveyed = false,
			noData = true,
			inBounds = true,
		}
	end
	return {
		depth = depth,
		provenance = field.provenance,
		surveyed = field.surveyed,
		noData = false,
		inBounds = true,
	}
end

--=============================================================================
-- Reporting
--=============================================================================

--- Fraction of cells carrying real data. The bathymetry counterpart of
--- Chart.coverage: an honest number to show next to the chart.
function Bathymetry.coverage(field: Field): number
	if field.totalCells == 0 then
		return 0
	end
	return field.validCells / field.totalCells
end

--- Provenance summary for UI surfaces: what this grid is, in its own words.
function Bathymetry.describe(field: Field): any
	return {
		name = field.name,
		description = field.description,
		surveyed = field.surveyed,
		provenance = field.provenance,
		coverage = Bathymetry.coverage(field),
		cellSize = field.cellSize,
		cols = field.cols,
		rows = field.rows,
	}
end

return Bathymetry
