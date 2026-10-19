--!strict
--[[
	Wallet tests — the money, and the loop that moves it.

	Run via tests/run.sh, which feeds the server and shared sources in as
	program arguments (the luau CLI has no file I/O — see tests/run-boot.sh
	for the mechanism).

	Two halves, and the split is the point:

	- src/Shared/Wallet.luau is tested directly. Money rules are the one
	  place where "exactly right" is the whole requirement: integer cents,
	  explicit rejection instead of clamping, consume-once sales, and a
	  persistence round-trip through the exact bytes a DataStore would hold.

	- The REAL server path is then driven through the fake Roblox engine in
	  tests/harness/: one cast, one catch, and a series of sells — including
	  hostile ones (a stolen catchId, a spoofed species/price/quantity, a
	  double sell). This is where "the price is always server-derived" and
	  "the stock is deducted exactly once" are proven against the code that
	  actually runs in Studio, not against a reimplementation of it.

	What is NOT covered here, on purpose: the DataStore plumbing itself. The
	harness's DataStores answer every read with nil, so the service-level
	load/save path can only be observed as "degrades to in-memory". The
	round-trip that matters — snapshot in, restore out, money intact — is
	pinned below against Wallet.snapshot/restore, the exact values
	UpdateAsync writes and GetAsync hands back.
]]

-- selene does not model the main chunk's varargs, hence the allowance below.
-- selene: allow(undefined_variable)
local programArgs = { ... }
local argCount = #programArgs
if argCount == 0 then
	error("no embedded sources — run via ./tests/run.sh, which feeds them in", 0)
end
if argCount % 2 ~= 0 then
	error("embedded sources are malformed (odd argument count) — run via ./tests/run.sh", 0)
end

local sources: { [string]: string } = {}
for i = 1, argCount, 2 do
	local path = programArgs[i]
	local contents = programArgs[i + 1]
	if type(path) ~= "string" or type(contents) ~= "string" then
		error(
			"embedded sources are malformed at pair "
				.. tostring(i)
				.. " — run via ./tests/run.sh",
			0
		)
	end
	sources[path] = contents
end

--=============================================================================
-- Tiny test framework (same shape as the other suites)
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

--- Structural equality over plain-data snapshots. Iteration order cannot
--- leak into the result: the comparison is order-independent by construction.
local function deepEq(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEq(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

--=============================================================================
-- Part 1 — the pure money rules
--=============================================================================

local Wallet = require("./../src/Shared/Wallet")
local Species = require("./../src/Shared/Species")

-- any species id that is really on the roster, for restore fixtures
local realSpeciesId = Species.list[1].id

local function fixtureCatch(yielded: number)
	return {
		speciesId = realSpeciesId,
		regionId = "r_test",
		weightKg = 4.5,
		yielded = yielded,
	}
end

suite("wallet — what counts as money", function()
	test("isCents accepts exact non-negative integers up to the ceiling", function()
		assertTrue(Wallet.isCents(0))
		assertTrue(Wallet.isCents(1))
		assertTrue(Wallet.isCents(123456789))
		assertTrue(Wallet.isCents(Wallet.MAX_BALANCE_CENTS))
	end)

	test("isCents rejects fractions, negatives, non-numbers, NaN and infinity", function()
		assertFalse(Wallet.isCents(0.5))
		assertFalse(Wallet.isCents(1.5))
		assertFalse(Wallet.isCents(-1))
		assertFalse(Wallet.isCents(-0.5))
		assertFalse(Wallet.isCents("5"))
		assertFalse(Wallet.isCents(true))
		assertFalse(Wallet.isCents(nil))
		assertFalse(Wallet.isCents(0 / 0)) -- NaN
		assertFalse(Wallet.isCents(math.huge))
		assertFalse(Wallet.isCents(-math.huge))
		assertFalse(Wallet.isCents(Wallet.MAX_BALANCE_CENTS * 10))
	end)

	test("a new wallet is broke, unstocked and starts ids at c1", function()
		local r = Wallet.new()
		assertEq(r.balanceCents, 0)
		assertEq(#r.hold, 0)
		assertEq(r.nextCatchSeq, 1)
		assertEq(Wallet.nextCatchId(r), "c1")
		assertEq(Wallet.nextCatchId(r), "c2")
	end)
end)

suite("wallet — integer arithmetic, rejection and overflow", function()
	test("credit adds exactly and repeatedly", function()
		local r = Wallet.new()
		assertTrue(select(1, Wallet.credit(r, 500)))
		assertTrue(select(1, Wallet.credit(r, 700)))
		assertEq(r.balanceCents, 1200)
	end)

	test("credit rejects zero, negatives and fractions without touching the balance", function()
		local r = Wallet.new()
		Wallet.credit(r, 250)
		local ok1 = select(1, Wallet.credit(r, 0))
		local ok2 = select(1, Wallet.credit(r, -100))
		local ok3 = select(1, Wallet.credit(r, 10.5))
		assertFalse(ok1 or ok2 or ok3)
		assertEq(r.balanceCents, 250)
	end)

	test("credit rejects overflow at the ceiling, balance unchanged", function()
		local r = Wallet.new()
		assertTrue(select(1, Wallet.credit(r, Wallet.MAX_BALANCE_CENTS)))
		local ok, err = Wallet.credit(r, 1)
		assertFalse(ok)
		assertEq(err, "balance overflow")
		assertEq(r.balanceCents, Wallet.MAX_BALANCE_CENTS)
	end)

	test("debit subtracts exactly", function()
		local r = Wallet.new()
		Wallet.credit(r, 1200)
		assertTrue(select(1, Wallet.debit(r, 200)))
		assertEq(r.balanceCents, 1000)
	end)

	test("debit of more than the balance is a rejection, never a clamp", function()
		local r = Wallet.new()
		Wallet.credit(r, 1000)
		local ok, err = Wallet.debit(r, 2000)
		assertFalse(ok)
		assertEq(err, "insufficient funds")
		assertEq(r.balanceCents, 1000)
	end)

	test("debit rejects zero, negatives and fractions without touching the balance", function()
		local r = Wallet.new()
		Wallet.credit(r, 300)
		assertFalse(select(1, Wallet.debit(r, 0)))
		assertFalse(select(1, Wallet.debit(r, -5)))
		assertFalse(select(1, Wallet.debit(r, 3.5)))
		assertEq(r.balanceCents, 300)
	end)

	test("debit of an empty wallet is refused, not negative", function()
		local r = Wallet.new()
		local ok, err = Wallet.debit(r, 1)
		assertFalse(ok)
		assertEq(err, "insufficient funds")
		assertEq(r.balanceCents, 0)
	end)
end)

suite("wallet — the one float -> int boundary", function()
	-- expected values pinned against the real interpreter, not derived here
	test("saleCents pins representative conversions", function()
		assertEq(Wallet.saleCents(220, 5), 11000)
		assertEq(Wallet.saleCents(25, 5), 1250) -- 12.5 credits exactly
		assertEq(Wallet.saleCents(24.69, 5), 1235) -- half-cent lands up in float practice
		assertEq(Wallet.saleCents(6, 3), 180)
		assertEq(Wallet.saleCents(40, 2.7), 1080)
		assertEq(Wallet.saleCents(460, 1), 4600)
	end)

	test("a sub-cent price rounds up to one cent, never to a free fish", function()
		assertEq(Wallet.saleCents(0.05, 1), 1)
	end)

	test("saleCents is deterministic for the same inputs", function()
		local first = Wallet.saleCents(123.456, 7.89)
		for _ = 1, 10 do
			assertEq(Wallet.saleCents(123.456, 7.89), first)
		end
	end)
end)

suite("wallet — the hold and the sale", function()
	test("recordCatch holds fish in landing order with server-minted ids", function()
		local r = Wallet.new()
		local a = Wallet.recordCatch(r, fixtureCatch(5))
		local b = Wallet.recordCatch(r, fixtureCatch(3))
		assertEq(a.catchId, "c1")
		assertEq(b.catchId, "c2")
		assertEq(#r.hold, 2)
		assertEq(r.hold[1].catchId, "c1")
		assertEq(r.hold[2].catchId, "c2")
		assertEq(r.hold[1].yielded, 5)
	end)

	test("recordCatch refuses a catch with no positive finite biomass", function()
		-- harvest can answer ok with yielded == 0 (a species with no capacity
		-- at the region); a zero-yield fish could never be sold and must not
		-- enter the hold. NaN and infinity are refused for the same reason.
		local r = Wallet.new()
		assertEq(Wallet.recordCatch(r, fixtureCatch(0)), nil)
		assertEq(Wallet.recordCatch(r, fixtureCatch(-2)), nil)
		assertEq(Wallet.recordCatch(r, fixtureCatch(0 / 0)), nil)
		assertEq(Wallet.recordCatch(r, fixtureCatch(math.huge)), nil)
		assertEq(Wallet.recordCatch(r, fixtureCatch("many")) :: any, nil :: any)
		assertEq(#r.hold, 0, "a worthless catch entered the hold")
		assertEq(r.nextCatchSeq, 1, "a refused catch still minted an id")
	end)

	test("sell pays, empties the hold and reports the outcome", function()
		local r = Wallet.new()
		Wallet.recordCatch(r, fixtureCatch(5))
		local outcome, err = Wallet.sell(r, "c1", 11000)
		assertTrue(outcome ~= nil, "sell failed: " .. tostring(err))
		assertEq(outcome.catchId, "c1")
		assertEq(outcome.speciesId, realSpeciesId)
		assertEq(outcome.paidCents, 11000)
		assertEq(outcome.balanceCents, 11000)
		assertEq(#r.hold, 0)
		assertEq(r.balanceCents, 11000)
	end)

	test("a fish cannot be sold twice — idempotency by consumption", function()
		local r = Wallet.new()
		Wallet.recordCatch(r, fixtureCatch(5))
		Wallet.sell(r, "c1", 11000)
		local again, err = Wallet.sell(r, "c1", 11000)
		assertTrue(again == nil)
		assertEq(err, "no such catch")
		assertEq(r.balanceCents, 11000)
		assertEq(#r.hold, 0)
	end)

	test("unknown, empty and never-minted catch ids are refused", function()
		local r = Wallet.new()
		local o1, e1 = Wallet.sell(r, "c99", 100)
		local o2, e2 = Wallet.sell(r, "", 100)
		assertTrue(o1 == nil and o2 == nil)
		assertEq(e1, "no such catch")
		assertEq(e2, "no such catch")
	end)

	test("a non-positive or fractional price is refused and the fish STAYS HELD", function()
		local r = Wallet.new()
		Wallet.recordCatch(r, fixtureCatch(5))
		for _, bad in { 0, -100, 10.5 } do
			local outcome, err = Wallet.sell(r, "c1", bad)
			assertTrue(outcome == nil)
			assertEq(err, "bad price")
		end
		assertEq(#r.hold, 1, "a refused sale must not consume the catch")
		assertEq(r.balanceCents, 0)
	end)

	test("a sale that would overflow the bank is refused and the fish STAYS HELD", function()
		local r = Wallet.new()
		Wallet.credit(r, Wallet.MAX_BALANCE_CENTS)
		Wallet.recordCatch(r, fixtureCatch(5))
		local outcome, err = Wallet.sell(r, "c1", 11000)
		assertTrue(outcome == nil)
		assertEq(err, "balance overflow")
		assertEq(#r.hold, 1)
		assertEq(r.balanceCents, Wallet.MAX_BALANCE_CENTS)
	end)

	test("selling one of two fish leaves the other untouched", function()
		local r = Wallet.new()
		Wallet.recordCatch(r, fixtureCatch(5))
		Wallet.recordCatch(r, fixtureCatch(3))
		Wallet.sell(r, "c1", 11000)
		assertEq(#r.hold, 1)
		assertEq(r.hold[1].catchId, "c2")
		assertEq(r.hold[1].yielded, 3)
	end)
end)

suite("wallet — persistence round-trip (the bytes a DataStore holds)", function()
	test("snapshot -> restore -> snapshot is a fixed point", function()
		local r = Wallet.new()
		Wallet.credit(r, 123456)
		Wallet.recordCatch(r, fixtureCatch(5))
		Wallet.recordCatch(r, fixtureCatch(3))
		local snap1 = Wallet.snapshot(r)
		local r2 = Wallet.restore(snap1)
		local snap2 = Wallet.snapshot(r2)
		assertTrue(deepEq(snap1, snap2), "round-trip changed the snapshot")
		assertEq(r2.balanceCents, 123456)
		assertEq(#r2.hold, 2)
	end)

	test("restore repairs a fractional balance toward zero, never up", function()
		assertEq(
			Wallet.restore({ balanceCents = 12.7, hold = {}, nextCatchSeq = 1 }).balanceCents,
			12
		)
		assertEq(
			Wallet.restore({ balanceCents = -50, hold = {}, nextCatchSeq = 1 }).balanceCents,
			0
		)
		assertEq(
			Wallet.restore({
				balanceCents = Wallet.MAX_BALANCE_CENTS * 4,
				hold = {},
				nextCatchSeq = 1,
			}).balanceCents,
			Wallet.MAX_BALANCE_CENTS
		)
		assertEq(
			Wallet.restore({ balanceCents = "rich", hold = {}, nextCatchSeq = 1 }).balanceCents,
			0
		)
	end)

	test("restore degrades junk of any shape to a fresh wallet", function()
		assertEq(Wallet.restore(nil).balanceCents, 0)
		assertEq(Wallet.restore("nope").balanceCents, 0)
		assertEq(Wallet.restore(42).balanceCents, 0)
		assertEq(#Wallet.restore({ balanceCents = 100 }).hold, 0)
	end)

	test("restore drops hold entries it cannot price or identify", function()
		local restored = Wallet.restore({
			balanceCents = 100,
			nextCatchSeq = 5,
			hold = {
				{
					catchId = "c1",
					speciesId = realSpeciesId,
					regionId = "r",
					weightKg = 1,
					yielded = 2,
				},
				{
					catchId = "c2",
					speciesId = "not_a_species",
					regionId = "r",
					weightKg = 1,
					yielded = 2,
				},
				{ speciesId = realSpeciesId, regionId = "r", weightKg = 1, yielded = 2 }, -- no id
				"c3", -- not a table
			},
		})
		assertEq(#restored.hold, 1)
		assertEq(restored.hold[1].catchId, "c1")
	end)

	test("restore keeps only the FIRST of duplicated catch ids", function()
		local restored = Wallet.restore({
			balanceCents = 0,
			nextCatchSeq = 9,
			hold = {
				{ catchId = "c1", speciesId = realSpeciesId, weightKg = 1, yielded = 2 },
				{ catchId = "c1", speciesId = realSpeciesId, weightKg = 2, yielded = 9 },
			},
		})
		assertEq(#restored.hold, 1)
		assertEq(restored.hold[1].yielded, 2)
	end)

	test("restore raises the id sequence past any id still held — no resurrection", function()
		local restored = Wallet.restore({
			balanceCents = 0,
			nextCatchSeq = 1, -- tampered/rolled-back sequence
			hold = {
				{ catchId = "c5", speciesId = realSpeciesId, weightKg = 1, yielded = 2 },
			},
		})
		assertEq(
			Wallet.nextCatchId(restored),
			"c6",
			"must not re-mint c5's neighbour over the held id"
		)
	end)

	test("identical play produces byte-identical snapshots", function()
		local function play(): any
			local r = Wallet.new()
			local a = Wallet.recordCatch(r, fixtureCatch(5))
			Wallet.sell(r, a.catchId, Wallet.saleCents(220, 5))
			Wallet.recordCatch(r, fixtureCatch(3))
			return Wallet.snapshot(r)
		end
		assertTrue(deepEq(play(), play()))
	end)
end)

suite("wallet — the wire payload", function()
	test("syncPayload carries identity and weight, never biomass to price with", function()
		local r = Wallet.new()
		Wallet.recordCatch(r, fixtureCatch(5))
		local payload = Wallet.syncPayload(r)
		assertEq(payload.balanceCents, 0)
		assertEq(#payload.hold, 1)
		local entry = payload.hold[1]
		assertEq(type(entry.catchId), "string")
		assertEq(entry.speciesId, realSpeciesId)
		assertEq(entry.weightKg, 4.5)
		assertEq(entry.yielded, nil, "yielded must not cross the wire (house rule 2)")
	end)
end)

--=============================================================================
-- Part 2 — the real server path, under the fake Roblox engine
--=============================================================================

local Roblox = require("./harness/Roblox")
local Runner = require("./harness/Runner")

local roblox = Roblox.new()
local runner = Runner.new(sources, roblox)

local CastService = runner:load("src/Server/CastService.luau")
CastService.start()

local OceanService = runner:load("src/Server/OceanService.luau")
local WalletService = runner:load("src/Server/Wallet.luau")
local OceanSim = runner:load("src/Shared/Ocean/OceanSim.luau")

local svc = OceanService.get()
local wallets = WalletService.get()
local ocean: any = if svc then svc.ocean else nil

local function walletRemote(name: string): any
	local folder = roblox.services.ReplicatedStorage:FindFirstChild("Remotes")
	return folder:FindFirstChild(name)
end

local sellRemote = walletRemote("SellRequest")
local walletSyncRemote = walletRemote("WalletSync")

-- the service rate-limits sells per player (0.25 s); tests that fire twice
-- for one player space their shots out with a busy wait, since the CLI has
-- no sleep
local function spin(seconds: number)
	local t0 = os.clock()
	-- selene: allow(empty_loop)
	while os.clock() - t0 < seconds do
	end
end

local function resultsFor(remote: any, player: any): { any }
	local out = {}
	for _, sent in remote.sentToPlayers do
		if sent.player == player then
			table.insert(out, sent.args[1])
		end
	end
	return out
end

local function lastResult(remote: any, player: any): any
	local all = resultsFor(remote, player)
	return all[#all]
end

suite("server wallet — boot and join", function()
	test("the wallet service started alongside the cast service", function()
		assertTrue(wallets ~= nil, "WalletService.get() is nil — CastService never started it")
	end)

	test("the wallet remotes exist in ReplicatedStorage", function()
		assertTrue(sellRemote ~= nil, "SellRequest was never created")
		assertTrue(walletRemote("SellResult") ~= nil, "SellResult was never created")
		assertTrue(walletSyncRemote ~= nil, "WalletSync was never created")
	end)

	test("a joining player gets an authoritative empty wallet", function()
		local player = roblox.makePlayer(101, "skipper_a")
		player.Parent = roblox.services.Players
		roblox.services.Players.PlayerAdded:Fire(player)
		runner:flushTasks()

		local sync = lastResult(walletSyncRemote, player)
		assertTrue(sync ~= nil, "no WalletSync ever fired for the joining player")
		assertEq(sync.balanceCents, 0)
		assertEq(#sync.hold, 0)
	end)
end)

do
	-- the shared fixture: deepest region, a species that actually lives there
	local deepestRegionId: string? = nil
	local deepestDepth = -1
	for _, regionId in (ocean :: any).order do
		local region = OceanSim.getRegion(ocean, regionId)
		if region and region.depth > deepestDepth then
			deepestRegionId, deepestDepth = regionId, region.depth
		end
	end
	local castSpeciesId: string? = nil
	for _, species in Species.list do
		if
			deepestRegionId ~= nil
			and species.minDepth <= deepestDepth
			and deepestDepth <= species.maxDepth
			and OceanSim.abundance(ocean, deepestRegionId, species.id) > 0.05
		then
			castSpeciesId = species.id
			break
		end
	end

	local playerA = roblox.makePlayer(201, "skipper_a_casts")
	local playerB = roblox.makePlayer(202, "skipper_b_thief")
	playerA.Parent = roblox.services.Players
	playerB.Parent = roblox.services.Players
	roblox.services.Players.PlayerAdded:Fire(playerA)
	roblox.services.Players.PlayerAdded:Fire(playerB)
	runner:flushTasks()

	local castResultRemote = if svc then svc.remotes["CastResult"] else nil
	local castRequestRemote = if svc then svc.remotes["CastRequest"] else nil

	local stockBefore: number? = nil
	local stockAfterCast: number? = nil
	local catchId: string? = nil
	local valueCents: number? = nil

	suite("server wallet — one cast, one held catch", function()
		test("a cast without a performance field resolves instead of throwing", function()
			assertTrue(
				deepestRegionId ~= nil and castSpeciesId ~= nil,
				"fixture problem, not a game bug"
			)
			stockBefore =
				OceanSim.getStock(ocean, deepestRegionId :: string, castSpeciesId :: string)

			castRequestRemote.OnServerEvent:Fire(playerA, {
				regionId = deepestRegionId,
				speciesId = castSpeciesId,
				effort = 0,
				-- performance deliberately absent: the contract says it is
				-- optional, and the handler used to crash on exactly this
			})
			runner:flushTasks()

			local results = resultsFor(castResultRemote, playerA)
			assertEq(#results, 1, "a cast must produce exactly one CastResult")
			local payload = results[1]
			assertTrue(payload.ok == true, "cast failed: " .. tostring(payload.reason))
			assertTrue(type(payload.catchId) == "string", "no catchId on a successful cast")
			assertTrue(
				type(payload.valueCents) == "number" and payload.valueCents > 0,
				"no cents quote"
			)
			catchId = payload.catchId
			valueCents = payload.valueCents
		end)

		test("the fish is held: WalletSync carries it, priced field-free", function()
			local sync = lastResult(walletSyncRemote, playerA)
			assertTrue(sync ~= nil)
			assertEq(#sync.hold, 1)
			assertEq(sync.hold[1].catchId, catchId)
			assertEq(sync.hold[1].speciesId, castSpeciesId)
			assertEq(sync.hold[1].yielded, nil, "yielded must not cross the wire")
			assertEq(sync.balanceCents, 0)
		end)

		test("the stock was deducted exactly once — at harvest, already", function()
			stockAfterCast =
				OceanSim.getStock(ocean, deepestRegionId :: string, castSpeciesId :: string)
			assertTrue(
				(stockAfterCast :: number) < (stockBefore :: number),
				"harvest did not deduct the stock"
			)
		end)
	end)

	suite("server wallet — the sell wire, hostile inputs included", function()
		test("another player's catchId cannot be sold", function()
			sellRemote.OnServerEvent:Fire(playerB, { catchId = catchId })
			runner:flushTasks()
			local result = lastResult(walletRemote("SellResult"), playerB)
			assertTrue(result ~= nil, "no SellResult answered the theft attempt")
			assertFalse(result.ok, "selling someone else's fish succeeded")
			assertEq(result.reason, "no such catch")
			assertEq(result.paidCents, 0)
		end)

		test("a spoofed species, price and quantity in the payload are ignored", function()
			spin(0.3) -- the per-player sell cooldown
			sellRemote.OnServerEvent:Fire(playerA, {
				catchId = catchId,
				speciesId = "whatever_pays_most",
				price = 1e12,
				quantity = 999,
				paidCents = 1e12,
			})
			runner:flushTasks()
			local result = lastResult(walletRemote("SellResult"), playerA)
			assertTrue(result ~= nil, "no SellResult answered the sale")
			assertTrue(result.ok, "the honest part of the sale failed: " .. tostring(result.reason))
			assertEq(
				result.speciesId,
				castSpeciesId,
				"the payload's species claim leaked into the sale"
			)
			assertEq(
				result.paidCents,
				valueCents,
				"paid price must be the market-derived quote, not the payload's number"
			)
			assertEq(result.balanceCents, valueCents)
		end)

		test("the sale left the ocean untouched — deducted exactly once, at cast", function()
			assertEq(
				OceanSim.getStock(ocean, deepestRegionId :: string, castSpeciesId :: string),
				stockAfterCast,
				"selling double-counted the fish against the stock"
			)
		end)

		test("the hold is empty and the balance is the paid amount", function()
			local sync = lastResult(walletSyncRemote, playerA)
			assertEq(#sync.hold, 0)
			assertEq(sync.balanceCents, valueCents)
		end)

		test("the same catch cannot be sold again through the wire", function()
			spin(0.3)
			sellRemote.OnServerEvent:Fire(playerA, { catchId = catchId })
			runner:flushTasks()
			local result = lastResult(walletRemote("SellResult"), playerA)
			assertFalse(result.ok, "a sold fish sold twice")
			assertEq(result.reason, "no such catch")
			assertEq(result.balanceCents, valueCents, "a refused re-sale changed the balance")
		end)

		test("malformed sell requests are answered, not crashed", function()
			spin(0.3)
			sellRemote.OnServerEvent:Fire(playerA, "not a table")
			runner:flushTasks()
			local result = lastResult(walletRemote("SellResult"), playerA)
			assertFalse(result.ok)
			assertEq(result.reason, "malformed request")

			spin(0.3)
			sellRemote.OnServerEvent:Fire(playerA, { catchId = 5 })
			runner:flushTasks()
			result = lastResult(walletRemote("SellResult"), playerA)
			assertFalse(result.ok)
			assertEq(result.reason, "malformed request")

			local sync = lastResult(walletSyncRemote, playerA)
			assertEq(sync.balanceCents, valueCents, "malformed requests changed the balance")
		end)
	end)

	-- ==================================================================
	-- Buying gear
	--
	-- This is the purchase that used to not exist. Progression.buy validated
	-- level and funds and granted ownership, and nothing called it: there was
	-- no buyer, no deduction, and no way to spend money on anything. The whole
	-- economy was sell-only.
	--
	-- The transaction spans two stores — gear in the profile, money in the
	-- wallet — so these tests watch BOTH sides of it. A handler that granted
	-- the gear and forgot the money would pass any test that only looked at
	-- ownedGear, which is exactly the bug the missing owner invited.
	-- ==================================================================

	local ProfileService = runner:load("src/Server/ProfileService.luau")
	local Progression = runner:load("src/Shared/Progression.luau")
	local Types = runner:load("src/Shared/Types.luau")

	local gearRemote = walletRemote("GearRequest")
	local profileSyncRemote = walletRemote("ProfileSync")

	-- The rod: the cheapest thing that is actually purchasable, so a purchase
	-- test does not depend on the market paying out a large enough fish.
	local ROD = Types.Gear["rod"]
	local GEAR_COOLDOWN = 0.5

	local buyer: any = nil
	local profiles: any = nil

	suite("server gear — buying spends money and grants gear", function()
		test("the gear remotes exist", function()
			assertTrue(gearRemote ~= nil, "GearRequest was never created")
			assertTrue(profileSyncRemote ~= nil, "ProfileSync was never created")
		end)

		test("set up a skipper who can afford and qualify for the rod", function()
			buyer = roblox.makePlayer(777, "skipper_buys")
			buyer.Parent = roblox.services.Players
			roblox.services.Players.PlayerAdded:Fire(buyer)
			runner:flushTasks()

			profiles = ProfileService.get()
			assertTrue(profiles ~= nil, "ProfileService never started")
			local profile = profiles.profiles[buyer]
			assertTrue(profile ~= nil, "the buyer got no profile")

			-- Level and purse are set directly, on the server's own objects.
			-- They are inputs to the transaction under test, not part of it:
			-- earning them through casts would make this suite a second test
			-- of the economy, and the economy already has one.
			profile.xp = Progression.totalXpForLevel(ROD.unlockLevel)

			local record = WalletService.recordFor(wallets, buyer)
			record.balanceCents = ROD.price
			wallets.dirty[buyer] = true

			assertEq(Progression.levelOf(profile), ROD.unlockLevel, "level fixture is wrong")
			assertFalse(Progression.owns(profile, ROD.id), "the buyer already owns the rod")
		end)

		test("buying takes the price and hands over the gear", function()
			gearRemote.OnServerEvent:Fire(buyer, { gearId = ROD.id })
			runner:flushTasks()

			local profile = profiles.profiles[buyer]
			local record = WalletService.recordFor(wallets, buyer)

			assertTrue(
				Progression.owns(profile, ROD.id),
				"the rod was not granted — the request reached nothing"
			)
			assertEq(
				record.balanceCents,
				0,
				"the gear was free: the wallet still holds the price"
			)
			assertTrue(
				profiles.dirty[buyer] == true,
				"the profile was not marked for save — a restart would lose the purchase"
			)
		end)

		test("the purchase is not also an equip", function()
			local profile = profiles.profiles[buyer]
			assertEq(
				profile.currentGearId,
				Progression.STARTER_GEAR.id,
				"buying silently equipped the rod; that is the player's next decision, not ours"
			)
		end)

		test("the next ProfileSync reports the gear and the emptied purse", function()
			local sync = lastResult(profileSyncRemote, buyer)
			assertTrue(sync ~= nil, "no ProfileSync answered the purchase")
			local sawRod = false
			for _, id in sync.ownedGear do
				if id == ROD.id then
					sawRod = true
				end
			end
			assertTrue(sawRod, "ProfileSync did not carry the new gear to the client")
			assertEq(sync.equipError, nil, "a successful purchase reported a refusal")
			assertEq(
				sync.balanceCents,
				0,
				"ProfileSync did not carry the balance the gear sheet prices against"
			)
		end)

		test("an unaffordable gear is refused and costs nothing", function()
			spin(GEAR_COOLDOWN)
			-- Qualified first, then short of money. Order matters: the same gear
			-- at a lower level refuses as "locked" below, and a test that only
			-- checked "some refusal arrived" would pass against either.
			local drake = Types.Gear["longline"]
			local profile = profiles.profiles[buyer]
			profile.xp = Progression.totalXpForLevel(drake.unlockLevel)

			local record = WalletService.recordFor(wallets, buyer)
			local before = record.balanceCents
			assertEq(before, 0, "fixture: the purse should be empty")
			assertEq(
				Progression.levelOf(profile),
				drake.unlockLevel,
				"fixture: the profile should now qualify for the rig"
			)

			gearRemote.OnServerEvent:Fire(buyer, { gearId = drake.id })
			runner:flushTasks()

			assertFalse(
				Progression.owns(profile, drake.id),
				"a longline rig was handed over with an empty purse"
			)
			assertEq(
				record.balanceCents,
				before,
				"a refused purchase moved money"
			)
			local sync = lastResult(profileSyncRemote, buyer)
			assertEq(sync.equipError, "not enough funds", "the refusal was not explained")
		end)

		test("a locked gear is refused before money is considered", function()
			spin(GEAR_COOLDOWN)
			-- Same rig, same empty purse, but back below its unlock level: the
			-- level gate must win, so the player is told to level rather than to
			-- go fishing for the money.
			local profile = profiles.profiles[buyer]
			local drake = Types.Gear["longline"]
			profile.xp = Progression.totalXpForLevel(ROD.unlockLevel)
			assertTrue(drake.unlockLevel > ROD.unlockLevel, "fixture is wrong")

			gearRemote.OnServerEvent:Fire(buyer, { gearId = drake.id })
			runner:flushTasks()

			assertFalse(Progression.owns(profile, drake.id))
			local sync = lastResult(profileSyncRemote, buyer)
			assertEq(
				sync.equipError,
				"locked",
				"a level-gated gear must say locked, not not enough funds"
			)
		end)

		test("a spoofed price in the request is ignored", function()
			spin(GEAR_COOLDOWN)
			-- Stock the purse so the buy would otherwise succeed, then claim a
			-- price of one cent. The charge must come from the catalogue.
			local record = WalletService.recordFor(wallets, buyer)
			record.balanceCents = ROD.price
			wallets.dirty[buyer] = true

			gearRemote.OnServerEvent:Fire(buyer, {
				gearId = ROD.id,
				price = 1,
			})
			runner:flushTasks()

			-- Already owned from the first purchase, so this is an equip and
			-- must move no money at all.
			assertEq(
				record.balanceCents,
				ROD.price,
				"the catalogue price was overridden by the payload"
			)
		end)

		test("an unknown gear id is refused, not created", function()
			spin(GEAR_COOLDOWN)
			local profile = profiles.profiles[buyer]
			local before = WalletService.recordFor(wallets, buyer).balanceCents

			gearRemote.OnServerEvent:Fire(buyer, { gearId = "gravitation_net" })
			runner:flushTasks()

			assertTrue(
				profile.ownedGear["gravitation_net"] == nil,
				"a gear id that is not in the catalogue was written into the profile"
			)
			assertEq(WalletService.recordFor(wallets, buyer).balanceCents, before)
			local sync = lastResult(profileSyncRemote, buyer)
			assertEq(sync.equipError, "unknown gear")
		end)

		test("a malformed gear request is answered, not crashed", function()
			spin(GEAR_COOLDOWN)
			local before = WalletService.recordFor(wallets, buyer).balanceCents

			gearRemote.OnServerEvent:Fire(buyer, "not a table")
			runner:flushTasks()
			local sync = lastResult(profileSyncRemote, buyer)
			assertEq(sync.equipError, "malformed request")

			spin(GEAR_COOLDOWN)
			gearRemote.OnServerEvent:Fire(buyer, { gearId = 5 })
			runner:flushTasks()
			sync = lastResult(profileSyncRemote, buyer)
			assertEq(sync.equipError, "malformed request")

			assertEq(
				WalletService.recordFor(wallets, buyer).balanceCents,
				before,
				"malformed gear requests moved money"
			)
		end)

		test("equipping the purchased rod still works and still costs nothing", function()
			spin(GEAR_COOLDOWN)
			local profile = profiles.profiles[buyer]
			local record = WalletService.recordFor(wallets, buyer)
			local purseBefore = record.balanceCents

			gearRemote.OnServerEvent:Fire(buyer, { gearId = ROD.id })
			runner:flushTasks()

			assertEq(profile.currentGearId, ROD.id, "the owned rod could not be equipped")
			assertEq(record.balanceCents, purseBefore, "equipping charged for the gear")
		end)

		test("the effort a cast is clamped to follows the equipped gear", function()
			-- The purchase is only worth making if the rod actually changes the
			-- game: Progression.effortFor is what CastService reads.
			local profile = profiles.profiles[buyer]
			assertEq(Progression.effortFor(profile), ROD.effort, "the rod's effort did not take")
		end)
	end)

	suite("server wallet — no background errors", function()
		test("no task or event handler errored during the whole run", function()
			local problems = {}
			for _, err in roblox.taskErrors do
				table.insert(problems, err)
			end
			for _, signal in roblox.allSignals do
				for _, err in signal.errors do
					table.insert(problems, err)
				end
			end
			if #problems > 0 then
				error(#problems .. " background error(s), first: " .. tostring(problems[1]), 0)
			end
		end)
	end)
end

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
