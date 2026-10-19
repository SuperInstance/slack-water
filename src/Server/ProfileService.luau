--!strict
--[[
	ProfileService — the skipper's career, per player.

	Owns the Progression.Profile for every player in the server: level and xp
	(through Progression's rules only — no xp maths is re-derived here), which
	gear is owned, and which is being worked. CastService asks this service for
	the equipped gear before clamping a cast, and reports landed catches back
	through awardCatch so the profile is the single write path for progression.

	Persistence is DataStoreService, and DataStores fail — throttle limits,
	Studio without API access, a backend blip. A fishing game whose server
	dies because a save threw is worse than one that forgets a level, so every
	DataStore call is pcall'd, a failure degrades to in-memory play, and no
	handler (PlayerAdded, PlayerRemoving, GearRequest, BindToClose) is allowed
	to throw. The ocean is untouched here; house rule 3 still belongs to
	OceanService.

	Replication is per player: ProfileSync fires at exactly one client, so one
	skipper's level never leaks onto anyone else's screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Progression = require(Shared.Progression)
local Remotes = require(script.Parent.Remotes)
local WalletService = require(script.Parent.Wallet)

export type Service = {
	remotes: { [string]: any },
	profiles: { [any]: any },
	dirty: { [any]: boolean },
	store: any,
	-- WalletService, joined at start(). Held so sync() can report the balance
	-- alongside the gear: the gear sheet cannot price a purchase without it,
	-- and the sheet is the only place the number is legible next to the prices.
	wallets: any,
}

local ProfileService = {}

local instance: Service? = nil

-- Seconds between autosaves of profiles that changed since the last pass.
-- PlayerRemoving saves immediately; this is the crash net between them.
local AUTOSAVE_INTERVAL = 120

-- Minimum seconds between gear requests from one player. Switching tackle is
-- not urgent, and this keeps a modified client from using the profile channel
-- as a firehose.
local GEAR_REQUEST_COOLDOWN = 0.5

local lastGearRequestAt: { [any]: number } = {}

--=============================================================================
-- Persistence
--
-- Every entry point is pcall'd. `store` is nil when DataStores are unusable
-- (Studio without API access, or the GetDataStore call itself failing), and
-- the service runs on in-memory profiles alone rather than erroring.
--=============================================================================

local function datastoreKey(player: any): string
	return "player_" .. tostring(player.UserId)
end

local function openStore(): any
	local ok, store = pcall(function()
		local DataStoreService = game:GetService("DataStoreService")
		return DataStoreService:GetDataStore("slack-water-profiles-v1")
	end)
	if not ok then
		warn("[slack-water] profiles: DataStore unavailable, playing in-memory only")
		return nil
	end
	return store
end

local function loadProfile(store: any, player: any): any
	if not store then
		return nil
	end
	local ok, data = pcall(function()
		return store:GetAsync(datastoreKey(player))
	end)
	if not ok then
		warn(
			"[slack-water] profiles: load failed for "
				.. tostring(player.UserId)
				.. "; starting fresh"
		)
		return nil
	end
	return data
end

local function saveProfile(svc: Service, player: any): boolean
	local store = svc.store
	local profile = svc.profiles[player]
	if not store or not profile then
		return false
	end

	local snapshot = Progression.snapshot(profile)
	local ok = pcall(function()
		store:UpdateAsync(datastoreKey(player), function()
			return snapshot
		end)
	end)
	if ok then
		svc.dirty[player] = false
	else
		warn(
			"[slack-water] profiles: save failed for " .. tostring(player.UserId) .. "; will retry"
		)
	end
	return ok
end

--=============================================================================
-- Replication
--
-- The whole profile as plain data, for exactly one client. Level and the
-- progress-bar numbers are computed here by Progression, never by the client
-- (house rule 2). This payload is a pending Types.luau addition:
--
--   ProfileSyncPayload = {
--     level: number, levelInto: number, levelNeeded: number,
--     fraction: number, xp: number,
--     currentGearId: string, ownedGear: { string },
--     balanceCents: number,
--     equipError: string?,
--   }
--
-- `equipError` is now the refusal channel for any gear request, buy included.
-- The client renders it and nothing else; it never decides whether a purchase
-- is affordable.
--=============================================================================

local function sync(svc: Service, player: any, equipError: string?): ()
	if not (player and player.Parent) then
		return
	end
	local profile = svc.profiles[player]
	if not profile then
		return
	end

	local progress = Progression.levelProgress(profile)
	local snapshot = Progression.snapshot(profile)
	local balanceCents = 0
	if svc.wallets then
		balanceCents = WalletService.recordFor(svc.wallets, player).balanceCents
	end
	svc.remotes[Remotes.ProfileSync]:FireClient(player, {
		level = progress.level,
		levelInto = progress.intoLevel,
		levelNeeded = progress.needed,
		fraction = progress.fraction,
		xp = profile.xp,
		currentGearId = snapshot.currentGearId,
		ownedGear = snapshot.ownedGear,
		balanceCents = balanceCents,
		equipError = equipError,
	})
end

--=============================================================================
-- Lifecycle
--=============================================================================

local function onPlayerAdded(svc: Service, player: any): ()
	-- The in-memory profile exists immediately, so a cast in the first
	-- seconds of a session resolves against a real profile instead of a
	-- DataStore race.
	svc.profiles[player] = Progression.new()
	svc.dirty[player] = false

	task.spawn(function()
		local data = loadProfile(svc.store, player)
		if data == nil or not svc.profiles[player] then
			-- no save (new skipper), load failure, or the player left during
			-- the read: the fresh profile already in place is correct
			if svc.profiles[player] then
				sync(svc, player, nil)
			end
			return
		end

		-- If the player already landed a catch while the save was reading,
		-- the live session is newer than anything on disk; keep it and let
		-- the next save reconcile, rather than overwriting earned xp.
		if svc.dirty[player] then
			warn(
				"[slack-water] profiles: save raced a catch for "
					.. tostring(player.UserId)
					.. "; keeping the session"
			)
			sync(svc, player, nil)
			return
		end

		svc.profiles[player] = Progression.restore(data)
		sync(svc, player, nil)
	end)
end

local function onPlayerRemoving(svc: Service, player: any): ()
	if svc.profiles[player] ~= nil then
		saveProfile(svc, player)
	end
	svc.profiles[player] = nil
	svc.dirty[player] = nil
	lastGearRequestAt[player] = nil
end

--=============================================================================
-- API used by CastService
--=============================================================================

--- The live profile for a player. Always returns something workable even if
--- the player is mid-leave: a throwaway starter beats a nil dereference in
--- the middle of resolving a cast.
function ProfileService.profileFor(svc: Service, player: any): any
	return svc.profiles[player] or Progression.new()
end

--- Credit a landed catch and resolve any level-ups. The CatchRecord is built
--- entirely from what the server derived for the cast; see Progression.luau
--- for the shaping rules and why effort is the clamped, pre-tide value.
--- Returns the CatchOutcome (or nil if the profile vanished mid-cast).
function ProfileService.awardCatch(svc: Service, player: any, rec: any): any
	local profile = svc.profiles[player]
	if not profile then
		return nil
	end

	local outcome = Progression.recordCatch(profile, rec)
	svc.dirty[player] = true
	sync(svc, player, nil)
	return outcome
end

--=============================================================================
-- Boot
--=============================================================================

function ProfileService.start(): Service
	if instance then
		return instance
	end

	local svc: Service = {
		remotes = Remotes.build(),
		profiles = {},
		dirty = {},
		store = openStore(),
		wallets = nil,
	}

	-- The funds owner. Gear lives in the profile and money lives in the wallet,
	-- so buying one needs both; the wallet owns the balance and is the only
	-- thing allowed to reduce it. start() is idempotent and CastService starts
	-- it too, so this is a join, not a second wallet.
	local wallets = WalletService.start()
	svc.wallets = wallets

	-- Work different owned gear, or buy the gear you do not own yet.
	--
	-- Progression owns every rule about what gear exists and whether a profile
	-- qualifies for it; the server decides what a player holds, so a request can
	-- only pick among the catalogue, and the answer — success or refusal — is
	-- the next ProfileSync. The client never predicts the outcome.
	svc.remotes[Remotes.GearRequest].OnServerEvent:Connect(function(player: any, payload: any)
		local profile = svc.profiles[player]
		if not profile then
			return
		end

		local now = os.clock()
		if now - (lastGearRequestAt[player] or 0) < GEAR_REQUEST_COOLDOWN then
			return
		end
		lastGearRequestAt[player] = now

		local gearId = if typeof(payload) == "table" and type(payload.gearId) == "string"
			then payload.gearId
			else nil
		if not gearId then
			sync(svc, player, "malformed request")
			return
		end

		if Progression.owns(profile, gearId) then
			local ok, err = Progression.equip(profile, gearId)
			if ok then
				svc.dirty[player] = true
			end
			sync(svc, player, if ok then nil else err)
			return
		end

		-- Not owned: this is a purchase.
		--
		-- Charge first, grant second. The other order hands out gear and then
		-- hopes the charge lands; here a refusal leaves the player exactly as
		-- they were, which is the failure that is safe to get wrong.
		local record = WalletService.recordFor(wallets, player)
		local allowed, refusal, price = Progression.canBuy(profile, gearId, record.balanceCents)
		if not allowed then
			sync(svc, player, refusal)
			return
		end

		local paid, payErr = WalletService.debit(wallets, player, price)
		if not paid then
			sync(svc, player, payErr)
			return
		end

		Progression.grantGear(profile, gearId)
		svc.dirty[player] = true
		-- No error line. The feedback is the row itself: it stops offering a
		-- price and starts showing effort, because the next ProfileSync is the
		-- authority and the client does not predict any of it.
		sync(svc, player, nil)
	end)

	Players.PlayerAdded:Connect(function(player: any)
		local ok, err = pcall(onPlayerAdded, svc, player)
		if not ok then
			warn("[slack-water] profiles: player join failed — " .. tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(player: any)
		local ok, err = pcall(onPlayerRemoving, svc, player)
		if not ok then
			warn("[slack-water] profiles: player leave failed — " .. tostring(err))
		end
	end)

	-- Players who joined before the service existed still get a profile.
	for _, player in Players:GetPlayers() do
		onPlayerAdded(svc, player)
	end

	-- Crash net between leaves. Keys are collected before any save runs
	-- because saving yields, and a player leaving mid-save would otherwise
	-- mutate the profile map during iteration and end this loop for good.
	task.spawn(function()
		while svc do
			task.wait(AUTOSAVE_INTERVAL)
			local pending: { any } = {}
			for player in svc.profiles do
				if svc.dirty[player] then
					table.insert(pending, player)
				end
			end
			for _, player in pending do
				if svc.profiles[player] ~= nil then
					saveProfile(svc, player)
				end
			end
		end
	end)

	-- Server shutdown: flush what is dirty. Bounded so Studio's short close
	-- window is not spent queueing saves that cannot finish.
	game:BindToClose(function()
		for player in svc.profiles do
			if svc.dirty[player] then
				task.spawn(saveProfile, svc, player)
			end
		end
		task.wait(2)
	end)

	instance = svc
	print("[slack-water] profile service started" .. if svc.store then "" else " (in-memory only)")

	return svc
end

function ProfileService.get(): Service?
	return instance
end

return ProfileService
