--!strict
--[[
	Slack Water — client test suite.

	Run headlessly:
		luau tests/client-tests.luau

	Covers the pure half of src/Client: the formatting and wire-normalization
	layer in Ui.luau and the GameClock extrapolator. The panels themselves need
	Studio; these tests exist so the client can at least be proven unable to
	crash on a malformed payload or print a mangled number.

	Each test is written against behaviour the panels rely on: if one of these
	passes trivially — cannot fail — it is a liability, not a net. The
	scenario payloads below are malformed on purpose.
]]

local Ui = require("./../src/Client/Ui")

--=============================================================================
-- Tiny test framework (same shape as tests/run-tests.luau)
--=============================================================================

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
		local msg = tostring(err)
		table.insert(failures, currentSuite .. " / " .. name .. ": " .. msg)
		print("  FAIL  " .. name .. "\n        " .. msg)
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

local function assertNear(actual: number, expected: number, tol: number, msg: string?)
	if math.abs(actual - expected) > tol then
		error(
			(msg or "not within tolerance")
				.. " — expected "
				.. tostring(expected)
				.. " +/- "
				.. tostring(tol)
				.. ", got "
				.. tostring(actual),
			2
		)
	end
end

local function assertTrue(cond: boolean, msg: string?)
	if not cond then
		error(msg or "expected true", 2)
	end
end

--=============================================================================
-- Formatting
--=============================================================================

suite("Ui.formatInt — integer grouping", function()
	test("groups thousands", function()
		assertEq(Ui.formatInt(0), "0")
		assertEq(Ui.formatInt(7), "7")
		assertEq(Ui.formatInt(999), "999")
		assertEq(Ui.formatInt(1000), "1,000")
		assertEq(Ui.formatInt(1234567), "1,234,567")
		assertEq(Ui.formatInt(123456789012), "123,456,789,012")
	end)

	test("rounds halves up", function()
		assertEq(Ui.formatInt(1234.5), "1,235")
		assertEq(Ui.formatInt(42.4), "42")
	end)

	test("negative values keep their sign", function()
		assertEq(Ui.formatInt(-9876.4), "-9,876")
		assertEq(Ui.formatInt(-250), "-250")
	end)

	test("never leaks scientific notation (regression: tostring goes 1e+15)", function()
		-- the old implementation produced "1e,15" here; a HUD must never
		-- show either form
		assertEq(Ui.formatInt(1e15), "1,000,000,000,000,000")
		assertEq(Ui.formatInt(2e16), "20,000,000,000,000,000")
		local rendered = Ui.formatInt(1e15)
		assertTrue(not rendered:find("e"), "scientific notation leaked: " .. rendered)
	end)

	test("NaN and infinities degrade to fixed text, not a crash", function()
		assertEq(Ui.formatInt(0 / 0), "0")
		assertEq(Ui.formatInt(math.huge), "∞")
		assertEq(Ui.formatInt(-math.huge), "-∞")
	end)
end)

suite("Ui.clockFace — game hour to clock", function()
	test("formats hours and minutes", function()
		assertEq(Ui.clockFace(13.66667), "13:40")
		assertEq(Ui.clockFace(9.5), "9:30")
		assertEq(Ui.clockFace(61.3), "13:18")
	end)

	test("wraps past midnight in both directions", function()
		assertEq(Ui.clockFace(25.25), "1:15")
		assertEq(Ui.clockFace(-0.1), "23:54")
	end)

	test("rounds 23:59.98 up into the next day, not 24:00", function()
		assertEq(Ui.clockFace(23.9997), "0:00")
	end)

	test("NaN degrades to 0:00", function()
		assertEq(Ui.clockFace(0 / 0), "0:00")
	end)
end)

suite("Ui.countdown — real-seconds countdown", function()
	test("formats mm:ss with rounding", function()
		assertEq(Ui.countdown(42.4), "0:42")
		assertEq(Ui.countdown(0), "0:00")
		assertEq(Ui.countdown(3601), "60:01")
	end)

	test("negative and NaN inputs clamp to zero, never a crash", function()
		assertEq(Ui.countdown(-5), "0:00")
		assertEq(Ui.countdown(0 / 0), "0:00")
	end)
end)

suite("Ui.formatWeight — weights", function()
	test("little fish keep their decimals", function()
		assertEq(Ui.formatWeight(0.05), "0.05 kg")
		assertEq(Ui.formatWeight(9.34), "9.34 kg")
	end)

	test("bigger fish lose precision gradually", function()
		assertEq(Ui.formatWeight(12.34), "12.3 kg")
		assertEq(Ui.formatWeight(123.4), "123 kg")
	end)

	test("NaN degrades to a zero weight, not 'nan kg'", function()
		assertEq(Ui.formatWeight(0 / 0), "0.00 kg")
	end)
end)

suite("Ui.tonum — wire-value coercion", function()
	test("numeric strings coerce", function()
		assertEq(Ui.tonum("12", 5), 12)
		assertEq(Ui.tonum("3.5", 0), 3.5)
		assertEq(Ui.tonum(3.5, 0), 3.5)
	end)

	test("junk takes the fallback", function()
		assertEq(Ui.tonum(nil, 7), 7)
		assertEq(Ui.tonum("abc", 7), 7)
		assertEq(Ui.tonum(true, 7), 7)
		assertEq(Ui.tonum({}, 7), 7)
	end)

	test("NaN and infinities take the fallback", function()
		assertEq(Ui.tonum(0 / 0, 7), 7)
		assertEq(Ui.tonum(math.huge, 7), 7)
		assertEq(Ui.tonum(-math.huge, 7), 7)
	end)
end)

--=============================================================================
-- Wire normalization
--=============================================================================

suite("Ui.normalizeMarketEntries — market payload defense", function()
	test("nil and non-table payloads become empty lists", function()
		assertEq(#Ui.normalizeMarketEntries(nil), 0)
		assertEq(#Ui.normalizeMarketEntries("nope"), 0)
		assertEq(#Ui.normalizeMarketEntries({}), 0)
	end)

	test("drops non-table entries and entries without a species id", function()
		local out = Ui.normalizeMarketEntries({
			3,
			"cod",
			{ price = 10 }, -- no speciesId
			{ speciesId = "" }, -- empty id
			{ speciesId = "cod", price = 15 },
		})
		assertEq(#out, 1)
		assertEq(out[1].speciesId, "cod")
	end)

	test("defaults every field a panel reads", function()
		local out = Ui.normalizeMarketEntries({ { speciesId = "herring" } })
		local row = out[1]
		assertEq(row.displayName, "herring") -- missing display name falls back to id
		assertEq(row.price, 0)
		assertEq(row.baseValue, 0)
		assertEq(row.scarcityMultiplier, 1)
		assertEq(row.globalAbundance, 1)
		assertEq(row.direction, "flat")
	end)

	test("wrong-typed fields coerce or default instead of reaching a format string", function()
		local out = Ui.normalizeMarketEntries({
			{
				speciesId = "cod",
				price = "15", -- numeric string
				direction = "sideways", -- not a direction
				scarcityMultiplier = 0 / 0, -- NaN
				globalAbundance = nil, -- missing
			},
		})
		assertEq(#out, 1)
		assertEq(out[1].price, 15)
		assertEq(out[1].direction, "flat")
		assertEq(out[1].scarcityMultiplier, 1)
		assertEq(out[1].globalAbundance, 1)
	end)

	test("a single entry survives alone", function()
		local out = Ui.normalizeMarketEntries({ { speciesId = "cod", price = 3 } })
		assertEq(#out, 1)
		assertEq(out[1].price, 3)
	end)
end)

suite("Ui.normalizeRegions — ocean payload defense", function()
	test("nil and non-table payloads become empty lists", function()
		assertEq(#Ui.normalizeRegions(nil), 0)
		assertEq(#Ui.normalizeRegions(17), 0)
		assertEq(#Ui.normalizeRegions({}), 0)
	end)

	test("drops regions without a usable id", function()
		local out = Ui.normalizeRegions({
			{ name = "noid" },
			{ id = 123, name = "numeric id" },
			{ id = "", name = "empty id" },
			"id",
			{ id = "real", name = "Real Ground" },
		})
		assertEq(#out, 1)
		assertEq(out[1].id, "real")
	end)

	test("a missing name falls back to the id, never the string 'nil'", function()
		local out = Ui.normalizeRegions({ { id = "r7" }, { id = "r8", name = false } })
		assertEq(out[1].name, "r7")
		assertEq(out[2].name, "r8")
	end)

	test("species and abundances are filtered to honest types", function()
		local out = Ui.normalizeRegions({
			{
				id = "r1",
				species = { 1, "halibut", true, "", "cod" },
				abundances = { halibut = 0.5, cod = "junk", rockfish = 0 / 0, sablefish = 0 },
			},
		})
		assertEq(#out[1].species, 2)
		assertEq(out[1].species[1], "halibut")
		assertEq(out[1].species[2], "cod")
		assertEq(out[1].abundances.halibut, 0.5)
		assertEq(out[1].abundances.sablefish, 0) -- zero abundance is real and kept
		assertTrue(out[1].abundances.cod == nil, "junk abundance must be dropped")
		assertTrue(out[1].abundances.rockfish == nil, "NaN abundance must be dropped")
	end)

	test("contested keeps only true flags", function()
		local out = Ui.normalizeRegions({
			{ id = "r1", contested = { a = true, b = false, c = "yes" } },
		})
		assertTrue(out[1].contested.a == true, "true flag kept")
		assertTrue(out[1].contested.b == nil, "false flag dropped")
		assertTrue(out[1].contested.c == nil, "non-boolean flag dropped")
	end)

	test("unknown provenance downgrades to grown, known labels survive", function()
		local out = Ui.normalizeRegions({
			{ id = "a", provenance = "measured" },
			{ id = "b", provenance = "composed" },
			{ id = "c", provenance = "grown" },
			{ id = "d", provenance = "divined" },
			{ id = "e" }, -- missing
			{ id = "f", provenance = 42 }, -- wrong type
		})
		assertEq(out[1].provenance, "measured")
		assertEq(out[2].provenance, "composed")
		assertEq(out[3].provenance, "grown")
		assertEq(out[4].provenance, "grown", "unrecognised label must downgrade")
		assertEq(out[5].provenance, "grown", "missing label must downgrade")
		assertEq(out[6].provenance, "grown", "wrong-typed label must downgrade")
	end)

	test("accessibility defaults to reachable; charted depth falls back to depth", function()
		local out = Ui.normalizeRegions({
			{ id = "a" },
			{ id = "b", accessible = false, depth = 40, chartedDepth = 22 },
			{ id = "c", depth = 55, chartedDepth = "42" },
		})
		assertTrue(out[1].accessible, "missing accessible means reachable")
		assertTrue(out[2].accessible == false, "explicit false survives")
		assertEq(out[2].chartedDepth, 22)
		assertEq(out[3].chartedDepth, 42, "numeric-string depth coerces")
	end)

	test("a single region renders alone", function()
		local out = Ui.normalizeRegions({ { id = "only", name = "The Only Ground" } })
		assertEq(#out, 1)
		assertEq(out[1].name, "The Only Ground")
	end)
end)

--=============================================================================
-- GameClock
--
-- The server is the authority on time and broadcasts its own tide hour; the
-- clock anchors on that hour, unwraps the midnight rollover, measures the
-- real rate over a rolling window, and must survive a restart or a malformed
-- payload without coasting at a poisoned speed. These tests inject `now` so
-- they are deterministic.
--=============================================================================

suite("Ui.GameClock — anchoring and coasting", function()
	test("the first sync anchors on the server's tide hour", function()
		local c = Ui.newClock(1 / 20)
		assertTrue(not c.synced, "a fresh clock is unsynced")
		Ui.clockSync(c, 3, 2, 7, 5.25, 100)
		assertTrue(c.synced, "synced after the first payload")
		assertEq(c.month, 3)
		assertEq(c.day, 2)
		assertNear(Ui.clockHour(c, 100), 5.25, 1e-9)
	end)

	test("coasts between syncs at the fallback rate until one is measured", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 1, 1, 0, 5.25, 100)
		-- 10 real seconds at 1/20 game hours per second = +0.5 h
		assertNear(Ui.clockHour(c, 110), 5.75, 1e-9)
	end)

	test("measures the real rate from the server's own hour deltas", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 1, 1, 0, 5.25, 100)
		Ui.clockSync(c, 1, 1, 0, 6.0, 140) -- +0.75 h over 40 s
		assertNear(c.hoursPerSecond, 0.75 / 40, 1e-9)
		assertNear(Ui.clockHour(c, 150), 6.0 + 10 * (0.75 / 40), 1e-9)
		assertNear(Ui.clockSecondsPerGameHour(c), 40 / 0.75, 1e-6)
	end)

	test("a bursty cadence measures the average, not the step (regression)", function()
		-- the real cadence: broadcast every 5 s, hour steps once per 20 s.
		-- Per-sync measurement reads the step as 1 h per 5 s (4x too fast)
		-- and the coast sprints; the rolling window must land on 0.05.
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 1, 1, 0, 0, 0)
		Ui.clockSync(c, 1, 1, 0, 0, 5)
		Ui.clockSync(c, 1, 1, 0, 0, 10)
		Ui.clockSync(c, 1, 1, 0, 0, 15)
		Ui.clockSync(c, 1, 1, 1, 1, 20)
		assertNear(c.hoursPerSecond, 0.05, 1e-9, "rate must be the 20 s average")
		assertNear(Ui.clockHour(c, 30), 1.5, 1e-9)
	end)

	test("client hour tracks the server hour hour-for-hour at the real cadence", function()
		local c = Ui.newClock(1 / 20)
		for tick = 0, 6 do
			Ui.clockSync(c, 1, 1, tick, tick % 24, tick * 20)
		end
		assertNear(c.hoursPerSecond, 0.05, 1e-9)
		assertNear(Ui.clockHour(c, 130), 6.5, 1e-9)
	end)
end)

suite("Ui.GameClock — rollover, restart and malformed payloads", function()
	test("the midnight rollover stays continuous instead of jumping back 24 h", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 1, 1, 0, 23.75, 100)
		Ui.clockSync(c, 1, 1, 0, 0.0, 120) -- +0.25 h across midnight
		assertNear(Ui.clockHour(c, 120), 24.0, 1e-9, "continuous hour must keep counting past 24")
	end)

	test("an hour that jumps backwards is treated as a server restart", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 5, 3, 40, 6.0, 100)
		Ui.clockSync(c, 5, 3, 40, 6.75, 140) -- a measured rate: +0.75 h over 40 s
		assertNear(c.hoursPerSecond, 0.75 / 40, 1e-9)
		Ui.clockSync(c, 1, 1, 2, 2.0, 180) -- restarted world, earlier hour
		assertEq(c.month, 1, "calendar re-anchors after restart")
		assertEq(c.day, 1)
		assertNear(c.hoursPerSecond, 1 / 20, 1e-9, "restart must reset the measured rate")
		assertNear(Ui.clockHour(c, 180), 2.0, 1e-9, "the new world's hour becomes the anchor")
	end)

	test("a forward leap no cadence allows does not poison the rate", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 1, 1, 0, 6.0, 100)
		Ui.clockSync(c, 1, 1, 0, 14.0, 110) -- +8 h in 10 s: a jump, not motion
		assertNear(c.hoursPerSecond, 1 / 20, 1e-9, "implausible rate must be rejected")
		assertNear(Ui.clockHour(c, 115), 14.0 + 5 * (1 / 20), 1e-9)
	end)

	test("a missing tide hour falls back to the tick count at one hour per tick", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 1, 1, 9, nil, 100)
		assertNear(Ui.clockHour(c, 100), 9, 1e-9)
	end)

	test("malformed calendar fields degrade without crashing", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, "x", nil, "9", "nan", 10)
		assertEq(c.month, 1)
		assertEq(c.day, 1)
		assertNear(Ui.clockHour(c, 10), 9, 1e-9, "tick fallback applies when the hour is junk")
	end)

	test("month and day are clamped into the calendar", function()
		local c = Ui.newClock(1 / 20)
		Ui.clockSync(c, 13, 0, 0, 0, 1)
		assertEq(c.month, 12, "month clamps to the calendar")
		assertEq(c.day, 1, "day never reads as 0")
		Ui.clockSync(c, 2, 2.7, 1, 1.0, 30)
		assertEq(c.day, 2, "fractional days floor")
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
