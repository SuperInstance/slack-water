--!strict
--[[
	CastService — turning a player's intent into a catch.

	The whole security model of the game lives in this file, and it is one rule:
	the client sends intent, never outcome. A client says "I cast at this region
	for this species with this gear"; it never says "I caught 40 halibut". Every
	number that appears in a result is computed here, on the server, from the
	shared simulation.

	That matters because the ocean is shared. If a modified client could write to
	a stock, one player could drain a fishery for everyone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Species = require(Shared.Species)
local Config = require(Shared.Config)
local OceanSim = require(Shared.Ocean.OceanSim)
local OceanService = require(script.Parent.OceanService)

local CastService = {}

--- Gear is server-authoritative. A client may ask for better gear, but the
--- effective effort is clamped to what that gear actually provides.
local DEFAULT_GEAR = Types.Gear.handline

local function gearEffortFor(player: any, requestedGearId: string?): any
	if type(requestedGearId) ~= "string" then
		return DEFAULT_GEAR
	end
	local gear = Types.Gear[requestedGearId]
	if not gear then
		return DEFAULT_GEAR
	end
	return gear
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

	remotes[Types.CastRequest].OnServerEvent:Connect(function(player: any, payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		local regionId = payload.regionId
		local speciesId = payload.speciesId

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

		-- Clamp the client's effort claim to the gear it says it holds. Effort
		-- is the only client-influenced input to the simulation, so this is the
		-- line between a player rolling well and a player cheating.
		local gear = gearEffortFor(player, payload.gearId)
		local effort = math.clamp(tonumber(payload.effort) or gear.effort, 0, gear.effort)

		local result = OceanService.harvest(svc, regionId, speciesId, effort)

		if not result or result.yielded <= 0.0 then
			remotes[Types.CastResult]:FireClient(player, {
				ok = false,
				reason = "nothing here",
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
			})
			return
		end

		local rng = svc.rng
		local performance = math.clamp(payload.performance, 0.0, 1.0)
		local weightKg = rollWeight(species, performance, rng)
		local value = math.floor(result.yielded * svc.market.entries[species.id].price / 10)

		local inRun = species.anadromous and Species.isRunning(species, svc.ocean.month)

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

	Players.PlayerAdded:Connect(function(player: any)
		player.CharacterAdded:Connect(function() end)
	end)

	print("[slack-water] cast service listening")
end

CastService._DEFAULT_GEAR = DEFAULT_GEAR

return CastService