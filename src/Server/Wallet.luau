--!strict
--[[
	WalletService — the money, per player.

	Owns the Wallet.WalletRecord for every player in the server: an integer
	balance in cents and the hold of caught-but-unsold fish. The record is
	server state, built only by CastService (via recordCatch, from numbers the
	simulation derived) and spent only here, against a price the live market
	derived. The client's entire contribution to a sale is a catchId.

	That is the anti-cheat surface, and it is small on purpose. A sale request
	cannot name a species the player never caught, cannot name a quantity, and
	cannot name a price — those fields do not exist on the wire. It can only
	point at an id the server itself minted into that player's hold, and the
	server re-prices the fish at the moment it processes the request. A stale
	price is not a case to handle; it is a case the wire cannot express.

	Ocean accounting: a fish leaves the water exactly once, at harvest —
	OceanService.harvest already deducted the stock and refreshed the market
	before CastResult was ever sent. Selling converts an already-landed catch
	into money and deliberately touches no ocean state again; double-counting
	a sold fish against stock would tax the player twice for one fish. Tests
	pin this: stock after cast == stock after sale.

	Persistence is its own DataStore (not the profile store): the profile is
	Progression's closed shape — `snapshot` whitelists xp/gear and would drop
	foreign fields — so money lives in `slack-water-wallets-v1` under the same
	"player_<UserId>" keying, with the same failure philosophy as
	ProfileService: every DataStore call pcall'd, a failure degrades to
	in-memory play, no handler allowed to throw.

	Restart semantics: a sale is ONE synchronous mutation (remove from hold +
	credit), and the snapshot persists balance and hold atomically in a
	single UpdateAsync. A crash therefore lands on one side or the other —
	never money without the fish leaving the hold, never the fish gone without
	the money. What a crash CAN do is lose the last <=120s of unsaved play
	(autosave window), exactly like xp today; the player may see "sold" and
	find the fish back in the hold after a restart. That is a lost sale, not a
	duplicated one — the direction that cannot mint money.

	Races: RemoteEvent handlers run serially on the server, and the handler
	between reading the hold and mutating it never yields, so two sells of the
	same catch resolve in order — the first consumes it, the second fails with
	"no such catch".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Wallet = require(Shared.Wallet)
local Types = require(Shared.Types)
local Market = require(Shared.Market)
local OceanService = require(script.Parent.OceanService)
local Remotes = require(script.Parent.Remotes)

export type Service = {
	remotes: { [string]: any },
	records: { [any]: any },
	dirty: { [any]: boolean },
	store: any,
	-- OceanService's service; the live market lives on it. Nil only if the
	-- ocean never started, in which case sells fail loudly instead of pricing
	-- against nothing.
	ocean: any,
}

local WalletService = {}

local instance: Service? = nil

-- Seconds between autosaves of wallets that changed since the last pass.
-- PlayerRemoving saves immediately; this is the crash net between them.
-- Matches ProfileService's window so money and xp lose the same amount of
-- play to a crash, whatever that amount is.
local AUTOSAVE_INTERVAL = 120

-- Minimum seconds between sell requests from one player. Not anti-cheat —
-- every sell is validated regardless — just a guard against a modified
-- client using the channel as a firehose. Unlike rate-limited casts (which
-- are dropped silently), a limited sell is ANSWERED with a failure result,
-- because a card with a pending sale is visibly waiting on an answer.
local SELL_COOLDOWN = 0.25

local lastSellAt: { [any]: number } = {}

--=============================================================================
-- Persistence
--
-- Every entry point is pcall'd. `store` is nil when DataStores are unusable,
-- and the service runs on in-memory wallets alone rather than erroring.
--=============================================================================

local function datastoreKey(player: any): string
	return "player_" .. tostring(player.UserId)
end

local function openStore(): any
	local ok, store = pcall(function()
		local DataStoreService = game:GetService("DataStoreService")
		return DataStoreService:GetDataStore("slack-water-wallets-v1")
	end)
	if not ok then
		warn("[slack-water] wallets: DataStore unavailable, playing in-memory only")
		return nil
	end
	return store
end

local function loadRecord(store: any, player: any): any
	if not store then
		return nil
	end
	local ok, data = pcall(function()
		return store:GetAsync(datastoreKey(player))
	end)
	if not ok then
		warn(
			"[slack-water] wallets: load failed for "
				.. tostring(player.UserId)
				.. "; starting fresh"
		)
		return nil
	end
	return data
end

local function saveRecord(svc: Service, player: any): boolean
	local store = svc.store
	local record = svc.records[player]
	if not store or not record then
		return false
	end

	local snapshot = Wallet.snapshot(record)
	local ok = pcall(function()
		store:UpdateAsync(datastoreKey(player), function()
			return snapshot
		end)
	end)
	if ok then
		svc.dirty[player] = false
	else
		warn("[slack-water] wallets: save failed for " .. tostring(player.UserId) .. "; will retry")
	end
	return ok
end

--=============================================================================
-- Replication
--
-- The whole wallet as plain data, for exactly one client. balanceCents and
-- the hold are read straight off the record by Wallet.syncPayload; nothing
-- here computes a value (house rule 2).
--=============================================================================

local function sync(svc: Service, player: any): ()
	if not (player and player.Parent) then
		return
	end
	local record = svc.records[player]
	if not record then
		return
	end
	svc.remotes[Remotes.WalletSync]:FireClient(player, Wallet.syncPayload(record))
end

--=============================================================================
-- Lifecycle
--=============================================================================

local function onPlayerAdded(svc: Service, player: any): ()
	-- The in-memory record exists immediately, so a cast in the first seconds
	-- of a session lands in a real hold instead of a DataStore race.
	svc.records[player] = Wallet.new()
	svc.dirty[player] = false

	task.spawn(function()
		local data = loadRecord(svc.store, player)
		if data == nil or not svc.records[player] then
			-- no save (new skipper), load failure, or the player left during
			-- the read: the fresh record already in place is correct
			if svc.records[player] then
				sync(svc, player)
			end
			return
		end

		-- If the player already landed a catch while the save was reading,
		-- the live session is newer than anything on disk; keep it and let
		-- the next save reconcile, rather than overwriting held fish.
		if svc.dirty[player] then
			warn(
				"[slack-water] wallets: save raced a catch for "
					.. tostring(player.UserId)
					.. "; keeping the session"
			)
			sync(svc, player)
			return
		end

		svc.records[player] = Wallet.restore(data)
		sync(svc, player)
	end)
end

local function onPlayerRemoving(svc: Service, player: any): ()
	if svc.records[player] ~= nil then
		saveRecord(svc, player)
	end
	svc.records[player] = nil
	svc.dirty[player] = nil
	lastSellAt[player] = nil
end

--=============================================================================
-- API used by CastService
--=============================================================================

--- The live wallet record for a player. Always returns something workable
--- even if the player is mid-leave: a fresh empty wallet beats a nil
--- dereference in the middle of resolving a cast.
function WalletService.recordFor(svc: Service, player: any): any
	return svc.records[player] or Wallet.new()
end

--- A fish that has just been landed enters the hold. Called by CastService
--- with numbers the cast itself derived (species, region, rolled weight,
--- OceanSim's yielded) — never anything a client sent. Returns the held
--- catch, or nil when Wallet.recordCatch refused it (no positive biomass —
--- nothing came out of the water, so nothing is held and nothing changed)
--- or the player left mid-cast.
function WalletService.recordCatch(svc: Service, player: any, info: any): any
	local record = svc.records[player]
	if not record then
		return nil
	end

	local held = Wallet.recordCatch(record, info)
	if held == nil then
		return nil
	end

	svc.dirty[player] = true
	sync(svc, player)
	return held
end

--=============================================================================
-- Selling
--=============================================================================

local function failSell(svc: Service, player: any, catchId: string, reason: string): ()
	local record = svc.records[player]
	svc.remotes[Types.SellResult]:FireClient(player, {
		ok = false,
		reason = reason,
		catchId = catchId,
		speciesId = nil,
		paidCents = 0,
		balanceCents = if record then record.balanceCents else 0,
	})
end

--=============================================================================
-- Boot
--=============================================================================

function WalletService.start(): Service
	if instance then
		return instance
	end

	local svc: Service = {
		remotes = Remotes.build(),
		records = {},
		dirty = {},
		store = openStore(),
		ocean = OceanService.start(),
	}

	svc.remotes[Types.SellRequest].OnServerEvent:Connect(function(player: any, payload: any)
		local record = svc.records[player]
		if not record then
			return
		end

		local catchId = if typeof(payload) == "table" and type(payload.catchId) == "string"
			then payload.catchId
			else ""

		local now = os.clock()
		if now - (lastSellAt[player] or 0) < SELL_COOLDOWN then
			failSell(svc, player, catchId, "too fast")
			return
		end
		lastSellAt[player] = now

		if catchId == "" then
			-- covers non-table payloads, missing fields, wrong types, and
			-- junk extras: nothing about the fish is taken on trust
			failSell(svc, player, "", "malformed request")
			return
		end

		-- Look the catch up in the server's own record BEFORE pricing, so
		-- the price is derived from what the hold says the fish is — a
		-- species/quantity/price in the payload would be ignored even if
		-- one were sent.
		local held = Wallet.findCatch(record, catchId)
		if held == nil then
			-- already sold, a stale card after a restart, another player's
			-- fish, or an invented id: same answer, no information offered
			failSell(svc, player, catchId, "no such catch")
			return
		end

		local market = if svc.ocean ~= nil then svc.ocean.market else nil
		if market == nil then
			failSell(svc, player, catchId, "the market is not running")
			return
		end

		-- The price is computed HERE, from the live market, against the
		-- yielded biomass in the server's own record. This is the only
		-- pricing call on the sell path.
		local paidCents = Wallet.saleCents(Market.priceOf(market, held.speciesId), held.yielded)

		local outcome, err = Wallet.sell(record, catchId, paidCents)
		if outcome == nil then
			failSell(svc, player, catchId, err or "sale refused")
			return
		end

		svc.dirty[player] = true
		svc.remotes[Types.SellResult]:FireClient(player, {
			ok = true,
			reason = nil,
			catchId = outcome.catchId,
			speciesId = outcome.speciesId,
			paidCents = outcome.paidCents,
			balanceCents = outcome.balanceCents,
		})
		sync(svc, player)
	end)

	Players.PlayerAdded:Connect(function(player: any)
		local ok, err = pcall(onPlayerAdded, svc, player)
		if not ok then
			warn("[slack-water] wallets: player join failed — " .. tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(player: any)
		local ok, err = pcall(onPlayerRemoving, svc, player)
		if not ok then
			warn("[slack-water] wallets: player leave failed — " .. tostring(err))
		end
	end)

	-- Players who joined before the service existed still get a wallet.
	for _, player in Players:GetPlayers() do
		onPlayerAdded(svc, player)
	end

	-- Crash net between leaves; keys are collected before any save runs
	-- because saving yields (see ProfileService for the same reasoning).
	task.spawn(function()
		while svc do
			task.wait(AUTOSAVE_INTERVAL)
			local pending: { any } = {}
			for player in svc.records do
				if svc.dirty[player] then
					table.insert(pending, player)
				end
			end
			for _, player in pending do
				if svc.records[player] ~= nil then
					saveRecord(svc, player)
				end
			end
		end
	end)

	-- Server shutdown: flush what is dirty, bounded like ProfileService's.
	game:BindToClose(function()
		for player in svc.records do
			if svc.dirty[player] then
				task.spawn(saveRecord, svc, player)
			end
		end
		task.wait(2)
	end)

	instance = svc
	print("[slack-water] wallet service started" .. if svc.store then "" else " (in-memory only)")

	return svc
end

function WalletService.get(): Service?
	return instance
end

return WalletService
