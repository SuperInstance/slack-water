--!strict
--[[
	Water surface tests — Waves, Water, and the tide integration.

	These pin the parts of the ocean that must never drift:

	- DETERMINISM is a hard requirement (same inputs -> byte-identical
	  heights), because the sea is part of the shared world two servers
	  must agree about;
	- boundedness: no NaN, no runaway heights, no foam outside [0, 1] —
	  a single NaN would poison a CFrame write and drop a hole in the sea;
	- the integration: the tide must visibly move the surface, and a
	  2 m shoal must genuinely dry out at low water, because that is the
	  game's core mechanic made visible.

	Kept as its own file in the house style; merged into the runner by
	tests/run-tests.luau, so `./tests/run.sh` remains the single entry point.
]]

local Waves = require("./../src/Shared/Ocean/Waves")
local Water = require("./../src/Shared/Ocean/Water")
local Tide = require("./../src/Shared/Tide")

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

--=============================================================================
-- Waves — determinism and boundedness
--=============================================================================

local function runSuites(): ()
	suite("Waves — determinism", function()
		test("same arguments give identical heights", function()
			for i = 1, 100 do
				local x = (i * 37.0) % 400.0 - 200.0
				local z = (i * 53.0) % 400.0 - 200.0
				local t = i * 1.7
				local a = Waves.heightAt(x, z, t, 2.5, 0.7)
				local b = Waves.heightAt(x, z, t, 2.5, 0.7)
				assertEq(a, b, "repeat call diverged at i=" .. tostring(i))
			end
		end)

		test("a whole-grid sweep is reproducible", function()
			local function sweep(): { number }
				local out = {}
				local n = 0
				for ix = -3, 3 do
					for iz = -3, 3 do
						n += 1
						out[n] = Waves.heightAt(ix * 30.0, iz * 30.0, 12.5, 1.8, 2.1)
					end
				end
				return out
			end
			local a = sweep()
			local b = sweep()
			assertEq(#a, #b)
			for i = 1, #a do
				assertEq(a[i], b[i], "sweep diverged at tile " .. tostring(i))
			end
		end)

		test("component amplitudes sum to exactly 1 (the |h| <= amp bound)", function()
			local total = 0.0
			for _, c in Waves.COMPONENTS do
				total += c.ampFrac
			end
			assertNear(total, 1.0, 1e-12, "ampFrac sum")
		end)
	end)

	suite("Waves — boundedness", function()
		test("|heightAt| never exceeds amp", function()
			for i = 1, 400 do
				local x = (i * 91.0) % 900.0 - 450.0
				local z = (i * 149.0) % 900.0 - 450.0
				local t = i * 0.31
				local amp = 0.15 + (i % 7) * 0.9
				local dir = (i * 0.61) % (2.0 * math.pi)
				local h = Waves.heightAt(x, z, t, amp, dir)
				assertTrue(
					math.abs(h) <= amp + 1e-9,
					"height " .. tostring(h) .. " exceeded amp " .. tostring(amp)
				)
			end
		end)

		test("finite and continuous at extreme coordinates and times", function()
			local samples = {
				{ 1e9, 1e9, 1e6, 6.0, 0.0 },
				{ -1e9, 1e9, 1e6, 6.0, 3.0 },
				{ 1e12, -1e12, 1e7, 3.9, 1.0 },
				{ 0.0, 0.0, 1e9, 6.0, 2.0 },
			}
			for i, s in samples do
				local h = Waves.heightAt(s[1], s[2], s[3], s[4], s[5])
				assertTrue(h == h, "NaN at sample " .. tostring(i))
				assertTrue(math.abs(h) < math.huge, "infinite height at sample " .. tostring(i))
				assertTrue(math.abs(h) <= s[4] + 1e-9, "bound broken at sample " .. tostring(i))
			end
		end)

		test("NaN inputs fold to 0 instead of poisoning the renderer", function()
			local nan = 0.0 / 0.0
			assertEq(Waves.heightAt(nan, 0.0, 1.0, 1.0, 0.0), 0.0, "NaN x")
			assertEq(Waves.heightAt(0.0, nan, 1.0, 1.0, 0.0), 0.0, "NaN z")
			assertEq(Waves.heightAt(0.0, 0.0, nan, 1.0, 0.0), 0.0, "NaN t")
			assertEq(Waves.heightAt(0.0, 0.0, 1.0, nan, 0.0), 0.0, "NaN amp")
			assertEq(Waves.heightAt(0.0, 0.0, 1.0, 1.0, nan), 0.0, "NaN dir")
		end)

		test("zero amplitude flattens the sea exactly", function()
			assertEq(Waves.heightAt(123.4, -567.8, 99.0, 0.0, 1.2), 0.0)
		end)

		test("height changes smoothly in time (no per-refresh jumps)", function()
			-- the renderer samples at ~4 Hz; over 0.1 s the surface must
			-- move a fraction of the amplitude or it will strobe
			local amp = 6.0 -- worst case: sea state 6
			for i = 1, 300 do
				local x = (i * 31.0) % 780.0 - 390.0
				local z = (i * 47.0) % 780.0 - 390.0
				local t = i * 0.37
				local d = Waves.heightAt(x, z, t, amp, 0.9)
				local e = Waves.heightAt(x, z, t + 0.1, amp, 0.9)
				assertTrue(
					math.abs(e - d) < amp * 0.25,
					"jumped " .. tostring(math.abs(e - d)) .. " studs in 0.1 s"
				)
			end
		end)

		test("direction actually steers the sea", function()
			local differs = false
			for i = 1, 50 do
				local x = (i * 83.0) % 400.0 - 200.0
				local z = (i * 29.0) % 400.0 - 200.0
				if
					Waves.heightAt(x, z, 5.0, 2.0, 0.0)
					~= Waves.heightAt(x, z, 5.0, 2.0, math.pi / 2.0)
				then
					differs = true
					break
				end
			end
			assertTrue(differs, "rotating the wind changed nothing")
		end)
	end)

	suite("Waves — sea state", function()
		test("sea state is deterministic per day", function()
			for day = 1, 96 do
				assertEq(
					Waves.seaState(day),
					Waves.seaState(day),
					"day " .. tostring(day) .. " changed its mind"
				)
			end
		end)

		test("sea state stays on the 0..6 scale", function()
			for day = 1, 400 do
				local s = Waves.seaState(day)
				assertTrue(s >= 0 and s <= 6 and s == math.floor(s), "out of band: " .. tostring(s))
			end
		end)

		test("the sea is not the same every day", function()
			local seen: { [number]: boolean } = {}
			for day = 1, 48 do -- one compressed year
				seen[Waves.seaState(day)] = true
			end
			local count = 0
			for _ in seen do
				count += 1
			end
			assertTrue(count >= 3, "only " .. tostring(count) .. " distinct sea states in a year")
		end)

		test("gales are rare but not mythical", function()
			local blows = 0
			for day = 1, 48 do
				if Waves.seaState(day) >= 5 then
					blows += 1
				end
			end
			assertTrue(blows >= 1, "no state-5+ day in a whole year")
			assertTrue(blows <= 10, tostring(blows) .. " storm days in a year is too many")
		end)

		test("conditions: amplitude never decreases with sea state", function()
			local prev = -1.0
			for s = 0, 6 do
				local amp = Waves.conditions(s).amplitude
				assertTrue(amp >= prev, "amplitude not monotone at state " .. tostring(s))
				prev = amp
			end
		end)

		test("wind setup stays small next to the tide (the tide is the signal)", function()
			for s = 0, 6 do
				local off = Waves.conditions(s).baseOffset
				assertTrue(
					off >= 0.0 and off <= 2.2,
					"setup out of band at state " .. tostring(s) .. ": " .. tostring(off)
				)
			end
		end)

		test("dayIndex runs the compressed calendar", function()
			assertEq(Waves.dayIndex(1, 1), 1)
			assertEq(Waves.dayIndex(1, 2), 2)
			assertEq(Waves.dayIndex(2, 1), 5) -- 4 days per month
			assertEq(Waves.dayIndex(12, 4), 48)
		end)
	end)

	suite("Waves — chart depth to display depth", function()
		test("zero and negative depths are clamped to the datum", function()
			assertEq(Waves.depthToStuds(0.0), 0.0)
			assertEq(Waves.depthToStuds(-5.0), 0.0)
		end)

		test("monotone: a deeper chart always draws lower", function()
			local prev = -1.0
			for m = 1, 600 do
				local d = Waves.depthToStuds(m)
				assertTrue(d > prev, "not monotone at " .. tostring(m) .. " m")
				prev = d
			end
		end)

		test("honest near the surface: a 2 m shoal sits at ~6 studs", function()
			assertNear(Waves.depthToStuds(2.0), 6.0, 0.5, "2 m shoal display depth")
		end)

		test("compressed with depth: 600 m stays above the display cap", function()
			local deep = Waves.depthToStuds(600.0)
			assertTrue(deep < Waves.MAX_DISPLAY_DEPTH, "600 m exceeded the cap: " .. tostring(deep))
			assertTrue(deep > 30.0, "600 m compressed so hard it reads shallow: " .. tostring(deep))
		end)
	end)

	--=============================================================================
	-- Water — colour and foam
	--=============================================================================

	suite("Water — colour and foam", function()
		test("all outputs stay in [0, 1] and finite over a hostile sweep", function()
			local heights = { -8.0, -1.0, 0.0, 0.5, 1.0, 2.55, 6.0, 100.0, -100.0 }
			local depths = { -3.0, 0.0, 0.5, 5.0, 12.0, 40.0, 300.0 }
			local amps = { 0.0, 0.15, 1.5, 2.55, 6.0 }
			for _, h in heights do
				for _, d in depths do
					for _, a in amps do
						local r, g, b, foam = Water.appearance(h, a, d)
						for _, v in { r, g, b, foam } do
							assertTrue(v == v, "NaN out of appearance")
							assertTrue(v >= 0.0 and v <= 1.0, "out of [0,1]: " .. tostring(v))
						end
					end
				end
			end
		end)

		test("crests foam more than troughs in a working sea", function()
			local _, _, _, crest = Water.appearance(2.4, 2.55, 200.0)
			local _, _, _, trough = Water.appearance(-2.4, 2.55, 200.0)
			assertTrue(
				crest > trough,
				"crest " .. tostring(crest) .. " vs trough " .. tostring(trough)
			)
			assertTrue(crest > 0.3, "a state-4 crest should visibly foam: " .. tostring(crest))
		end)

		test("a calm sea has shiny crests but no whitecaps", function()
			local _, _, _, foam = Water.appearance(0.15, 0.15, 200.0)
			assertTrue(foam < 0.05, "whitecaps on a glassy calm: " .. tostring(foam))
		end)

		test("shallow water foams more than deep water", function()
			local _, _, _, shallow = Water.appearance(0.0, 1.5, 4.0)
			local _, _, _, deep = Water.appearance(0.0, 1.5, 200.0)
			assertTrue(
				shallow > deep,
				"shallow " .. tostring(shallow) .. " vs deep " .. tostring(deep)
			)
			assertTrue(shallow > 0.5, "the surf line should be unmistakable: " .. tostring(shallow))
		end)

		test("a drying shoal is all surf", function()
			local _, _, _, foam = Water.appearance(0.3, 1.5, -1.0)
			assertTrue(foam >= 0.9, "drying ground should foam fully: " .. tostring(foam))
		end)

		test("shoal water is lighter and greener than open water", function()
			local sr, sg, sb = Water.appearance(0.0, 1.5, 2.0)
			local dr, dg, db = Water.appearance(0.0, 1.5, 200.0)
			local shallowLum = 0.3 * sr + 0.5 * sg + 0.2 * sb
			local deepLum = 0.3 * dr + 0.5 * dg + 0.2 * db
			assertTrue(shallowLum > deepLum, "shallow should read lighter than deep")
			assertTrue(sg > sr, "shallow water should lean green, not red")
		end)
	end)

	--=============================================================================
	-- Tide integration — the game's signature
	--=============================================================================

	suite("Tide integration — the surface the renderer draws", function()
		-- exactly what Server/OceanSurface composes, minus the Roblox half
		local function baseLevel(hour: number, seaState: number): number
			return Tide.heightAt(hour) * Waves.STUDS_PER_METRE
				+ Waves.conditions(seaState).baseOffset
		end

		test("the tide visibly moves the whole ocean over a cycle", function()
			local minH, maxH = math.huge, -math.huge
			for hour = 0, 400, 0.25 do
				local level = baseLevel(hour, 2)
				minH = math.min(minH, level)
				maxH = math.max(maxH, level)
			end
			local range = maxH - minH
			assertTrue(
				range >= 10.0,
				"full tidal range is only " .. tostring(range) .. " studs — not visible"
			)
		end)

		test("the tide, not the weather, is the dominant signal", function()
			local tideSwing = baseLevel(6.2, 0) - baseLevel(0.0, 0) -- near-high vs near-low
			tideSwing = math.abs(tideSwing)
			local maxSetup = Waves.conditions(6).baseOffset
			assertTrue(
				tideSwing > maxSetup * 3.0,
				"setup rivals the tide: swing "
					.. tostring(tideSwing)
					.. " vs setup "
					.. tostring(maxSetup)
			)
		end)

		test("a 2 m shoal dries out at low water and floods at high", function()
			-- the shoal's disc top sits displayDepth studs below the datum;
			-- the surface sits at tide*SPM. Dried: the surface is BELOW the
			-- disc top. Flooded: comfortable water over it (>= 9 studs,
			-- i.e. tide >= 1 m, which every spring high exceeds).
			local displayDepth = Waves.depthToStuds(2.0)
			local dried, flooded = false, false
			for hour = 0, 400, 0.25 do
				local water = Tide.heightAt(hour) * Waves.STUDS_PER_METRE
				if water < -displayDepth + 0.25 then
					dried = true
				end
				if water + displayDepth >= 9.0 then
					flooded = true
				end
			end
			assertTrue(dried, "2 m shoal never dries: the core mechanic is invisible")
			assertTrue(flooded, "2 m shoal never floods: it would read as permanent rock")
		end)

		test("the composed surface is deterministic end to end", function()
			local function sample(
				month: number,
				day: number,
				hour: number,
				x: number,
				z: number,
				t: number
			): { number }
				local dayIdx = Waves.dayIndex(month, day)
				local cond = Waves.conditions(Waves.seaState(dayIdx))
				local level = Tide.heightAt(hour) * Waves.STUDS_PER_METRE + cond.baseOffset
				local h = Waves.heightAt(x, z, t, cond.amplitude, Waves.windDir(dayIdx))
				local r, g, b, foam = Water.appearance(h, cond.amplitude, level + h + 20.0)
				return { level + h, r, g, b, foam }
			end
			for i = 1, 60 do
				local month = (i % 12) + 1
				local day = (i % 4) + 1
				local hour = (i * 7.3) % 24.0
				local x = (i * 67.0) % 780.0 - 390.0
				local z = (i * 41.0) % 780.0 - 390.0
				local a = sample(month, day, hour, x, z, i * 0.9)
				local b = sample(month, day, hour, x, z, i * 0.9)
				assertNear(a[1], b[1], 0.0, "level diverged")
				assertNear(a[2], b[2], 0.0, "colour diverged")
				assertNear(a[3], b[3], 0.0, "green diverged")
				assertNear(a[4], b[4], 0.0, "blue diverged")
				assertNear(a[5], b[5], 0.0, "foam diverged")
			end
		end)
	end)
end

--- Run every suite; returns (passed, failed, failures) so tests/run-tests.luau
--- can merge the counts into its own summary.
function run(): (number, number, { string })
	runSuites()
	return passed, failed, failures
end

return {
	run = run,
}
