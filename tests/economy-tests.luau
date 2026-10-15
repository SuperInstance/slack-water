--!strict
--[[
	Economy tests — validator, market, and region generation.

	These cover the AI/simulation boundary and the price feedback loop. If the
	validator is too permissive the game ships broken content; if it is too
	strict the AI is wasted. If the market does not respond to scarcity, the
	entire reason the ocean is shared evaporates.
]]

local Rng = require("./../src/Shared/Ocean/Rng")
local BankSpec = require("./../src/Shared/Ocean/BankSpec")
local Regions = require("./../src/Shared/Ocean/Regions")
local Market = require("./../src/Shared/Market")
local Species = require("./../src/Shared/Species")
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
		error((msg or "values differ") .. " — expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function assertNear(actual: number, expected: number, tol: number, msg: string?)
	if math.abs(actual - expected) > tol then
		error((msg or "out of tolerance") .. " — expected " .. tostring(expected) .. " +/- " .. tostring(tol) .. ", got " .. tostring(actual), 2)
	end
end

local function validBank(overrides: { [string]: any }?): { [string]: any }
	local base = {
		name = "Slack Water Flats",
		habitat = "sand",
		depth = 120,
		richness = 1.0,
		salinity = 32,
		speciesMix = { { speciesId = "flounder", weight = 1 } },
		hazard = "none",
	}
	if overrides then
		for k, v in overrides do
			base[k] = v
		end
	end
	return base
end

--=============================================================================
-- BankSpec — the AI boundary
--=============================================================================

suite("BankSpec — validation", function()
	test("a well-formed bank is accepted unchanged", function()
		local report = BankSpec.validate(validBank(), "bank_1")
		assertTrue(report.ok, "should accept a good bank: " .. tostring(report.rejections[1]))
		local bank = report.bank
		assertTrue(bank ~= nil, "bank should be present")
		assertEq(bank.name, "Slack Water Flats")
		assertEq(bank.depth, 120)
		assertEq(bank.habitat, "sand")
		assertEq(#report.repairs, 0, "no repairs expected, got: " .. table.concat(report.repairs, "; "))
	end)

	test("non-object payloads are rejected", function()
		assertFalse(BankSpec.validate("a string", "b").ok)
		assertFalse(BankSpec.validate(42, "b").ok)
		assertFalse(BankSpec.validate(nil, "b").ok)
	end)

	test("unknown habitat is a hard rejection", function()
		local report = BankSpec.validate(validBank({ habitat = "volcano" }), "b")
		assertFalse(report.ok, "unknown habitat must reject")
		assertEq(report.rejections[1], "unknown or missing habitat")
	end)

	test("out-of-range depth is repaired, not rejected", function()
		local report = BankSpec.validate(validBank({ depth = 5000 }), "b")
		assertTrue(report.ok, "depth should be clamped not rejected")
		assertEq(report.bank.depth, 900)
		assertTrue(#report.repairs > 0, "a repair should be recorded")
	end)

	test("negative depth clamps to the floor", function()
		local report = BankSpec.validate(validBank({ depth = -50 }), "b")
		assertTrue(report.ok, "should still be valid")
		assertEq(report.bank.depth, 5)
	end)

	test("non-numeric depth falls back to a sane default", function()
		local report = BankSpec.validate(validBank({ depth = "deep" }), "b")
		assertTrue(report.ok, "string depth should fall back")
		assertEq(report.bank.depth, 60)
	end)

	test("richness and salinity clamp into range", function()
		local report = BankSpec.validate(validBank({ richness = 99, salinity = -5 }), "b")
		assertTrue(report.ok)
		assertEq(report.bank.richness, 1.5)
		assertEq(report.bank.salinity, 18)
	end)

	test("unknown species are dropped", function()
		local report = BankSpec.validate(validBank({
			speciesMix = { { speciesId = "flounder", weight = 1 }, { speciesId = "dragon", weight = 2 } },
		}), "b")
		assertTrue(report.ok, "should survive with one valid species")
		assertEq(#report.bank.speciesMix, 1)
		assertEq(report.bank.speciesMix[1].speciesId, "flounder")
	end)

	test("a mix of only unknown species is rejected", function()
		local report = BankSpec.validate(validBank({
			speciesMix = { { speciesId = "dragon", weight = 1 } },
		}), "b")
		assertFalse(report.ok, "no valid species should reject")
	end)

	test("an empty mix is rejected", function()
		assertFalse(BankSpec.validate(validBank({ speciesMix = {} }), "b").ok)
		assertFalse(BankSpec.validate(validBank({ speciesMix = "nope" }), "b").ok)
	end)

	test("species weights are normalised to sum to 1", function()
		local report = BankSpec.validate(validBank({
			speciesMix = { { speciesId = "flounder", weight = 3 }, { speciesId = "skate", weight = 1 } },
		}), "b")
		assertTrue(report.ok)
		local sum = 0.0
		for _, entry in report.bank.speciesMix do
			sum += entry.weight
		end
		assertNear(sum, 1.0, 1e-6, "weights should sum to 1")
	end)

	test("zero and negative weights are discarded", function()
		local report = BankSpec.validate(validBank({
			speciesMix = { { speciesId = "flounder", weight = -5 }, { speciesId = "skate", weight = 0 } },
		}), "b")
		assertFalse(report.ok, "all-zero weights should reject")
	end)
end)

suite("BankSpec — name sanitization", function()
	test("blocked tokens fall back to a safe name", function()
		local report = BankSpec.validate(validBank({ name = "The Fuck Flats" }), "b")
		assertTrue(report.ok, "bank should still be valid")
		assertFalse(string.find(report.bank.name, "fuck") ~= nil, "blocked token must not survive")
	end)

	test("names that are too short or too long fall back", function()
		assertEq(BankSpec.validate(validBank({ name = "ab" }), "b").bank.name, "Unnamed Ground")
		local long = string.rep("x", 100)
		assertEq(BankSpec.validate(validBank({ name = long }), "b").bank.name, "Unnamed Ground")
	end)

	test("punctuation outside the allowed set falls back", function()
		assertEq(BankSpec.validate(validBank({ name = "<script>alert</script>" }), "b").bank.name, "Unnamed Ground")
	end)

	test("real place names survive intact", function()
		local name = "Outer Kelp Bed"
		assertEq(BankSpec.validate(validBank({ name = name }), "b").bank.name, name)
	end)

	test("whitespace is collapsed", function()
		assertEq(BankSpec.validate(validBank({ name = "Outer   Kelp    Bed" }), "b").bank.name, "Outer Kelp Bed")
	end)

	test("non-string names fall back", function()
		assertEq(BankSpec.validate(validBank({ name = 12345 }), "b").bank.name, "Unnamed Ground")
	end)
end)

suite("BankSpec — toRegion", function()
	test("converts a valid bank into a region", function()
		local report = BankSpec.validate(validBank(), "bank_x")
		local region = BankSpec.toRegion(report.bank)
		assertEq(region.id, "bank_x")
		assertEq(region.name, "Slack Water Flats")
		assertEq(region.origin, "composed")
		assertTrue(region.richness >= 0.5 and region.richness <= 1.5, "richness must stay in band")
	end)

	test("a rare-species mix produces a richer ground than a common one", function()
		local common = BankSpec.validate(validBank({
			speciesMix = { { speciesId = "herring", weight = 1 } },
		}), "b")
		local rare = BankSpec.validate(validBank({
			speciesMix = { { speciesId = "kingcrab", weight = 1 } },
		}), "b")
		local commonRichness = BankSpec.toRegion(common.bank).richness
		local rareRichness = BankSpec.toRegion(rare.bank).richness
		assertTrue(rareRichness > commonRichness, "rare species should imply a richer ground")
	end)
end)

--=============================================================================
-- Market
--=============================================================================

suite("Market — scarcity", function()
	test("full abundance means no scarcity premium", function()
		assertNear(Market.scarcityMultiplier(1.0), 1.0, 1e-9)
	end)

	test("scarcity multiplier rises as abundance falls", function()
		local rich = Market.scarcityMultiplier(0.9)
		local middling = Market.scarcityMultiplier(0.5)
		local poor = Market.scarcityMultiplier(0.2)
		assertTrue(rich < middling and middling < poor, "multiplier must rise as stock falls")
	end)

	test("multiplier is capped so collapse is not a money printer", function()
		local extreme = Market.scarcityMultiplier(0.0)
		assertNear(extreme, Config.MAX_SCARCITY_MULTIPLIER, 0.001, "zero abundance should sit at the cap")
		assertTrue(extreme <= Config.MAX_SCARCITY_MULTIPLIER, "must respect the cap")
	end)

	test("target price scales with base value", function()
		local herring = Species.get("herring")
		local halibut = Species.get("halibut")
		local h = Market.targetPrice(herring.baseValue, 0.3)
		local l = Market.targetPrice(halibut.baseValue, 0.3)
		assertTrue(l > h, "halibut should be worth more than herring at equal abundance")
	end)
end)

suite("Market — response", function()
	test("a fresh market sits at base value", function()
		local market = Market.new()
		assertNear(market.entries["halibut"].price, Species.get("halibut").baseValue, 1e-9)
		assertEq(market.entries["halibut"].direction, "flat")
	end)

	test("falling abundance raises the price", function()
		local market = Market.new()
		Market.updateSpecies(market, "halibut", 1.0)
		local before = market.entries["halibut"].price

		-- a single step should read as rising immediately
		Market.updateSpecies(market, "halibut", 0.2)
		assertEq(market.entries["halibut"].direction, "rising", "first move should read as rising")

		for _ = 1, 60 do
			Market.updateSpecies(market, "halibut", 0.2)
		end
		local after = market.entries["halibut"].price
		assertTrue(after > before, "price should climb as stock falls: " .. tostring(before) .. " -> " .. tostring(after))
		-- once the price has settled at the new scarcity level it is flat again
		assertEq(market.entries["halibut"].direction, "flat", "settled price should be flat")
	end)

	test("recovery lowers the price back toward fair value", function()
		local market = Market.new()
		for _ = 1, 80 do
			Market.updateSpecies(market, "cod", 0.1)
		end
		local spiked = market.entries["cod"].price
		for _ = 1, 200 do
			Market.updateSpecies(market, "cod", 1.0)
		end
		local recovered = market.entries["cod"].price
		assertTrue(recovered < spiked, "price should fall as stock recovers")
		assertNear(recovered, Species.get("cod").baseValue, 1.0, "should settle near fair value")
	end)

	test("inertia means a single change does not teleport the price", function()
		local market = Market.new()
		local before = market.entries["rockfish"].price
		Market.updateSpecies(market, "rockfish", 0.1)
		local after = market.entries["rockfish"].price
		local target = Market.targetPrice(Species.get("rockfish").baseValue, 0.1)
		assertTrue(after < target, "one step should not reach the target")
		assertTrue(after > before, "but it should move")
	end)

	test("direction settles to flat when nothing is changing", function()
		local market = Market.new()
		for _ = 1, 5 do
			Market.updateSpecies(market, "flounder", 1.0)
		end
		assertEq(market.entries["flounder"].direction, "flat")
	end)

	test("updateAll refreshes every species from an abundance table", function()
		local market = Market.new()
		Market.updateAll(market, { rockfish = 0.25 })
		assertTrue(market.entries["rockfish"].scarcityMultiplier > 1.0, "rockfish should carry a premium")
		assertNear(market.entries["herring"].price, Species.get("herring").baseValue, 1e-6, "unspecified species unchanged")
	end)

	test("unknown species does not crash the market", function()
		local market = Market.new()
		assertTrue(Market.updateSpecies(market, "dragon", 0.5) == nil, "unknown species should return nil")
		assertNear(Market.priceOf(market, "dragon"), 0.0, 1e-9)
	end)

	test("isScarce flags a stock in trouble", function()
		local market = Market.new()
		Market.updateSpecies(market, "yelloweye", 0.05)
		assertTrue(Market.isScarce(market.entries["yelloweye"]), "a 5% stock is scarce")
		Market.updateSpecies(market, "yelloweye", 1.0)
		assertFalse(Market.isScarce(market.entries["yelloweye"]), "a healthy stock is not scarce")
	end)

	test("bestOpportunity names the most valuable species", function()
		local market = Market.new()
		Market.updateAll(market, {
			halibut = 0.15,
			herring = 1.0,
			pollock = 1.0,
		})
		local best = Market.bestOpportunity(market)
		assertTrue(best ~= nil, "should return something")
		assertEq(best.speciesId, "halibut", "the scarce high-value species is the opportunity")
	end)

	test("snapshot covers the whole roster", function()
		local market = Market.new()
		assertEq(#Market.snapshot(market), #Species.list)
	end)
end)

--=============================================================================
-- Regions
--=============================================================================

suite("Regions — generation", function()
	test("generates the requested count", function()
		local regions = Regions.generate(42, 12)
		assertEq(#regions, 12)
	end)

	test("ids are unique and ordered", function()
		local regions = Regions.generate(42, 20)
		local seen: { [string]: boolean } = {}
		for i, r in regions do
			assertFalse(seen[r.id] == true, "duplicate id " .. r.id)
			seen[r.id] = true
			assertEq(r.id, "r" .. tostring(i))
		end
	end)

	test("same seed reproduces the same ocean", function()
		local a = Regions.generate(7, 10)
		local b = Regions.generate(7, 10)
		for i = 1, 10 do
			assertEq(a[i].name, b[i].name, "name must match at " .. tostring(i))
			assertEq(a[i].depth, b[i].depth, "depth must match at " .. tostring(i))
			assertEq(a[i].habitat, b[i].habitat, "habitat must match at " .. tostring(i))
		end
	end)

	test("different seeds produce different oceans", function()
		local a = Regions.generate(1, 10)
		local b = Regions.generate(2, 10)
		local differences = 0
		for i = 1, 10 do
			if a[i].name ~= b[i].name then
				differences += 1
			end
		end
		assertTrue(differences > 5, "seeds should diverge, got " .. tostring(differences))
	end)

	test("generated regions are biologically valid", function()
		local regions = Regions.generate(99, 40)
		for _, region in regions do
			local range = Regions.DEPTH_RANGE[region.habitat]
			assertTrue(range ~= nil, "unknown habitat " .. tostring(region.habitat))
			assertTrue(
				region.depth >= range[1] and region.depth <= range[2],
				"depth out of habitat range for " .. region.habitat .. ": " .. tostring(region.depth)
			)
			assertTrue(region.richness >= 0.5 and region.richness <= 1.5, "richness out of band")
			assertEq(region.origin, "procedural")
		end
	end)

	test("every region has a human-sized name", function()
		local regions = Regions.generate(5, 30)
		for _, region in regions do
			assertTrue(#region.name >= 3 and #region.name <= 42, "bad name length: " .. region.name)
		end
	end)

	test("fillTo tops the ocean back up", function()
		local existing = Regions.generate(1, 5)
		local extra = Regions.fillTo(1, #existing, 9)
		assertEq(#extra, 4)
		assertEq(extra[1].id, "r6", "fill continues the id sequence")
	end)

	test("fillTo is a no-op when already at target", function()
		assertEq(#Regions.fillTo(1, 10, 10), 0)
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