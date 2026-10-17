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
local Chart = require(Shared.Ocean.Chart)
local Tide = require(Shared.Tide)
local Reconcile = require(Shared.Ocean.Reconcile)
local Market = require(Shared.Market)
local Species = require(Shared.Species)
local Config = require(Shared.Config)
local Types = require(Shared.Types)

export type Service = {
	ocean: any,
	market: any,
	chart: any,
	rng: any,
	remotes: { [string]: any },
	seed: number,
	round: number,
	hour: number,
	backendOnline: boolean,
	everSynced: boolean,
	reconciler: any,
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
	--
	-- Everything seeded this way is `grown`, not `measured` — the chart is
	-- honest about being an inference until a real sounding arrives. See
	-- src/Shared/Ocean/Chart.luau.
	local chart = Chart.new()
	local initialRegions = Regions.generate(seed, Config.INITIAL_REGIONS)
	for _, region in initialRegions do
		OceanSim.addRegion(ocean, region)
		Chart.add(chart, {
			id = region.id,
			name = region.name,
			habitat = region.habitat,
			lat = 0,
			lon = 0,
			hasPosition = false,
			chartedDepth = region.depth,
			bottomType = "sand",
			provenance = "grown",
			confidence = 0.4,
			surveyedAt = nil,
			source = "procedural seed",
		})
	end

	local svc: Service = {
		ocean = ocean,
		market = market,
		chart = chart,
		rng = rng,
		remotes = buildRemotes(),
		seed = seed,
		round = 0,
		hour = 0,
		backendOnline = false,
		everSynced = false,
		reconciler = Reconcile.new(),

		-- A BindableEvent, fired on the SERVER when a region is admitted.
		--
		-- This exists because Main.server used to learn about new grounds by
		-- connecting to `remotes.RegionDiscovered`. That can never work: a
		-- RemoteEvent's OnServerEvent fires when a CLIENT calls FireServer. The
		-- server calling FireAllClients on itself does not trigger it. So the
		-- world silently never rebuilt -- the ocean grew and the map did not.
		--
		-- Broadcasting to clients and notifying server-side code are two
		-- different jobs and need two different channels.
		regionAdded = Instance.new("BindableEvent"),
	}

	-- Refresh prices from the starting ocean so day one is coherent.
	Service.refreshMarket(svc)

	instance = svc
	Service.beginLoops(svc)

	print(
		string.format(
			"[slack-water] ocean started: %d regions, %d species, seed %d",
			#ocean.order,
			#Species.list,
			seed
		)
	)

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

	-- Advance the clock. One tick is one in-game hour, so a real tidal cycle
	-- passes over a couple of minutes of play rather than never.
	svc.hour += 1.0
	if svc.hour >= Config.HOURS_PER_DAY then
		svc.hour -= Config.HOURS_PER_DAY
		Service.advanceDay(svc)
	end

	Service.refreshMarket(svc)
	Service.advanceCalendar(svc)
end

--- The simulation's own calendar now only tracks days and months for the
--- salmon runs; the hour of day lives on the service, because the tide needs a
--- continuous clock while the runs only need to know the month.
function Service.advanceDay(svc: Service): ()
	OceanSim.advanceDay(svc.ocean, svc.rng)
end

--- Every tick rolls a small chance the calendar crosses into a new month, and
--- a new month is the natural time to ask the backend for new fishing grounds.
function Service.advanceCalendar(svc: Service)
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

	-- Pull the global ocean. Until this lands, every Roblox server is fishing
	-- its own water; once it runs, they share one.
	task.spawn(function()
		while svc do
			Service.pullGlobal(svc)
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
---
--- The tide is applied here, and this is the mechanic the whole game rests on:
--- a shoal with less water over it than the boat draws is simply not reachable,
--- and what can be reached fishes worse in a heavy current than at slack.
function Service.harvest(svc: Service, regionId: string, speciesId: string, effort: number): any
	local region = OceanSim.getRegion(svc.ocean, regionId)
	if not region then
		return nil
	end

	-- Chart depth, not a generated depth, is what the tide acts on. Falling
	-- back to the region's depth keeps seeded water playable.
	local sounding = Chart.get(svc.chart, regionId)
	local chartedDepth = if sounding then sounding.chartedDepth else region.depth

	local accessible = Tide.accessAt(chartedDepth, svc.hour)
	if not accessible then
		return nil
	end

	-- Slack water is worth real money. At dead slack a cast is worth full
	-- effort; in a heavy current the same cast pulls far less out of the water.
	local quality = Tide.fishingQuality(chartedDepth, svc.hour)
	local scaledEffort = effort * math.clamp(quality, 0.25, 1.0)

	local result = OceanSim.harvest(svc.ocean, regionId, speciesId, scaledEffort)
	if not result then
		return nil
	end

	-- Carry the tide through so callers (and the UI) can explain the catch.
	result.tideQuality = quality
	result.tideHour = svc.hour

	-- Queue the catch as unconfirmed, then tell the Worker about it. If the
	-- Worker confirms, the delta leaves the queue and the next snapshot will
	-- carry it. If not, the delta is replayed on top of every snapshot, so the
	-- catch the player just landed is never silently undone.
	Reconcile.queue(svc.reconciler, regionId, speciesId, result.yielded)
	Service.reportCatch(svc, regionId, speciesId, result.yielded)

	Service.refreshMarket(svc)
	return result
end

--- Tell the Worker about a catch, off the hot path.
function Service.reportCatch(svc: Service, regionId: string, speciesId: string, biomass: number): ()
	task.spawn(function()
		local ok, OceanClient = pcall(function()
			return require(Shared.Net.OceanClient)
		end)
		if not ok then
			return
		end

		-- The Worker recomputes the harvest itself against the global stock; we
		-- send effort, not outcome, exactly as we would from a player.
		local accepted = OceanClient.reportCatch(regionId, speciesId, biomass)
		if accepted > 0 then
			Reconcile.confirm(svc.reconciler, accepted)
		end
	end)
end

--- Pull the authoritative global ocean and merge it in.
function Service.pullGlobal(svc: Service): boolean
	local ok, OceanClient = pcall(function()
		return require(Shared.Net.OceanClient)
	end)
	if not ok then
		return false
	end

	local snapshot = OceanClient.getSnapshot()
	if not snapshot.ok or not snapshot.regions then
		return false
	end

	-- Normalise first: the Worker returns regions as an ARRAY of objects each
	-- carrying an ARRAY of stock rows, while the merge above wants it keyed.
	-- Passing the raw shape matched nothing and silently left the ocean
	-- per-server, so the normalisation lives in Reconcile and is pinned by a
	-- test built from a real capture.
	local normalised = Reconcile.fromWorker(snapshot)
	if not normalised then
		return false
	end

	-- Adopt the Worker's geography BEFORE merging stocks. A server that seeded
	-- its own regions shares no ids with the backend, so it would merge nothing
	-- and quietly keep fishing a private ocean while reporting success.
	local adopted = Reconcile.ensureRegions(svc.ocean, normalised)
	if adopted > 0 then
		print(string.format("[slack-water] adopted %d region(s) from the global ocean", adopted))
	end

	local replayed = Reconcile.applySnapshot(svc.ocean, svc.reconciler, normalised)

	svc.backendOnline = true
	svc.everSynced = true

	-- Replaying on top of every snapshot means a growing queue means we are
	-- drifting from the shared ocean. That is the signal worth a log line.
	if replayed > 0 then
		print(
			string.format("[slack-water] global sync: %d unconfirmed catch(es) replayed", replayed)
		)
	end

	Service.refreshMarket(svc)
	return true
end

--- The public tide state, for the HUD and for gating UI before a player tries
--- to sail somewhere they cannot go.
function Service.tideState(svc: Service): any
	local events = Tide.nextEvents(svc.hour)
	return {
		hour = svc.hour,
		height = Tide.heightAt(svc.hour),
		current = Tide.currentAt(svc.hour),
		isSlack = Tide.isSlack(svc.hour),
		phase = Tide.phaseName(svc.hour),
		nextHigh = events.high,
		nextHighTime = events.highTime,
		nextLow = events.low,
		nextLowTime = events.lowTime,
		hoursToSlack = Tide.hoursToSlack(svc.hour),
	}
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

			-- Tide access is per region, not global: a 2 m shoal and a 200 m
			-- channel can be in the same bay and behave completely differently
			-- right now. The client needs this to grey out grounds the boat
			-- cannot physically reach.
			local sounding = Chart.get(svc.chart, regionId)
			local chartedDepth = if sounding then sounding.chartedDepth else region.depth
			local accessible, waterDepth = Tide.accessAt(chartedDepth, svc.hour)

			table.insert(regions, {
				id = region.id,
				name = region.name,
				habitat = region.habitat,
				depth = region.depth,
				chartedDepth = chartedDepth,
				abundances = abundances,
				contested = {},
				species = present,
				accessible = accessible,
				waterDepth = waterDepth,
				quality = Tide.fishingQuality(chartedDepth, svc.hour),
				provenance = if sounding then sounding.provenance else "grown",
			})
		end
	end

	local health = Reconcile.health(svc.reconciler, svc.everSynced)

	svc.remotes[Types.OceanSync]:FireAllClients({
		month = svc.ocean.month,
		day = svc.ocean.day,
		tick = svc.ocean.tickCount,
		tide = Service.tideState(svc),
		chartCoverage = Chart.coverage(svc.chart),
		-- whether this server is describing the shared ocean or its own. Worth
		-- surfacing: "the ocean is shared" should be a visible claim, not a
		-- marketing line that is quietly false on an empty server.
		shared = health.ok and svc.everSynced,
		sharedStatus = health.reason,
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
		-- Previously this returned in silence. A backend that is down, misnamed
		-- or unreachable looked exactly like a backend that is simply never
		-- called, which is how "the AI composer never runs" went unnoticed for
		-- an entire working session. Every fallback now says why.
		print(
			string.format(
				"[slack-water] compose round %d: backend module unavailable (%s); using procedural banks",
				svc.round,
				tostring(OceanClient)
			)
		)
		Service.fillWithProceduralBanks(svc)
		return
	end

	local result = OceanClient.composeBanks(svc.round)
	if not result.ok or not result.banks or #result.banks == 0 then
		print(
			string.format(
				"[slack-water] compose round %d: backend unusable (%s); using procedural banks",
				svc.round,
				tostring(result.error)
			)
		)
		Service.fillWithProceduralBanks(svc)
		return
	end

	svc.backendOnline = true
	local admitted = 0

	for _, candidate in result.banks do
		if #svc.ocean.order >= Config.MAX_REGIONS then
			break
		end
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

	-- ONE rebuild per round, not one per region. Main turns regionAdded into a
	-- full WorldGen.build(), which tears down and recreates every marker and
	-- all 676 water tiles. Firing per region made each round do BANKS_PER_ROUND
	-- complete rebuilds of the entire ocean, and the cost grew with the ocean.
	if admitted > 0 then
		svc.regionAdded:Fire()
	end

	print(
		string.format(
			"[slack-water] composition round %d: %d/%d banks admitted (%d grounds total)",
			svc.round,
			admitted,
			#result.banks,
			#svc.ocean.order
		)
	)
end

--- Fallback generation. Keeps the discovery treadmill running even with no
--- backend at all — the game must never be able to run dry.
function Service.fillWithProceduralBanks(svc: Service): ()
	local nextIndex = #svc.ocean.order + 1
	local added = 0
	for i = nextIndex, nextIndex + Config.BANKS_PER_ROUND - 1 do
		if #svc.ocean.order >= Config.MAX_REGIONS then
			break
		end
		local region = Regions.generateOne(svc.seed, i)
		OceanSim.addRegion(svc.ocean, region)
		added += 1
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

	-- Same coalescing as composeNewBanks: one world rebuild per round.
	if added > 0 then
		svc.regionAdded:Fire()
	end
end

Service._TICK_INTERVAL = TICK_INTERVAL
Service._SYNC_INTERVAL = SYNC_INTERVAL

return Service
