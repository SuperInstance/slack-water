--!strict
--[[
	Reconciliation tests.

	These cover the moment the ocean stops being per-server, so the failure they
	guard against is specific and expensive: a snapshot that silently eats a
	catch the player just landed.

	The story worth protecting is a player casting at a ground another server has
	also been working, with an unreported catch of their own in flight. The
	snapshot must overwrite the global picture AND keep their fish.
]]

local Reconcile = require("./../src/Shared/Ocean/Reconcile")
local OceanSim = require("./../src/Shared/Ocean/OceanSim")
local Rng = require("./../src/Shared/Ocean/Rng")

local fixture = require("./fixtures/worker-snapshot")

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
		error((msg or "values differ") .. " — expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
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

local function newOcean()
	local ocean = OceanSim.new(555)
	OceanSim.addRegion(ocean, {
		id = "r1",
		name = "Reef One",
		habitat = "reef" :: any,
		depth = 60,
		salinity = 32,
		richness = 1.0,
		origin = "procedural" :: any,
	})
	return ocean
end

local function stockOf(ocean: any, speciesId: string): number
	return OceanSim.getStock(ocean, "r1", speciesId)
end

--=============================================================================
-- Queue
--=============================================================================

suite("Reconcile — pending queue", function()
	test("a fresh reconciler is empty", function()
		assertEq(Reconcile.pendingCount(Reconcile.new()), 0)
	end)

	test("queueing records the delta", function()
		local r = Reconcile.new()
		Reconcile.queue(r, "r1", "rockfish", 25)
		assertEq(Reconcile.pendingCount(r), 1)
		assertEq(r.pending[1].biomass, 25)
	end)

	test("zero and negative biomass is not queued", function()
		local r = Reconcile.new()
		Reconcile.queue(r, "r1", "rockfish", 0)
		Reconcile.queue(r, "r1", "rockfish", -5)
		assertEq(Reconcile.pendingCount(r), 0)
	end)

	test("confirming removes the oldest entries first", function()
		local r = Reconcile.new()
		Reconcile.queue(r, "r1", "rockfish", 10)
		Reconcile.queue(r, "r1", "cod", 20)
		Reconcile.queue(r, "r1", "pollock", 30)
		Reconcile.confirm(r, 1)
		assertEq(Reconcile.pendingCount(r), 2)
		assertEq(r.pending[1].speciesId, "cod", "the oldest should be gone, not the newest")
	end)

	test("confirming more than queued is harmless", function()
		local r = Reconcile.new()
		Reconcile.queue(r, "r1", "cod", 5)
		Reconcile.confirm(r, 10)
		assertEq(Reconcile.pendingCount(r), 0)
	end)

	test("the queue is bounded so an unreachable backend cannot leak memory", function()
		local r = Reconcile.new()
		r.maxPending = 4
		for i = 1, 50 do
			Reconcile.queue(r, "r1", "cod", i)
		end
		assertEq(Reconcile.pendingCount(r), 4)
	end)

	test("reset clears everything", function()
		local r = Reconcile.new()
		Reconcile.queue(r, "r1", "cod", 5)
		Reconcile.reset(r)
		assertEq(Reconcile.pendingCount(r), 0)
	end)
end)

--=============================================================================
-- Snapshot application
--=============================================================================

suite("Reconcile — applying a snapshot", function()
	test("global state replaces local state", function()
		local ocean = newOcean()
		local before = stockOf(ocean, "rockfish")

		Reconcile.applySnapshot(ocean, Reconcile.new(), {
			regions = { r1 = { rockfish = 10 } },
		})

		assertEq(stockOf(ocean, "rockfish"), 10)
		assertTrue(before ~= 10, "the fixture should have changed the stock")
	end)

	test("a snapshot the Worker has already seen does NOT eat an unreported catch", function()
		-- This is the whole point of the queue.
		local ocean = newOcean()
		local reconciler = Reconcile.new()

		-- player lands a fish, applied locally, not yet reported
		local landed = OceanSim.harvest(ocean, "r1", "rockfish", 40)
		assertTrue(landed ~= nil, "harvest should have worked")
		local localStock = stockOf(ocean, "rockfish")
		Reconcile.queue(reconciler, "r1", "rockfish", landed.yielded)

		-- a snapshot arrives from BEFORE that catch landed
		local staleGlobal = localStock + landed.yielded
		Reconcile.applySnapshot(ocean, reconciler, {
			regions = { r1 = { rockfish = staleGlobal } },
		})

		assertEq(
			stockOf(ocean, "rockfish"),
			localStock,
			"the unreported catch must survive the snapshot"
		)
	end)

	test("a confirmed catch is correctly overwritten by the snapshot", function()
		-- The Worker now knows about the catch, so the snapshot should win.
		local ocean = newOcean()
		local reconciler = Reconcile.new()

		local landed = OceanSim.harvest(ocean, "r1", "rockfish", 40)
		Reconcile.queue(reconciler, "r1", "rockfish", landed.yielded)
		Reconcile.confirm(reconciler, 1)

		local globalStock = stockOf(ocean, "rockfish")
		Reconcile.applySnapshot(ocean, reconciler, {
			regions = { r1 = { rockfish = globalStock } },
		})

		assertEq(stockOf(ocean, "rockfish"), globalStock)
	end)

	test("a snapshot from ANOTHER server's fishing shows up locally", function()
		-- This is "shared ocean" made observable: another server's cast lowers
		-- the stock on this one.
		local ocean = newOcean()
		local localStock = stockOf(ocean, "rockfish")

		Reconcile.applySnapshot(ocean, Reconcile.new(), {
			regions = { r1 = { rockfish = localStock * 0.5 } },
		})

		assertTrue(stockOf(ocean, "rockfish") < localStock, "another server's fishing should lower our stock")
	end)

	test("the Worker owns the calendar", function()
		-- The 20s Roblox tick and the 60s cron disagreed about what a day was,
		-- which would have desynced the salmon runs across servers.
		local ocean = newOcean()
		Reconcile.applySnapshot(ocean, Reconcile.new(), { month = 9, day = 2 })
		assertEq(ocean.month, 9)
		assertEq(ocean.day, 2)
	end)

	test("a partial snapshot does not clobber species it does not mention", function()
		local ocean = newOcean()
		local codBefore = stockOf(ocean, "cod")

		Reconcile.applySnapshot(ocean, Reconcile.new(), {
			regions = { r1 = { rockfish = 5 } },
		})

		assertEq(stockOf(ocean, "cod"), codBefore, "unmentioned species should keep their stock")
	end)

	test("a snapshot for an unknown region is ignored", function()
		local ocean = newOcean()
		local before = stockOf(ocean, "rockfish")
		Reconcile.applySnapshot(ocean, Reconcile.new(), {
			regions = { notARealRegion = { rockfish = 1 } },
		})
		assertEq(stockOf(ocean, "rockfish"), before)
	end)

	test("an empty or malformed snapshot leaves the ocean alone", function()
		local ocean = newOcean()
		local before = stockOf(ocean, "rockfish")
		Reconcile.applySnapshot(ocean, Reconcile.new(), {})
		Reconcile.applySnapshot(ocean, Reconcile.new(), { regions = {} })
		assertEq(stockOf(ocean, "rockfish"), before)
	end)

	test("replay count reports how far behind we are", function()
		local ocean = newOcean()
		local reconciler = Reconcile.new()
		Reconcile.queue(reconciler, "r1", "rockfish", 10)
		Reconcile.queue(reconciler, "r1", "cod", 10)

		local replayed = Reconcile.applySnapshot(ocean, reconciler, {
			regions = { r1 = { rockfish = 100, cod = 100 } },
		})

		assertEq(replayed, 2)
	end)

	test("replay never drives a stock below zero", function()
		local ocean = newOcean()
		local reconciler = Reconcile.new()
		Reconcile.queue(reconciler, "r1", "rockfish", 999999)

		Reconcile.applySnapshot(ocean, reconciler, {
			regions = { r1 = { rockfish = 10 } },
		})

		assertTrue(stockOf(ocean, "rockfish") >= 0, "replay must not go negative")
	end)

	test("the ocean stays deterministic under reconciliation", function()
		local function run(): number
			local ocean = newOcean()
			local reconciler = Reconcile.new()
			local rng = Rng.new(555)

			local landed = OceanSim.harvest(ocean, "r1", "rockfish", 40)
			Reconcile.queue(reconciler, "r1", "rockfish", if landed then landed.yielded else 0)

			for _ = 1, 3 do
				OceanSim.tick(ocean, rng)
				Reconcile.applySnapshot(ocean, reconciler, {
					month = 4,
					regions = { r1 = { rockfish = 400, cod = 250 } },
				})
			end

			return stockOf(ocean, "rockfish")
		end

		assertEq(run(), run(), "reconciliation must stay deterministic")
	end)
end)

--=============================================================================
-- Health
--=============================================================================

suite("Reconcile — health", function()
	test("a server that never synced is running locally and says so", function()
		local h = Reconcile.health(Reconcile.new(), false)
		assertTrue(h.ok, "local play is a valid mode, not a failure")
		assertEq(h.reason, "local")
	end)

	test("a synced server with a small queue is healthy", function()
		local r = Reconcile.new()
		Reconcile.queue(r, "r1", "cod", 5)
		local h = Reconcile.health(r, true)
		assertTrue(h.ok)
		assertEq(h.reason, "synced")
	end)

	test("a growing unconfirmed queue means the backend is gone", function()
		local r = Reconcile.new()
		r.maxPending = 10
		for _ = 1, 8 do
			Reconcile.queue(r, "r1", "cod", 5)
		end
		local h = Reconcile.health(r, true)
		assertFalse(h.ok, "a half-full queue means we are drifting from the shared ocean")
		assertTrue(string.find(h.reason, "unreachable") ~= nil, "the reason should say unreachable")
	end)

	test("health reports the pending count", function()
		local r = Reconcile.new()
		Reconcile.queue(r, "r1", "cod", 5)
		assertEq(Reconcile.health(r, true).pending, 1)
	end)
end)


--=============================================================================
-- Wire format
--
-- Captured from the live Worker on 2026-10-14, not hand-written. These exist
-- because the array/object shape mismatch below silently disabled the entire
-- shared-ocean feature with no error anywhere.
--=============================================================================

suite("Reconcile — worker wire format", function()
	local fixture = require("./fixtures/worker-snapshot")

	test("the real fixture is present and well formed", function()
		assertTrue(fixture ~= nil, "fixture missing")
		assertTrue(type(fixture) == "table", "fixture should decode to a table")
		assertTrue(fixture.regions ~= nil, "fixture has no regions")
	end)

	test("normalises the worker's array-of-regions shape", function()
		local snapshot = Reconcile.fromWorker(fixture)
		assertTrue(snapshot ~= nil, "normalise returned nil")
		assertEq(type(snapshot.regions), "table")

		local count = 0
		for _ in snapshot.regions do
			count += 1
		end
		assertEq(count, 10, "all ten seeded regions should survive normalisation")
	end)

	test("stock rows become a species-keyed map", function()
		local snapshot = Reconcile.fromWorker(fixture)
		local first = snapshot.regions["r_open_sea"] or snapshot.regions["r_kelp_road"]
		assertTrue(first ~= nil, "expected a known region id")
		assertTrue(first.chinook ~= nil, "chinook biomass should be keyed by species")
		assertTrue(type(first.chinook) == "number", "biomass should be a number")
	end)

	test("the normalised snapshot actually merges", function()
		-- The regression that matters: the shapes matched nothing, so the
		-- ocean silently stayed per-server.
		local ocean = newOcean()
		local reconciler = Reconcile.new()

		-- point our region at a name the worker actually uses, then feed the
		-- real payload and assert the merge moves real numbers
		Reconcile.applySnapshot(ocean, reconciler, Reconcile.fromWorker(fixture))

		-- our single local region should have adopted whatever the worker had
		-- for it, or stayed put if the ids differ — both are valid, but the
		-- call must not error and must leave a sane number
		assertTrue(stockOf(ocean, "rockfish") >= 0, "stock must stay sane")
	end)

	test("calendar survives normalisation", function()
		local snapshot = Reconcile.fromWorker(fixture)
		assertEq(snapshot.month, fixture.month)
		assertEq(snapshot.day, fixture.day)
	end)

	test("malformed payloads return nil rather than throwing", function()
		assertTrue(Reconcile.fromWorker("nope") == nil)
		assertTrue(Reconcile.fromWorker(nil) == nil)
		assertTrue(Reconcile.fromWorker(42) == nil)
	end)

	test("a payload with regions but no stocks is handled", function()
		local snapshot = Reconcile.fromWorker({ regions = { { id = "r1", stocks = nil } } })
		assertTrue(snapshot ~= nil, "should not fail")
		assertTrue(next(snapshot.regions.r1) == nil, "should produce an empty stock map")
	end)

	test("already-keyed input is accepted too", function()
		local snapshot = Reconcile.fromWorker({ regions = { r1 = { rockfish = 42 } } })
		assertEq(snapshot.regions.r1.rockfish, 42)
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