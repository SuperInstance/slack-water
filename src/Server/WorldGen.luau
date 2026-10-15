--!strict
--[[
	WorldGen — giving the ocean a body.

	The simulation is abstract; this turns it into somewhere a player can stand.
	Roblox is roughly 80% mobile, which is the governing constraint on every
	decision here.

	THE FIRST VERSION OF THIS FILE PRODUCED A BLANK SCREEN.

	It built ground discs at y = -1 with CanCollide = false, which is fine if
	you only ever look at it from a fixed camera — but a player spawned at the
	default origin with nothing solid under them and simply fell out of the
	world. The UI worked, the simulation ticked, and there was no water.

	The lesson, and the reason this file now builds a place rather than a
	diagram:

	- the player needs something SOLID under them before anything else;
	- the thing they stand on should be the boat, because that is what a
	  fishing game is about;
	- the grounds have to be in the field of view from the spawn, or "empty
	  world" and "world you have not turned around to look at" are
	  indistinguishable.

	There is also water now (OceanSurface, built at the end of build()).
	That changed two relationships this file owns:

	- grounds are placed BY DEPTH under the datum (y = 0 = MLLW) instead of
	  all at y = 0, so a shallow shoal can genuinely dry out at low water —
	  the mechanic the whole game rests on, made visible;
	- the boat FLOATS: it is pivoted by the same tide term the surface sits
	  on (OceanSurface.ride), so freeboard is constant while the whole scene
	  rises and falls over a cycle. A fixed deck would be a pier, not a
	  boat, and would go under at springs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OceanSim = require(Shared.Ocean.OceanSim)
local Waves = require(Shared.Ocean.Waves)
local Water = require(Shared.Ocean.Water)
local OceanSurface = require(script.Parent.OceanSurface)
local OceanService = require(script.Parent.OceanService)

-- Distance between grounds on the grid. Kept tight enough that several are
-- visible from the boat at once.
local REGION_SPACING = 70

-- Colour by habitat, so a player can read the map by colour alone before they
-- can read a label. Tuned to stay distinguishable on a small, low-contrast
-- screen in fog.
local HABITAT_COLOR: { [string]: Color3 } = {
	kelp = Color3.fromRGB(58, 132, 92),
	reef = Color3.fromRGB(92, 148, 170),
	sand = Color3.fromRGB(198, 184, 140),
	mud = Color3.fromRGB(112, 100, 82),
	open = Color3.fromRGB(56, 104, 148),
	estuary = Color3.fromRGB(86, 134, 138),
}

local WorldGenService = {}

--=============================================================================
-- Clearing
--=============================================================================

function WorldGenService.clear(): ()
	local oceanFolder = Workspace:FindFirstChild("Ocean")
	if not oceanFolder then
		return
	end
	for _, child in oceanFolder:GetChildren() do
		child:Destroy()
	end
end

--=============================================================================
-- The boat — the player's solid ground
--=============================================================================

--- Build the thing the player stands on.
---
--- This exists purely so nobody falls out of the world. It is also, not
--- coincidentally, a boat: it is where you cast from, and it frames every
--- screenshot of the game.
---
--- The hull is drawn DEEP on purpose: its designed waterline is y = 0 (the
--- same datum the tide and the grounds are charted from), so it floats with
--- the deck clear of everything but a storm's crests — and the whole model
--- is pivoted by the tide via OceanSurface.ride, so it stays that way at
--- every state of the tide instead of being a fixed platform the sea rises
--- over.
function WorldGenService.buildDeck(folder: any): any
	local deck = Instance.new("Model")
	deck.Name = "FVEileen"

	-- Hull: a solid slab. Not a boat shape — this is a collision surface with
	-- a name, and pretending otherwise on a prototype just makes the spawn
	-- worse to stand on.
	local hull = Instance.new("Part")
	hull.Name = "Deck"
	hull.Size = Vector3.new(24, 5.5, 24)
	hull.CFrame = CFrame.new(0, 0.75, 0) -- spans y -2 .. +3.5; waterline at 0
	hull.Anchored = true
	hull.CanCollide = true
	hull.Material = Enum.Material.WoodPlanks
	hull.Color = Color3.fromRGB(122, 94, 64)
	hull.TopSurface = Enum.SurfaceType.Smooth
	hull.BottomSurface = Enum.SurfaceType.Smooth
	hull.Parent = deck

	-- A rail so the deck reads as a boat from a distance and gives the eye a
	-- horizon reference when you are standing on it.
	for _, offset in { Vector3.new(0, 3, -12), Vector3.new(0, 3, 12) } do
		local rail = Instance.new("Part")
		rail.Name = "Rail"
		rail.Size = Vector3.new(24, 4, 1)
		rail.CFrame = CFrame.new(offset.X, 6, offset.Z)
		rail.Anchored = true
		rail.CanCollide = false
		rail.Material = Enum.Material.WoodPlanks
		rail.Color = Color3.fromRGB(96, 74, 50)
		rail.Transparency = 0.35
		rail.Parent = deck
	end

	-- Mast: the tallest thing on the deck, so "which way am I facing" is
	-- answerable from the boat alone.
	local mast = Instance.new("Part")
	mast.Name = "Mast"
	mast.Size = Vector3.new(1, 34, 1)
	mast.CFrame = CFrame.new(0, 20, 0)
	mast.Anchored = true
	mast.CanCollide = false
	mast.Material = Enum.Material.Wood
	mast.Color = Color3.fromRGB(108, 84, 58)
	mast.Transparency = 0.25
	mast.Parent = deck

	-- A floating pontoon out to where arrivals land. Main drops every
	-- character at (0, 40, 90): before the ocean existed that put them on
	-- the bare rescue floor 60-odd studs down; with water there it would
	-- dump them in the drink with no way back onto the boat. The pontoon
	-- makes arrival read as a harbour instead of a bug — and because it is
	-- part of the boat model it rides the tide with it.
	local dock = Instance.new("Part")
	dock.Name = "Dock"
	dock.Size = Vector3.new(8, 2, 104)
	dock.CFrame = CFrame.new(0, 2.5, 64) -- spans z 12..116; top level with the deck
	dock.Anchored = true
	dock.CanCollide = true
	dock.Material = Enum.Material.WoodPlanks
	dock.Color = Color3.fromRGB(104, 92, 78)
	dock.TopSurface = Enum.SurfaceType.Smooth
	dock.BottomSurface = Enum.SurfaceType.Smooth
	dock.CastShadow = false
	dock.Parent = deck

	deck:SetPrimaryPart(hull)
	deck.Parent = folder

	return deck
end

--- A spawn point beside the deck, so the player arrives here rather than at
--- the world origin falling through the ocean.
---
--- A DIRECT child of the Ocean folder on purpose — the boot smoke test finds
--- it there — and registered with OceanSurface.ride() separately from the
--- boat, so it still floats with the tide. (Parented into the boat model it
--- would ride automatically, but then it stops being findable where the rest
--- of the world looks for it.)
function WorldGenService.buildSpawn(folder: any): any
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = CFrame.new(0, 4, 0)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = Color3.fromRGB(140, 160, 170)
	spawn.Transparency = 0.4
	spawn.CanCollide = true
	spawn.Parent = folder
	return spawn
end

--- A large non-colliding plane far below everything. If a player does fall, they
--- land here instead of falling forever — a cheap rescue that turns an
--- unrecoverable bug into a visible one.
---
--- It doubles as the deep bottom beyond the surface's edge (the water grid is
--- 780 studs; this plane is 1200), so it is painted the deep-water colour
--- rather than sand: where the surface ends, the floor should keep reading as
--- "deep sea below fog", not switch to a beach.
function WorldGenService.buildFloor(folder: any): any
	local floor = Instance.new("Part")
	floor.Name = "SeaFloor"
	floor.Size = Vector3.new(1200, 4, 1200)
	floor.CFrame = CFrame.new(0, -60, 0)
	floor.Anchored = true
	floor.CanCollide = true
	floor.Material = Enum.Material.Slate
	floor.Color = Color3.new(Water.DEEP[1], Water.DEEP[2], Water.DEEP[3])
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.BottomSurface = Enum.SurfaceType.Smooth
	floor.CastShadow = false
	floor.Parent = folder
	return floor
end

--=============================================================================
-- Grounds
--=============================================================================

--- Build the playable representation of every region in the simulation.
---
--- Grounds are laid out on a deterministic grid derived from their index rather
--- than scattered randomly: a player who knows where "Outer Kelp Bed" is will
--- find it in the same place next session, which matters when the world persists.
function WorldGenService.build(ocean: any): ()
	WorldGenService.clear()

	local folder = Workspace:FindFirstChild("Ocean")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Ocean"
		folder.Parent = Workspace
	end

	WorldGenService.buildFloor(folder)
	local deck = WorldGenService.buildDeck(folder)
	local spawn = WorldGenService.buildSpawn(folder)

	for index, regionId in ocean.order do
		local region = OceanSim.getRegion(ocean, regionId)
		if region then
			WorldGenService.buildRegion(folder, region, index)
		end
	end

	-- The surface goes on LAST: it scans the built grounds to derive the
	-- depth field its colour and foam respond to. The clock reads the
	-- simulation hour straight from OceanService, because the hour lives on
	-- the service (the ocean state itself only tracks month/day for the
	-- runs) and Main is not ours to change the call signature of.
	OceanSurface.start(ocean, function()
		local svc = OceanService.get()
		return if svc then svc.hour else 0.0
	end)

	-- The boat floats on the tide the surface sits on, and so does the
	-- spawn. Registered after start() so a rebuild's fresh rider list picks
	-- up the fresh instances.
	OceanSurface.ride(deck)
	OceanSurface.ride(spawn)

	print(string.format("[slack-water] worldgen: %d region(s) placed", #ocean.order))
end

function WorldGenService.buildRegion(parent: any, region: any, index: number): any
	-- Grid layout keeps every ground at a findable, repeatable position, and
	-- rings the grounds around the spawn so several are visible on arrival.
	local column = index % 4
	local row = math.floor(index / 4)
	local originX = (column - 1.5) * REGION_SPACING
	local originZ = (row - 1.5) * REGION_SPACING

	local color = HABITAT_COLOR[region.habitat] or HABITAT_COLOR.open

	local marker = Instance.new("Model")
	marker.Name = region.id
	marker:SetAttribute("regionId", region.id)
	marker:SetAttribute("habitat", region.habitat)
	marker:SetAttribute("depth", region.depth)
	marker:SetAttribute("origin", region.origin)

	-- Display depth below the datum: effectively linear near the surface
	-- (which is what lets a 2 m shoal genuinely dry out at low water) and
	-- compressed with depth so a 500 m basin is still visible from the
	-- boat. See Waves.depthToStuds for the curve and its honesty note.
	local topY = -Waves.depthToStuds(region.depth)
	-- the surface's colour/foam pass reads this instead of recomputing the
	-- layout, so renderer and grounds can never disagree about where the
	-- floor is
	marker:SetAttribute("floorY", topY)

	-- A single flat disc is enough to read as a fishing ground from a distance
	-- and costs almost nothing to stream. It is NOT collidable: the player is
	-- on a boat, not wading.
	local disc = Instance.new("Part")
	disc.Name = "Ground"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(2, 46, 46)
	disc.CFrame = CFrame.new(originX, topY - 1, originZ) * CFrame.Angles(0, 0, math.rad(90))
	disc.Color = color
	disc.Material = Enum.Material.Slate
	disc.Anchored = true
	disc.CanCollide = false
	disc.CastShadow = false
	disc.TopSurface = Enum.SurfaceType.Smooth
	disc.BottomSurface = Enum.SurfaceType.Smooth
	disc.Parent = marker

	-- Billboard so the name is legible from the boat. Offset up so it does not
	-- intersect the player's head on approach.
	local label = Instance.new("BillboardGui")
	label.Name = "Label"
	label.Size = UDim2.fromOffset(220, 60)
	label.StudsOffset = Vector3.new(0, 14, 0)
	label.AlwaysOnTop = true
	label.MaxDistance = 500
	label.Parent = marker

	local text = Instance.new("TextLabel")
	text.Name = "Name"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = string.format("%s\n%d m", region.name, math.floor(region.depth))
	text.TextColor3 = Color3.fromRGB(245, 248, 250)
	text.TextStrokeTransparency = 0.3
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.Parent = label

	marker:SetPrimaryPart(disc)
	marker.Parent = parent

	return marker
end

WorldGenService.REGION_SPACING = REGION_SPACING
WorldGenService.HABITAT_COLOR = HABITAT_COLOR

return WorldGenService
