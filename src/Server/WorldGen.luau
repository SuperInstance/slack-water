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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OceanSim = require(Shared.Ocean.OceanSim)

local WorldGen = {}

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
function WorldGenService.buildDeck(folder: any): any
	local deck = Instance.new("Model")
	deck.Name = "FVEileen"

	-- Hull: a solid slab. Not a boat shape — this is a collision surface with
	-- a name, and pretending otherwise on a prototype just makes the spawn
	-- worse to stand on.
	local hull = Instance.new("Part")
	hull.Name = "Deck"
	hull.Size = Vector3.new(24, 3, 24)
	hull.CFrame = CFrame.new(0, 2, 0)
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

	deck:SetPrimaryPart(hull)
	deck.Parent = folder

	return deck
end

--- A spawn point on the deck, so the player arrives here rather than at the
--- world origin falling through the ocean.
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
function WorldGenService.buildFloor(folder: any): any
	local floor = Instance.new("Part")
	floor.Name = "SeaFloor"
	floor.Size = Vector3.new(1200, 4, 1200)
	floor.CFrame = CFrame.new(0, -60, 0)
	floor.Anchored = true
	floor.CanCollide = true
	floor.Material = Enum.Material.Sand
	floor.Color = Color3.fromRGB(70, 66, 54)
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
	WorldGenService.buildDeck(folder)
	WorldGenService.buildSpawn(folder)

	for index, regionId in ocean.order do
		local region = OceanSim.getRegion(ocean, regionId)
		if region then
			WorldGenService.buildRegion(folder, region, index)
		end
	end

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

	-- A single flat disc is enough to read as a fishing ground from a distance
	-- and costs almost nothing to stream. It is NOT collidable: the player is
	-- on a boat, not wading.
	local disc = Instance.new("Part")
	disc.Name = "Ground"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(2, 46, 46)
	disc.CFrame = CFrame.new(originX, 0, originZ) * CFrame.Angles(0, 0, math.rad(90))
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