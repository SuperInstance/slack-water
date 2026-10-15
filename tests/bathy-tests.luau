--!strict
--[[
	Bathymetry tests.

	These exist to protect two things:

	1. The maths. depthAt is what the boat floats on; a bilinear bug is
	   invisible until a player falls through a shoal.
	2. The honesty rule. A depth sampled from the procedural fallback or a
	   coverage hole must never come back labelled "surveyed". These
	   assertions are the mechanism, not decoration: if they fail, the game
	   is lying about its own terrain.

	The converter is driven directly (as a module) so these tests run
	headlessly with no process spawning. The bash path — convert.sh embedding
	the file and luau printing JSON — is exercised end-to-end by
	tests/run-bathy.sh.
]]

local Convert = require("./../pipeline/bathy/convert")
local Fallback = require("./../pipeline/bathy/fallback")
local Json = require("./../pipeline/bathy/json")
local Bathymetry = require("./../src/Shared/Ocean/Bathymetry")

local passed = 0
local failed = 0
local failures: { string } = {}
local currentSuite = ""

local function suite(name: string, fn: () -> ())
	currentSuite = name
	print("")
	print("== " .. name .. " ==")
	fn()
end

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  PASS  " .. name)
	else
		failed += 1
		table.insert(failures, currentSuite .. " / " .. name .. ": " .. tostring(err))
		print("  FAIL  " .. name .. "\n        " .. tostring(err))
	end
end

local function assertEq(actual: any, expected: any, msg: string?)
	if actual ~= expected then
		error(
			(msg or "values differ")
				.. " — expected "
				.. tostring(expected)
				.. ", got "
				.. tostring(actual),
			2
		)
	end
end

local function assertTrue(cond: any, msg: string?)
	if not cond then
		error(msg or "expected true", 2)
	end
end

local function assertFalse(cond: any, msg: string?)
	if cond then
		error(msg or "expected false", 2)
	end
end

local function assertClose(actual: number, expected: number, tol: number, msg: string?)
	if math.abs(actual - expected) > tol then
		error(
			(msg or "values differ")
				.. " — expected "
				.. tostring(expected)
				.. " ± "
				.. tostring(tol)
				.. ", got "
				.. tostring(actual),
			2
		)
	end
end

--- Deep-copy a grid document, because fromGrid scales the values array in
--- place and would corrupt a shared fixture for the next test.
local function copyDoc(doc: any): any
	local out = {}
	for k, v in doc do
		if type(v) == "table" and k == "values" then
			out[k] = table.clone(v)
		elseif type(v) == "table" then
			out[k] = copyDoc(v)
		else
			out[k] = v
		end
	end
	return out
end

--=============================================================================
-- Fixtures as text (the converter's native input format)
--=============================================================================

-- Projected metres, regular 100 m spacing, but only the WEST half is covered;
-- one far-corner sounding stretches the bounds so the grid extends into
-- uncovered water. With radius 1 the east edge must come back no-data.
local HOLED_TEXT = [[
# projected metres: easting northing depth_m
0 0 20
100 0 22
200 0 24
0 100 30
100 100 33
200 100 36
0 200 44
100 200 48
200 200 52
0 300 62
100 300 67
200 300 72
400 400 90
]]

-- Four corners of one cell, constant depth — every node an exact hit, so the
-- values are pure unit conversion with no interpolation to reason about.
local FATHOM_TEXT = [[
0 0 10
100 0 10
0 100 10
100 100 10
]]

local FEET_TEXT = [[
0 0 100
100 0 100
0 100 100
100 100 100
]]

local CSV_HEADER_TEXT = [[
Northing,Easting,Depth_fm
0,0,10
100,0,10
0,100,10
100,100,10
]]

local GEO_TEXT = [[
-135.43 57.05 50
-135.42 57.05 52
-135.43 57.06 54
-135.42 57.06 56
]]

--=============================================================================
-- Format detection and parsing
--=============================================================================

suite("Bathymetry — format detection", function()
	test("space-separated triples with no header read as NOAA-style XYZ", function()
		local d = Convert.detectFormat(HOLED_TEXT)
		assertEq(d.format, "xyz")
		assertEq(d.delimiter, "ws")
		assertFalse(d.headerRow)
	end)

	test("comma-separated with a header row reads as CSV", function()
		local d = Convert.detectFormat(CSV_HEADER_TEXT)
		assertEq(d.format, "csv")
		assertEq(d.delimiter, ",")
		assertTrue(d.headerRow)
	end)

	test("tab-separated with a header row reads as TSV", function()
		local tsv = "Easting\tNorthing\tDepth_ft\n0\t0\t60\n100\t0\t66\n"
		local d = Convert.detectFormat(tsv)
		assertEq(d.format, "tsv")
		assertEq(d.delimiter, "\t")
		assertTrue(d.headerRow)
	end)

	test("comment lines are skipped, not parsed as data", function()
		local r = Convert.parseSoundings(HOLED_TEXT, "m")
		assertEq(#r.soundings, 13)
		assertEq(r.rowsSkipped, 0)
	end)

	test("column names in the header beat column order", function()
		-- Northing comes FIRST here; positional parsing would swap the axes.
		local r = Convert.parseSoundings(CSV_HEADER_TEXT, "fm")
		local s2 = r.soundings[2] -- row "100,0,10": northing 100, easting 0
		assertEq(s2.e, 0, "easting must come from the Easting column, not column 1")
		assertEq(s2.n, 100, "northing must come from the Northing column")
		local s3 = r.soundings[3] -- row "0,100,10": northing 0, easting 100
		assertEq(s3.e, 100)
		assertEq(s3.n, 0)
		assertTrue(
			r.columnMapping:find("header names") ~= nil,
			"mapping should say it used header names"
		)
	end)

	test("units are required and never guessed", function()
		local ok, err = pcall(function()
			return Convert.parseSoundings(HOLED_TEXT, nil)
		end)
		assertFalse(ok)
		assertTrue(
			tostring(err):find("units") ~= nil,
			"error should mention units: " .. tostring(err)
		)
	end)

	test("an unknown unit spelling is rejected, not approximated", function()
		local ok = pcall(function()
			return Convert.parseSoundings(HOLED_TEXT, "leagues")
		end)
		assertFalse(ok)
	end)
end)

--=============================================================================
-- Units and sign conventions
--=============================================================================

suite("Bathymetry — units", function()
	local function gridValues(text: string, units: string): { number }
		local doc = Convert.buildGrid(text, {
			units = units,
			coords = "projected",
			cellMetres = 100,
			radiusCells = 2,
			convertedAt = "2026-10-14T00:00:00Z",
		})
		return doc.grid.values
	end

	test("fathoms convert exactly: 10 fm = 18.288 m, quantised to 18.3 studs", function()
		local values = gridValues(FATHOM_TEXT, "fm")
		for _, v in values do
			assertEq(v, 183, "every node should be 183 decimetres")
		end
	end)

	test("feet convert exactly: 100 ft = 30.48 m, quantised to 30.5 studs", function()
		local values = gridValues(FEET_TEXT, "ft")
		for _, v in values do
			assertEq(v, 305)
		end
	end)

	test("metres pass through unchanged", function()
		local values = gridValues(FATHOM_TEXT:gsub("10", "18"), "m")
		for _, v in values do
			assertEq(v, 180)
		end
	end)

	test("positive-elevation input (--depth-sign up) is negated, not clamped", function()
		local text = [[
0 0 -20
100 0 -20
0 100 -20
100 100 -20
]]
		local doc = Convert.buildGrid(text, {
			units = "m",
			coords = "projected",
			cellMetres = 100,
			depthSign = "up",
			radiusCells = 2,
			convertedAt = "t",
		})
		for _, v in doc.grid.values do
			assertEq(v, 200, "-20 elevation with sign up is 20 m down")
		end
	end)

	test("soundings above datum are clamped to zero and counted", function()
		local text = [[
0 0 -5
100 0 20
0 100 20
100 100 20
]]
		local ok, result = pcall(function()
			return Convert.buildGrid(text, {
				units = "m",
				coords = "projected",
				cellMetres = 100,
				radiusCells = 2,
				convertedAt = "t",
			})
		end)
		assertTrue(ok, tostring(result))
		assertEq(result.provenanceBlock.aboveDatumClamped, 1)
	end)
end)

--=============================================================================
-- Gridding
--=============================================================================

suite("Bathymetry — gridding", function()
	test("cell count and bounds come out exact for a projected survey", function()
		local doc = Convert.buildGrid(HOLED_TEXT, {
			units = "m",
			coords = "projected",
			cellMetres = 100,
			radiusCells = 1,
			convertedAt = "t",
		})
		local g = doc.grid
		-- easting 0..400, northing 0..400 (the far corner sounding is at 400),
		-- anchor at centre (200, 200), north mapped to -Z
		assertEq(g.cols, 5)
		assertEq(g.rows, 5)
		assertClose(g.minX, -200, 1e-6)
		assertClose(g.minZ, -200, 1e-6)
		assertClose(doc.provenanceBlock.gridBoundsStuds.maxX, 200, 1e-6)
		assertClose(doc.provenanceBlock.gridBoundsStuds.maxZ, 200, 1e-6)
	end)

	test("uncovered cells are the explicit sentinel, never zero, and counted", function()
		local doc = Convert.buildGrid(HOLED_TEXT, {
			units = "m",
			coords = "projected",
			cellMetres = 100,
			radiusCells = 1,
			convertedAt = "t",
		})
		local g = doc.grid
		assertEq(#g.values, g.cols * g.rows)
		assertTrue(
			doc.provenanceBlock.noDataCells > 0,
			"the holed fixture must produce no-data cells"
		)
		local sentinels = 0
		local zeros = 0
		for _, v in g.values do
			if v == g.noDataValue then
				sentinels += 1
			elseif v == 0 then
				zeros += 1
			end
		end
		assertEq(sentinels, doc.provenanceBlock.noDataCells)
		assertEq(zeros, 0, "no cell may silently read as dry rock")
		assertTrue(doc.provenanceBlock.coverageFraction < 1)
		assertTrue(doc.provenanceBlock.coverageFraction > 0)
	end)

	test("geographic input is detected and recorded, not assumed silently", function()
		local doc = Convert.buildGrid(GEO_TEXT, {
			units = "m",
			cellMetres = 400,
			convertedAt = "t",
		})
		local geo = doc.provenanceBlock.georeference
		assertEq(geo.coords, "geographic")
		assertTrue(
			geo.coordsAssumed,
			"detection (not an explicit flag) should be reported as assumed"
		)
	end)

	test("an explicit coords flag beats detection", function()
		local doc = Convert.buildGrid(HOLED_TEXT, {
			units = "m",
			coords = "projected",
			cellMetres = 100,
			convertedAt = "t",
		})
		assertEq(doc.provenanceBlock.georeference.coords, "projected")
		assertFalse(doc.provenanceBlock.georeference.coordsAssumed)
	end)

	test("IDW on the holed fixture matches the soundings it interpolates", function()
		-- node (0,0) is an exact hit: depth must be 20 m = 200 decimetres
		local doc = Convert.buildGrid(HOLED_TEXT, {
			units = "m",
			coords = "projected",
			cellMetres = 100,
			radiusCells = 1,
			convertedAt = "t",
		})
		-- world x for easting 0 with anchor 200 is -200; northing 0 with
		-- anchor 200 maps to z = +200
		local field = Bathymetry.fromGrid(copyDoc(doc))
		assertTrue(field ~= nil)
		local s = Bathymetry.sample(field, -200, 200)
		assertClose(s.depth, 20, 0.05, "exact node hit should reproduce the sounding")
	end)
end)

--=============================================================================
-- Sampler maths
--=============================================================================

-- A hand-built document: bypasses the converter so the bilinear maths is
-- tested against exact numbers, not against IDW output.
local function planeField(): any
	local doc = {
		surveyed = true,
		provenance = "measured",
		grid = {
			cols = 2,
			rows = 2,
			cellSize = 100,
			minX = 0,
			minZ = 0,
			valueScale = 1,
			noDataValue = -32768,
			fallbackDepth = 500,
			values = { 0, 10, 20, 30 },
		},
	}
	return Bathymetry.fromGrid(doc) :: any
end

suite("Bathymetry — sampler", function()
	test("nodes return their exact values", function()
		local f = planeField()
		assertEq(Bathymetry.depthAt(f, 0, 0), 0)
		assertEq(Bathymetry.depthAt(f, 100, 0), 10)
		assertEq(Bathymetry.depthAt(f, 0, 100), 20)
		assertEq(Bathymetry.depthAt(f, 100, 100), 30)
	end)

	test("cell centre is the average of its four corners", function()
		local f = planeField()
		assertClose(Bathymetry.depthAt(f, 50, 50), 15, 1e-9)
		assertClose(Bathymetry.depthAt(f, 50, 0), 5, 1e-9)
	end)

	test("bilinear is monotonic across a monotonic surface", function()
		local f = planeField()
		local last = -1
		for x = 0, 100, 10 do
			local d = Bathymetry.depthAt(f, x, 0)
			assertTrue(d >= last, "depth should never decrease along +x here")
			last = d
		end
		assertEq(last, 10)
	end)

	test("bilinear is continuous across cell boundaries — no jumps", function()
		local doc = {
			surveyed = false,
			provenance = "grown",
			grid = {
				cols = 3,
				rows = 2,
				cellSize = 100,
				minX = 0,
				minZ = 0,
				valueScale = 1,
				noDataValue = -32768,
				fallbackDepth = 999,
				values = { 0, 10, 20, 0, 10, 20 },
			},
		}
		local f = Bathymetry.fromGrid(doc) :: any
		local left = Bathymetry.depthAt(f, 99.9999, 40)
		local right = Bathymetry.depthAt(f, 100.0001, 40)
		-- continuity means no JUMP: the difference is bounded by the slope
		-- times the probe distance (0.1/stud * 0.0002 studs = 2e-5)
		assertClose(left, right, 1e-3, "adjacent samples across a boundary must agree")
	end)

	test("a known plane is reproduced exactly at off-node positions", function()
		-- f(x, z) = 2 + 0.5x + 0.25z sampled at 50-stud nodes; bilinear
		-- interpolation reproduces planes with zero error.
		local cols, rows, cell = 5, 5, 50
		local values = {}
		for j = 0, rows - 1 do
			for i = 0, cols - 1 do
				values[j * cols + i + 1] = 2 + 0.5 * (i * cell) + 0.25 * (j * cell)
			end
		end
		local f = Bathymetry.fromGrid({
			surveyed = false,
			provenance = "grown",
			grid = {
				cols = cols,
				rows = rows,
				cellSize = cell,
				minX = 0,
				minZ = 0,
				valueScale = 1,
				noDataValue = -32768,
				fallbackDepth = 999,
				values = values,
			},
		}) :: any
		local probes = { { 37.3, 91.7 }, { 1.5, 2.5 }, { 198.2, 173.4 }, { 100, 100 } }
		for _, p in probes do
			local x, z = p[1], p[2]
			assertClose(Bathymetry.depthAt(f, x, z), 2 + 0.5 * x + 0.25 * z, 1e-9)
		end
	end)

	test("out of bounds returns the documented fallback, not NaN or error", function()
		local f = planeField()
		local probes =
			{ { -1, 0 }, { 0, -0.001 }, { 101, 0 }, { 0, 100.001 }, { 1e9, 1e9 }, { -1e9, 0 } }
		for _, p in probes do
			local d = Bathymetry.depthAt(f, p[1], p[2])
			assertEq(d, 500, "the fallback is the grid's fallbackDepth, always")
			local s = Bathymetry.sample(f, p[1], p[2])
			assertFalse(s.inBounds)
			assertFalse(s.surveyed)
			assertEq(s.provenance, "grown")
		end
	end)

	test("NaN input coordinates return the fallback rather than throwing", function()
		local f = planeField()
		local nan = 0 / 0
		assertEq(Bathymetry.depthAt(f, nan, 0), 500)
		local s = Bathymetry.sample(f, 0, nan)
		assertFalse(s.inBounds)
		assertEq(s.depth, 500)
	end)

	test("a no-data corner makes the sample noData with the fallback depth", function()
		local doc = {
			surveyed = true,
			provenance = "measured",
			grid = {
				cols = 2,
				rows = 2,
				cellSize = 100,
				minX = 0,
				minZ = 0,
				valueScale = 1,
				noDataValue = -32768,
				fallbackDepth = 400,
				values = { 0, -32768, 20, 30 },
			},
		}
		local f = Bathymetry.fromGrid(doc) :: any
		local s = Bathymetry.sample(f, 50, 50)
		assertTrue(s.inBounds)
		assertTrue(s.noData)
		assertEq(s.depth, 400)
		assertFalse(s.surveyed, "a hole is never surveyed, whatever the grid claims")
		assertEq(s.provenance, "grown")
		-- the untouched north-west corner still interpolates normally
		assertEq(Bathymetry.depthAt(f, 0, 100), 20)
	end)

	test("coverage is the valid fraction of cells", function()
		local f = Bathymetry.fromGrid({
			surveyed = false,
			provenance = "grown",
			grid = {
				cols = 2,
				rows = 2,
				cellSize = 100,
				minX = 0,
				minZ = 0,
				valueScale = 1,
				noDataValue = -32768,
				fallbackDepth = 400,
				values = { 0, -32768, 20, 30 },
			},
		}) :: any
		assertClose(Bathymetry.coverage(f), 0.75, 1e-9)
	end)

	test("sampling is deterministic across repeated calls", function()
		local f = planeField()
		local a = Bathymetry.sample(f, 33.3, 66.6)
		local b = Bathymetry.sample(f, 33.3, 66.6)
		assertEq(a.depth, b.depth)
		assertEq(a.provenance, b.provenance)
		assertEq(a.surveyed, b.surveyed)
	end)
end)

--=============================================================================
-- Provenance — the honesty rule
--=============================================================================

suite("Bathymetry — provenance", function()
	test("a synthetic surveyed fixture reports surveyed:true at covered nodes", function()
		local doc = Convert.buildGrid(FATHOM_TEXT, {
			units = "fm",
			coords = "projected",
			cellMetres = 100,
			radiusCells = 2,
			surveyed = true,
			sourceFile = "synthetic-survey.xyz",
			sourceDescription = "synthetic fixture, used to exercise the flag",
			convertedAt = "t",
		})
		assertEq(doc.surveyed, true)
		assertEq(doc.provenance, "measured")

		local field = Bathymetry.fromGrid(copyDoc(doc))
		assertTrue(field ~= nil)
		local s = Bathymetry.sample(field, -50, 50)
		assertTrue(s.inBounds)
		assertTrue(s.surveyed, "a covered node of an asserted survey is surveyed")
		assertEq(s.provenance, "measured")
	end)

	test("the same fixture WITHOUT the assertion reports surveyed:false", function()
		local doc = Convert.buildGrid(FATHOM_TEXT, {
			units = "fm",
			coords = "projected",
			cellMetres = 100,
			radiusCells = 2,
			surveyed = false,
			convertedAt = "t",
		})
		assertEq(doc.surveyed, false)
		assertEq(doc.provenance, "grown")
		local field = Bathymetry.fromGrid(copyDoc(doc))
		local s = Bathymetry.sample(field, -50, 50)
		assertFalse(s.surveyed)
		assertEq(s.provenance, "grown")
		assertTrue(
			doc.description:find("did NOT assert") ~= nil,
			"the description should say the assertion is missing"
		)
	end)

	test("the procedural fallback reports surveyed:false everywhere", function()
		local doc = Fallback.build()
		assertEq(doc.surveyed, false)
		assertEq(doc.provenance, "grown")
		assertTrue(
			doc.description:find("NOT real survey data") ~= nil,
			"the fallback description must say it is not real data"
		)

		local field = Bathymetry.fromGrid(copyDoc(doc))
		assertTrue(field ~= nil)
		-- probe corners, centre and mid-edges: nowhere may it claim to be surveyed
		local probes = {
			{ -599, -599 },
			{ 599, -599 },
			{ -599, 599 },
			{ 599, 599 },
			{ 0, 0 },
			{ -300, 0 },
			{ 250, 350 },
		}
		for _, p in probes do
			local s = Bathymetry.sample(field, p[1], p[2])
			assertTrue(s.inBounds, "the fallback covers the whole world footprint")
			assertFalse(s.surveyed, "procedural water is never surveyed")
			assertEq(s.provenance, "grown")
			assertFalse(s.noData)
		end
	end)

	test("the fallback's depths stay inside the documented shelf range", function()
		local field = Bathymetry.fromGrid(copyDoc(Fallback.build())) :: any
		local minD, maxD = math.huge, -math.huge
		for j = 0, field.rows - 1 do
			for i = 0, field.cols - 1 do
				local d = Bathymetry.depthAt(
					field,
					field.minX + i * field.cellSize,
					field.minZ + j * field.cellSize
				)
				if d < minD then
					minD = d
				end
				if d > maxD then
					maxD = d
				end
			end
		end
		assertTrue(minD >= 3, "clamped shallow floor is 3 studs, got " .. minD)
		assertTrue(maxD <= 400, "clamped shelf break is 400 studs, got " .. maxD)
		assertTrue(maxD > 150, "a shelf that never deepens is a bug in the profile")
		assertTrue(field.fallbackDepth > 0)
	end)

	test("fromGrid downgrades an unrecognised provenance word to grown", function()
		local doc = copyDoc(Fallback.build())
		doc.provenance = "definitely-fine-trust-me"
		doc.surveyed = true
		local field = Bathymetry.fromGrid(doc)
		assertTrue(field ~= nil)
		assertEq(field.provenance, "grown")
		assertFalse(field.surveyed, "surveyed rides on the provenance word, never alone")
	end)

	test("measured without surveyed=true is also downgraded", function()
		local doc = copyDoc(Fallback.build())
		doc.provenance = "measured"
		doc.surveyed = false
		local field = Bathymetry.fromGrid(doc)
		assertEq(field.provenance, "grown")
	end)
end)

--=============================================================================
-- Loader validation
--=============================================================================

suite("Bathymetry — loader", function()
	local function baseGridDoc(): any
		return {
			surveyed = false,
			provenance = "grown",
			grid = {
				cols = 2,
				rows = 2,
				cellSize = 100,
				minX = 0,
				minZ = 0,
				valueScale = 1,
				noDataValue = -32768,
				fallbackDepth = 100,
				values = { 10, 20, 30, 40 },
			},
		}
	end

	test("a well-formed document loads and keeps its grid identity", function()
		local f = Bathymetry.fromGrid(baseGridDoc()) :: any
		assertTrue(f ~= nil)
		assertEq(f.name, "unnamed")
		assertEq(f.totalCells, 4)
		assertEq(f.validCells, 4)
		local d = Bathymetry.describe(f)
		assertEq(d.surveyed, false)
		assertClose(d.coverage, 1, 1e-9)
	end)

	test("a values array that disagrees with cols*rows is rejected", function()
		local doc = baseGridDoc()
		table.remove(doc.grid.values)
		assertTrue(Bathymetry.fromGrid(doc) == nil)
	end)

	test("a single-cell grid is rejected (nothing to interpolate)", function()
		local doc = baseGridDoc()
		doc.grid.cols = 1
		doc.grid.rows = 1
		assertTrue(Bathymetry.fromGrid(doc) == nil)
	end)

	test("non-table input is rejected without throwing", function()
		assertTrue(Bathymetry.fromGrid(nil) == nil)
		assertTrue(Bathymetry.fromGrid("nope") == nil)
		assertTrue(Bathymetry.fromGrid(42) == nil)
		assertTrue(Bathymetry.fromGrid({}) == nil)
	end)

	test("an all-no-data grid is rejected rather than always falling back", function()
		local doc = baseGridDoc()
		doc.grid.values = { -32768, -32768, -32768, -32768 }
		assertTrue(Bathymetry.fromGrid(doc) == nil)
	end)

	test("out-of-range values degrade to no-data instead of failing the load", function()
		local doc = baseGridDoc()
		doc.grid.values = { 10, 99999999, 30, 40 }
		local f = Bathymetry.fromGrid(doc) :: any
		assertTrue(f ~= nil)
		assertEq(f.validCells, 3)
		assertClose(Bathymetry.coverage(f), 0.75, 1e-9)
	end)

	test("a missing fallbackDepth is derived as the mean of valid cells", function()
		local doc = baseGridDoc()
		doc.grid.fallbackDepth = nil
		local f = Bathymetry.fromGrid(doc) :: any
		assertClose(f.fallbackDepth, 25, 1e-9)
	end)

	test("valueScale is applied at load (decimetres become studs)", function()
		local doc = baseGridDoc()
		doc.grid.valueScale = 0.1
		doc.grid.fallbackDepth = 1000
		local f = Bathymetry.fromGrid(doc) :: any
		assertClose(Bathymetry.depthAt(f, 0, 0), 1.0, 1e-9)
		assertClose(f.fallbackDepth, 100, 1e-9)
	end)
end)

--=============================================================================
-- Determinism
--=============================================================================

suite("Bathymetry — determinism", function()
	test("the converter is byte-identical across runs for pinned input", function()
		local opts = {
			units = "m",
			coords = "projected",
			cellMetres = 100,
			radiusCells = 1,
			name = "det",
			sourceFile = "det.xyz",
			convertedAt = "2026-10-14T00:00:00Z",
		}
		local a = Convert.toJson(Convert.buildGrid(HOLED_TEXT, opts))
		local b = Convert.toJson(Convert.buildGrid(HOLED_TEXT, opts))
		assertEq(#a, #b)
		assertEq(a, b, "same input must serialise to identical JSON")
		assertTrue(#a > 100)
	end)

	test("the fallback bake is byte-identical across builds", function()
		local a = Json.encode(Fallback.build())
		local b = Json.encode(Fallback.build())
		assertEq(a, b)
	end)

	test("the JSON encoder itself is stable (sorted keys, no clock)", function()
		local a = Json.encode({ b = 1, a = { z = 1.5, y = 2 }, c = { 3, 2, 1 } })
		local b = Json.encode({ c = { 3, 2, 1 }, a = { y = 2, z = 1.5 }, b = 1 })
		assertEq(a, b)
	end)
end)

--=============================================================================
-- Summary
--=============================================================================

print("")
print("===========================================")
print(string.format("passed: %d   failed: %d", passed, failed))
if failed > 0 then
	print("")
	print("Failures:")
	for _, f in failures do
		print("  - " .. f)
	end
	print("===========================================")
	error(string.format("%d test(s) failed", failed), 0)
end
print("all green")
print("===========================================")
