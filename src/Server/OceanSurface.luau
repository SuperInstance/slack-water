--!strict
--[[
	OceanSurface — draws the sea. The Roblox-facing half of Waves/Water.

	RENDERER CHOICE — a grid of anchored Parts, and why

	Three candidates were weighed against "~80% of players are on a phone":

	1. A SurfaceGui-backed plane. The cheapest thing that can call itself
	   water — one part, one GUI — but a SurfaceGui cannot be displaced:
	   no waves, and a tide that can only slide a flat plane up and down
	   instead of raising the water. For a game whose signature is a
	   visibly rising and falling ocean, that is the one thing it cannot
	   do. Rejected.

	2. A MeshPart with per-frame vertex animation (EditableMesh). Roblox
	   has no custom shaders, so animating a mesh means rewriting vertex
	   data continuously. That per-frame cost is exactly what low-end
	   mobile cannot afford — and this file runs server-side, so every
	   vertex delta also replicates to every client. Rejected.

	3. A grid of thin anchored Parts whose CFrame and Color are mutated on
	   a throttled cadence. Geometry is built once; an update is property
	   writes on existing instances; grid density, refresh rate and write
	   quanta are three knobs in one table. Chosen.

	The known costs of that choice — seam slits between tiles, and server->client
	replication proportional to how much of the grid actually moves — are
	spelled out with numbers in docs/OCEAN.md rather than hidden here.

	COHERENT PASSES, NOT ROTATING SUBSETS

	Every pass refreshes the WHOLE grid at one shared timestamp. Updating a
	rotating subset of tiles would be fewer writes per pass, but neighbours
	out of phase with each other read as a torn sheet of water; one atomic
	pass per tick is what makes 26x26 flat parts read as one surface. The
	write savings come from quanta instead: a tile whose height and colour
	have not moved past their quantum is not written at all, so a calm sea
	is nearly free and only a storm pays full price.

	DRIVING

	WorldGen calls start(ocean, clock) on every rebuild; `clock` returns the
	simulation hour (OceanService owns the hour — the ocean state itself
	only tracks month/day for the runs). The tide comes from Tide.luau
	unmodified; the sea state and wind direction are derived inside Waves
	from the calendar, so no weather state crosses the wire.

	Anything registered via ride() — the boat and its dock — floats: it is
	pivoted by the same tide + setup term the surface sits on, so freeboard
	stays constant while the whole scene rises and falls over a cycle.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tide = require(Shared.Tide)
local Waves = require(Shared.Ocean.Waves)
local Water = require(Shared.Ocean.Water)

local OceanSurface = {}

--- Everything tunable about the surface, in studs and seconds.
OceanSurface.TUNING = {
	-- 26 x 26 = 676 tiles of 30 studs = a 780 x 780 ocean, which covers the
	-- grounds grid (~+-130) with fog margin to spare.
	GRID = 26,
	TILE = 30.0,
	THICKNESS = 4.0,

	-- World Y of MLLW (chart datum). The tide swings roughly +-8 studs
	-- around this; grounds are charted downward from it.
	DATUM_Y = 0.0,

	-- Seconds between full passes. 4 Hz keeps every wave component (period
	-- >= 3.2 s) above its Nyquist limit with room to spare.
	UPDATE_INTERVAL = 0.25,

	-- Skip a tile's CFrame/Color write until it has moved this far.
	HEIGHT_QUANTUM = 0.06,
	COLOR_QUANTUM = 0.02, -- per channel, 0..1
	RIDE_QUANTUM = 0.02, -- skip pivoting riders below this much tide change

	-- How fast the presented sea approaches the day's target sea state
	-- (fraction per second), so the day rollover eases in instead of popping.
	SEA_CHANGE_RATE = 0.15,

	TRANSPARENCY = 0.55,
	REFLECTANCE = 0.04,
}

--=============================================================================
-- State
--=============================================================================

local state: any = nil
local connection: RBXScriptConnection? = nil

--=============================================================================
-- Build
--=============================================================================

--- Collect the floor heights the colour/foam logic needs: every ground disc
--- WorldGen placed (it stamps a floorY attribute and carries the disc as a
--- child named "Ground"), plus the rescue SeaFloor as the default.
---
--- Deliberately duck-typed (attribute + named child) rather than IsA/typeof:
--- the marker models are ours, so asking for our own stamp is more precise
--- than asking for a class, and it keeps this loadable under headless fakes
--- that implement fewer Instance APIs than Studio.
local function collectFloors(oceanFolder: Folder?): (number, { any })
	local defaultFloor = OceanSurface.TUNING.DATUM_Y - 58.0

	local seaFloor = oceanFolder and oceanFolder:FindFirstChild("SeaFloor")
	if seaFloor and seaFloor.CFrame and seaFloor.Size then
		defaultFloor = seaFloor.CFrame.Y + seaFloor.Size.Y * 0.5
	end

	local grounds: { any } = {}
	if oceanFolder then
		for _, child in oceanFolder:GetChildren() do
			local floorY = child:GetAttribute("floorY")
			local disc = child:FindFirstChild("Ground")
			if type(floorY) == "number" and disc then
				-- a tile "belongs" to a ground when its centre falls
				-- within the disc radius plus half a tile
				local radius = math.max(disc.Size.Y, disc.Size.Z) * 0.5
					+ OceanSurface.TUNING.TILE * 0.5
				table.insert(grounds, {
					x = disc.CFrame.X,
					z = disc.CFrame.Z,
					radius = radius,
					floorY = floorY,
				})
			end
		end
	end

	return defaultFloor, grounds
end

local function buildTiles(oceanFolder: Folder, defaultFloor: number, grounds: { any }): { any }
	local tuning = OceanSurface.TUNING
	local half = (tuning.GRID - 1) / 2.0

	local tiles: { any } = {}

	for ix = 0, tuning.GRID - 1 do
		for iz = 0, tuning.GRID - 1 do
			local x = (ix - half) * tuning.TILE
			local z = (iz - half) * tuning.TILE

			-- shallowest floor under this tile: a ground disc if one is
			-- here, otherwise the sea floor plain
			local floorY = defaultFloor
			for _, g in grounds do
				local dx = x - g.x
				local dz = z - g.z
				if dx * dx + dz * dz <= g.radius * g.radius and g.floorY < floorY then
					floorY = g.floorY
				end
			end

			local part = Instance.new("Part")
			part.Name = "Tile"
			part.Size = Vector3.new(tuning.TILE, tuning.THICKNESS, tuning.TILE)
			part.CFrame = CFrame.new(x, tuning.DATUM_Y - tuning.THICKNESS * 0.5, z)
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.CastShadow = false
			-- Water, not SmoothPlastic: these parts ARE the ocean, and the
			-- material is how the rest of the world (and the boot smoke
			-- test) recognises them as such.
			part.Material = Enum.Material.Water
			part.Transparency = tuning.TRANSPARENCY
			part.Reflectance = tuning.REFLECTANCE
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Color = Color3.new(Water.DEEP[1], Water.DEEP[2], Water.DEEP[3])
			part.Parent = oceanFolder

			-- lastY/lastRGB start "never written" so the first pass sets
			-- every tile once
			table.insert(tiles, {
				part = part,
				x = x,
				z = z,
				floorY = floorY,
				lastY = -1e9,
				lastR = -1.0,
				lastG = -1.0,
				lastB = -1.0,
			})
		end
	end

	return tiles
end

--=============================================================================
-- Pass
--=============================================================================

--- One full pass: recompute the surface from the current tide, sea state
--- and wave phase, and write only what has meaningfully moved. Safe to call
--- by hand; `dt` defaults to one update interval.
function OceanSurface.update(dt: number?)
	if not state then
		return
	end

	local folder: Folder = state.folder
	if not folder or folder.Parent == nil then
		-- WorldGen.clear() destroyed the surface out from under us; a
		-- rebuild will follow, so stop cleanly instead of writing to
		-- orphaned parts.
		OceanSurface.stop()
		return
	end

	local tuning = OceanSurface.TUNING
	local step = dt or tuning.UPDATE_INTERVAL

	local dayIdx = Waves.dayIndex(state.ocean.month, state.ocean.day)
	local cond = Waves.conditions(Waves.seaState(dayIdx))

	-- presentation-only smoothing: the day's sea eases in over a few passes
	local blend = math.clamp(step * tuning.SEA_CHANGE_RATE, 0.0, 1.0)
	state.amp += (cond.amplitude - state.amp) * blend
	state.baseOffset += (cond.baseOffset - state.baseOffset) * blend
	-- wind direction snaps at the day line; lerping an angle across its
	-- wrap would spin the long way round, which looks worse than the snap
	state.dir = Waves.windDir(dayIdx)
	state.t += step

	if state.seaName ~= cond.name then
		folder:SetAttribute("seaState", cond.name)
		state.seaName = cond.name
	end

	-- THE TIDE IS THE SIGNAL: the whole ocean's base level comes from the
	-- real harmonic height at the current sim hour, in studs.
	local tide = Tide.heightAt(state.clock()) * Waves.STUDS_PER_METRE
	local baseY = tuning.DATUM_Y + tide + state.baseOffset

	-- riders (the boat, the dock, the spawn) float on the same tide + setup term
	local rideY = tide + state.baseOffset
	if state.lastRideY == nil then
		state.lastRideY = rideY
	end
	local dy = rideY - state.lastRideY
	if math.abs(dy) >= tuning.RIDE_QUANTUM then
		for _, rider in state.riders do
			rider:PivotTo(rider:GetPivot() + Vector3.new(0, dy, 0))
		end
		state.lastRideY = rideY
	end

	local amp = state.amp
	local quantum = tuning.HEIGHT_QUANTUM
	local colorQuantum = tuning.COLOR_QUANTUM

	for _, tile in state.tiles do
		local h = Waves.heightAt(tile.x, tile.z, state.t, amp, state.dir)
		local y = baseY + h

		if math.abs(y - tile.lastY) > quantum then
			tile.part.CFrame = CFrame.new(tile.x, y - tuning.THICKNESS * 0.5, tile.z)
			tile.lastY = y
		end

		local r, g, b = Water.appearance(h, amp, y - tile.floorY)
		if
			math.abs(r - tile.lastR) > colorQuantum
			or math.abs(g - tile.lastG) > colorQuantum
			or math.abs(b - tile.lastB) > colorQuantum
		then
			tile.part.Color = Color3.new(r, g, b)
			tile.lastR = r
			tile.lastG = g
			tile.lastB = b
		end
	end
end

--=============================================================================
-- Lifecycle
--=============================================================================

--- Build (or rebuild) the surface and start its throttled animation loop.
--- Safe to call repeatedly: any previous surface is stopped and cleared
--- first, which is what makes the WorldGen rebuild on region discovery safe.
---
--- `clock` returns the current simulation hour (OceanService.hour). Without
--- one the surface draws the tide at hour 0 — static, but not wrong.
function OceanSurface.start(ocean: any, clock: (() -> number)?): ()
	OceanSurface.stop()

	local oceanFolder = Workspace:FindFirstChild("Ocean")
	if not oceanFolder then
		oceanFolder = Instance.new("Folder")
		oceanFolder.Name = "Ocean"
		oceanFolder.Parent = Workspace
	end

	local folder = Instance.new("Folder")
	folder.Name = "Surface"
	folder.Parent = oceanFolder

	local defaultFloor, grounds = collectFloors(oceanFolder)

	local dayIdx = Waves.dayIndex(ocean.month, ocean.day)
	local cond = Waves.conditions(Waves.seaState(dayIdx))

	state = {
		folder = folder,
		tiles = buildTiles(folder, defaultFloor, grounds),
		riders = {},
		ocean = ocean,
		clock = clock or function()
			return 0.0
		end,
		t = 0.0,
		-- start AT the day's conditions; the lerp only exists to ease the
		-- day rollover, not to spin up from calm
		amp = cond.amplitude,
		baseOffset = cond.baseOffset,
		dir = Waves.windDir(dayIdx),
		lastRideY = nil,
		seaName = nil,
	}

	-- first coherent frame immediately, so the ocean exists on the same
	-- tick it is built rather than one interval later
	OceanSurface.update(0.0)

	-- If the very first update bailed (folder already gone), don't arm a
	-- loop that will immediately stop itself.
	if not state then
		return
	end

	local accumulated = 0.0
	local interval = OceanSurface.TUNING.UPDATE_INTERVAL

	local conn
	conn = RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(function()
			accumulated += dt
			if accumulated < interval then
				return
			end
			-- clamp so a loading hitch cannot trigger a burst of catch-up
			-- passes; the sea simply resumes where it is
			local step = math.min(accumulated, interval * 4)
			accumulated = 0.0
			OceanSurface.update(step)
		end)
		if not ok then
			conn:Disconnect()
			warn("[slack-water] ocean surface stopped after update error: " .. tostring(err))
		end
	end)
	connection = conn
end

--- Stop the animation loop and destroy the surface parts. Idempotent.
function OceanSurface.stop(): ()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if state then
		if state.folder then
			state.folder:Destroy()
		end
		state = nil
	end
end

--- Register something to float on the tide — WorldGen registers the boat
--- model (dock and all) and the spawn. Models and BaseParts both pivot
--- (PivotTo is on every PVInstance), so either is accepted. Call after
--- start(); the rider list is cleared by the next start().
function OceanSurface.ride(rider: any): ()
	if state then
		table.insert(state.riders, rider)
	end
end

return OceanSurface
