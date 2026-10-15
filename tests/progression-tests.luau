--!strict
--[[
	Progression tests — the skipper's career.

	These exist to keep progression pointed the same way as the economy. The
	ocean is shared and persistent; if xp ever rewarded camping a picked-over
	ground — or if endgame gear made the handline a joke — the progression
	system would be paying players to damage the one resource the whole game
	is about.

	The interesting fixtures here are real OceanSim oceans: a fresh reef and
	the same reef hammered for two hundred casts, so the xp shaping is tested
	against what harvest actually yields, not against invented numbers.
]]

local Progression = require("./../src/Shared/Progression")
local Types = require("./../src/Shared/Types")
local OceanSim = require("./../src/Shared/Ocean/OceanSim")
local Rng = require("./../src/Shared/Ocean/Rng")

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

local function assertNear(actual: number, expected: number, tol: number, msg: string?)
	if math.abs(actual - expected) > tol then
		error(
			(msg or "out of tolerance")
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

-- a catch record with everything defaulted but the numbers under test
local function catchRec(
	yielded: number,
	effortUsed: number,
	abundanceBefore: number,
	speciesId: string?,
	tideQuality: number?
): any
	return {
		speciesId = speciesId or "rockfish",
		yielded = yielded,
		effortUsed = effortUsed,
		abundanceBefore = abundanceBefore,
		tideQuality = tideQuality,
	}
end

-- the roster in unlock order; tests assert relationships along this order,
-- never magic effort numbers, so gear retuning does not break them
local function gearByUnlock(): { any }
	local rows: { any } = {}
	for _, gear in Types.Gear do
		table.insert(rows, gear)
	end
	table.sort(rows, function(a, b)
		if a.unlockLevel ~= b.unlockLevel then
			return a.unlockLevel < b.unlockLevel
		end
		return a.id < b.id
	end)
	return rows
end

-- a healthy, untouched reef ground
local function freshReef()
	local ocean = OceanSim.new(30)
	OceanSim.addRegion(ocean, makeRegion("r1", "reef", 60, 1.0))
	return ocean
end

-- the same reef after another crew has worked it over for a long while.
-- 60 effort per tick is genuinely unsustainable pressure — the stock falls
-- through the collapse threshold and pins near the extirpation floor, which
-- is what "picked over" honestly means in this ocean.
local function hammeredReef()
	local ocean = freshReef()
	local rng = Rng.new(30)
	for _ = 1, 200 do
		OceanSim.harvest(ocean, "r1", "rockfish", 60)
		OceanSim.tick(ocean, rng)
	end
	return ocean
end

--=============================================================================
-- Profile lifecycle
--=============================================================================

suite("Progression — profile lifecycle", function()
	test("a new skipper starts on the starter gear at level 1", function()
		local p = Progression.new()
		assertEq(Progression.levelOf(p), 1)
		assertNear(p.xp, 0.0, 1e-9)
		assertEq(p.currentGearId, "handline")
		assertNear(Progression.effortFor(p), Types.Gear.handline.effort, 1e-9)
		assertTrue(Progression.owns(p, "handline"))
		assertEq(
			Progression.STARTER_GEAR.id,
			"handline",
			"the derived starter should be the handline"
		)
	end)

	test("snapshot and restore round-trip a real profile", function()
		local p = Progression.restore({ xp = Progression.totalXpForLevel(5) })
		assertTrue(Progression.buy(p, "rod", 5000))
		assertTrue(Progression.buy(p, "gi", 5000))
		assertTrue(Progression.equip(p, "gi"))

		local snap = Progression.snapshot(p)
		local restored = Progression.restore(snap)

		assertEq(restored.xp, p.xp)
		assertEq(restored.currentGearId, "gi")
		assertNear(Progression.effortFor(restored), Types.Gear.gi.effort, 1e-9)
		assertTrue(
			Progression.owns(restored, "handline")
				and Progression.owns(restored, "rod")
				and Progression.owns(restored, "gi")
		)

		-- snapshotting the restore reproduces the same bytes
		local snap2 = Progression.snapshot(restored)
		assertEq(table.concat(snap2.ownedGear, ","), table.concat(snap.ownedGear, ","))
	end)

	test("restore repairs hostile payloads instead of trusting them", function()
		for _, junk in { nil, 42, "nope", true } do
			local p = Progression.restore(junk)
			assertEq(Progression.levelOf(p), 1)
			assertEq(p.currentGearId, "handline")
			assertTrue(Progression.owns(p, "handline"))
		end

		local healed = Progression.restore({ xp = -50, currentGearId = "photon cannon" })
		assertNear(healed.xp, 0.0, 1e-9)
		assertEq(healed.currentGearId, "handline")

		-- a save claiming gear above its earned level is repaired, not believed
		local hacked = Progression.restore({
			xp = 100, -- level 2: rod is legal, trawler is not
			ownedGear = { "rod", "trawler", "dragon", 7 },
			currentGearId = "trawler",
		})
		assertFalse(
			Progression.owns(hacked, "trawler"),
			"gear above the saved level must be dropped"
		)
		assertFalse(Progression.owns(hacked, "dragon"), "unknown gear must be dropped")
		assertTrue(Progression.owns(hacked, "rod"), "gear at or below the level is kept")
		assertEq(hacked.currentGearId, "handline", "dropped gear cannot stay equipped")
	end)

	test("level is derived from xp, never read back from the save", function()
		local pinned = Progression.restore({ xp = Progression.totalXpForLevel(10), level = 1 })
		assertEq(Progression.levelOf(pinned), 10, "a stale stored level must be ignored")
	end)
end)

--=============================================================================
-- The xp curve
--=============================================================================

suite("Progression — the xp curve", function()
	test("xpToNext starts at the base and rises with level", function()
		assertNear(Progression.xpToNext(1), Progression.XP_LEVEL_BASE, 1e-9)
		local prev = -1.0
		for level = 1, Progression.MAX_LEVEL do
			local need = Progression.xpToNext(level)
			assertTrue(need > prev, "xpToNext must strictly increase at level " .. tostring(level))
			prev = need
		end
	end)

	test("totalXpForLevel is the running sum of xpToNext", function()
		assertNear(Progression.totalXpForLevel(1), 0.0, 1e-9)
		local sum = 0.0
		for level = 1, Progression.MAX_LEVEL - 1 do
			sum += Progression.xpToNext(level)
			assertNear(Progression.totalXpForLevel(level + 1), sum, 1e-6)
		end
	end)

	test("level boundaries are exact", function()
		local justBelow = Progression.restore({ xp = Progression.totalXpForLevel(5) - 0.001 })
		assertEq(Progression.levelOf(justBelow), 4)
		local exactly = Progression.restore({ xp = Progression.totalXpForLevel(5) })
		assertEq(Progression.levelOf(exactly), 5)
	end)

	test("level pins at MAX_LEVEL no matter the xp", function()
		local maxed = Progression.restore({ xp = 1e12 })
		assertEq(Progression.levelOf(maxed), Progression.MAX_LEVEL)
	end)

	test("levelProgress on a fresh profile reads as an empty bar", function()
		local lp = Progression.levelProgress(Progression.new())
		assertEq(lp.level, 1)
		assertNear(lp.intoLevel, 0.0, 1e-9)
		assertNear(lp.needed, Progression.xpToNext(1), 1e-9)
		assertNear(lp.fraction, 0.0, 1e-9)
	end)

	test("levelProgress fraction stays inside [0, 1) below the cap", function()
		local p =
			Progression.restore({ xp = Progression.totalXpForLevel(Progression.MAX_LEVEL) + 100.0 })
		local lp = Progression.levelProgress(p)
		assertEq(lp.level, Progression.MAX_LEVEL)
		assertTrue(
			lp.fraction >= 0.0 and lp.fraction < 1.0,
			"fraction out of band: " .. tostring(lp.fraction)
		)
	end)
end)

--=============================================================================
-- XP shaping — the thesis
--=============================================================================

suite("Progression — xp shaping (the thesis)", function()
	test("a fresh ground pays several times the xp of a hammered one", function()
		local fresh = freshReef()
		local freshRes: any = OceanSim.harvest(fresh, "r1", "rockfish", 40)
		local poor = hammeredReef()
		local poorRes: any = OceanSim.harvest(poor, "r1", "rockfish", 40)

		assertTrue(freshRes ~= nil and poorRes ~= nil, "harvest returned nil")
		local freshXp =
			Progression.xpForCatch(catchRec(freshRes.yielded, 40, freshRes.abundanceBefore))
		local poorXp =
			Progression.xpForCatch(catchRec(poorRes.yielded, 40, poorRes.abundanceBefore))
		assertTrue(
			freshXp > poorXp * 3.0,
			"picked-over ground must pay far less xp: "
				.. tostring(freshXp)
				.. " vs "
				.. tostring(poorXp)
		)
		-- and it is not just the smaller catch: per biomass landed, the fresh
		-- ground is still the better teacher
		assertTrue(
			freshXp / freshRes.yielded > poorXp / poorRes.yielded,
			"per-biomass xp must favour the fresh ground"
		)
	end)

	test("xp rises strictly with the ground's abundance", function()
		local last = -1.0
		for _, a in { 0.0, 0.25, 0.5, 0.75, 1.0 } do
			local xp = Progression.xpForCatch(catchRec(10, 14, a))
			assertTrue(xp > last, "xp must rise with abundance at " .. tostring(a))
			last = xp
		end
		assertNear(
			Progression.xpForCatch(catchRec(10, 14, 1.3)),
			Progression.xpForCatch(catchRec(10, 14, 1.0)),
			1e-9,
			"over-full abundance must clamp to 1"
		)
	end)

	test("an empty catch is worth nothing", function()
		assertNear(Progression.xpForCatch(catchRec(0, 60, 0.9)), 0.0, 1e-9)
	end)

	test("harder species pay more xp per catch", function()
		local herring = Progression.xpForCatch(catchRec(10, 14, 0.8, "herring"))
		local kingcrab = Progression.xpForCatch(catchRec(10, 14, 0.8, "kingcrab"))
		assertTrue(kingcrab > herring, "a difficulty-5 catch must out-pay a difficulty-1 one")
	end)

	test("slack water pays; missing tide data is safe", function()
		local none = Progression.xpForCatch(catchRec(10, 14, 0.8))
		local half = Progression.xpForCatch(catchRec(10, 14, 0.8, "rockfish", 0.5))
		local full = Progression.xpForCatch(catchRec(10, 14, 0.8, "rockfish", 1.0))
		assertTrue(none < half and half < full, "xp should rise with tide quality")
		assertTrue(none > 0.0 and half > 0.0 and full > 0.0)
	end)

	test("an unknown species does not crash the xp math", function()
		local xp = Progression.xpForCatch(catchRec(10, 14, 0.8, "dragon"))
		assertTrue(xp > 0.0, "unknown species should pay out at mid skill")
	end)

	test("identical catches on identical profiles give identical outcomes", function()
		local a, b = Progression.new(), Progression.new()
		local rec = catchRec(7.5, 6, 0.62)
		local o1 = Progression.recordCatch(a, rec)
		local o2 = Progression.recordCatch(b, rec)
		assertNear(a.xp, b.xp, 1e-12)
		assertEq(o1.level, o2.level)
		assertEq(o1.levelsGained, o2.levelsGained)
		assertEq(#o1.unlockedGear, #o2.unlockedGear)
		assertEq(
			table.concat(Progression.snapshot(a).ownedGear, ","),
			table.concat(Progression.snapshot(b).ownedGear, ",")
		)
	end)
end)

--=============================================================================
-- Gear gating and purchase
--=============================================================================

suite("Progression — gear gating and purchase", function()
	test("a level-1 skipper sees only the starter gear", function()
		local gear = Progression.availableGear(Progression.new())
		assertEq(#gear, 1)
		assertEq(gear[1].id, "handline")
	end)

	test("unlock levels gate correctly", function()
		local l1 = Progression.restore({ xp = Progression.totalXpForLevel(2) - 0.001 })
		assertFalse(Progression.isUnlocked(l1, "rod"))
		assertFalse(Progression.isUnlocked(l1, "trawler"))
		assertFalse(Progression.isUnlocked(l1, "not_a_gear"))

		local l2 = Progression.restore({ xp = Progression.totalXpForLevel(2) })
		assertTrue(Progression.isUnlocked(l2, "rod"))
		assertFalse(Progression.isUnlocked(l2, "gi"))

		local l14 = Progression.restore({ xp = Progression.totalXpForLevel(14) })
		assertTrue(Progression.isUnlocked(l14, "trawler"))
	end)

	test("buy respects the level gate, then funds", function()
		local p = Progression.restore({ xp = Progression.totalXpForLevel(5) - 1.0 })
		assertFalse(Progression.buy(p, "gi", 999999), "one xp short of level 5 must refuse the gi")

		Progression.recordCatch(p, catchRec(1, 6, 1.0)) -- crosses the boundary
		assertTrue(Progression.buy(p, "gi", 5000), "at level 5 with funds the buy should succeed")
		assertTrue(Progression.owns(p, "gi"))
		assertEq(p.currentGearId, "handline", "buying must not auto-equip")
	end)

	test("buy respects the gear's price", function()
		local p = Progression.restore({ xp = Progression.totalXpForLevel(14) })
		local price = Types.Gear.trawler.price
		assertFalse(Progression.buy(p, "trawler", price - 1), "one coin short must refuse")
		assertTrue(Progression.buy(p, "trawler", price))
	end)

	test("buy rejects unknown and already-owned gear", function()
		local p = Progression.restore({ xp = Progression.totalXpForLevel(14) })
		assertFalse(Progression.buy(p, "seine_net", 1000000))
		assertTrue(Progression.buy(p, "trawler", 1000000))
		assertFalse(Progression.buy(p, "trawler", 1000000), "buying owned gear must fail")
	end)

	test("equip requires ownership, and switching back to the starter always works", function()
		local p = Progression.new()
		assertFalse(Progression.equip(p, "rod"), "cannot equip unowned gear")
		assertTrue(Progression.equip(p, "handline"), "re-equipping the starter is always legal")

		local q = Progression.restore({
			xp = Progression.totalXpForLevel(2),
			ownedGear = { "rod" },
			currentGearId = "rod",
		})
		assertNear(Progression.effortFor(q), Types.Gear.rod.effort, 1e-9)
		assertTrue(
			Progression.equip(q, "handline"),
			"dropping back to light tackle is the stewardship verb"
		)
		assertNear(Progression.effortFor(q), Types.Gear.handline.effort, 1e-9)
	end)
end)

--=============================================================================
-- Effort, finesse, and the handline's endgame
--=============================================================================

suite("Progression — effort, finesse, and the handline's endgame", function()
	test("gear effort strictly increases along the unlock order", function()
		local ordered = gearByUnlock()
		assertTrue(#ordered >= 2, "the roster should have several tiers")
		local lastEffort = -1.0
		for _, gear in ordered do
			assertTrue(
				gear.effort > lastEffort,
				"effort must rise with unlock level at " .. gear.id
			)
			lastEffort = gear.effort
		end
	end)

	test("xp per cast strictly increases with gear — upgrades still matter", function()
		local lastPerCast = -1.0
		for _, gear in gearByUnlock() do
			local perCast = Progression.xpForCatch(catchRec(gear.effort, gear.effort, 1.0))
			assertTrue(perCast > lastPerCast, "xp per cast must rise with gear tier at " .. gear.id)
			lastPerCast = perCast
		end
	end)

	test("xp per biomass strictly decreases with gear — restraint stays efficient", function()
		local lastPerBiomass = math.huge
		for _, gear in gearByUnlock() do
			local perCast = Progression.xpForCatch(catchRec(gear.effort, gear.effort, 1.0))
			local perBiomass = perCast / gear.effort
			assertTrue(
				perBiomass < lastPerBiomass,
				"xp per fish killed must fall with gear tier at " .. gear.id
			)
			lastPerBiomass = perBiomass
		end
	end)

	test("the trawler out-levels the handline per cast, but not per fish", function()
		local handlineEffort = Types.Gear.handline.effort
		local trawlerEffort = Types.Gear.trawler.effort
		local handXp = Progression.xpForCatch(catchRec(handlineEffort, handlineEffort, 1.0))
		local trawlXp = Progression.xpForCatch(catchRec(trawlerEffort, trawlerEffort, 1.0))
		assertTrue(trawlXp > handXp, "endgame gear must out-level the starter per cast")
		assertTrue(
			handXp / handlineEffort > trawlXp / trawlerEffort,
			"the handline must stay the more xp-efficient tool per fish killed"
		)
	end)
end)

--=============================================================================
-- recordCatch and level-ups
--=============================================================================

suite("Progression — recordCatch and level-ups", function()
	test("recordCatch accrues xp and reports the level", function()
		local p = Progression.new()
		local out = Progression.recordCatch(p, catchRec(10, 6, 1.0))
		assertNear(out.xpGained, p.xp, 1e-9)
		assertEq(out.level, Progression.levelOf(p))
		assertEq(out.levelsGained, 0)
		assertEq(#out.unlockedGear, 0)
	end)

	test("crossing one boundary unlocks exactly the next tier", function()
		local p = Progression.restore({ xp = Progression.totalXpForLevel(2) - 0.01 })
		local out = Progression.recordCatch(p, catchRec(1, 6, 1.0))
		assertEq(out.levelsGained, 1)
		assertEq(out.level, 2)
		assertEq(#out.unlockedGear, 1)
		assertEq(out.unlockedGear[1].id, "rod")
		assertFalse(Progression.owns(p, "rod"), "unlocking must not grant ownership")
	end)

	test("a huge catch can jump several levels at once", function()
		local p = Progression.restore({ xp = Progression.totalXpForLevel(2) - 1.0 })
		local out = Progression.recordCatch(p, catchRec(2000, 6, 1.0))
		assertTrue(
			out.levelsGained >= 5,
			"expected a multi-level jump, got " .. tostring(out.levelsGained)
		)
		assertEq(out.level, Progression.levelOf(p))
		local ids = {}
		for _, gear in out.unlockedGear do
			table.insert(ids, gear.id)
		end
		assertEq(
			table.concat(ids, ","),
			"rod,gi,crab_pot,longline",
			"the unlock list must be complete and ordered"
		)
	end)

	test("at MAX_LEVEL xp still accrues but the level pins", function()
		local p = Progression.restore({ xp = Progression.totalXpForLevel(Progression.MAX_LEVEL) })
		local out = Progression.recordCatch(p, catchRec(100, 60, 1.0))
		assertTrue(out.xpGained > 0.0)
		assertEq(out.level, Progression.MAX_LEVEL)
		assertEq(out.levelsGained, 0)
		assertEq(#out.unlockedGear, 0)
	end)

	test("end-to-end: a skipper levels far faster on a fresh ground than a hammered one", function()
		local function session(hammerFirst: boolean): number
			local ocean = if hammerFirst then hammeredReef() else freshReef()
			local profile = Progression.new()
			for _ = 1, 10 do
				local res: any =
					OceanSim.harvest(ocean, "r1", "rockfish", Progression.effortFor(profile))
				if res ~= nil then
					Progression.recordCatch(
						profile,
						catchRec(res.yielded, Progression.effortFor(profile), res.abundanceBefore)
					)
				end
			end
			return profile.xp
		end
		local fresh = session(false)
		local hammered = session(true)
		assertTrue(
			fresh > hammered * 2.0,
			"ten casts on a fresh ground should more than double the hammered ground's xp: "
				.. tostring(fresh)
				.. " vs "
				.. tostring(hammered)
		)
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
