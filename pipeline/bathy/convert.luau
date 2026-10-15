--!strict
--[[
	Convert — irregular sounding text → normalised, baked depth grid.

	This is the ingest side of the bathymetry pipeline. It runs ONLY under the
	standalone `luau` CLI (never in Roblox), so it may not need the dual-target
	require idiom — but it must obey the same honesty rule as everything else
	in this repo: **generated water is never presented as surveyed.**

	Three decisions are deliberately NOT made silently:

	1. UNITS are an explicit, required input (`m`, `ft`, `fm`). Depth units are
	   never guessed from the file, because a fathom column mistaken for metres
	   puts every shoal 1.8× deeper than it is — the kind of error that poisons
	   a dataset silently.
	2. `--surveyed` is an explicit operator assertion, off by default. The
	   converter cannot verify that a file contains real soundings; it can only
	   record WHO asserted what. Without the flag the output is marked
	   `surveyed: false` / `provenance: "grown"`.
	3. No-data is explicit. A grid cell with no sounding inside the search
	   radius is written as the sentinel -32768 and counted — never as zero,
	   which would invent dry rock where nobody has measured.

	Provenance vocabulary is shared with src/Shared/Ocean/Chart.luau:
	`measured` (operator-asserted real soundings) and `grown` (everything
	else). There is no `composed` here — the language model does not generate
	bathymetry.

	Everything is deterministic: no RNG, no wall clock inside the gridding
	maths, fixed iteration order everywhere. The optional timestamp in the
	provenance block is metadata, and tests pin it to prove byte-identical
	output.
]]

local Json = require("./json")

local Convert = {}

--=============================================================================
-- Constants
--=============================================================================

-- Depth values are stored quantised to this many studs; integers keep the JSON
-- compact (a 1000x1000 grid is ~1M values) and survive a JSON round-trip
-- exactly, unlike decimals.
local VALUE_SCALE = 0.1
-- Sentinel written into cells with no sounding inside the search radius.
-- Negative, so it can never collide with a real (>= 0) depth.
local NODATA = -32768

-- Soundings deeper/shallower than this (in metres) are skipped and counted,
-- not clamped: a 99999 in a hand-edited file is a bad row, not deep water.
local MAX_DEPTH_M = 5000

-- Horizontal conversion. Equirectangular is exact enough at the ~10 km extent
-- of a fishing ground; the alternative (a real projection) is not worth a
-- dependency in a Luau pipeline.
local METRES_PER_DEG_LAT = 111320

-- Unit factors, exact. 1 fathom = 6 ft = 1.8288 m exactly.
local UNIT_FACTORS: { [string]: number } = {
	m = 1.0,
	metre = 1.0,
	metres = 1.0,
	meter = 1.0,
	meters = 1.0,
	ft = 0.3048,
	foot = 0.3048,
	feet = 0.3048,
	fm = 1.8288,
	fathom = 1.8288,
	fathoms = 1.8288,
}

-- Header names we recognise, normalised (lowercase, alphanumerics only).
local LON_NAMES = { lon = true, long = true, longitude = true, easting = true, x = true }
local LAT_NAMES = { lat = true, latitude = true, northing = true, y = true }
local DEPTH_NAMES = {
	depth = true,
	dep = true,
	depthm = true,
	depthmllw = true,
	depthft = true,
	depthfm = true,
	sounding = true,
	soundings = true,
	z = true,
}

--=============================================================================
-- Text parsing
--=============================================================================

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unquote(s: string): string
	if #s >= 2 and s:sub(1, 1) == '"' and s:sub(-1) == '"' then
		return (s:sub(2, -2):gsub('""', '"'))
	end
	return s
end

local function splitFields(line: string, delimiter: string): { string }
	local fields: { string } = {}
	if delimiter == "ws" then
		for token in line:gmatch("[^ \t]+") do
			table.insert(fields, token)
		end
	else
		local start = 1
		while true do
			local hit = line:find(delimiter, start, true)
			if not hit then
				table.insert(fields, line:sub(start))
				break
			end
			table.insert(fields, line:sub(start, hit - 1))
			start = hit + 1
		end
	end
	return fields
end

--- Look at the first data line and decide what we are reading.
---
--- Reports rather than assumes: the caller surfaces `format`, `delimiter`
--- and `headerRow` in the provenance block so a human can check the guess.
function Convert.detectFormat(text: string): {
	format: string,
	delimiter: string,
	headerRow: boolean,
	headerFields: { string }?,
}
	local firstDataLine = ""
	local sawData = false
	for rawLine in text:gmatch("([^\r\n]*)") do
		local line = trim(rawLine)
		if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 2) ~= "//" then
			firstDataLine = line
			sawData = true
			break
		end
	end
	if not sawData then
		error("convert: no non-empty, non-comment lines in input", 0)
	end

	local delimiter = "ws"
	if firstDataLine:find(",", 1, true) then
		delimiter = ","
	elseif firstDataLine:find("\t", 1, true) then
		delimiter = "\t"
	end

	local fields = splitFields(firstDataLine, delimiter)
	local hasAlpha = false
	for _, f in fields do
		if f:find("%a") then
			hasAlpha = true
			break
		end
	end

	local format = if delimiter == "," then "csv" elseif delimiter == "\t" then "tsv" else "xyz"
	return {
		format = format,
		delimiter = delimiter,
		headerRow = hasAlpha,
		headerFields = if hasAlpha then fields else nil,
	}
end

local function normaliseName(name: string): string
	return (trim(name):gsub("[^%a%d]", ""):lower())
end

--- Map header names to column indices. Returns nil if the names are not
--- recognisable — the caller then falls back to positional columns and says so.
local function mapHeader(fields: { string }): { lon: number, lat: number, depth: number }?
	local map: { [string]: number } = {}
	for i, raw in fields do
		local n = normaliseName(raw)
		if LON_NAMES[n] and map.lon == nil then
			map.lon = i
		elseif LAT_NAMES[n] and map.lat == nil then
			map.lat = i
		elseif DEPTH_NAMES[n] and map.depth == nil then
			map.depth = i
		end
	end
	if map.lon and map.lat and map.depth then
		return { lon = map.lon, lat = map.lat, depth = map.depth }
	end
	return nil
end

export type Sounding = { e: number, n: number, depthM: number }

export type ParseResult = {
	soundings: { Sounding },
	format: string,
	delimiter: string,
	headerRow: boolean,
	columnMapping: string,
	linesRead: number,
	rowsSkipped: number,
	aboveDatumClamped: number,
	outOfRangeSkipped: number,
}

--- Parse sounding rows. `units` is required and must be one of the keys of
--- UNIT_FACTORS (m/ft/fm and long aliases) — depth units are never guessed.
--- `depthSign` is "down" (positive depth, the default) or "up" (positive
--- elevation, e.g. GEBCO-style exports; depth = -value).
function Convert.parseSoundings(text: string, units: string, depthSign: string?): ParseResult
	local factor = UNIT_FACTORS[units and units:lower() or ""]
	if factor == nil then
		error(
			'convert: --units is required and must be m, ft or fm (got "'
				.. tostring(units)
				.. '"); units are never guessed',
			0
		)
	end
	if depthSign == nil then
		depthSign = "down"
	end
	if depthSign ~= "down" and depthSign ~= "up" then
		error(
			'convert: --depth-sign must be "down" or "up", got "' .. tostring(depthSign) .. '"',
			0
		)
	end

	local detection = Convert.detectFormat(text)
	local mapping: { lon: number, lat: number, depth: number }?
	local mappingHow = "positional lon,lat,depth (assumed — no recognisable header)"
	if detection.headerRow and detection.headerFields then
		mapping = mapHeader(detection.headerFields)
		if mapping then
			mappingHow = "header names"
		else
			mappingHow =
				"positional lon,lat,depth (assumed — header present but names not recognised)"
		end
	end
	if mapping == nil then
		mapping = { lon = 1, lat = 2, depth = 3 }
	end

	local soundings: { Sounding } = {}
	local linesRead = 0
	local rowsSkipped = 0
	local aboveDatumClamped = 0
	local outOfRangeSkipped = 0
	local headerSkipped = false

	for rawLine in text:gmatch("([^\r\n]*)") do
		local line = trim(rawLine)
		if line == "" or line:sub(1, 1) == "#" or line:sub(1, 2) == "//" then
			continue
		end
		if detection.headerRow and not headerSkipped then
			-- the header row is metadata, not a bad data row
			headerSkipped = true
			continue
		end
		linesRead += 1

		local fields = splitFields(line, detection.delimiter)
		local eRaw = tonumber(unquote(fields[mapping.lon] or ""))
		local nRaw = tonumber(unquote(fields[mapping.lat] or ""))
		local dRaw = tonumber(unquote(fields[mapping.depth] or ""))
		if eRaw == nil or nRaw == nil or dRaw == nil then
			rowsSkipped += 1
			continue
		end

		local depthM = dRaw * factor
		if depthSign == "up" then
			depthM = -depthM
		end
		if depthM < 0 then
			-- above datum (rock, shoreline); the game's water surface IS the
			-- datum, so clamp to 0 and count it honestly.
			depthM = 0
			aboveDatumClamped += 1
		end
		if depthM > MAX_DEPTH_M then
			rowsSkipped += 1
			outOfRangeSkipped += 1
			continue
		end

		table.insert(soundings, { e = eRaw, n = nRaw, depthM = depthM })
	end

	if #soundings == 0 then
		error(
			string.format(
				"convert: no parseable rows (%d read, %d skipped) — check delimiter and columns",
				linesRead,
				rowsSkipped
			),
			0
		)
	end
	if rowsSkipped > linesRead * 0.1 + 2 then
		error(
			string.format(
				"convert: too many bad rows (%d of %d) — this is probably the wrong format guess",
				rowsSkipped,
				linesRead
			),
			0
		)
	end

	return {
		soundings = soundings,
		format = detection.format,
		delimiter = detection.delimiter,
		headerRow = detection.headerRow,
		columnMapping = string.format(
			"lon=col%d lat=col%d depth=col%d (%s)",
			mapping.lon,
			mapping.lat,
			mapping.depth,
			mappingHow
		),
		linesRead = linesRead,
		rowsSkipped = rowsSkipped,
		aboveDatumClamped = aboveDatumClamped,
		outOfRangeSkipped = outOfRangeSkipped,
	}
end

--=============================================================================
-- Georeferencing and gridding
--=============================================================================

local function finiteNumber(v: any, fallback: number?): number?
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return fallback
end

export type GridOptions = {
	cellMetres: number,
	coords: string?, -- "geographic" | "projected" (nil = detect and report)
	anchorLon: number?,
	anchorLat: number?,
	studsPerMetre: number,
	radiusCells: number,
	maxNodes: number,
}

--- Resample irregular soundings onto a regular node grid.
---
--- Method: bucket the soundings by grid cell, then for each node walk buckets
--- outwards in Chebyshev rings, accumulating an inverse-distance-weighted
--- (1/d^2) mean of every sounding within the radius. Rings are walked in a
--- fixed order and the bucket lists keep input order, so the float summation
--- order — and therefore the output — is identical every run.
---
--- A node with no sounding within `radiusCells` cells is NODATA. It is never
--- zero and never silently interpolated from far away.
function Convert.toGrid(parsed: ParseResult, opts: GridOptions): any
	local soundings = parsed.soundings

	-- Coordinate mode: explicit wins; otherwise detect and REPORT.
	local coordsMode = opts.coords
	local coordsAssumed = coordsMode == nil
	if coordsAssumed then
		local maxAbsE, maxAbsN = 0, 0
		for _, s in soundings do
			if math.abs(s.e) > maxAbsE then
				maxAbsE = math.abs(s.e)
			end
			if math.abs(s.n) > maxAbsN then
				maxAbsN = math.abs(s.n)
			end
		end
		-- Degrees are <= 180/90; projected metres (UTM etc.) are in the
		-- hundreds of thousands. A small projected survey in local metres is
		-- indistinguishable from degrees and the explicit flag exists for it.
		coordsMode = if maxAbsE <= 180 and maxAbsN <= 90 then "geographic" else "projected"
	end
	if coordsMode ~= "geographic" and coordsMode ~= "projected" then
		error('convert: coords must be "geographic" or "projected"', 0)
	end

	-- Bounds in input coordinates.
	local minE, maxE = math.huge, -math.huge
	local minN, maxN = math.huge, -math.huge
	for _, s in soundings do
		if s.e < minE then
			minE = s.e
		end
		if s.e > maxE then
			maxE = s.e
		end
		if s.n < minN then
			minN = s.n
		end
		if s.n > maxN then
			maxN = s.n
		end
	end

	local anchorE = finiteNumber(opts.anchorLon, (minE + maxE) / 2) :: number
	local anchorN = finiteNumber(opts.anchorLat, (minN + maxN) / 2) :: number
	local spm = finiteNumber(opts.studsPerMetre, 1.0) :: number
	if spm <= 0 then
		error("convert: studsPerMetre must be > 0", 0)
	end

	-- Input coords → metres east/north of the anchor.
	local mPerDegLon = METRES_PER_DEG_LAT * math.cos(math.rad(anchorN))
	local function toMetres(s: Sounding): (number, number)
		if coordsMode == "geographic" then
			return (s.e - anchorE) * mPerDegLon, (s.n - anchorN) * METRES_PER_DEG_LAT
		end
		return s.e - anchorE, s.n - anchorN
	end

	-- Metres → world studs. North maps to -Z (Roblox convention: -Z is
	-- "forward"/north on a map view). Recorded in the provenance block.
	local pts: { { x: number, z: number, v: number } } = {}
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, s in soundings do
		local eastM, northM = toMetres(s)
		local x = eastM * spm
		local z = -northM * spm
		table.insert(pts, { x = x, z = z, v = s.depthM * spm })
		if x < minX then
			minX = x
		end
		if x > maxX then
			maxX = x
		end
		if z < minZ then
			minZ = z
		end
		if z > maxZ then
			maxZ = z
		end
	end

	local cellMetres = finiteNumber(opts.cellMetres, 50) :: number
	local cell = cellMetres * spm
	if cell <= 0 then
		error("convert: cell size must be > 0", 0)
	end
	local cols = math.floor((maxX - minX) / cell + 1e-9) + 1
	local rows = math.floor((maxZ - minZ) / cell + 1e-9) + 1
	local totalNodes = cols * rows
	if cols < 2 or rows < 2 then
		error(
			string.format(
				"convert: grid is %dx%d — the input span is smaller than one cell",
				cols,
				rows
			),
			0
		)
	end
	if totalNodes > opts.maxNodes then
		error(
			string.format(
				"convert: grid would be %dx%d = %d nodes (max %d) — increase --cell or --max-nodes",
				cols,
				rows,
				totalNodes,
				opts.maxNodes
			),
			0
		)
	end

	-- Bucket soundings by cell. buckets[i] is nil or a list in input order.
	local buckets: { { { x: number, z: number, v: number } }? } = {}
	for _, p in pts do
		local bi = math.clamp(math.floor((p.x - minX) / cell + 1e-9), 0, cols - 1)
		local bj = math.clamp(math.floor((p.z - minZ) / cell + 1e-9), 0, rows - 1)
		local idx = bj * cols + bi + 1
		local list = buckets[idx]
		if list == nil then
			list = {}
			buckets[idx] = list
		end
		table.insert(list, p)
	end

	local radius = math.max(1, math.floor(finiteNumber(opts.radiusCells, 3) :: number))
	local maxDist = (radius + 0.5) * cell
	local maxDist2 = maxDist * maxDist

	local values: { number } = {}
	-- nodes are written strictly in row-major order, so the array part grows
	-- densely without table.resize (which this luau build does not provide)
	local valid = 0
	local sumV = 0.0
	local minV, maxV = math.huge, -math.huge

	for j = 0, rows - 1 do
		for i = 0, cols - 1 do
			local nx = minX + i * cell
			local nz = minZ + j * cell

			-- Inverse-distance mean over soundings in expanding rings.
			local sumW, sumWV, count = 0.0, 0.0, 0
			local nodeValue: number? = nil
			for r = 0, radius do
				for dj = -r, r do
					local j0 = j + dj
					if j0 < 0 or j0 > rows - 1 then
						continue
					end
					for di = -r, r do
						-- Chebyshev ring r only: skip the interior, which an
						-- earlier ring already visited.
						if math.max(math.abs(di), math.abs(dj)) ~= r then
							continue
						end
						local i0 = i + di
						if i0 < 0 or i0 > cols - 1 then
							continue
						end
						local list = buckets[j0 * cols + i0 + 1]
						if list == nil then
							continue
						end
						for _, p in list do
							local dx = p.x - nx
							local dz = p.z - nz
							local d2 = dx * dx + dz * dz
							if d2 > maxDist2 then
								continue
							end
							if d2 < 1e-12 then
								-- sounding exactly on the node: no weighting
								-- can beat it
								nodeValue = p.v
								break
							end
							local w = 1 / (d2 + 1e-4)
							sumW += w
							sumWV += w * p.v
							count += 1
						end
						if nodeValue ~= nil then
							break
						end
					end
					if nodeValue ~= nil then
						break
					end
				end
				-- Enough nearby soundings; stop expanding. Bounded and
				-- deterministic: the ring order is fixed.
				if nodeValue == nil and r >= 1 and count >= 6 then
					break
				end
			end

			if nodeValue == nil and count > 0 then
				nodeValue = sumWV / sumW
			end

			local idx = j * cols + i + 1
			if nodeValue == nil then
				values[idx] = NODATA
			else
				local q = math.floor(nodeValue / VALUE_SCALE + 0.5)
				values[idx] = q
				valid += 1
				sumV += q
				if q < minV then
					minV = q
				end
				if q > maxV then
					maxV = q
				end
			end
		end
	end

	if valid == 0 then
		error(
			string.format(
				"convert: no node found a sounding within %d cells — try a larger --radius or smaller --cell",
				radius
			),
			0
		)
	end

	-- Documented fallback for out-of-bounds / no-data sampling: the mean of
	-- the valid cells. Honest in aggregate, never presented as surveyed.
	local fallbackQ = math.floor(sumV / valid + 0.5)

	return {
		cols = cols,
		rows = rows,
		cellSize = cell,
		minX = minX,
		minZ = minZ,
		valueScale = VALUE_SCALE,
		noDataValue = NODATA,
		depthUnits = "studs",
		positive = "down",
		values = values,
		fallbackDepth = fallbackQ,
		coverage = valid / totalNodes,
		noDataCells = totalNodes - valid,
		depthMinStuds = minV * VALUE_SCALE,
		depthMaxStuds = maxV * VALUE_SCALE,
		boundsInput = { minE = minE, maxE = maxE, minN = minN, maxN = maxN },
		gridBoundsStuds = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ },
		georeference = {
			mode = if coordsMode == "geographic" then "equirectangular" else "local metres",
			coords = coordsMode,
			coordsAssumed = coordsAssumed,
			anchorE = anchorE,
			anchorN = anchorN,
			studsPerMetre = spm,
			northAxis = "-Z",
		},
	}
end

--=============================================================================
-- Document assembly
--=============================================================================

export type BuildOptions = {
	units: string, -- REQUIRED: m | ft | fm
	depthSign: string?, -- "down" (default) | "up"
	coords: string?, -- "geographic" | "projected" (nil = detect)
	cellMetres: number?,
	anchorLon: number?,
	anchorLat: number?,
	studsPerMetre: number?,
	radiusCells: number?,
	maxNodes: number?,
	name: string?,
	description: string?,
	sourceFile: string?,
	sourceDescription: string?,
	surveyed: boolean?,
	-- ISO string; default is the current time. Tests pin this for
	-- byte-identical output.
	convertedAt: string?,
}

--- Full pipeline: text → parse → grid → document table ready for Json.encode.
function Convert.buildGrid(text: string, opts: BuildOptions): any
	local parsed = Convert.parseSoundings(text, opts.units, opts.depthSign)

	local grid = Convert.toGrid(parsed, {
		cellMetres = finiteNumber(opts.cellMetres, 50) :: number,
		coords = opts.coords,
		anchorLon = opts.anchorLon,
		anchorLat = opts.anchorLat,
		studsPerMetre = finiteNumber(opts.studsPerMetre, 1.0) :: number,
		radiusCells = finiteNumber(opts.radiusCells, 3) :: number,
		maxNodes = finiteNumber(opts.maxNodes, 2500000) :: number,
	})

	local surveyed = opts.surveyed == true
	local spm = grid.georeference.studsPerMetre

	local sourceName = tostring(opts.sourceFile or "unnamed")
	local description
	if opts.description then
		description = opts.description
	elseif surveyed then
		description = 'Converted from sounding file "'
			.. sourceName
			.. '". Surveyed status is an OPERATOR ASSERTION (--surveyed); the pipeline records it, it cannot verify it.'
	else
		description = 'Converted from sounding file "'
			.. sourceName
			.. '", but the operator did NOT assert these are real soundings. Treat as provisional: surveyed is false.'
	end

	return {
		name = opts.name or "survey",
		description = description,
		surveyed = surveyed,
		provenance = if surveyed then "measured" else "grown",
		grid = {
			cols = grid.cols,
			rows = grid.rows,
			cellSize = grid.cellSize,
			minX = grid.minX,
			minZ = grid.minZ,
			valueScale = grid.valueScale,
			noDataValue = grid.noDataValue,
			depthUnits = grid.depthUnits,
			positive = grid.positive,
			fallbackDepth = grid.fallbackDepth,
			values = grid.values,
		},
		provenanceBlock = {
			sourceDescription = opts.sourceDescription or "",
			sourceFile = opts.sourceFile or "",
			convertedAt = opts.convertedAt or os.date("!%Y-%m-%dT%H:%M:%SZ"),
			converter = "slack-water pipeline/bathy convert v1",
			formatDetected = parsed.format,
			delimiter = parsed.delimiter,
			headerRow = parsed.headerRow,
			columnMapping = parsed.columnMapping,
			unitsInput = opts.units:lower(),
			depthSign = opts.depthSign or "down",
			soundingsRead = parsed.linesRead,
			soundingsUsed = #parsed.soundings,
			rowsSkipped = parsed.rowsSkipped,
			aboveDatumClamped = parsed.aboveDatumClamped,
			outOfRangeSkipped = parsed.outOfRangeSkipped,
			depthMinMetres = grid.depthMinStuds / spm,
			depthMaxMetres = grid.depthMaxStuds / spm,
			cellSizeMetres = grid.cellSize / spm,
			radiusCells = math.max(1, math.floor(finiteNumber(opts.radiusCells, 3) :: number)),
			noDataPolicy = string.format(
				"nodes with no sounding within radiusCells of coverage are the sentinel %d, never zero; the sampler reports them as noData",
				NODATA
			),
			noDataCells = grid.noDataCells,
			coverageFraction = grid.coverage,
			valueScale = grid.valueScale,
			unitsOutput = "studs",
			boundsInput = grid.boundsInput,
			gridBoundsStuds = grid.gridBoundsStuds,
			georeference = grid.georeference,
		},
	}
end

function Convert.toJson(doc: any): string
	return Json.encode(doc)
end

Convert.VALUE_SCALE = VALUE_SCALE
Convert.NODATA = NODATA

return Convert
