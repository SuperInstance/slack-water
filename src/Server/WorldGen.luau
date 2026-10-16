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

	-- NOTE ON WHY THIS IS PARTS AND NOT THE BLENDER MESH
	-- --------------------------------------------------
	-- art/fv_eileen/ holds a lofted FBX of the real boat, built from the
	-- owner's photographs. It cannot be used directly: Rojo does not embed
	-- binary assets in the place it builds, and Roblox cannot import an FBX
	-- at runtime. The mesh only becomes usable if it is uploaded to Roblox as
	-- an asset and referenced by id — see MESH_ID below.
	--
	-- Until then the boat is built from Parts so it ships through Rojo. The
	-- silhouette is a real attempt at the Eileen rather than a placeholder
	-- slab, and the parts count is small enough for mobile.
	--
	-- SAFETY: whatever the visual, there is ALWAYS a collidable deck under
	-- the player. Showstopper #2 was a player falling through the world
	-- because the deck had CanCollide = false. No amount of prettiness is
	-- worth reintroducing that.
	local MESH_ID = "" -- set to a Roblox asset id to swap the hull for the mesh

	if MESH_ID ~= "" then
		local mesh = Instance.new("MeshPart")
		mesh.Name = "HullMesh"
		mesh.MeshId = MESH_ID
		mesh.Size = Vector3.new(58, 1, 16)
		mesh.CFrame = CFrame.new(0, 0, 0)
		mesh.Anchored = true
		mesh.CanCollide = false -- collision stays on Deck, deliberately
		mesh.Parent = deck
	end

	local HULL_LEN, HULL_BEAM = 50, 14 -- confirmed by the owner: 50 ft overall
	local DECK_Y = 4.4 -- sheer height; the waterline stays at y = 0

	-- Collision surface. A single wide slab, inset from the visible hull so
	-- a player cannot stand on an overhanging edge of nothing.
	local hull = Instance.new("Part")
	hull.Name = "Deck"
	hull.Size = Vector3.new(HULL_LEN - 6, 1.0, HULL_BEAM - 3)
	hull.CFrame = CFrame.new(0, DECK_Y, 0)
	hull.Anchored = true
	hull.CanCollide = true
	hull.Material = Enum.Material.WoodPlanks
	hull.Color = Color3.fromRGB(122, 94, 64)
	hull.TopSurface = Enum.SurfaceType.Smooth
	hull.BottomSurface = Enum.SurfaceType.Smooth
	hull.Parent = deck

	-- The visible hull: a tapered stack of slabs following the real sheer
	-- curve, white topsides over dark antifouling below the waterline.
	local tiers = {
		{ y = 2.6, len = HULL_LEN - 2, beam = HULL_BEAM - 1.5 },
		{ y = 1.2, len = HULL_LEN - 1, beam = HULL_BEAM },
		{ y = 0.0, len = HULL_LEN, beam = HULL_BEAM },
		{ y = -1.6, len = HULL_LEN - 3, beam = HULL_BEAM - 2.5 },
		{ y = -3.2, len = HULL_LEN - 9, beam = HULL_BEAM - 6 },
	}
	for i, t in tiers do
		local part = Instance.new("Part")
		part.Name = "HullTier"
		part.Size = Vector3.new(t.len, 2.0, t.beam)
		part.CFrame = CFrame.new(0, t.y, 0)
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		-- Below the waterline is antifouling; above it is white topsides.
		if t.y < 0 then
			part.Material = Enum.Material.SmoothPlastic
			part.Color = Color3.fromRGB(18, 26, 38)
		else
			part.Material = Enum.Material.SmoothPlastic
			part.Color = Color3.fromRGB(224, 226, 224)
		end
		part.Parent = deck
		-- The bow is finer than the stern on a real hull.
		part:SetAttribute("tier", i)
	end

	-- Sheer stripe / rubbing strake, the line that reads the hull length.
	local strake = Instance.new("Part")
	strake.Name = "SheerStripe"
	strake.Size = Vector3.new(HULL_LEN - 1, 0.5, HULL_BEAM + 0.3)
	strake.CFrame = CFrame.new(0, DECK_Y - 0.6, 0)
	strake.Anchored = true
	strake.CanCollide = false
	strake.Material = Enum.Material.SmoothPlastic
	strake.Color = Color3.fromRGB(198, 190, 168)
	strake.Parent = deck

	-- Bulwark round the working deck.
	for _, side in { -1, 1 } do
		local bw = Instance.new("Part")
		bw.Name = "Bulwark"
		bw.Size = Vector3.new(HULL_LEN - 12, 2.2, 0.5)
		bw.CFrame = CFrame.new(-2, DECK_Y + 1.1, side * (HULL_BEAM * 0.5 - 0.9))
		bw.Anchored = true
		bw.CanCollide = false
		bw.Material = Enum.Material.SmoothPlastic
		bw.Color = Color3.fromRGB(224, 226, 224)
		bw.Parent = deck
	end

	-- Main deckhouse: a row of windows, as on the real boat.
	local house = Instance.new("Part")
	house.Name = "Deckhouse"
	house.Size = Vector3.new(17, 4.5, 12.5)
	house.CFrame = CFrame.new(-8, DECK_Y + 2.75, 0)
	house.Anchored = true
	house.CanCollide = false
	house.Material = Enum.Material.SmoothPlastic
	house.Color = Color3.fromRGB(232, 232, 228)
	house.Parent = deck
	for k = 0, 4 do
		local win = Instance.new("Part")
		win.Name = "HouseWindow"
		win.Size = Vector3.new(2.1, 1.3, 0.3)
		win.CFrame = CFrame.new(-14.4 + k * 3.2, DECK_Y + 3.2, 6.35)
		win.Anchored = true
		win.CanCollide = false
		win.Material = Enum.Material.Glass
		win.Color = Color3.fromRGB(40, 52, 60)
		win.Parent = deck
	end

	-- Raised pilothouse forward of it — the two-tier profile is the single
	-- most recognisable thing about the Eileen.
	local pilot = Instance.new("Part")
	pilot.Name = "Pilothouse"
	pilot.Size = Vector3.new(11, 4.0, 10.6)
	pilot.CFrame = CFrame.new(7, DECK_Y + 7.0, 0)
	pilot.Anchored = true
	pilot.CanCollide = false
	pilot.Material = Enum.Material.SmoothPlastic
	pilot.Color = Color3.fromRGB(238, 238, 234)
	pilot.Parent = deck
	for _, side in { -1, 1 } do
		local w = Instance.new("Part")
		w.Name = "PilotWindow"
		w.Size = Vector3.new(2.4, 1.5, 0.3)
		w.CFrame = CFrame.new(7 - 2.6, DECK_Y + 7.3, side * 5.35)
		w.Anchored = true
		w.CanCollide = false
		w.Material = Enum.Material.Glass
		w.Color = Color3.fromRGB(40, 52, 60)
		w.Parent = deck
	end

	-- Spreader mast with its cross-tree, on the pilothouse roof.
	local mast = Instance.new("Part")
	mast.Name = "Mast"
	mast.Size = Vector3.new(0.7, 22, 0.7)
	mast.CFrame = CFrame.new(7, DECK_Y + 19, 0)
	mast.Anchored = true
	mast.CanCollide = false
	mast.Material = Enum.Material.Wood
	mast.Color = Color3.fromRGB(228, 228, 224)
	mast.Parent = deck

	local tree = Instance.new("Part")
	tree.Name = "MastCrosstree"
	tree.Size = Vector3.new(0.5, 0.5, 8)
	tree.CFrame = CFrame.new(7, DECK_Y + 24, 0)
	tree.Anchored = true
	tree.CanCollide = false
	tree.Material = Enum.Material.Wood
	tree.Color = Color3.fromRGB(228, 228, 224)
	tree.Parent = deck

	-- Working gear aft: net reel under tarp, and the A-frame at the transom.
	local reel = Instance.new("Part")
	reel.Name = "NetReel"
	reel.Size = Vector3.new(9, 3.2, 10)
	reel.CFrame = CFrame.new(-15, DECK_Y + 2.1, 0)
	reel.Anchored = true
	reel.CanCollide = false
	reel.Material = Enum.Material.Fabric
	reel.Color = Color3.fromRGB(58, 58, 62)
	reel.Parent = deck

	for _, side in { -1, 1 } do
		local leg = Instance.new("Part")
		leg.Name = "AFrame"
		leg.Size = Vector3.new(0.6, 9, 0.6)
		leg.CFrame = CFrame.new(-21, DECK_Y + 5, side * 2.5)
		leg.Anchored = true
		leg.CanCollide = false
		leg.Material = Enum.Material.Metal
		leg.Color = Color3.fromRGB(150, 152, 156)
		leg.Parent = deck
	end

	-- Green net floats and the orange buoy, outboard on the rail.
	for k = 0, 3 do
		local f = Instance.new("Part")
		f.Name = "NetFloat"
		f.Shape = Enum.PartType.Cylinder
		f.Size = Vector3.new(2.6, 1.7, 1.7)
		f.CFrame = CFrame.new(2 + k * 2.4, DECK_Y + 2.6, -(HULL_BEAM * 0.5 + 0.4))
			* CFrame.Angles(0, 0, math.rad(90))
		f.Anchored = true
		f.CanCollide = false
		f.Material = Enum.Material.SmoothPlastic
		f.Color = Color3.fromRGB(30, 132, 62)
		f.Parent = deck
	end
	local buoy = Instance.new("Part")
	buoy.Name = "Buoy"
	buoy.Shape = Enum.PartType.Cylinder
	buoy.Size = Vector3.new(3.2, 2.1, 2.1)
	buoy.CFrame = CFrame.new(9, DECK_Y + 2.8, HULL_BEAM * 0.5 + 0.5)
		* CFrame.Angles(0, 0, math.rad(90))
	buoy.Anchored = true
	buoy.CanCollide = false
	buoy.Material = Enum.Material.SmoothPlastic
	buoy.Color = Color3.fromRGB(214, 74, 20)
	buoy.Parent = deck

	deck.PrimaryPart = hull

	-- A floating pontoon out to where arrivals land. Main drops every
	-- character at (0, 40, 90): before the ocean existed that put them on
	-- the bare rescue floor 60-odd studs down; with water there it would
	-- dump them in the drink with no way back onto the boat. The pontoon
	-- makes arrival read as a harbour instead of a bug — and because it is
	-- part of the boat model it rides the tide with it.
	local dock = Instance.new("Part")
	dock.Name = "Dock"
	dock.Size = Vector3.new(8, 2, 86)
	-- Starts clear of the hull (which now runs z -29..29) and its top is level
	-- with the deck top at y = 4.9, so a player can step aboard rather than
	-- climb a wall. The old slab was only 24 long and the dock began at z=12,
	-- which put it inside the new hull.
	dock.CFrame = CFrame.new(0, 3.9, 73) -- spans z 30..116
	dock.Anchored = true
	dock.CanCollide = true
	dock.Material = Enum.Material.WoodPlanks
	dock.Color = Color3.fromRGB(104, 92, 78)
	dock.TopSurface = Enum.SurfaceType.Smooth
	dock.BottomSurface = Enum.SurfaceType.Smooth
	dock.CastShadow = false
	dock.Parent = deck

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
	-- Sits just above the Deck collision surface (top at y = 4.9) rather than
	-- at the old slab's height, so arrivals stand on the boat, not inside it.
	spawn.CFrame = CFrame.new(0, 5.4, 0)
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

	marker.PrimaryPart = disc
	marker.Parent = parent

	return marker
end

WorldGenService.REGION_SPACING = REGION_SPACING
WorldGenService.HABITAT_COLOR = HABITAT_COLOR

return WorldGenService
