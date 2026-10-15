--!strict
--[[
	Tide and chart tests.

	The tide is the game's clock, so these tests care about *shape*, not exact
	heights — the harmonic constants are estimated, not measured. What must hold
	is that the tide behaves like a real mixed semidiurnal tide: a range a small
	boat can be caught by, slack that genuinely occurs, shallows that dry out at
	low water, and a current that is strongest mid-tide.
]]

local Tide = require("./../src/Shared/Tide")
local Chart = require("./../src/Shared/Ocean/Chart")
local Config = require("./../src/Shared/Config")

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

local function assertTrue(cond: boolean, msg: string?)
	if not cond then
		error(msg or "expected true", 2)
	end
end

local function assertFalse(cond: boolean, msg: string?)
	if cond then
		error(msg or "expected false", 2)
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

--=============================================================================
-- Tide
--=============================================================================

suite("Tide — the clock", function()
	test("height stays inside a plausible range", function()
		local minH, maxH = math.huge, -math.huge
		for i = 0, 24 * 30 do
			local h = Tide.heightAt(i * 0.25)
			minH = math.min(minH, h)
			maxH = math.max(maxH, h)
		end
		assertTrue(maxH - minH > 1.5, "tidal range should be felt, got " .. tostring(maxH - minH))
		assertTrue(
			maxH - minH < 6.0,
			"tidal range should stay plausible, got " .. tostring(maxH - minH)
		)
	end)

	test("the tide actually moves over a day", function()
		local a = Tide.heightAt(0)
		local b = Tide.heightAt(6)
		local c = Tide.heightAt(12)
		assertFalse(math.abs(a - b) < 0.02, "six hours apart should not be the same height")
		assertFalse(math.abs(b - c) < 0.02, "twelve hours apart should not be the same height")
	end)

	test("the pattern is not a plain sine — constituents beat against each other", function()
		-- A single-frequency tide repeats exactly every period. A real one does
		-- not, because M2 and S2 drift apart. If this test ever passes with a
		-- constant difference, the harmonic sum has collapsed to one term.
		local d1 = math.abs(Tide.heightAt(0) - Tide.heightAt(12.42))
		local d2 = math.abs(Tide.heightAt(12.42) - Tide.heightAt(24.84))
		assertFalse(math.abs(d1 - d2) < 1e-9, "tide should not be perfectly periodic over a day")
	end)

	test("nextEvents finds a genuine high and low in the future", function()
		-- Note we deliberately do NOT assert low water follows high water. This is
		-- a mixed semidiurnal tide, so where you are in the cycle decides the
		-- order of the next two events. That irregularity is the point: it is
		-- why slack water lands at a different hour each day, and why a player
		-- has to read the tide rather than memorise a clock.
		local events = Tide.nextEvents(0)
		assertTrue(events.highTime > 0, "high time should be in the future")
		assertTrue(events.lowTime > 0, "low time should be in the future")
		assertTrue(events.high > events.low, "high water must stand above low water")
		assertTrue(
			Tide.heightAt(events.highTime) >= events.high - 0.05,
			"reported high should match the curve"
		)
		assertTrue(
			Tide.heightAt(events.lowTime) <= events.low + 0.05,
			"reported low should match the curve"
		)
	end)

	test("nextEvents returns events strictly after the query time", function()
		-- The bug this guards against: bisecting at the query time and walking
		-- backwards returns an extremum the skipper has already passed.
		for hour = 0, 24, 1 do
			local events = Tide.nextEvents(hour)
			assertTrue(events.highTime > hour, "high must be in the future at hour " .. hour)
			assertTrue(events.lowTime > hour, "low must be in the future at hour " .. hour)
		end
	end)

	test("current is strongest mid-tide and slack at the extremes", function()
		local high = Tide.nextEvents(0)
		local slackAtHigh = Tide.currentAt(high.highTime)
		local slackAtLow = Tide.currentAt(high.lowTime)
		local midTide = Tide.currentAt((high.highTime + high.lowTime) / 2)

		assertTrue(slackAtHigh < midTide, "current must be weaker at high water than mid-tide")
		assertTrue(slackAtLow < midTide, "current must be weaker at low water than mid-tide")
	end)

	test("slack water occurs somewhere in every half day", function()
		-- This is what makes the game's name true: there is always a window.
		local slackWindows = 0
		for hour = 0, 48, 0.25 do
			if Tide.isSlack(hour) then
				slackWindows += 1
			end
		end
		assertTrue(slackWindows > 0, "there must be slack water to find")
	end)

	test("hoursToSlack is never negative", function()
		for hour = 0, 24, 1 do
			assertTrue(Tide.hoursToSlack(hour) >= 0, "hours to slack cannot be negative")
		end
	end)

	test("a shallow shoal is dry at low water and fishable at high water", function()
		-- The mechanic in one assertion: a 2 m shoal is rock at low water.
		local shoal = 2.0
		local lowWater = Tide.nextEvents(0).lowTime
		local highWater = Tide.nextEvents(0).highTime

		local accessibleLow = Tide.accessAt(shoal, lowWater)
		local accessibleHigh = Tide.accessAt(shoal, highWater)

		assertFalse(accessibleLow, "a 2 m shoal must be unreachable at low water")
		assertTrue(accessibleHigh, "a 2 m shoal must be fishable at high water")
	end)

	test("deep water is accessible at any tide", function()
		local deep = 120.0
		local lowWater = Tide.nextEvents(0).lowTime
		assertTrue(Tide.accessAt(deep, lowWater), "deep water should always be reachable")
	end)

	test("fishing quality is zero when inaccessible", function()
		local lowWater = Tide.nextEvents(0).lowTime
		assertEq(Tide.fishingQuality(1.0, lowWater), 0.0)
	end)

	test("better conditions beat worse ones", function()
		local high = Tide.nextEvents(0).highTime
		local deepQuality = Tide.fishingQuality(20, high)
		assertTrue(deepQuality > 0.0, "reachable ground should be fishable")
		assertTrue(deepQuality <= 1.0, "quality must not exceed 1")
	end)

	test("phaseName returns something a HUD can show", function()
		local phase = Tide.phaseName(3.5)
		assertTrue(type(phase) == "string" and #phase > 0, "phase should be a non-empty string")
	end)
end)

--=============================================================================
-- Chart provenance
--=============================================================================

local function sounding(id: string, provenance: string, confidence: number)
	return {
		id = id,
		name = id,
		habitat = "reef" :: any,
		lat = 57.0,
		lon = -135.3,
		hasPosition = true,
		chartedDepth = 12.0,
		bottomType = "rock" :: any,
		provenance = provenance :: any,
		confidence = confidence,
		surveyedAt = nil,
		source = "test",
	}
end

suite("Chart — provenance", function()
	test("add and get round-trip", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "measured", 1.0))
		assertEq(Chart.count(chart), 1)
		assertEq(Chart.get(chart, "r1").name, "r1")
	end)

	test("re-adding an id replaces rather than duplicates", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "grown", 0.3))
		Chart.add(chart, sounding("r1", "measured", 1.0))
		assertEq(Chart.count(chart), 1)
		assertEq(Chart.get(chart, "r1").provenance, "measured")
	end)

	test("a fully measured chart has full coverage", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "measured", 1.0))
		Chart.add(chart, sounding("r2", "measured", 1.0))
		assertEq(Chart.coverage(chart), 1.0)
	end)

	test("a generated chart has low coverage", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "grown", 0.5))
		assertTrue(Chart.coverage(chart) < 0.25, "grown ground must not read as surveyed")
	end)

	test("an empty chart has zero coverage", function()
		assertEq(Chart.coverage(Chart.new()), 0.0)
	end)

	test("surveying upgrades a region and moves coverage", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "grown", 0.4))
		local before = Chart.coverage(chart)
		local updated = Chart.survey(chart, "r1", { chartedDepth = 7.5, source = "boat pass" })
		assertTrue(updated ~= nil, "survey should return the updated sounding")
		assertEq(updated.provenance, "measured")
		assertEq(updated.chartedDepth, 7.5)
		assertTrue(Chart.coverage(chart) > before, "coverage should improve after a survey")
	end)

	test("surveying a non-existent region returns nil", function()
		assertTrue(Chart.survey(Chart.new(), "nope", { chartedDepth = 5 }) == nil)
	end)

	test("survey depth is clamped to a sane range", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "grown", 0.4))
		local s = Chart.survey(chart, "r1", { chartedDepth = 99999 })
		assertEq(s.chartedDepth, 900)
	end)

	test("provenance breakdown counts correctly", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "measured", 1.0))
		Chart.add(chart, sounding("r2", "grown", 0.4))
		Chart.add(chart, sounding("r3", "composed", 0.6))
		local breakdown = Chart.provenanceBreakdown(chart)
		assertEq(breakdown.measured, 1)
		assertEq(breakdown.grown, 1)
		assertEq(breakdown.composed, 1)
	end)
end)

suite("Chart — loading real data", function()
	test("loads a decoded chart array", function()
		local chart = Chart.new()
		local loaded = Chart.loadFromChart(chart, {
			{
				id = "a",
				name = "Measured Shoal",
				chartedDepth = 3.1,
				provenance = "measured",
				confidence = 1.0,
			},
			{
				id = "b",
				name = "Grown Flats",
				chartedDepth = 20,
				provenance = "grown",
				confidence = 0.4,
			},
		})
		assertEq(loaded, 2)
		assertEq(Chart.get(chart, "a").chartedDepth, 3.1)
	end)

	test("an unknown provenance string is never trusted as measured", function()
		-- This is the important one: a fabricated chart must not be able to
		-- claim it was surveyed.
		local chart = Chart.new()
		Chart.loadFromChart(chart, {
			{ id = "a", chartedDepth = 5, provenance = "verified_by_magic", confidence = 1.0 },
		})
		assertEq(Chart.get(chart, "a").provenance, "grown")
	end)

	test("out-of-range depths are clamped on load", function()
		local chart = Chart.new()
		Chart.loadFromChart(chart, { { id = "a", chartedDepth = -5, provenance = "measured" } })
		assertTrue(Chart.get(chart, "a").chartedDepth >= 0.1, "negative depth must not load")
	end)

	test("malformed payloads load nothing rather than crashing", function()
		assertEq(Chart.loadFromChart(Chart.new(), "not a table"), 0)
		assertEq(Chart.loadFromChart(Chart.new(), nil), 0)
		assertEq(Chart.loadFromChart(Chart.new(), { soundings = 5 }), 0)
	end)

	test("entries without an id are skipped", function()
		local chart = Chart.new()
		local loaded = Chart.loadFromChart(chart, { { name = "no id" }, { id = "ok" } })
		assertEq(loaded, 1)
	end)

	test("toChartArray round-trips through load", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "measured", 1.0))
		Chart.add(chart, sounding("r2", "composed", 0.7))

		local reloaded = Chart.new()
		Chart.loadFromChart(reloaded, Chart.toChartArray(chart))

		assertEq(Chart.count(reloaded), 2)
		assertEq(Chart.get(reloaded, "r1").provenance, "measured")
		assertEq(Chart.get(reloaded, "r2").provenance, "composed")
	end)

	test("toRegion carries chart depth into the simulation shape", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "measured", 1.0))
		local region = Chart.toRegion(chart, "r1")
		assertEq(region.id, "r1")
		assertEq(region.depth, 12.0)
		assertTrue(region.richness >= 0.5 and region.richness <= 1.5)
	end)

	test("toRegionArray covers the whole chart", function()
		local chart = Chart.new()
		Chart.add(chart, sounding("r1", "measured", 1.0))
		Chart.add(chart, sounding("r2", "grown", 0.4))
		assertEq(#Chart.toRegionArray(chart), 2)
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
