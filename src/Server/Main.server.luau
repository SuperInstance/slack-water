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
local StarterGui = game:GetService("StarterGui")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

-- NOTE: `Shared.Types` on its own is a ModuleScript INSTANCE, and Roblox does
-- not proxy a module's return values onto the instance. Reading
-- `Shared.Types.RegionDiscovered` therefore yields nil in Studio exactly as it
-- did in the headless boot test — the connection below silently never happened,
-- so AI-composed grounds were announced to clients but never built into the
-- world. The module has to be required first.
local Types = require(Shared.Types)

local OceanService = require(script.Parent.OceanService)
local CastService = require(script.Parent.CastService)
local WorldGen = require(script.Parent.WorldGen)
local Environment = require(script.Parent.Environment)

local Main = {}

--- Run a boot stage in isolation.
---
--- Without this, a single failure anywhere in start() kills the rest of it and
--- you get a blank world with no idea why. Every stage reports itself, so one
--- Play tells you exactly which part broke.
local function stage(name: string, fn: () -> ()): boolean
	local ok, err = pcall(fn)
	if ok then
		print(string.format("[slack-water] boot: %s ok", name))
		return true
	end
	print(string.format("[slack-water] boot: %s FAILED -> %s", name, tostring(err)))
	return false
end

function Main.start(): ()
	-- 0. Look before anything else. A flat plane of water without atmosphere
	--    reads as a grey grid no matter how good the simulation underneath is.
	stage("environment", function()
		Environment.apply()
	end)

	-- 1. The simulation owns the truth and starts its own loops.
	local svc: any = nil
	stage("ocean service", function()
		svc = OceanService.start()
	end)

	if not svc then
		warn("[slack-water] boot aborted: the ocean never started")
		return
	end

	-- 2. The world is drawn from whatever the simulation currently believes.
	stage("worldgen", function()
		WorldGen.build(svc.ocean)
	end)

	-- 3. Only now can a cast be resolved against anything.
	stage("cast service", function()
		CastService.start()
	end)

	-- 4. New regions arrive over time; each one gets built when it is admitted.
	--
	--    A RemoteEvent has no `.Event` property in current Roblox -- it was
	--    removed. The server listens on `OnServerEvent`; the client listens on
	--    `OnClientEvent`. `remote:Connect(...)` and `remote.Event:Connect(...)`
	--    are both wrong, for different reasons.
	--
	--    This line has now been wrong in THREE different ways across the life
	--    of the project, and each version was "fixed" against a stub rather
	--    than against real Roblox. The harness had a hand-written RemoteEvent
	--    that grew an `.Event` field to satisfy the broken code, which made the
	--    30/30 green run actively misleading. The stub now models modern
	--    Roblox exactly.
	--
	--    Main wraps every stage in pcall and only prints, so every version of
	--    this bug was silent: the listener simply never existed.
	stage("region listener", function()
		svc.regionAdded.Event:Connect(function()
			task.defer(function()
				WorldGen.build(svc.ocean)
			end)
		end)
	end)

	-- Roblox's own chrome sits on top of a HUD designed for a phone: the chat
	-- box lands on the tide strip, the player list on the region panel, and the
	-- mobile jump button on the cast bar. This belongs to bootstrap rather than
	-- to any panel, because no panel should be deciding what else's chrome is
	-- allowed to do.
	--
	-- Best-effort: SetCoreGuiEnabled has changed shape across Roblox releases,
	-- and a failure here must never stop the ocean booting.
	local function quietenDefaultGui(): ()
		for _, core in {
			Enum.CoreGuiType.Chat,
			Enum.CoreGuiType.PlayerList,
			Enum.CoreGuiType.Health,
			Enum.CoreGuiType.Backpack,
			Enum.CoreGuiType.EmotesMenu,
		} do
			pcall(function()
				StarterGui:SetCoreGuiEnabled(core, false)
			end)
		end
		pcall(function()
			StarterGui:SetCore("ChatMakeSystemMessage", false)
		end)
	end

	-- Called once at boot rather than only in PlayerAdded, which is correct as
	-- well as tidier: the server call applies to every player at once, so once
	-- is enough and it also covers anyone already connected.
	stage("ui", function()
		quietenDefaultGui()
	end)

	Players.PlayerAdded:Connect(function(player: any)
		player:SetAttribute("joinedAt", os.time())

		quietenDefaultGui()

		-- Drop the player somewhere they can actually see the water. A blank
		-- slate at spawn is indistinguishable from a broken worldgen, so make
		-- the first frame unambiguous.
		task.defer(function()
			local character = player.Character or player.CharacterAdded:Wait()
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if rootPart then
				rootPart.CFrame = CFrame.new(0, 40, 90)
					* CFrame.lookAt(Vector3.new(0, 40, 90), Vector3.new(0, 0, 0))
			end
		end)
	end)

	print("[slack-water] ready")
end

Main.start()

return Main
