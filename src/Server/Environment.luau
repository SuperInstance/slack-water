--!strict
--[[
	Environment — the look of the sky over the water.

	Deliberately minimal. On Roblox the difference between a place that reads as
	"a dev made this" and one that reads as a game is overwhelmingly lighting,
	fog and colour, and none of it needs geometry.

	These values are tuned for a cool North Pacific overcast morning rather than
	tropical blue. The game's whole premise is a working ocean, so the light
	should feel like weather you would actually fish in.

	The water's own colour and foam live in Shared/Ocean/Water.luau and are
	applied by Server/OceanSurface.luau. This file once tried to style a
	Terrain "Water" instance here — dead code, since nothing ever created one
	(the lookup ran twice and always returned nil) — so the sea's look now has
	one owner and this file keeps the sky.
]]

local Lighting = game:GetService("Lighting")

local Environment = {}

local TUNING = {
	-- Cool overcast morning. Not "ocean blue" — actual North Pacific light is
	-- grey-green and low contrast, and faking a postcard wastes the premise.
	ambient = Color3.fromRGB(96, 108, 116),
	outdoorAmbient = Color3.fromRGB(118, 130, 138),

	fogColor = Color3.fromRGB(146, 158, 164),
	fogEnd = 900,
	fogStart = 140,

	-- Low sun. Long shadows read as depth on a featureless ocean plane.
	timeOfDay = 7.25,

	-- Clouds matter more than any other single setting for "this is a real
	-- place" on a flat plane of water.
	cloudsDensity = 0.42,
	cloudsColor = Color3.fromRGB(202, 208, 212),
	cloudsCover = 0.62,
}

function Environment.apply(): ()
	Lighting.Ambient = TUNING.ambient
	Lighting.OutdoorAmbient = TUNING.outdoorAmbient
	Lighting.FogColor = TUNING.fogColor
	Lighting.FogStart = TUNING.fogStart
	Lighting.FogEnd = TUNING.fogEnd
	Lighting.ClockTime = TUNING.timeOfDay
	Lighting.GlobalShadows = true
	-- Lighting.Technology is a Script Security property and CANNOT be written
	-- from a normal play session -- Studio denies it outright:
	--   "The current thread cannot write 'Technology' (lacking capability)"
	-- which threw Environment.apply() and took the whole boot with it, because
	-- Main's pcall stage reported the failure and Studio only printed it.
	-- Future shading is the Studio default anyway, so this is best-effort.
	local techOk = pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	if not techOk then
		print("[slack-water] environment: leaving Lighting.Technology at the Studio default")
	end

	-- There is no `Lighting.PropertyChangedSignal` property. Every Instance
	-- exposes `GetPropertyChangedSignal(propertyName)` as a METHOD returning a
	-- signal for that one property. Reading the property threw
	--   "PropertyChangedSignal is not a valid member of Lighting"
	-- which killed Environment.apply() and therefore the whole boot stage.
	--
	-- The harness stub used to carry a fake PropertyChangedSignal property,
	-- which hid this. Found by the fidelity audit, not by a failing test.
	Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
		Lighting.ClockTime = TUNING.timeOfDay
	end)

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "SlackWaterAtmosphere"
		atmosphere.Parent = Lighting
	end
	atmosphere.Density = 0.28
	atmosphere.Offset = 0.18
	atmosphere.Color = TUNING.fogColor
	atmosphere.Decay = TUNING.fogColor
	atmosphere.Glare = 0.12
	atmosphere.Haze = 1.4

	local clouds = Lighting:FindFirstChildOfClass("Clouds")
	if not clouds then
		clouds = Instance.new("Clouds")
		clouds.Name = "SlackWaterClouds"
		clouds.Parent = Lighting
	end
	clouds.Color = TUNING.cloudsColor
	clouds.Cover = TUNING.cloudsCover
	clouds.Density = TUNING.cloudsDensity
end

Environment.TUNING = TUNING

return Environment
