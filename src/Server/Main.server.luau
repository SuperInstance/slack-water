--!strict
--[[
	Main — boot order and player lifecycle.

	Kept deliberately thin. The interesting logic lives in OceanService,
	CastService and WorldGen; this file only decides the order things start in
	and keeps the world in sync as players come and go.

	Order matters more than it looks. The simulation has to exist before world
	generation (which reads regions), and the ocean has to exist before any cast
	can be validated (which needs somewhere to cast).
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local OceanService = require(script.Parent.OceanService)
local CastService = require(script.Parent.CastService)
local WorldGen = require(script.Parent.WorldGen)
local Environment = require(script.Parent.Environment)

local Main = {}

function Main.start(): ()
	-- 0. Look before anything else. A flat plane of water without atmosphere
	--    reads as a grey grid no matter how good the simulation underneath is.
	Environment.apply()

	-- 1. The simulation owns the truth and starts its own loops.
	local svc = OceanService.start()

	-- 2. The world is drawn from whatever the simulation currently believes.
	WorldGen.build(svc.ocean)

	-- 3. Only now can a cast be resolved against anything.
	CastService.start()

	-- 4. New regions arrive over time; each one gets built when it is admitted.
	--    The service owns admission, so listen for its change rather than
	--    duplicating the logic that decides what exists.
	svc.remotes[Shared.Types.RegionDiscovered].Event:Connect(function()
		task.defer(function()
			WorldGen.build(svc.ocean)
		end)
	end)

	Players.PlayerAdded:Connect(function(player: any)
		player:SetAttribute("joinedAt", os.time())
	end)

	print("[slack-water] ready")
end

Main.start()

return Main