--!strict
--[[
	CastService — turning a player's intent into a catch.

	The whole security model of the game lives in this file, and it is one rule:
	the client sends intent, never outcome. A client says "I cast at this region
	for this species"; it never says "I caught 40 halibut", and it never says
	what gear it holds — the profile does. Every number that appears in a
	result is computed here, on the server, from the shared simulation.

	That matters because the ocean is shared. If a modified client could write to
	a stock, one player could drain a fishery for everyone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Species = require(Shared.Species)
local OceanSim = require(Shared.Ocean.OceanSim)
local Config = require(Shared.Config)
local Progression = require(Shared.Progression)
local OceanService = require(script.Parent.OceanService)
local ProfileService = require(script.Parent.ProfileService)

local CastService = {}

--- Per-player rate limiting.
---
--- This is not an anti-cheat measure, it is a conservation measure. The ocean
--- is shared, so a client that could cast in a tight loop would drain a
--- fishery that everyone else is fishing. The limit is deliberately generous —
--- a cast involves a real minigame, so nobody can reach it by playing normally.
local lastCastAt: { [any]: number } = {}

local function isRateLimited(player: any): boolean
	local now = os.clock()
	local last = lastCastAt[player] or 0
	if now - last < Config.CAST_COOLDOWN then
		return true
	end
	lastCastAt[player] = now
	return false
end

--- Roll a plausible body weight for the catch.
---
--- Weight is not derived from biomass — biomass is an abstract economy unit.
--- It is rolled from the species' real weight range, biased by how well the
--- player did against the difficulty, so a fight that went well is visibly a
--- bigger fish.
local function rollWeight(species: any, performance: number, rng: any): number
	local t = rng.nextFloat and rng.nextFloat(rng) or 0.5
	-- performance in [0,1] shifts the roll toward the heavy end
	local biased = math.clamp(t * 0.65 + performance * 0.35, 0.0, 1.0)
	local min = species.weightRange.min
	local max = species.weightRange.max
	-- square the roll so small fish are genuinely more common than big ones
	return min + (max - min) * (biased * biased)
end

--- A catch is "rare" when it came off a healthy ground with a good fight. This
--- is a small, frequent reward — not a lottery, or it stops feeling good.
local function rollRare(species: any, abundance: number, performance: number, rng: any): boolean
	local chance = 0.04 + abundance * 0.06 + performance * 0.10
	if rng.nextFloat and rng.nextFloat(rng) < chance * (1.0 - species.rarity * 0.5) then
		return true
	end
	return false
end

function CastService.start(): ()
	local svc = OceanService.start()
	local remotes = svc.remotes
	local profiles = ProfileService.start()

	remotes[Types.CastRequest].OnServerEvent:Connect(function(player: any, payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		local regionId = payload.regionId
		local speciesId = payload.speciesId

		if isRateLimited(player) then
			return
		end

		-- Structural validation first. Anything malformed gets a tidy failure
		-- rather than a thrown error inside a RemoteEvent handler, which would
		-- kill the connection with no explanation.
		if type(regionId) ~= "string" or type(speciesId) ~= "string" then
			remotes[Types.CastResult]:FireClient(player, {
				ok = false,
				reason = "malformed request",
				speciesId = tostring(speciesId),
				regionId = tostring(regionId),
				yielded = 0,
				remaining = 0,
				abundanceBefore = 0,
				abundanceAfter = 0,
				depleted = false,
				contested = false,
				weightKg = 0,
				value = 0,
				rare = false,
				inRun = false,
			})
			return
		end

		local species = Species.get(speciesId)
		local region = OceanSim.getRegion(svc.ocean, regionId)

		if not species then
			remotes[Types.CastResult]:FireClient(player, {
				ok = false,
				reason = "unknown species",
				speciesId = speciesId,
				regionId = regionId,
				yielded = 0,
				remaining = 0,
				abundanceBefore = 0,
				abundanceAfter = 0,
				depleted = false,
				contested = false,
				weightKg = 0,
				value = 0,
				rare = false,
				inRun = false,
			})
			return
		end

		if not region then
			remotes[Types.CastResult]:FireClient(player, {
				ok = false,
				reason = "unknown region",
				speciesId = speciesId,
				regionId = regionId,
				yielded = 0,
				remaining = 0,
				abundanceBefore = 0,
				abundanceAfter = 0,
				depleted = false,
				contested = false,
				weightKg = 0,
				value = 0,
				rare = false,
				inRun = false,
			})
			return
		end

		-- Clamp the client's effort claim to the gear in the player's profile.
		-- Effort is the only client-influenced input to the simulation, so
		-- this is the line between a player rolling well and a player
		-- cheating. The gear comes from ProfileService — the server's own
		-- record of what this skipper holds — and any gear claim inside the
		-- cast payload itself is ignored: changing gear is a separate request
		-- the server validates against ownership.
		--
		-- A non-positive or missing claim falls back to the gear's own rating
		-- rather than being taken as a literal zero. The client deliberately
		-- sends effort = 0 — it has no idea what a good cast is worth — so
		-- trusting that number would mean nothing is ever caught.
		local profile = ProfileService.profileFor(profiles, player)
		local gear = Progression.equippedGear(profile)
		local claimed = tonumber(payload.effort) or 0
		local effort = if claimed > 0 then math.clamp(claimed, 0, gear.effort) else gear.effort

		local result = OceanService.harvest(svc, regionId, speciesId, effort)

		if not result then
			-- No result from the service means the tide has this ground under
			-- water — or dry. That is not "nothing here", it is "not now", and
			-- the player deserves to know when to come back. Telling them the
			-- time of the next high water turns a dead end into an appointment.
			local tide = OceanService.tideState(svc)
			local nextHighIn = math.max(0, math.floor(tide.nextHighTime - tide.hour))
			remotes[Types.CastResult]:FireClient(player, {
				ok = false,
				reason = ("The tide has this ground under you. High water in about %dh."):format(
					nextHighIn
				),
				speciesId = speciesId,
				regionId = regionId,
				yielded = 0,
				remaining = OceanSim.getStock(svc.ocean, regionId, speciesId),
				abundanceBefore = 0,
				abundanceAfter = OceanSim.abundance(svc.ocean, regionId, speciesId),
				depleted = true,
				contested = false,
				weightKg = 0,
				value = 0,
				rare = false,
				inRun = false,
				tideQuality = 0,
			})
			return
		end

		local rng = svc.rng
		local performance = math.clamp(payload.performance, 0.0, 1.0)
		local weightKg = rollWeight(species, performance, rng)
		local value = math.floor(result.yielded * svc.market.entries[species.id].price / 10)

		local inRun = species.anadromous and Species.isRunning(species, svc.ocean.month)

		-- Credit the career. Every field of the record is what this server
		-- derived for the cast: the biomass OceanSim landed, the effort the
		-- gear actually made available (the clamped value — Progression shapes
		-- the tide in itself, via tideQuality, so the tide is not counted
		-- twice), and the ground's abundance BEFORE the cast. Progression owns
		-- every rule about what that is worth; nothing here may flatten it.
		local outcome = ProfileService.awardCatch(profiles, player, {
			speciesId = species.id,
			yielded = result.yielded,
			effortUsed = effort,
			abundanceBefore = result.abundanceBefore,
			tideQuality = result.tideQuality,
		})

		local unlockedIds: { string } = {}
		if outcome then
			for _, unlocked in outcome.unlockedGear do
				table.insert(unlockedIds, unlocked.id)
			end
		end

		remotes[Types.CastResult]:FireClient(player, {
			ok = true,
			speciesId = speciesId,
			regionId = regionId,
			yielded = result.yielded,
			remaining = result.remaining,
			abundanceBefore = result.abundanceBefore,
			abundanceAfter = result.abundanceAfter,
			depleted = result.depleted,
			contested = result.contested,
			weightKg = weightKg,
			value = value,
			rare = rollRare(species, result.abundanceBefore, performance, rng),
			inRun = inRun,
			tideQuality = result.tideQuality or 0,
			-- career fields (pending Types.luau additions): the skipper's
			-- state after this cast, straight from Progression via the profile
			level = if outcome then outcome.level else nil,
			xpGained = if outcome then outcome.xpGained else 0.0,
			unlockedGear = unlockedIds,
			currentGearId = gear.id,
		})

		-- Tell everyone at the ground that it is being worked, so other crews
		-- find out before they spend the trip. This is the whole PvP layer: no
		-- theft minigame, just honest information and a shared consequence.
		if result.contested then
			OceanService.notify(svc, { player }, {
				kind = "contest",
				text = "Another crew is working this ground.",
				speciesId = speciesId,
				regionId = regionId,
			})
		end

		if result.depleted then
			OceanService.notify(svc, { player }, {
				kind = "scarcity",
				text = ("%s thinned out at %s."):format(species.displayName, region.name),
				speciesId = speciesId,
				regionId = regionId,
			})
		end
	end)

	Players.PlayerRemoving:Connect(function(player: any)
		lastCastAt[player] = nil
	end)

	print("[slack-water] cast service listening")
end

return CastService
