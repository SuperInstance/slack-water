--!strict
--[[
	Slack Water — simulation test suite.

	Run headlessly:
		luau tests/run-tests.luau

	These tests are the safety net for the whole economy. If the population
	model drifts, every downstream number (prices, yields, scarcity) is wrong
	and nobody would notice from playing for five minutes.
]]

local ROOT = (nil :: any)
local scriptDir = (nil :: any)

local Rng = require("./../src/Shared/Ocean/Rng")
local OceanSim = require("./../src/Shared/Ocean/OceanSim")
local Species = require("./../src/Shared/Species")
local Config = require("./../src/Shared/Config")

--=============================================================================
-- Tiny test framework
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
		error((msg or "values differ") .. " — expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function assertNear(actual: number, expected: number, tol: number, msg: string?)
	if math.abs(actual - expected) > tol then
		error((msg or "not within tolerance") .. " — expected " .. tostring(expected) .. " +/- " .. tostring(tol) .. ", got " .. tostring(actual), 2)
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

--=============================================================================
-- Fixtures
--=============================================================================

local function makeRegion(id: string, habitat: string, depth: number, richness: number)
	return {
		id = id,
		name = id,
		habitat = habitat,
		depth = depth,
		salinity = 32.0,
		richness = richness,
		origin = "procedural" :: "procedural",
	}
end

local function newOcean(seed: number)
	return OceanSim.new(seed)
end

--=============================================================================
-- Tests: Rng
--=============================================================================

suite("Rng — determinism", function()
	test("same seed produces identical streams", function()
		local a = Rng.new(12345)
		local b = Rng.new(12345)
		for _ = 1, 200 do
			assertEq(Rng.nextFloat(a), Rng.nextFloat(b))
		end
	end)

	test("different seeds diverge", function()
		local a = Rng.new(1)
		local b = Rng.new(2)
		local sameCount = 0
		for _ = 1, 50 do
			if Rng.nextFloat(a) == Rng.nextFloat(b) then
				sameCount += 1
			end
		end
		assertEq(sameCount, 0, "different seeds should not match")
	end)

	test("nextFloat stays in [0,1)", function()
		local r = Rng.new(999)
		for _ = 1, 2000 do
			local v = Rng.nextFloat(r)
			assertTrue(v >= 0.0 and v < 1.0, "out of range: " .. tostring(v))
		end
	end)

	test("range respects bounds", function()
		local r = Rng.new(7)
		for _ = 1, 500 do
			local v = Rng.range(r, 10, 20)
			assertTrue(v >= 10 and v < 20, "out of range: " .. tostring(v))
		end
	end)

	test("int is inclusive on both ends", function()
		local r = Rng.new(3)
		local sawLow, sawHigh = false, false
		for _ = 1, 500 do
			local v = Rng.int(r, 1, 3)
			assertTrue(v >= 1 and v <= 3, "out of range: " .. tostring(v))
			if v == 1 then sawLow = true end
			if v == 3 then sawHigh = true end
		end
		assertTrue(sawLow and sawHigh, "int should reach both bounds")
	end)

	test("forked streams are independent", function()
		local base = Rng.new(42)
		local f1 = Rng.fork(base, "region-a")
		local f2 = Rng.fork(base, "region-b")
		local same = 0
		for _ = 1, 100 do
			if Rng.nextFloat(f1) == Rng.nextFloat(f2) then same += 1 end
		end
		assertEq(same, 0, "forks should be independent")
	end)
end)

--=============================================================================
-- Tests: species biology
--=============================================================================

suite("Species — roster integrity", function()
	test("no duplicate ids", function()
		local seen: { [string]: boolean } = {}
		for _, s in Species.list do
			assertFalse(seen[s.id] == true, "duplicate species id: " .. s.id)
			seen[s.id] = true
		end
	end)

	test("all fields are sane", function()
		for _, s in Species.list do
			assertTrue(s.capacity > 0, s.id .. " capacity must be > 0")
			assertTrue(s.growthRate > 0 and s.growthRate < 1, s.id .. " growthRate out of (0,1)")
			assertTrue(s.minDepth < s.maxDepth, s.id .. " depth band inverted")
			assertTrue(s.baseValue > 0, s.id .. " baseValue must be > 0")
			assertTrue(s.weightRange.min < s.weightRange.max, s.id .. " weight range inverted")
			assertTrue(s.rarity > 0 and s.rarity < 1, s.id .. " rarity out of (0,1)")
			assertTrue(
				s.harvestDifficulty >= 1 and s.harvestDifficulty <= 5,
				s.id .. " difficulty out of 1..5"
			)
		end
	end)

	test("halibut really is deeper than herring", function()
		local halibut = Species.get("halibut")
		local herring = Species.get("herring")
		assertTrue(halibut ~= nil and herring ~= nil, "missing species")
		assertTrue(halibut.minDepth > herring.minDepth, "halibut should live deeper than herring")
	end)

	test("salmon are anadromous with valid run windows", function()
		for _, id in { "chinook", "coho", "sockeye", "pink", "chum" } do
			local s = Species.get(id)
			assertTrue(s ~= nil, id .. " missing")
			assertTrue(s.anadromous, id .. " should be anadromous")
			assertTrue(s.runMonths ~= nil, id .. " should have run months")
			for _, m in s.runMonths do
				assertTrue(m >= 1 and m <= Config.MONTHS_PER_YEAR, id .. " run month out of range: " .. tostring(m))
			end
		end
	end)

	test("isRunning respects the run window", function()
		local coho = Species.get("coho")
		assertTrue(Species.isRunning(coho, 9), "coho should be running in month 9")
		assertFalse(Species.isRunning(coho, 1), "coho should not be running in month 1")
	end)

	test("candidatesAtDepth filters by depth band", function()
		local shallow = Species.candidatesAtDepth(20)
		local deep = Species.candidatesAtDepth(600)
		local shallowHasHalibut = false
		local deepHasHerring = false
		for _, s in shallow do
			if s.id == "halibut" then shallowHasHalibut = true end
		end
		for _, s in deep do
			if s.id == "herring" then deepHasHerring = true end
		end
		assertFalse(shallowHasHalibut, "halibut should not appear at 20m")
		assertFalse(deepHasHerring, "herring should not appear at 600m")
	end)
end)

--=============================================================================
-- Tests: ocean population dynamics
--=============================================================================

suite("OceanSim — population dynamics", function()
	test("regions seed at a healthy abundance", function()
		local ocean = newOcean(1)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local ab = OceanSim.abundance(ocean, "r1", "rockfish")
		assertTrue(ab > 0.5 and ab <= 1.0, "fresh region should be healthy, got " .. tostring(ab))
	end)

	test("an untouched ground grows toward capacity and saturates", function()
		local ocean = newOcean(1)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local rng = Rng.new(1)
		local before = OceanSim.getStock(ocean, "r1", "rockfish")
		for _ = 1, 40 do
			OceanSim.tick(ocean, rng)
		end
		local after = OceanSim.getStock(ocean, "r1", "rockfish")
		local cap = OceanSim.getCapacity(ocean, "r1", "rockfish")
		assertTrue(after > before, "stock should grow when unfished")
		assertTrue(after <= cap * 1.15, "stock must not exceed cap ceiling")
	end)

	test("logistic growth does not run away", function()
		local ocean = newOcean(2)
		OceanSim.addRegion(ocean, makeRegion("r1", "kelp", 60, 1.5))
		local rng = Rng.new(2)
		for _ = 1, 400 do
			OceanSim.tick(ocean, rng)
		end
		local ab = OceanSim.abundance(ocean, "r1", "herring")
		assertTrue(ab <= 1.16, "logistic model must saturate near 1.0, got " .. tostring(ab))
	end)

	test("habitat affinity: reef favours rockfish over mud dwellers", function()
		local ocean = newOcean(3)
		OceanSim.addRegion(ocean, makeRegion("reefRegion", "reef", 60, 1.0))
		OceanSim.addRegion(ocean, makeRegion("mudRegion", "mud", 60, 1.0))
		local reefRock = OceanSim.getCapacity(ocean, "reefRegion", "rockfish")
		local mudRock = OceanSim.getCapacity(ocean, "mudRegion", "rockfish")
		assertTrue(reefRock > mudRock, "rockfish should do better on a reef")
	end)

	test("depth gate suppresses out-of-band species", function()
		local shallow = newOcean(4)
		OceanSim.addRegion(shallow, makeRegion("shallow", "sand", 10, 1.0))
		local deep = newOcean(4)
		OceanSim.addRegion(deep, makeRegion("deep", "sand", 600, 1.0))
		assertTrue(
			OceanSim.getCapacity(deep, "deep", "halibut") > OceanSim.getCapacity(shallow, "shallow", "halibut") * 5,
			"halibut capacity should be far greater in its depth band"
		)
	end)

	test("salmon run raises biomass during its window", function()
		local ocean = newOcean(5)
		OceanSim.addRegion(ocean, makeRegion("est", "estuary", 40, 1.0))
		local rng = Rng.new(5)
		-- park on the coho window (months 8,9,10)
		ocean.month = 7
		for _ = 1, 12 do OceanSim.tick(ocean, rng) end
		local preRun = OceanSim.getStock(ocean, "est", "coho")
		ocean.month = 9
		for _ = 1, 12 do OceanSim.tick(ocean, rng) end
		local duringRun = OceanSim.getStock(ocean, "est", "coho")
		assertTrue(duringRun > preRun, "run should add biomass: " .. tostring(preRun) .. " -> " .. tostring(duringRun))
	end)

	test("the whole simulation is deterministic", function()
		local function run(): { number }
			local ocean = newOcean(777)
			OceanSim.addRegion(ocean, makeRegion("a", "reef", 60, 1.0))
			OceanSim.addRegion(ocean, makeRegion("b", "sand", 250, 1.0))
			OceanSim.addRegion(ocean, makeRegion("c", "estuary", 30, 0.9))
			local rng = Rng.new(777)
			for _ = 1, 100 do
				OceanSim.tick(ocean, rng)
				OceanSim.harvest(ocean, "a", "rockfish", 12)
				OceanSim.harvest(ocean, "b", "halibut", 8)
			end
			return {
				OceanSim.getStock(ocean, "a", "rockfish"),
				OceanSim.getStock(ocean, "b", "halibut"),
				OceanSim.getStock(ocean, "c", "coho"),
			}
		end
		local r1 = run()
		local r2 = run()
		assertEq(r1[1], r2[1], "determinism: rockfish")
		assertEq(r1[2], r2[2], "determinism: halibut")
		assertEq(r1[3], r2[3], "determinism: coho")
	end)
end)

--=============================================================================
-- Tests: harvesting and scarcity
--=============================================================================

suite("OceanSim — harvest and scarcity", function()
	test("harvest reduces stock and reports abundance", function()
		local ocean = newOcean(6)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local before = OceanSim.abundance(ocean, "r1", "rockfish")
		local res = OceanSim.harvest(ocean, "r1", "rockfish", 20)
		assertTrue(res ~= nil, "harvest returned nil")
		assertTrue(res.yielded > 0, "should yield something")
		assertTrue(res.abundanceAfter < before, "abundance should drop")
	end)

	test("harvest is capped so one cast cannot empty a ground", function()
		local ocean = newOcean(7)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local stock = OceanSim.getStock(ocean, "r1", "rockfish")
		local cap = OceanSim.getCapacity(ocean, "r1", "rockfish")
		local res = OceanSim.harvest(ocean, "r1", "rockfish", 100000)
		assertTrue(res ~= nil, "nil result")
		-- the cap is against capacity, not current stock
		assertTrue(
			res.yielded <= cap * Config.MAX_HARVEST_FRACTION + 1e-6,
			"harvest exceeded cap fraction: " .. tostring(res.yielded) .. " > " .. tostring(cap * Config.MAX_HARVEST_FRACTION)
		)
		assertTrue(res.yielded < stock, "a single cast must not take the entire stock")
	end)

	test("yield scales with abundance — depleted grounds pay less", function()
		local rich = newOcean(8)
		OceanSim.addRegion(rich, makeRegion("r1", "reef", 60, 1.0))
		local richRes = OceanSim.harvest(rich, "r1", "rockfish", 30)

		local poor = newOcean(9)
		OceanSim.addRegion(poor, makeRegion("r1", "reef", 60, 1.0))
		-- hammer the ground
		local rng = Rng.new(9)
		for _ = 1, 200 do
			OceanSim.harvest(poor, "r1", "rockfish", 40)
			OceanSim.tick(poor, rng)
		end
		local poorRes = OceanSim.harvest(poor, "r1", "rockfish", 30)

		assertTrue(richRes ~= nil and poorRes ~= nil, "nil results")
		assertTrue(
			richRes.yielded > poorRes.yielded,
			"a rich ground must out-yield a depleted one: " .. tostring(richRes.yielded) .. " vs " .. tostring(poorRes.yielded)
		)
	end)

	test("heavy pressure collapses a stock below the threshold", function()
		local ocean = newOcean(10)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local rng = Rng.new(10)
		local lastDepleted = false
		for _ = 1, 300 do
			local res = OceanSim.harvest(ocean, "r1", "rockfish", 60)
			if res then
				lastDepleted = res.depleted
			end
			OceanSim.tick(ocean, rng)
		end
		assertTrue(lastDepleted, "sustained heavy fishing should collapse the stock")
		assertTrue(
			OceanSim.abundance(ocean, "r1", "rockfish") < Config.COLLAPSE_THRESHOLD * 2,
			"abundance should be low after collapse"
		)
	end)

	test("a collapsed stock recovers when left alone", function()
		local ocean = newOcean(11)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local rng = Rng.new(11)
		for _ = 1, 250 do
			OceanSim.harvest(ocean, "r1", "rockfish", 60)
			OceanSim.tick(ocean, rng)
		end
		local depleted = OceanSim.abundance(ocean, "r1", "rockfish")
		for _ = 1, 900 do
			OceanSim.tick(ocean, rng)
		end
		local recovered = OceanSim.abundance(ocean, "r1", "rockfish")
		assertTrue(recovered > depleted, "stock should recover: " .. tostring(depleted) .. " -> " .. tostring(recovered))
	end)

	test("extirpation floor prevents permanent regional extinction", function()
		local ocean = newOcean(12)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local rng = Rng.new(12)
		for _ = 1, 500 do
			OceanSim.harvest(ocean, "r1", "yelloweye", 100)
			OceanSim.tick(ocean, rng)
		end
		local ab = OceanSim.abundance(ocean, "r1", "yelloweye")
		assertTrue(ab > 0, "stock must never reach literal zero")
	end)

	test("contested flag fires when another crew took a big share", function()
		local ocean = newOcean(13)
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		local cap = OceanSim.getCapacity(ocean, "r1", "rockfish")
		-- first crew takes a serious share of the ground
		OceanSim.harvest(ocean, "r1", "rockfish", cap * Config.MAX_HARVEST_FRACTION * 0.5)
		-- second crew arrives and should see contention
		local second = OceanSim.harvest(ocean, "r1", "rockfish", 1)
		assertTrue(second ~= nil, "nil result")
		assertTrue(second.contested, "second crew should see contention")
	end)

	test("harvesting an unknown species or missing region is safe", function()
		local ocean = newOcean(14)
		assertTrue(OceanSim.harvest(ocean, "r1", "rockfish", 5) == nil, "missing region should yield nil")
		OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
		assertTrue(OceanSim.harvest(ocean, "r1", "not_a_fish", 5) == nil, "unknown species should yield nil")
	end)
end)

--=============================================================================
-- Tests: global supply
--=============================================================================

suite("OceanSim — global supply", function()
	test("supply aggregates across regions", function()
		local ocean = newOcean(15)
		OceanSim.addRegion(ocean, makeRegion("a", "reef", 60, 1.0))
		OceanSim.addRegion(ocean, makeRegion("b", "reef", 80, 1.0))
		local total = 0.0
		for _, id in ocean.order do
			total += OceanSim.getStock(ocean, id, "rockfish")
		end
		assertNear(OceanSim.totalSupply(ocean, "rockfish"), total, 1e-6)
	end)

	test("fishing in one region reduces global supply", function()
		local ocean = newOcean(16)
		OceanSim.addRegion(ocean, makeRegion("a", "reef", 60, 1.0))
		OceanSim.addRegion(ocean, makeRegion("b", "reef", 80, 1.0))
		local before = OceanSim.totalSupply(ocean, "rockfish")
		OceanSim.harvest(ocean, "a", "rockfish", 40)
		local after = OceanSim.totalSupply(ocean, "rockfish")
		assertTrue(after < before, "global supply must fall when a region is fished")
	end)

	test("global abundance stays in a sane band", function()
		local ocean = newOcean(17)
		OceanSim.addRegion(ocean, makeRegion("a", "reef", 60, 1.0))
		OceanSim.addRegion(ocean, makeRegion("b", "kelp", 50, 1.0))
		local ab = OceanSim.globalAbundance(ocean, "rockfish")
		assertTrue(ab > 0 and ab <= 1.16, "global abundance out of band: " .. tostring(ab))
	end)
end)

--=============================================================================
-- Tests: snapshot
--=============================================================================

suite("OceanSim — snapshot", function()
	test("snapshot captures seed, month and order", function()
		local ocean = newOcean(18)
		OceanSim.addRegion(ocean, makeRegion("a", "reef", 60, 1.0))
		OceanSim.addRegion(ocean, makeRegion("b", "sand", 200, 1.0))
		local snap = OceanSim.snapshot(ocean)
		assertEq(snap.seed, 18)
		assertEq(#snap.order, 2)
		assertEq(snap.order[1], "a")
		assertTrue(snap.regions["a"] ~= nil, "region stocks missing from snapshot")
	end)

	test("snapshot of a sim equals the live sim", function()
		local ocean = newOcean(19)
		OceanSim.addRegion(ocean, makeRegion("a", "reef", 60, 1.0))
		local rng = Rng.new(19)
		for _ = 1, 25 do
			OceanSim.tick(ocean, rng)
		end
		local snap = OceanSim.snapshot(ocean)
		assertNear(snap.regions["a"]["rockfish"], OceanSim.getStock(ocean, "a", "rockfish"), 1e-9)
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