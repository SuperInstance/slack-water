--!strict
--[[
	WorldGen — giving the ocean a body.

	The simulation is abstract; this turns it into somewhere a player can stand.
	Roblox is roughly 80% mobile, which is the governing constraint on every
	decision here:

	- Regions are large, cheap, unmistakable markers. Players must be able to
	  find "Slack Water Flats" from a boat at a glance and on a small screen.
	- Detail goes to the water surface and the light, not to geometry. A
	  convincing ocean on a phone is about fog, colour and motion; it is not
	  about mesh density.
	- Nothing is baked. The world is built at runtime from the simulation, so a
	  region the AI invents appears with no place-file edit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OceanSim = require(Shared.Ocean.OceanSim)
local Types = require(Shared.Types)

local WorldGen = {}

-- Metres of ocean per stud. The whole playable area stays modest so the
-- streaming budget is never a problem on a phone.
local SCALE = 0.4
local REGION_SPACING = 90

-- Colour by habitat, so a player can read the map by colour alone. These are
-- deliberately distinguishable at a glance on a small, low-contrast screen.
local HABITAT_COLOR: { [string]: Color3 } = {
	kelp = Color3.fromRGB(38, 92, 66),
	reef = Color3.fromRGB(64, 108, 128),
	sand = Color3.fromRGB(126, 118, 92),
	mud = Color3.fromRGB(78, 72, 62),
	open = Color3.fromRGB(30, 58, 84),
	estuary = Color3.fromRGB(52, 84, 88),
}

local WorldGenService = {}

--- Clear any previously generated markers. Safe to call on restart.
function WorldGenService.clear(): ()
	local oceanFolder = Workspace:FindFirstChild("Ocean")
	if not oceanFolder then
		return
	end
	for _, child in oceanFolder:GetChildren() do
		child:Destroy()
	end
end

--- Build the playable representation of every region in the simulation.
---
--- Regions are laid out on a deterministic grid derived from their index, not
--- scattered randomly — a player who knows where "Outer Kelp Bed" is will find
--- it in the same place next session, which matters when the world persists.
function WorldGenService.build(ocean: any): ()
	WorldGenService.clear()

	local folder = Workspace:FindFirstChild("Ocean")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Ocean"
		folder.Parent = Workspace
	end

	for index, regionId in ocean.order do
		local region = OceanSim.getRegion(ocean, regionId)
		if region then
			WorldGenService.buildRegion(folder, region, index)
		end
	end

	print(string.format("[slack-water] worldgen: %d regions placed", #ocean.order))
end

function WorldGenService.buildRegion(parent: any, region: any, index: number): any
	-- grid layout keeps every ground at a findable, repeatable position
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
	-- and costs almost nothing to stream.
	local disc = Instance.new("Part")
	disc.Name = "Ground"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(2, 60, 60)
	disc.CFrame = CFrame.new(originX, -1, originZ) * CFrame.Angles(0, 0, math.rad(90))
	disc.Color = color
	disc.Material = Enum.Material.Slate
	disc.Anchored = true
	disc.CanCollide = false
	disc.CastShadow = false
	disc.Parent = marker

	-- Billboard so the name is legible from a boat. Offset up and forward so it
	-- does not intersect the player's head on approach.
	local label = Instance.new("BillboardGui")
	label.Name = "Label"
	label.Size = UDim2.fromOffset(220, 60)
	label.StudsOffset = Vector3.new(0, 14, 0)
	label.AlwaysOnTop = true
	label.MaxDistance = 320
	label.Parent = marker

	local text = Instance.new("TextLabel")
	text.Name = "Name"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = string.format("%s\n%d m", region.name, math.floor(region.depth))
	text.TextColor3 = Color3.fromRGB(238, 244, 248)
	text.TextStrokeTransparency = 0.35
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.Parent = label

	marker:SetPrimaryPart(disc)
	marker.Parent = parent

	return marker
end

--- Convenience for the depth band a region represents, used by the fishing UI
--- to show players where in the water column they are working.
function WorldGenService.depthBand(region: any): { number }
	return { region.depth, region.depth }
end

WorldGenService.SCALE = SCALE
WorldGenService.REGION_SPACING = REGION_SPACING
WorldGenService.HABITAT_COLOR = HABITAT_COLOR

return WorldGenService