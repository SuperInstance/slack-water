--!strict
--[[
	OceanService — the authoritative owner of the ocean.

	Everything about the shared world lives here: the simulation, the market, the
	region list and the periodic broadcast to clients. Nothing else mutates
	ocean state. That single-owner rule is what lets the economy be trusted —
	if cast handling could write to stocks directly, the scarcity maths would
	drift from reality within minutes.

	The tick loop runs at a fixed, slow cadence on purpose. Fish populations
	should move over days, not frames; a fast loop would spend the same CPU
	recomputing identical numbers and would make the whole world twitch.

	The Cloudflare backend is optional. If it is configured and reachable, the
	service reconciles against it; if not, it runs entirely locally. Players
	cannot tell the difference except that they may be sharing the ocean with
	other servers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rng = require(Shared.Ocean.Rng)
local OceanSim = require(Shared.Ocean.OceanSim)
local Regions = require(Shared.Ocean.Regions)
local Market = require(Shared.Market)
local Species = require(Shared.Species)
local Config = require(Shared.Config)
local Types = require(Shared.Types)

export type Service = {
	ocean: any,
	market: any,
	rng: any,
	remotes: { [string]: any },
	seed: number,
	round: number,
	backendOnline: boolean,
}

local Service = {}

local instance: Service? = nil

-- Seconds between simulation ticks. One tick is a small slice of a day; the
-- calendar advances inside the simulation itself.
local TICK_INTERVAL = 20

-- Seconds between client broadcasts.
local SYNC_INTERVAL = 5

-- Rounds of AI composition per in-game month.
local COMPOSE_INTERVAL_ROUNDS = 2

--=============================================================================
-- Boot
--=============================================================================

local function buildRemotes(): { [string]: any }
	local folder = ReplicatedStorage:FindFirstChild(Types.REMOTE_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Types.REMOTE_FOLDER
		folder.Parent = ReplicatedStorage
	end

	local remotes: { [string]: any } = {}
	local names = {
		Types.CastRequest,
		Types.CastResult,
		Types.OceanSync,
		Types.MarketSync,
		Types.RegionDiscovered,
		Types.Notify,
	}

	for _, name in names do
		local existing = folder:FindFirstChild(name)
		if not existing then
			existing = Instance.new("RemoteEvent")
			existing.Name = name
			existing.Parent = folder
		end
		remotes[name] = existing
	end

	return remotes
end

function Service.start(): Service?
	if instance then
		return instance
	end

	local seed = 20261014 -- fixed so every server starts from the same ocean
	local rng = Rng.new(seed)
	local ocean = OceanSim.new(seed)
	local market = Market.new()

	-- Seed the starting ocean procedurally. This is the floor: a fresh server
	-- always has somewhere to fish, with or without the backend.
	local initialRegions = Regions.generate(seed, 14)
	for _, region in initialRegions do
		OceanSim.addRegion(ocean, region)
	end

	local svc: Service = {
		ocean = ocean,
		market = market,
		rng = rng,
		remotes = buildRemotes(),
		seed = seed,
		round = 0,
		backendOnline = false,
	}

	-- Refresh prices from the starting ocean so day one is coherent.
	Service.refreshMarket(svc)

	instance = svc
	Service.beginLoops(svc)

	print(string.format(
		"[slack-water] ocean started: %d regions, %d species, seed %d",
		#ocean.order,
		#Species.list,
		seed
	))

	return svc
end

function Service.get(): Service?
	return instance
end

--=============================================================================
-- Simulation loop
--=============================================================================

local function tickOcean(svc: Service): ()
	OceanSim.tick(svc.ocean, svc.rng)
	Service.refreshMarket(svc)
	Service.advanceCalendar(svc)
end

--- Every tick rolls a small chance the calendar crosses into a new month, and
--- a new month is the natural time to ask the backend for new fishing grounds.
local function advanceCalendar(svc: Service)
	if svc.ocean.day ~= 1 then
		return
	end

	if svc.ocean.month % COMPOSE_INTERVAL_ROUNDS == 1 then
		Service.composeNewBanks(svc)
	end
end

function Service.beginLoops(svc: Service): ()
	task.spawn(function()
		local elapsed = 0
		RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			if elapsed < TICK_INTERVAL then
				return
			end
			elapsed = 0
			tickOcean(svc)
		end)
	end)

	task.spawn(function()
		while svc do
			Service.broadcastOcean(svc)
			Service.broadcastMarket(svc)
			task.wait(SYNC_INTERVAL)
		end
	end)
end

--=============================================================================
-- Market
--=============================================================================

--- Recompute every price from the ocean's current global abundance.
---
--- This is the entire market: one number in per species, one number out. The
--- feedback loop closes because harvest lowers abundance, abundance raises the
--- scarcity multiplier, and the raised price is what players act on.
function Service.refreshMarket(svc: Service): ()
	local abundances: { [string]: number } = {}
	for _, species in Species.list do
		abundances[species.id] = OceanSim.globalAbundance(svc.ocean, species.id)
	end
	Market.updateAll(svc.market, abundances)
end

--=============================================================================
-- Harvesting
--=============================================================================

--- Apply a catch. This is the only path by which the ocean changes, and it is
--- always server-authoritative — the client sends intent (region, species,
--- gear), never an outcome.
function Service.harvest(svc: Service, regionId: string, speciesId: string, effort: number): any
	local result = OceanSim.harvest(svc.ocean, regionId, speciesId, effort)
	if not result then
		return nil
	end

	Service.refreshMarket(svc)
	return result
end

--=============================================================================
-- Broadcasts
--=============================================================================

function Service.broadcastOcean(svc: Service): ()
	local regions = {}

	for _, regionId in svc.ocean.order do
		local region = OceanSim.getRegion(svc.ocean, regionId)
		if region then
			local abundances: { [string]: number } = {}
			local present: { string } = {}

			for _, species in Species.list do
				local abundance = OceanSim.abundance(svc.ocean, regionId, species.id)
				if abundance > 0.05 then
					abundances[species.id] = abundance
					table.insert(present, species.id)
				end
			end

			table.insert(regions, {
				id = region.id,
				name = region.name,
				habitat = region.habitat,
				depth = region.depth,
				abundances = abundances,
				contested = {},
				species = present,
			})
		end
	end

	svc.remotes[Types.OceanSync]:FireAllClients({
		month = svc.ocean.month,
		day = svc.ocean.day,
		tick = svc.ocean.tickCount,
		regions = regions,
	})
end

function Service.broadcastMarket(svc: Service): ()
	local entries = {}

	for _, entry in Market.snapshot(svc.market) do
		local species = Species.get(entry.speciesId)
		table.insert(entries, {
			speciesId = entry.speciesId,
			displayName = species and species.displayName or entry.speciesId,
			price = entry.price,
			baseValue = entry.baseValue,
			scarcityMultiplier = entry.scarcityMultiplier,
			globalAbundance = entry.globalAbundance,
			direction = entry.direction,
		})
	end

	svc.remotes[Types.MarketSync]:FireAllClients({ entries = entries })
end

function Service.notify(svc: Service, players: { any }, payload: any): ()
	for _, player in players do
		if player and player.Parent then
			svc.remotes[Types.Notify]:FireClient(player, payload)
		end
	end
end

--=============================================================================
-- Bank composition
--=============================================================================

--- Ask the backend for new fishing grounds.
---
--- This is the AI-authored content surface. Whatever comes back is validated
--- by BankSpec before it is admitted — and if the backend is unreachable or
--- returns nothing usable, procedural generation fills the gap so the ocean
--- simply never runs out of undiscovered water.
function Service.composeNewBanks(svc: Service): ()
	svc.round += 1

	local ok, OceanClient = pcall(function()
		return require(Shared.Net.OceanClient)
	end)

	if not ok then
		Service.fillWithProceduralBanks(svc)
		return
	end

	local result = OceanClient.composeBanks(svc.round)
	if not result.ok or not result.banks or #result.banks == 0 then
		Service.fillWithProceduralBanks(svc)
		return
	end

	svc.backendOnline = true
	local admitted = 0

	for _, candidate in result.banks do
		local BankSpec = require(Shared.Ocean.BankSpec)
		local id = "ai_" .. svc.round .. "_" .. tostring(admitted + 1)
		local report = BankSpec.validate(candidate, id)

		if report.ok and report.bank then
			OceanSim.addRegion(svc.ocean, BankSpec.toRegion(report.bank))
			admitted += 1
			svc.remotes[Types.RegionDiscovered]:FireAllClients({
				id = report.bank.id,
				name = report.bank.name,
				habitat = report.bank.habitat,
				depth = report.bank.depth,
				richness = report.bank.richness,
				hazard = report.bank.hazard,
				species = {},
				origin = "composed",
			})
		end
	end

	if admitted == 0 then
		Service.fillWithProceduralBanks(svc)
	end

	print(string.format("[slack-water] composition round %d: %d/%d banks admitted", svc.round, admitted, #result.banks))
end

--- Fallback generation. Keeps the discovery treadmill running even with no
--- backend at all — the game must never be able to run dry.
function Service.fillWithProceduralBanks(svc: Service): ()
	local nextIndex = #svc.ocean.order + 1
	for i = nextIndex, nextIndex + Config.BANKS_PER_ROUND - 1 do
		local region = Regions.generateOne(svc.seed, i)
		OceanSim.addRegion(svc.ocean, region)
		svc.remotes[Types.RegionDiscovered]:FireAllClients({
			id = region.id,
			name = region.name,
			habitat = region.habitat,
			depth = region.depth,
			richness = region.richness,
			hazard = region.hazard,
			species = {},
			origin = "procedural",
		})
	end
end

Service._TICK_INTERVAL = TICK_INTERVAL
Service._SYNC_INTERVAL = SYNC_INTERVAL

return Service